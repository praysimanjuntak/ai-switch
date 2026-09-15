import Combine
import Foundation

/// Connection to a self-hosted ai-switch-sync server (see `Server/`). Stored
/// beside the profiles as `sync.json`, owner-only, because it holds the push secret.
struct RemoteSyncSettings: Codable, Equatable, Sendable {
    var serverURL: URL
    var pushSecret: String
    var deviceID: UUID
}

/// What the Mac sends. Access tokens only: refresh tokens never leave this Mac,
/// so the server can read usage but can never renew or rotate a login.
struct PushedAccount: Codable, Equatable, Sendable {
    struct Token: Codable, Equatable, Sendable {
        var accessToken: String
        var accountId: String?
        var expiresAt: Date?
    }

    var id: UUID
    var provider: AIProvider
    var displayName: String
    var email: String?
    var plan: String?
    var isActive: Bool
    var token: Token?
    var usage: UsageSnapshot?
}

struct PushPayload: Codable, Equatable, Sendable {
    var pushedAt: Date
    var accounts: [PushedAccount]
}

struct HTTPReply: Sendable {
    let status: Int
    let body: Data
}

@MainActor
final class RemoteSync: ObservableObject {
    typealias Transport = @Sendable (URLRequest) async throws -> HTTPReply

    @Published private(set) var settings: RemoteSyncSettings?
    @Published private(set) var lastPushAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isPushing = false

    private let fileURL: URL
    private let transport: Transport
    private let debounce: Duration
    private var pending: Task<Void, Never>?
    private var queued: PushPayload?

    init(directory: URL, transport: @escaping Transport = RemoteSync.urlSessionTransport, debounce: Duration = .seconds(1.5)) {
        fileURL = directory.appendingPathComponent("sync.json")
        self.transport = transport
        self.debounce = debounce
        if let data = try? Data(contentsOf: fileURL) {
            settings = try? JSONDecoder().decode(RemoteSyncSettings.self, from: data)
        }
    }

    var isConfigured: Bool { settings != nil }

    func configure(serverURL: URL, pushSecret: String) throws {
        let secret = pushSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = serverURL.scheme?.lowercased(), ["https", "http"].contains(scheme), serverURL.host != nil else {
            throw AISwitchError.invalidResponse("Enter the sync server address as https://host.")
        }
        guard secret.count >= 16 else {
            throw AISwitchError.invalidResponse("The push secret must be at least 16 characters.")
        }
        var normalized = serverURL
        if normalized.path.hasSuffix("/") { normalized = URL(string: String(normalized.absoluteString.dropLast())) ?? normalized }
        let updated = RemoteSyncSettings(serverURL: normalized, pushSecret: secret, deviceID: settings?.deviceID ?? UUID())
        try FileManager.default.writeOwnerOnly(JSONEncoder().encode(updated), to: fileURL)
        settings = updated
        lastError = nil
    }

    func disconnect() {
        pending?.cancel()
        pending = nil
        queued = nil
        settings = nil
        lastPushAt = nil
        lastError = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Coalesces bursts of state changes (a refresh-all touches every account)
    /// into one push. Credentials are read from the profile directories at push
    /// time so the server always gets the tokens the CLIs currently hold.
    func schedulePush(profiles: [AccountProfile], activeProfileIDs: [String: UUID]) {
        guard settings != nil else { return }
        queued = Self.payload(profiles: profiles, activeProfileIDs: activeProfileIDs)
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.pushQueued()
        }
    }

    /// Waits for a scheduled push to finish. Used after configuring and by tests.
    func flush() async {
        pending?.cancel()
        pending = nil
        await pushQueued()
    }

    private func pushQueued() async {
        guard let settings, let payload = queued else { return }
        queued = nil
        isPushing = true
        defer { isPushing = false }
        do {
            var request = URLRequest(url: settings.serverURL.appendingPathComponent("api/devices/\(settings.deviceID.uuidString)/accounts"))
            request.httpMethod = "PUT"
            request.httpBody = try JSONEncoder.sync.encode(payload)
            let reply = try await send(request, settings: settings)
            guard reply.status == 204 else { throw Self.serverError(reply) }
            lastPushAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Mints a read-only pairing link for one phone. Encoded in the QR code; the
    /// token rides in the URL fragment, which browsers never send to the server.
    func createViewerLink() async throws -> URL {
        guard let settings else { throw AISwitchError.invalidResponse("Connect a sync server first.") }
        var request = URLRequest(url: settings.serverURL.appendingPathComponent("api/devices/\(settings.deviceID.uuidString)/viewers"))
        request.httpMethod = "POST"
        let reply = try await send(request, settings: settings)
        guard reply.status == 201,
              let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let link = object["url"] as? String, let url = URL(string: link) else {
            throw Self.serverError(reply)
        }
        return url
    }

    func revokeViewers() async throws {
        guard let settings else { return }
        var request = URLRequest(url: settings.serverURL.appendingPathComponent("api/devices/\(settings.deviceID.uuidString)/viewers"))
        request.httpMethod = "DELETE"
        let reply = try await send(request, settings: settings)
        guard reply.status == 200 else { throw Self.serverError(reply) }
    }

    private func send(_ request: URLRequest, settings: RemoteSyncSettings) async throws -> HTTPReply {
        var request = request
        request.timeoutInterval = 20
        request.setValue("Bearer \(settings.pushSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ai-switch/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return try await transport(request)
    }

    private static func serverError(_ reply: HTTPReply) -> AISwitchError {
        if reply.status == 401 { return .invalidResponse("The sync server rejected the push secret.") }
        let detail = (try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any])?["error"] as? String
        return .invalidResponse("Sync server error (HTTP \(reply.status))\(detail.map { ": \($0)" } ?? ".")")
    }

    nonisolated static func payload(profiles: [AccountProfile], activeProfileIDs: [String: UUID], now: Date = Date()) -> PushPayload {
        PushPayload(pushedAt: now, accounts: profiles.map { profile in
            PushedAccount(
                id: profile.id,
                provider: profile.provider,
                displayName: profile.displayName,
                email: profile.email,
                plan: profile.plan,
                isActive: activeProfileIDs[profile.provider.rawValue] == profile.id,
                token: accessToken(for: profile),
                usage: profile.usage
            )
        })
    }

    /// The CLI's current access token for a profile, or nil when the profile has
    /// no readable credential. Never includes the refresh token.
    nonisolated static func accessToken(for profile: AccountProfile) -> PushedAccount.Token? {
        let directory = URL(fileURLWithPath: profile.profileDirectory)
        switch profile.provider {
        case .codex:
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String else { return nil }
            return PushedAccount.Token(accessToken: access, accountId: tokens["account_id"] as? String, expiresAt: jwtExpiry(access))
        case .claude:
            guard let data = try? Data(contentsOf: ClaudeCredentialStore.credentialURL(configDirectory: directory)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["claudeAiOauth"] as? [String: Any],
                  let access = oauth["accessToken"] as? String else { return nil }
            let expiry = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return PushedAccount.Token(accessToken: access, accountId: nil, expiresAt: expiry)
        }
    }

    /// `exp` from an unverified JWT payload; the server only uses it to know when
    /// to stop trying a token.
    nonisolated static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
        guard let data = Data(base64Encoded: segment),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static let urlSessionTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AISwitchError.invalidResponse("The sync server returned an unexpected response.")
        }
        return HTTPReply(status: http.statusCode, body: data)
    }
}

private extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
