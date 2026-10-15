import Foundation
import Testing
@testable import AISwitch

/// Claude Code's config and profile folders in a temporary directory.
private struct ClaudeCodeFixture {
    let directory: URL
    var config: URL { directory.appendingPathComponent(".claude.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitchClaudeConfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A profile folder as Claude Code leaves it after `account` signed in there.
    func profile(_ name: String, signedInAs account: [String: Any]?) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let account { try writeConfig(["oauthAccount": account, "numStartups": 1], to: folder) }
        return folder
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

/// Writes `<folder>/.claude.json`.
private func writeConfig(_ object: [String: Any], to folder: URL) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent(".claude.json"))
}

private func config(at file: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
}

private func personal() -> [String: Any] {
    ["accountUuid": "user-pray", "emailAddress": "pray@example.com", "organizationUuid": "org-personal",
     "organizationName": "pray@example.com's Organization", "billingType": "stripe_subscription"]
}

private func team() -> [String: Any] {
    ["accountUuid": "user-ai", "emailAddress": "ai@example.com", "organizationUuid": "org-team",
     "organizationName": "Team", "organizationRole": "user"]
}

private let teamIdentity = AccountIdentity(user: "user-ai", organization: "org-team", email: "ai@example.com")

@Test("A switch makes Claude Code name the new account, copied whole from its own record, keeping every other setting")
func switchCopiesTheAccountRecord() async throws {
    let fixture = try ClaudeCodeFixture()
    defer { try? fixture.remove() }
    let projects: [String: Any] = ["/Users/me/code": ["allowedTools": ["Bash"]]]
    try writeConfig(["oauthAccount": personal(), "numStartups": 42, "projects": projects], to: fixture.directory)
    let profile = try fixture.profile("team", signedInAs: team())

    #expect(try await ClaudeAccountRecord.point(fixture.config, at: profile, identity: teamIdentity))

    let root = try config(at: fixture.config)
    #expect((root["oauthAccount"] as? NSDictionary)?.isEqual(to: team()) == true)
    #expect(root["numStartups"] as? Int == 42)
    #expect((root["projects"] as? NSDictionary)?.isEqual(to: projects) == true)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.config.path)[.posixPermissions] as? Int == 0o600)
    #expect(!FileManager.default.fileExists(atPath: fixture.config.path + ".lock"))
}

@Test("A record that already names the account is left as Claude Code keeps it")
func currentRecordIsLeftAlone() async throws {
    let fixture = try ClaudeCodeFixture()
    defer { try? fixture.remove() }
    var refreshed = team()
    refreshed["billingType"] = "invoice"
    try writeConfig(["oauthAccount": refreshed], to: fixture.directory)
    let before = try Data(contentsOf: fixture.config)
    let profile = try fixture.profile("team", signedInAs: team())

    #expect(try await !ClaudeAccountRecord.point(fixture.config, at: profile, identity: teamIdentity))
    #expect(try Data(contentsOf: fixture.config) == before)
}

@Test("Without Claude Code's own record of the account, the bare account is written, with nothing of the previous one")
func bareAccountReplacesAnotherAccountsRecord() async throws {
    let fixture = try ClaudeCodeFixture()
    defer { try? fixture.remove() }
    // An imported profile has no record; this other one holds another account's, which is never copied.
    for profile in [try fixture.profile("imported", signedInAs: nil), try fixture.profile("mismatched", signedInAs: personal())] {
        try writeConfig(["oauthAccount": personal()], to: fixture.directory)
        #expect(try await ClaudeAccountRecord.point(fixture.config, at: profile, identity: teamIdentity))
        let record = try config(at: fixture.config)["oauthAccount"] as? NSDictionary
        #expect(record?.isEqual(to: ["accountUuid": "user-ai", "emailAddress": "ai@example.com", "organizationUuid": "org-team"]) == true)
    }
}

@Test("Nothing is written while Claude Code holds its config lock; a lock it abandoned is taken over")
func waitsForClaudeCodesLock() async throws {
    let fixture = try ClaudeCodeFixture()
    defer { try? fixture.remove() }
    try writeConfig(["oauthAccount": personal()], to: fixture.directory)
    let profile = try fixture.profile("team", signedInAs: team())
    let lock = fixture.config.path + ".lock"
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)

    let config = fixture.config
    let switching = Task { try await ClaudeAccountRecord.point(config, at: profile, identity: teamIdentity) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(ClaudeAccountRecord.identity(inConfigAt: config)?.user == "user-pray")
    try FileManager.default.removeItem(atPath: lock)
    #expect(try await switching.value)
    #expect(ClaudeAccountRecord.identity(inConfigAt: config)?.user == "user-ai")

    try writeConfig(["oauthAccount": personal()], to: fixture.directory)
    try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock)
    #expect(try await ClaudeAccountRecord.point(config, at: profile, identity: teamIdentity))
    #expect(!FileManager.default.fileExists(atPath: lock))
}

// MARK: Through the store

/// The fixture's account signed in as `team()` in its folder, Claude Code's config
/// naming `liveRecord`, and a store whose live Claude Code uses that config.
@MainActor
private func store(liveRecord: [String: Any], live: LiveClaudeStub, fixture: RefreshFixture,
                   identify: (@Sendable (AIProvider, Data) async -> AccountIdentity?)? = nil,
                   extra: [AccountProfile] = []) async throws -> (AccountStore, URL) {
    try writeCredential("mine", of: fixture.profile)
    try writeConfig(["oauthAccount": team()], to: URL(fileURLWithPath: fixture.profile.profileDirectory))
    try writeConfig(["oauthAccount": liveRecord], to: fixture.directory)
    var claudeCode = await live.credential
    claudeCode.config = fixture.directory.appendingPathComponent(".claude.json")
    let store = identify.map {
        AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                     inspect: { _ in ProviderInspection() }, identify: $0, liveClaude: claudeCode)
    } ?? AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                      inspect: { _ in ProviderInspection() }, liveClaude: claudeCode)
    return (store, fixture.directory.appendingPathComponent(".claude.json"))
}

@Test("Switching Claude accounts makes Claude Code show the account switched to")
@MainActor
func switchingPointsClaudeCodeAtTheAccount() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let previous = RefreshFixture.claudeProfile(named: "Personal", directory: fixture.directory.appendingPathComponent("personal"))
    try fixture.save([previous, fixture.profile], active: ["claude": previous.id])
    try writeCredential("previous", of: previous)
    let live = LiveClaudeStub("previous")
    let (store, liveConfig) = try await store(liveRecord: personal(), live: live, fixture: fixture)

    try await store.activate(fixture.profile.id)

    #expect(await live.stored == Data("mine".utf8))
    #expect(ClaudeAccountRecord.identity(inConfigAt: liveConfig)?.email == "ai@example.com")
    #expect(store.errorMessage == nil)
}

@Test("A check repairs Claude Code's record of the active account when it still names another one")
@MainActor
func checkRepairsClaudeCodesRecord() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let (store, liveConfig) = try await store(liveRecord: personal(), live: LiveClaudeStub("mine"), fixture: fixture)

    await store.refresh(fixture.profile.id)

    #expect(ClaudeAccountRecord.identity(inConfigAt: liveConfig)?.email == "ai@example.com")
}

@Test("After Claude Code signs in to another account itself, its record of that account is kept")
@MainActor
func claudeCodesOwnSignInKeepsItsRecord() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let other: [String: Any] = ["accountUuid": "other", "emailAddress": "other@example.com"]
    let (store, liveConfig) = try await store(liveRecord: other, live: LiveClaudeStub("someone-else"), fixture: fixture,
                                              identify: identities(["mine": "user-ai", "someone-else": "other"]))

    await store.refresh(fixture.profile.id)

    #expect(ClaudeAccountRecord.identity(inConfigAt: liveConfig)?.email == "other@example.com")
}
