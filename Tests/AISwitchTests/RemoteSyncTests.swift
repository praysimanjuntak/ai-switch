import Foundation
import Testing
@testable import AISwitch

/// Records every request the sync sends; answers with a fixed status.
private actor TransportProbe {
    private(set) var requests: [URLRequest] = []
    var status = 204
    var body = Data()

    func record(_ request: URLRequest) -> HTTPReply {
        requests.append(request)
        return HTTPReply(status: status, body: body)
    }
}

private func unsignedJWT(exp: TimeInterval) -> String {
    let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
    let payload = Data(#"{"exp":\#(Int(exp)),"iss":"https://auth.openai.com"}"#.utf8).base64EncodedString()
    let strip = { (s: String) in s.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
    return "\(strip(header)).\(strip(payload)).sig"
}

@Test("The push carries each CLI's access token and expiry but never a refresh token")
func payloadCarriesAccessTokensOnly() throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let codexDir = fixture.directory.appendingPathComponent("codex-profile")
    let access = unsignedJWT(exp: 1_800_000_000)
    try FileManager.default.writeOwnerOnly(Data(#"""
    {"tokens":{"access_token":"\#(access)","refresh_token":"rt-secret","account_id":"acct-1","id_token":"idt"},"last_refresh":"x"}
    """#.utf8), to: codexDir.appendingPathComponent("auth.json"))
    try FileManager.default.writeOwnerOnly(Data(#"""
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-secret","expiresAt":1800003600000,"subscriptionType":"max"}}
    """#.utf8), to: ClaudeCredentialStore.credentialURL(configDirectory: URL(fileURLWithPath: fixture.profile.profileDirectory)))
    var codex = RefreshFixture.claudeProfile(named: "Work", directory: codexDir)
    codex = AccountProfile(id: codex.id, provider: .codex, displayName: "Work", email: "w@example.com", plan: "plus",
                           profileDirectory: codexDir.path, createdAt: Date(), lastActivatedAt: nil, usage: nil, authIssue: nil)

    let payload = RemoteSync.payload(profiles: [fixture.profile, codex], activeProfileIDs: ["claude": fixture.profile.id],
                                     now: Date(timeIntervalSince1970: 1_799_000_000))
    let claude = try #require(payload.accounts.first { $0.provider == .claude })
    #expect(claude.isActive)
    #expect(claude.token?.accessToken == "sk-ant-oat01-x")
    #expect(claude.token?.expiresAt == Date(timeIntervalSince1970: 1_800_003_600))
    #expect(claude.usage?.session?.usedPercent == 12)
    let pushed = try #require(payload.accounts.first { $0.provider == .codex })
    #expect(!pushed.isActive)
    #expect(pushed.token?.accessToken == access)
    #expect(pushed.token?.accountId == "acct-1")
    #expect(pushed.token?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
    #expect(!json.contains("rt-secret"))
    #expect(!json.contains("sk-ant-ort01"))
    #expect(!json.lowercased().contains("refresh"))
    #expect(json.contains("\"pushedAt\":\"2027-01-"))
}

@Test("A profile without a readable credential is pushed without a token rather than dropped")
func payloadWithoutCredentialHasNoToken() throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let payload = RemoteSync.payload(profiles: [fixture.profile], activeProfileIDs: [:])
    #expect(payload.accounts.count == 1)
    #expect(payload.accounts[0].token == nil)
}

@Test("Bursts of state changes coalesce into one authenticated push")
@MainActor
func pushesAreDebounced() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = TransportProbe()
    let sync = RemoteSync(directory: fixture.directory, transport: { await probe.record($0) }, debounce: .milliseconds(50))
    try sync.configure(serverURL: URL(string: "https://sync.example/")!, pushSecret: "secret-secret-secret")
    for _ in 0..<5 { sync.schedulePush(profiles: [fixture.profile], activeProfileIDs: [:]) }
    try await Task.sleep(for: .milliseconds(300))
    let requests = await probe.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.absoluteString == "https://sync.example/api/devices/\(sync.settings!.deviceID.uuidString)/accounts")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-secret-secret")
    #expect(sync.lastPushAt != nil)
    #expect(sync.lastError == nil)

    let reopened = RemoteSync(directory: fixture.directory, transport: { await probe.record($0) })
    #expect(reopened.settings == sync.settings)
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("sync.json").path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test("A rejected push secret is surfaced and pairing links come from the server")
@MainActor
func serverErrorsAreReported() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = TransportProbe()
    let sync = RemoteSync(directory: fixture.directory, transport: { await probe.record($0) }, debounce: .milliseconds(10))
    try sync.configure(serverURL: URL(string: "https://sync.example")!, pushSecret: "secret-secret-secret")
    await probe.setStatus(401)
    sync.schedulePush(profiles: [], activeProfileIDs: [:])
    await sync.flush()
    #expect(sync.lastError?.contains("push secret") == true)

    await probe.setStatus(201)
    await probe.setBody(Data(#"{"token":"abc","url":"https://sync.example/#v=abc"}"#.utf8))
    let link = try await sync.createViewerLink()
    #expect(link.absoluteString == "https://sync.example/#v=abc")
    #expect(await probe.requests.last?.httpMethod == "POST")
}

private extension TransportProbe {
    func setStatus(_ value: Int) { status = value }
    func setBody(_ value: Data) { body = value }
}
