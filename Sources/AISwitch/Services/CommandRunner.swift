import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

/// Owns one CLI invocation. Cancellation is forwarded across the detached I/O
/// task, and signals are scoped to this invocation (never all codex/claude apps).
private final class RunningCommand: @unchecked Sendable {
    private enum StopReason { case cancelled, timedOut }
    private let lock = NSLock()
    private let process: Process
    private let outputPipe: Pipe
    private let input: Data?
    private var stopReason: StopReason?
    private var processID: pid_t?
    private var ownsProcessGroup = false
    private var finished = false
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?

    init(executable: URL, arguments: [String], environment: [String: String], input: Data?) {
        process = Process()
        outputPipe = Pipe()
        self.input = input
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input == nil ? FileHandle.nullDevice as Any : Pipe() as Any
        process.standardOutput = outputPipe
        process.standardError = outputPipe
    }

    func execute(timeout: TimeInterval) throws -> CommandResult {
        defer {
            lock.withLock {
                finished = true
                timeoutWork?.cancel()
                killWork?.cancel()
                timeoutWork = nil
                killWork = nil
            }
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        }

        try lock.withLock {
            if stopReason != nil { throw CancellationError() }
            try process.run()
            let pid = process.processIdentifier
            processID = pid
            // Foundation normally creates a new process group. Verify ownership
            // before sending a group signal, so we cannot signal the host app.
            ownsProcessGroup = pid > 0 && getpgid(pid) == pid && pid != getpgrp()
            if timeout > 0 {
                let work = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
                timeoutWork = work
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }
        try? outputPipe.fileHandleForWriting.close()
        if let input, let stdin = process.standardInput as? Pipe {
            // Payloads are far below the pipe buffer, so this cannot block
            // before the child starts reading.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try lock.withLock {
            // A child can close/redirect stdout and outlive its parent. Finish
            // stopping the owned group even when the pipe has already reached EOF.
            if stopReason != nil { signal(SIGKILL) }
            switch stopReason {
            case .cancelled: throw CancellationError()
            case .timedOut: throw AISwitchError.commandTimedOut
            case nil:
                return CommandResult(
                    exitCode: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    func cancel() { stop(.cancelled) }

    private func stop(_ reason: StopReason) {
        lock.withLock {
            guard !finished, stopReason == nil else { return }
            stopReason = reason
            timeoutWork?.cancel()
            timeoutWork = nil
            guard processID != nil else { return } // Cancellation before launch.
            signal(SIGTERM)
            // A CLI may ignore SIGTERM, or leave children holding stdout open.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard !self.finished else { return }
                    self.signal(SIGKILL)
                }
            }
            killWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Called only while holding the lock and before the invocation finishes.
    private func signal(_ value: Int32) {
        guard let pid = processID else { return }
        if ownsProcessGroup {
            kill(-pid, value)
        } else if process.isRunning {
            kill(pid, value)
        }
    }
}

enum CommandRunner {
    static func locate(_ command: String) -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidateDirectories = environmentPath.split(separator: ":").map(String.init) + [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.codex/packages/standalone/current/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        for directory in candidateDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment additions: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        let command = RunningCommand(executable: executable, arguments: arguments, environment: environment, input: input)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) {
                try command.execute(timeout: timeout)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            command.cancel()
        }
    }
}
