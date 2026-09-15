import Darwin
import Foundation
import Testing
@testable import AISwitch

private struct CommandFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchCommandTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func waitForPID(_ name: String) async throws -> pid_t {
        let url = directory.appendingPathComponent(name)
        for _ in 0..<200 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AISwitchError.commandFailed("Test process did not start")
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

@Test("Commands retain output and exit status on failure")
func commandFailureReturnsOutput() async throws {
    let result = try await CommandRunner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'sign-in failed' >&2; exit 7"]
    )
    #expect(result.exitCode == 7)
    #expect(result.output == "sign-in failed")
}

@Test("Cancelling before launch does not start the command")
@MainActor
func cancelledCommandNeverLaunches() async throws {
    let fixture = try CommandFixture()
    defer { try? fixture.remove() }
    let task = Task {
        try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "touch \"$TEST_DIRECTORY/launched\""],
            environment: ["TEST_DIRECTORY": fixture.directory.path]
        )
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
}

@Test("Cancelling stops a running CLI promptly without stopping another command")
func cancellingCommandIsScoped() async throws {
    let fixture = try CommandFixture()
    defer { try? fixture.remove() }
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["20"]
    try unrelated.run()
    defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }

    let task = Task {
        try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > \"$TEST_DIRECTORY/parent.pid\"; exec /bin/sleep 20"],
            environment: ["TEST_DIRECTORY": fixture.directory.path], timeout: 4
        )
    }
    let pid = try await fixture.waitForPID("parent.pid")
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(kill(pid, 0) == -1)
    #expect(unrelated.isRunning)
}

@Test("Cancellation force-stops CLI children, including ones that close stdout", arguments: [false, true])
func cancellationStopsStubbornChildren(redirectOutput: Bool) async throws {
    let fixture = try CommandFixture()
    defer { try? fixture.remove() }
    let script = #"""
    \#(redirectOutput ? ":" : "trap '' TERM")
    /bin/sh -c 'trap "" TERM; echo $$ > "$TEST_DIRECTORY/child.pid"; exec /bin/sleep 20' \#(redirectOutput ? ">/dev/null 2>&1" : "") &
    echo $$ > "$TEST_DIRECTORY/parent.pid"
    wait
    """#
    let task = Task {
        try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: ["TEST_DIRECTORY": fixture.directory.path], timeout: 4
        )
    }
    let parent = try await fixture.waitForPID("parent.pid")
    let child = try await fixture.waitForPID("child.pid")
    #expect(getpgid(parent) == parent)
    #expect(getpgid(child) == parent)
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(kill(parent, 0) == -1)
    // An orphaned child can briefly remain as a zombie until launchd reaps it.
    let status = try await CommandRunner.run(
        executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-o", "stat=", "-p", String(child)]
    )
    #expect(status.output.isEmpty || status.output.hasPrefix("Z"))
}

@Test("A stuck command times out with an actionable error")
func commandTimeoutIsBounded() async throws {
    let start = ContinuousClock.now
    do {
        _ = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 20"], timeout: 0.15
        )
        Issue.record("Expected timeout")
    } catch AISwitchError.commandTimedOut {}
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test("A failed launch finishes normally without lingering cancellation work")
func commandLaunchFailureCanBeRetried() async throws {
    await #expect(throws: (any Error).self) {
        try await CommandRunner.run(executable: URL(fileURLWithPath: "/nonexistent/ai-switch-test"), arguments: [])
    }
    let retry = try await CommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    #expect(retry.exitCode == 0)
}
