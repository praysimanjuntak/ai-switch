import Foundation
import Testing
@testable import AISwitch

struct RefreshFixture {
    let directory: URL
    let profile: AccountProfile

    init(active: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profile = Self.claudeProfile(named: "Saved account", directory: directory.appendingPathComponent("saved"))
        try save([profile], active: active ? ["claude": profile.id] : [:])
    }

    static func claudeProfile(named name: String, directory: URL) -> AccountProfile {
        AccountProfile(
            id: UUID(), provider: .claude, displayName: name,
            email: "saved@example.com", plan: "max", profileDirectory: directory.path,
            createdAt: Date(), lastActivatedAt: nil,
            usage: UsageSnapshot(session: UsageWindow(usedPercent: 12, resetsAt: nil),
                                 weekly: nil, fetchedAt: Date(), note: nil),
            authIssue: nil
        )
    }

    func save(_ profiles: [AccountProfile], active: [String: UUID]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(StoredState(profiles: profiles, activeProfileIDs: active))
            .write(to: directory.appendingPathComponent("profiles.json"))
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

/// Stands in for the credential Claude Code reads for new sessions.
actor LiveClaudeStub {
    private(set) var stored: Data?
    private(set) var writes: [Data] = []

    init(_ initial: String?) { stored = initial.map { Data($0.utf8) } }

    var credential: LiveClaudeCredential {
        LiveClaudeCredential(read: { await self.stored }, write: { await self.write($0) }, deleteProfileItem: { _ in })
    }

    /// Claude Code changes its own credential: it refreshed it, or signed in again.
    func cliStores(_ text: String) {
        stored = Data(text.utf8)
    }

    private func write(_ data: Data) {
        stored = data
        writes.append(data)
    }
}

/// Stands in for `CredentialIdentity.identify`: test credentials are plain text,
/// and `owners` names the user each one belongs to.
func identities(_ owners: [String: String]) -> @Sendable (AIProvider, Data) async -> AccountIdentity? {
    { _, credential in
        owners[String(decoding: credential, as: UTF8.self)].map {
            AccountIdentity(user: $0, organization: nil, email: "\($0)@example.com")
        }
    }
}

func writeCredential(_ text: String, of profile: AccountProfile) throws {
    try FileManager.default.writeOwnerOnly(Data(text.utf8), to: ClaudeCredentialStore.credentialURL(
        configDirectory: URL(fileURLWithPath: profile.profileDirectory)))
}

func savedCredential(of profile: AccountProfile) -> String? {
    let url = ClaudeCredentialStore.credentialURL(configDirectory: URL(fileURLWithPath: profile.profileDirectory))
    return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

private actor InspectionProbe {
    private(set) var calls = 0
    private var suspend: Bool
    private var pending: [CheckedContinuation<ProviderInspection, Never>] = []
    private var started: CheckedContinuation<Void, Never>?

    init(suspend: Bool = false) {
        self.suspend = suspend
    }

    func inspect(_ profile: AccountProfile) async throws -> ProviderInspection {
        calls += 1
        started?.resume()
        started = nil
        if suspend {
            return await withCheckedContinuation { pending.append($0) }
        }
        return result
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    /// Resumes every suspended inspection and lets later ones return at once.
    func finish() {
        suspend = false
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume(returning: result) }
    }

    private var result: ProviderInspection {
        ProviderInspection(email: nil, plan: nil,
                           usage: UsageSnapshot(session: UsageWindow(usedPercent: 25, resetsAt: nil),
                                                weekly: nil, fetchedAt: Date(), note: nil))
    }
}

@Test("Refreshing all accounts checks them at the same time, not one after another")
@MainActor
func refreshAllRunsConcurrently() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let second = RefreshFixture.claudeProfile(named: "Second", directory: fixture.directory.appendingPathComponent("second"))
    try fixture.save([fixture.profile, second], active: [:])
    let probe = InspectionProbe(suspend: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { try await probe.inspect($0) })
    let all = Task { await store.refreshAll() }
    // Sequential refreshes would never start the second check while the first is suspended.
    for _ in 0..<100 {
        if await probe.calls >= 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.calls == 2)
    #expect(store.refreshingProfileIDs == [fixture.profile.id, second.id])
    await probe.finish()
    await all.value
    #expect(!store.isRefreshing)
    #expect(store.profiles.allSatisfy { $0.usage?.session?.usedPercent == 25 })
}

@Test("Concurrent menu, card and scheduled refreshes check an account only once")
@MainActor
func refreshDeduplicatesInFlightWork() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = InspectionProbe(suspend: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { try await probe.inspect($0) })
    let first = Task { await store.refresh(fixture.profile.id) }
    await probe.waitUntilStarted()
    #expect(store.isRefreshing)
    await store.refresh(fixture.profile.id)
    await store.refreshAll()
    #expect(await probe.calls == 1)
    #expect(store.isRefreshing)
    await probe.finish()
    await first.value
    #expect(!store.isRefreshing)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 25)
    #expect(store.profiles.first?.email == "saved@example.com")
    #expect(store.profiles.first?.plan == "max")
}

@Test("Cancelling a refresh preserves cached usage and does not mark an account signed out")
@MainActor
func cancelledRefreshKeepsCachedState() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = InspectionProbe(suspend: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { try await probe.inspect($0) })
    let refresh = Task { await store.refresh(fixture.profile.id) }
    await probe.waitUntilStarted()
    refresh.cancel()
    await probe.finish()
    await refresh.value
    #expect(!store.isRefreshing)
    #expect(store.profiles.first?.authIssue == nil)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
}

@Test("A failed usage check keeps cached usage and reports the reason on the account")
@MainActor
func failedRefreshReportsIssue() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let failure = AISwitchError.invalidResponse("Claude usage refresh failed (HTTP 500).")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in throw failure }, renew: { _, _ in Issue.record("Only an expired sign-in is renewed") })
    await store.refreshAll()
    #expect(store.profiles.first?.authIssue == failure.localizedDescription)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                                inspect: { _ in ProviderInspection() })
    #expect(reopened.profiles.first?.authIssue != nil)
    await reopened.refreshAll()
    #expect(reopened.profiles.first?.authIssue == nil)
}

/// Counts usage checks and answers each one with a rate-limit refusal.
private actor RateLimitedInspection {
    private(set) var calls = 0

    func inspect() throws -> ProviderInspection {
        calls += 1
        throw AISwitchError.usageRateLimited(.claude)
    }
}

@Test("A rate-limited account isn't checked again until its wait is over, except by renewing")
@MainActor
func rateLimitedUsageBacksOff() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let inspection = RateLimitedInspection()
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in try await inspection.inspect() }, renew: { _, _ in })
    await store.refresh(fixture.profile.id)
    #expect(store.profiles.first?.authIssue == AISwitchError.usageRateLimited(.claude).localizedDescription)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
    await store.refreshAll()
    #expect(await inspection.calls == 1)
    await store.renew(fixture.profile.id)
    #expect(await inspection.calls == 2)
}

@Test("Refreshing the active Claude account saves the CLI's refreshed credential before inspecting it")
@MainActor
func activeClaudeRefreshSyncsLiveCredential() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("saved", of: fixture.profile)
    let live = LiveClaudeStub("refreshed-by-cli")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, inspect: { profile in
        #expect(savedCredential(of: profile) == "refreshed-by-cli")
        return ProviderInspection()
    }, identify: identities(["saved": "me", "refreshed-by-cli": "me"]), liveClaude: await live.credential)
    await store.refresh(fixture.profile.id)
    #expect(savedCredential(of: fixture.profile) == "refreshed-by-cli")
    #expect(store.activeProfileIDs["claude"] == fixture.profile.id)
    #expect(await live.writes.isEmpty)
}

@Test("Refreshing never saves another account's live credential over the active account")
@MainActor
func refreshKeepsActiveAccountWhenCLISignedInElsewhere() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine", of: fixture.profile)
    let live = LiveClaudeStub("someone-else")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() },
                             identify: identities(["mine": "me", "someone-else": "other"]),
                             liveClaude: await live.credential)
    await store.refresh(fixture.profile.id)
    #expect(savedCredential(of: fixture.profile) == "mine")
    // The CLI no longer uses this account, and the account it uses isn't saved.
    #expect(store.activeProfileIDs["claude"] == nil)
    #expect(store.profiles.first?.authIssue == nil)
    #expect(await live.writes.isEmpty)
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false)
    #expect(reopened.activeProfileIDs["claude"] == nil)
}

@Test("When the CLI signs in to another saved account, that account becomes active with the CLI's credential")
@MainActor
func refreshFollowsCLIToAnotherSavedAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let other = RefreshFixture.claudeProfile(named: "Other", directory: fixture.directory.appendingPathComponent("other"))
    try fixture.save([fixture.profile, other], active: ["claude": fixture.profile.id])
    try writeCredential("mine", of: fixture.profile)
    try writeCredential("other-old", of: other)
    let live = LiveClaudeStub("other-new")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() },
                             identify: identities(["mine": "me", "other-old": "other", "other-new": "other"]),
                             liveClaude: await live.credential)
    await store.refresh(fixture.profile.id)
    #expect(store.activeProfileIDs["claude"] == other.id)
    #expect(savedCredential(of: other) == "other-new")
    #expect(savedCredential(of: fixture.profile) == "mine")
    #expect(await live.writes.isEmpty)
}

@Test("A changed credential whose account can't be checked is left out of the active profile until it can be")
@MainActor
func unverifiableLiveCredentialWaitsForNextRefresh() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine", of: fixture.profile)
    let live = LiveClaudeStub("expired-unknown")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() },
                             identify: identities(["mine": "me"]),
                             liveClaude: await live.credential)
    await store.refresh(fixture.profile.id)
    #expect(savedCredential(of: fixture.profile) == "mine")
    #expect(store.activeProfileIDs["claude"] == fixture.profile.id)
}

@Test("Switching Claude accounts keeps the outgoing account's refreshed credential and makes the new one live")
@MainActor
func switchingClaudeAccountsExchangesCredentials() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let outgoing = fixture.profile
    let incoming = RefreshFixture.claudeProfile(named: "Other", directory: fixture.directory.appendingPathComponent("other"))
    try fixture.save([outgoing, incoming], active: ["claude": outgoing.id])
    try FileManager.default.writeOwnerOnly(Data("outgoing-stale".utf8), to: ClaudeCredentialStore.credentialURL(
        configDirectory: URL(fileURLWithPath: outgoing.profileDirectory)))
    try FileManager.default.writeOwnerOnly(Data("incoming".utf8), to: ClaudeCredentialStore.credentialURL(
        configDirectory: URL(fileURLWithPath: incoming.profileDirectory)))
    let live = LiveClaudeStub("outgoing-refreshed")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, liveClaude: await live.credential)
    try await store.activate(incoming.id)
    #expect(store.activeProfileIDs["claude"] == incoming.id)
    #expect(await live.writes.map { String(decoding: $0, as: UTF8.self) } == ["incoming"])
    #expect(savedCredential(of: outgoing) == "outgoing-refreshed")
    #expect(savedCredential(of: incoming) == "incoming")
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false)
    #expect(reopened.activeProfileIDs["claude"] == incoming.id)
}

@Test("A Claude account without a saved credential cannot replace the live one")
@MainActor
func missingClaudeCredentialFailsBeforeSwitching() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let live = LiveClaudeStub("current")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, liveClaude: await live.credential)
    await #expect(throws: AISwitchError.self) { try await store.activate(fixture.profile.id) }
    #expect(store.activeProfileIDs.isEmpty)
    #expect(await live.writes.isEmpty)
}

@Test("Importing the current Claude account requires a signed-in CLI and leaves nothing behind otherwise")
@MainActor
func importRequiresSignedInClaude() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let live = LiveClaudeStub(nil)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, liveClaude: await live.credential)
    do {
        try await store.importCurrent(provider: .claude)
        Issue.record("Expected a signed-out error")
    } catch AISwitchError.notSignedIn(let provider) {
        #expect(provider == .claude)
    }
    #expect(store.profiles.count == 1)
    let profiles = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("Profiles").path)
    #expect(profiles.isEmpty)
}

@Test("Importing the current Claude account copies the live credential into an owner-only profile file")
@MainActor
func importCopiesLiveClaudeCredential() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let live = LiveClaudeStub("live")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection(email: "me@example.com") }, liveClaude: await live.credential)
    try await store.importCurrent(provider: .claude, activateImported: false)
    let imported = try #require(store.profiles.first { $0.id != fixture.profile.id })
    #expect(store.activeProfileIDs["claude"] == imported.id)
    #expect(imported.displayName == "me")
    #expect(savedCredential(of: imported) == "live")
    let url = ClaudeCredentialStore.credentialURL(configDirectory: URL(fileURLWithPath: imported.profileDirectory))
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(await live.writes.isEmpty)
}

@Test("Importing the account the CLI signed in to leaves the previously active account's credential alone")
@MainActor
func importKeepsPreviouslyActiveCredential() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine", of: fixture.profile)
    let live = LiveClaudeStub("someone-else")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() },
                             identify: identities(["mine": "me", "someone-else": "other"]),
                             liveClaude: await live.credential)
    try await store.importCurrent(provider: .claude)
    let imported = try #require(store.profiles.first { $0.id != fixture.profile.id })
    #expect(store.activeProfileIDs["claude"] == imported.id)
    #expect(savedCredential(of: imported) == "someone-else")
    #expect(savedCredential(of: fixture.profile) == "mine")
    // The credential names no account, so the import asked whose it is.
    #expect(imported.email == "other@example.com")
}

@Test("Removing the active account forgets it here without touching the CLI's live sign-in")
@MainActor
func removingActiveAccountLeavesLiveCredential() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try FileManager.default.writeOwnerOnly(Data("saved".utf8), to: ClaudeCredentialStore.credentialURL(
        configDirectory: URL(fileURLWithPath: fixture.profile.profileDirectory)))
    let live = LiveClaudeStub("live")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, liveClaude: await live.credential)
    await store.remove(fixture.profile.id)
    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.profile.profileDirectory))
    #expect(await live.writes.isEmpty)
    #expect(await live.stored == Data("live".utf8))
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false)
    #expect(reopened.profiles.isEmpty)
    #expect(reopened.activeProfileIDs.isEmpty)
}
