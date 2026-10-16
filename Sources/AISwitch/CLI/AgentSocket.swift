import Darwin
import Foundation

/// The Unix socket in AI Switch's support folder that `aiswitch` and the running
/// app talk over: one JSON request line in, one JSON answer line out. The folder
/// is owner-only and the socket file is 0600, and the app also checks that the
/// connecting process runs as the same user.
enum AgentSocket {
    static let fileName = "cli.sock"

    enum Failure: LocalizedError {
        /// Nothing listens: the app isn't running, or it quit and left the socket file.
        case notRunning
        case message(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "AI Switch isn't running."
            case .message(let message): message
            }
        }
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Sends one request and waits for the answer.
    static func send(_ request: AgentRequest, to path: String, timeout: TimeInterval = 60) throws -> AgentResponse {
        let connection = socket(AF_UNIX, SOCK_STREAM, 0)
        guard connection >= 0 else { throw Failure.message("Couldn't reach AI Switch: \(lastError).") }
        defer { close(connection) }
        configure(connection, timeout: timeout)
        guard try withAddress(path, { connect(connection, $0, $1) }) == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw Failure.notRunning }
            throw Failure.message("Couldn't reach AI Switch: \(lastError).")
        }
        var line = try encoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        try writeAll(connection, line)
        let answer = try readLine(connection, limit: 8 << 20)
        guard let response = try? decoder().decode(AgentResponse.self, from: answer) else {
            throw Failure.message("AI Switch answered in a way aiswitch doesn't understand. Update both to the same version.")
        }
        return response
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.message("The path to AI Switch's support folder is too long for its command socket.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Blocking reads and writes that give up after `timeout`, and a closed peer
    /// that fails the write instead of raising SIGPIPE, which would end the process.
    static func configure(_ connection: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads up to the first newline, or to the end of the stream.
    static func readLine(_ connection: Int32, limit: Int) throws -> Data {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(connection, &chunk, chunk.count)
            if count > 0 {
                if let end = chunk[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                    line.append(contentsOf: chunk[..<end])
                    return line
                }
                line.append(contentsOf: chunk[..<count])
                guard line.count <= limit else { throw Failure.message("The message from the other side was too long.") }
            } else if count == 0 {
                return line
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw Failure.message("AI Switch took too long to answer.")
            } else {
                throw Failure.message("Couldn't reach AI Switch: \(lastError).")
            }
        }
    }

    static func writeAll(_ connection: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(connection, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw Failure.message("Couldn't reach AI Switch: \(lastError).")
                }
            }
        }
    }

    private static var lastError: String { String(cString: strerror(errno)) }
}

/// Answers `aiswitch` while the app runs. Each connection carries one request,
/// handled on the store's main actor like the window's own actions.
final class AgentCommandServer: @unchecked Sendable {
    private let path: String
    private let source: DispatchSourceRead

    init(path: String, handle: @escaping @Sendable (AgentRequest) async -> AgentResponse) throws {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AgentSocket.Failure.message("Couldn't open the aiswitch socket.") }
        unlink(path) // Left by a run that ended without closing it.
        var ready = try AgentSocket.withAddress(path) { bind(listener, $0, $1) } == 0
        ready = ready && chmod(path, 0o600) == 0 && listen(listener, 16) == 0
        ready = ready && fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK) != -1
        guard ready else {
            let reason = String(cString: strerror(errno))
            close(listener)
            throw AgentSocket.Failure.message("Couldn't open the aiswitch socket: \(reason).")
        }
        self.path = path
        let queue = DispatchQueue(label: "com.pray.AISwitch.aiswitch")
        source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { break }
                Self.serve(client, on: queue, handle: handle)
            }
        }
        source.setCancelHandler { close(listener) }
        source.resume()
    }

    deinit {
        source.cancel()
        unlink(path)
    }

    private static func serve(_ client: Int32, on queue: DispatchQueue,
                              handle: @escaping @Sendable (AgentRequest) async -> AgentResponse) {
        var user = uid_t()
        var group = gid_t()
        guard getpeereid(client, &user, &group) == 0, user == getuid() else {
            close(client)
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        AgentSocket.configure(client, timeout: 5)
        guard let line = try? AgentSocket.readLine(client, limit: 64 * 1024),
              let request = try? AgentSocket.decoder().decode(AgentRequest.self, from: line) else {
            reply(.failure("AI Switch didn't understand that request. Update aiswitch and AI Switch to the same version."), to: client)
            return
        }
        Task {
            let response = await handle(request)
            queue.async { reply(response, to: client) }
        }
    }

    private static func reply(_ response: AgentResponse, to client: Int32) {
        if var line = try? AgentSocket.encoder().encode(response) {
            line.append(UInt8(ascii: "\n"))
            try? AgentSocket.writeAll(client, line)
        }
        close(client)
    }
}
