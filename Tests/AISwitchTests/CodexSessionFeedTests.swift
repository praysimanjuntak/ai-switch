import Foundation
import Testing
@testable import AISwitch

/// A stand-in for `~/.codex/sessions` with logs in the folder Codex would use for `day`.
private struct SessionsFixture {
    let root: URL
    let day = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchSessions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var folder: URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
    }

    func append(_ text: String, to name: String) throws {
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func remove() throws { try FileManager.default.removeItem(at: root) }
}

private func sessionMeta(user: String, account: String) -> String {
    #"{"timestamp":"2026-10-05T11:00:00.000Z","type":"session_meta","payload":{"creator_user_id":"\#(user)","creator_account_id":"\#(account)","base_instructions":{"text":"long"}}}"# + "\n"
}

private func tokenCount(at time: String, session: Int, weekly: Int) -> String {
    #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(session),"window_minutes":300,"resets_at":1791221373},"secondary":{"used_percent":\#(weekly),"window_minutes":10080,"resets_at":1791604329},"plan_type":"pro"}}}"# + "\n"
}

/// A Codex `auth.json` whose ID token names `user` in ChatGPT account `account`.
func codexAuth(user: String, account: String) -> Data {
    let claims = #"{"email":"\#(user)@example.com","https://api.openai.com/auth":{"chatgpt_user_id":"\#(user)","chatgpt_account_id":"\#(account)"}}"#
    let payload = Data(claims.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return Data(#"{"tokens":{"id_token":"e30.\#(payload).sig","access_token":"a","refresh_token":"r","account_id":"\#(account)"}}"#.utf8)
}

@Test("Usage Codex records after a turn is picked up on the next poll and attributed to the account that ran it")
func codexSessionFeedFollowsTurns() async throws {
    let sessions = try SessionsFixture()
    defer { try? sessions.remove() }
    let feed = CodexSessionFeed(root: sessions.root)
    try sessions.append(sessionMeta(user: "user-1", account: "acct-1") + tokenCount(at: "2026-10-05T11:01:00.000Z", session: 5, weekly: 1), to: "rollout-a.jsonl")

    // History from before AI Switch started is left to the regular usage check.
    #expect(await feed.poll(now: sessions.day).isEmpty)

    try sessions.append(tokenCount(at: "2026-10-05T11:02:00.000Z", session: 40, weekly: 12), to: "rollout-a.jsonl")
    let first = try #require(await feed.poll(now: sessions.day).first)
    #expect(first.identity.isSameAccount(as: AccountIdentity(user: "user-1", organization: "acct-1")))
    #expect(first.usage.session?.usedPercent == 40)
    #expect(first.usage.weekly?.usedPercent == 12)
    #expect(first.usage.fetchedAt == ISO8601DateFormatter().date(from: "2026-10-05T11:02:00Z"))
    #expect(first.plan == "pro")

    // A line Codex is still writing waits until it is complete.
    let line = tokenCount(at: "2026-10-05T11:03:00.000Z", session: 41, weekly: 12)
    try sessions.append(String(line.prefix(60)), to: "rollout-a.jsonl")
    #expect(await feed.poll(now: sessions.day).isEmpty)
    try sessions.append(String(line.dropFirst(60)), to: "rollout-a.jsonl")
    #expect(await feed.poll(now: sessions.day).first?.usage.session?.usedPercent == 41)

    // A session started later is read from its beginning, under its own account.
    try sessions.append(sessionMeta(user: "user-2", account: "acct-2") + tokenCount(at: "2026-10-05T11:04:00.000Z", session: 70, weekly: 30), to: "rollout-b.jsonl")
    let second = try #require(await feed.poll(now: sessions.day).first)
    #expect(second.identity.user == "user-2")
    #expect(second.usage.session?.usedPercent == 70)
}

@Test("A Codex turn updates the saved profile of the account that ran it, and only that one")
@MainActor
func codexTurnUpdatesMatchingProfile() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let sessions = try SessionsFixture()
    defer { try? sessions.remove() }
    func codexProfile(_ name: String, user: String, account: String) throws -> AccountProfile {
        let directory = fixture.directory.appendingPathComponent(name)
        try FileManager.default.writeOwnerOnly(codexAuth(user: user, account: account), to: directory.appendingPathComponent("auth.json"))
        return AccountProfile(id: UUID(), provider: .codex, displayName: name, email: nil, plan: "plus",
                              profileDirectory: directory.path, createdAt: Date(), lastActivatedAt: nil, usage: nil, authIssue: nil)
    }
    let personal = try codexProfile("personal", user: "user-1", account: "acct-1")
    let team = try codexProfile("team", user: "user-1", account: "acct-team")
    try fixture.save([personal, team], active: ["codex": personal.id])
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, codexSessions: sessions.root)
    try sessions.append(sessionMeta(user: "user-1", account: "acct-team"), to: "rollout-team.jsonl")
    await store.pollCodexSessions(now: sessions.day)

    try sessions.append(tokenCount(at: "2026-10-05T11:02:00.000Z", session: 55, weekly: 20), to: "rollout-team.jsonl")
    await store.pollCodexSessions(now: sessions.day)
    #expect(store.profiles.first { $0.id == team.id }?.usage?.session?.usedPercent == 55)
    #expect(store.profiles.first { $0.id == team.id }?.plan == "pro")
    #expect(store.profiles.first { $0.id == personal.id }?.usage == nil)
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, codexSessions: nil)
    #expect(reopened.profiles.first { $0.id == team.id }?.usage?.weekly?.usedPercent == 20)
}
