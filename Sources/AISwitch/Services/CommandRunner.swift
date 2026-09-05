import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
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
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            additions.forEach { environment[$0.key] = $0.value }
            process.environment = environment
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let box = ProcessBox(process)
            try process.run()

            if timeout > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if box.process.isRunning {
                        box.process.terminate()
                    }
                }
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandResult(exitCode: process.terminationStatus, output: output)
        }.value
    }
}
