import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

/// A running CLI whose stdin and stdout the caller drives line by line.
struct CommandSession: Sendable {
    /// Writes `line` plus "\n" to the child's stdin.
    let send: @Sendable (String) throws -> Void
    /// stdout and stderr merged, one element per line (no trailing newline), ending at EOF.
    let lines: AsyncStream<String>
}

/// Owns one CLI invocation. Cancellation is forwarded across the detached I/O
/// task, and signals are scoped to this invocation (never all codex/claude apps).
private final class RunningCommand: @unchecked Sendable {
    private enum StopReason { case cancelled, timedOut }
    private let lock = NSLock()
    private let process: Process
    private let outputPipe: Pipe
    private let inputPipe: Pipe?
    private let input: Data?
    private var stopReason: StopReason?
    private var processID: pid_t?
    private var ownsProcessGroup = false
    private var finished = false
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?,
        directory: URL? = nil,
        interactive: Bool = false
    ) {
        process = Process()
        outputPipe = Pipe()
        // `interact` drives stdin line by line; `run` only needs a pipe when it
        // has a payload to hand over.
        inputPipe = input == nil && !interactive ? nil : Pipe()
        self.input = input
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
    }

    /// Runs the process and arms the timeout. Called only while holding the lock.
    private func start(timeout: TimeInterval) throws {
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

        try lock.withLock { try start(timeout: timeout) }
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

    /// Starts the process with the timeout armed and hands back a line-oriented
    /// view of it. Always pair with `finish()`, which stops and reaps the child.
    func launch(timeout: TimeInterval) throws -> CommandSession {
        do {
            try lock.withLock { try start(timeout: timeout) }
        } catch {
            lock.withLock {
                finished = true
                timeoutWork?.cancel()
                timeoutWork = nil
            }
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            throw error
        }
        try? outputPipe.fileHandleForWriting.close()
        if let inputPipe {
            // Report EPIPE to the caller rather than raising SIGPIPE in the host
            // app when it writes to a child that has already exited.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        let lines = AsyncStream<String> { continuation in
            // Blocking reads belong on a Dispatch thread rather than in the
            // cooperative pool: a grandchild holding stdout open parks this pump
            // until it closes, long after the invocation itself is done.
            DispatchQueue.global(qos: .userInitiated).async { [self] in pump(into: continuation) }
        }
        return CommandSession(send: { [self] line in try write(line) }, lines: lines)
    }

    /// Splits the merged output pipe into lines until it reaches EOF.
    private func pump(into continuation: AsyncStream<String>.Continuation) {
        let handle = outputPipe.fileHandleForReading
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
        continuation.finish()
    }

    private func write(_ line: String) throws {
        guard let inputPipe else {
            throw AISwitchError.commandFailed("This command was started without an interactive stdin.")
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Stops the child, reaps it, and reports an abnormal end. Mirrors the
    /// teardown `execute` performs once its output pipe reaches EOF.
    func finish() async throws {
        stopAfterSession()
        await Task.detached(priority: .userInitiated) { [self] in process.waitUntilExit() }.value
        let reason: StopReason? = lock.withLock {
            // A child can close/redirect stdout and outlive its parent. Finish
            // stopping the owned group even when the pipe has already reached EOF.
            if stopReason != nil { signal(SIGKILL) }
            finished = true
            timeoutWork?.cancel()
            killWork?.cancel()
            timeoutWork = nil
            killWork = nil
            return stopReason
        }
        try? inputPipe?.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        // The read end belongs to the pump until EOF: closing it under a blocked
        // read would trap. It goes away with the pipe once the pump returns.
        switch reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw AISwitchError.commandTimedOut
        case nil: break
        }
    }

    func cancel() { stop(.cancelled) }

    private func stop(_ reason: StopReason) {
        lock.withLock {
            guard !finished, stopReason == nil else { return }
            stopReason = reason
            timeoutWork?.cancel()
            timeoutWork = nil
            requestStop()
        }
    }

    /// The caller is done with the session: stop the child without recording a
    /// failure, so a completed handshake still reports success.
    private func stopAfterSession() {
        lock.withLock {
            guard !finished, stopReason == nil else { return }
            timeoutWork?.cancel()
            timeoutWork = nil
            requestStop()
        }
    }

    /// Called only while holding the lock and before the invocation finishes.
    private func requestStop() {
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
        directory: URL? = nil,
        timeout: TimeInterval = 30
    ) async throws -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        let command = RunningCommand(
            executable: executable, arguments: arguments, environment: environment,
            input: input, directory: directory
        )
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

    /// Launches `executable`, hands the session to `body`, and stops the child
    /// (SIGTERM, then SIGKILL) as soon as `body` returns or throws. The child is
    /// always reaped before this returns. Timeout and task cancellation stop the
    /// child and surface as `AISwitchError.commandTimedOut` / `CancellationError`
    /// exactly like `run`, taking precedence over whatever `body` threw because
    /// its stream ended early.
    static func interact<T: Sendable>(
        executable: URL,
        arguments: [String],
        environment additions: [String: String] = [:],
        timeout: TimeInterval = 30,
        _ body: @Sendable (CommandSession) async throws -> T
    ) async throws -> T {
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        let command = RunningCommand(
            executable: executable, arguments: arguments, environment: environment,
            input: nil, interactive: true
        )
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let session = try command.launch(timeout: timeout)
            let outcome: Result<T, any Error>
            do {
                outcome = .success(try await body(session))
            } catch {
                outcome = .failure(error)
            }
            try await command.finish()
            try Task.checkCancellation()
            return try outcome.get()
        } onCancel: {
            command.cancel()
        }
    }
}
