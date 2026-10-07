import Foundation
import SQLite3
import Testing
@testable import AISwitch

private let personal = OmpAccount(provider: .codex, email: "me@example.com", orgId: "acct-personal")
private let team = OmpAccount(provider: .codex, email: "me@example.com", orgId: "acct-team")
private let claudeWork = OmpAccount(provider: .claude, email: "me@example.com", orgId: "org-work")

private func profile(_ provider: AIProvider, email: String?, organization: String?, directory: URL? = nil) -> AccountProfile {
    var profile = AccountProfile(
        id: UUID(), provider: provider, displayName: email ?? "account", email: email, plan: nil,
        profileDirectory: (directory ?? URL(fileURLWithPath: "/tmp/none/\(UUID())")).path,
        createdAt: Date(), lastActivatedAt: nil, usage: nil, authIssue: nil
    )
    profile.identity = organization.map { AccountIdentity(user: "user-1", organization: $0, email: email) }
    return profile
}

@Test("omp identity keys name the account's email and organization")
func parsesOmpIdentityKey() {
    #expect(OmpAccount(provider: .codex, identityKey: "email:me@example.com|org:acct-team") == team)
    #expect(OmpAccount(provider: .claude, identityKey: "email:me@example.com") == nil)
}

@Test("A saved account matches the omp account in the same workspace, never a namesake")
func matchesProfilesToOmpAccounts() {
    let accounts = [personal, team, claudeWork]
    #expect(OmpAccount.matching(profile(.codex, email: "me@example.com", organization: "acct-team"), in: accounts) == team)
    #expect(OmpAccount.matching(profile(.codex, email: "ME@example.com", organization: "acct-personal"), in: accounts) == personal)
    // Without a known workspace, one email in two omp workspaces is ambiguous.
    #expect(OmpAccount.matching(profile(.codex, email: "me@example.com", organization: nil), in: accounts) == nil)
    #expect(OmpAccount.matching(profile(.claude, email: "me@example.com", organization: nil), in: accounts) == claudeWork)
    #expect(OmpAccount.matching(profile(.codex, email: "other@example.com", organization: "acct-other"), in: accounts) == nil)
}

@Test("AI Switch's omp rule replaces only its own, outranks the user's, and steps aside for a rule the user wrote")
func plansOmpPolicies() {
    let userReserve = OmpAccountPolicy(provider: "openai-codex", account: .init(email: "me@example.com", orgId: "acct-personal"),
                                       priority: 250, reservePct: 20)
    let oldOurs = OmpAccountPolicy.preferring(personal, priority: 100)
    var plan = OmpPolicies.plan(existing: [userReserve], managed: [:], targets: [.codex: team])
    #expect(plan.policies == [userReserve, .preferring(team, priority: 251)])
    #expect(plan.managed == [.codex: .preferring(team, priority: 251)])

    // A user rule for the very account wins; omp rejects two rules for one account.
    plan = OmpPolicies.plan(existing: [userReserve], managed: [:], targets: [.codex: personal])
    #expect(plan.policies == [userReserve])
    #expect(plan.conflicts == [.codex])

    // Switching away replaces AI Switch's old rule; following nothing removes it.
    plan = OmpPolicies.plan(existing: [oldOurs], managed: [.codex: oldOurs], targets: [.codex: team])
    #expect(plan.policies == [.preferring(team, priority: 100)])
    plan = OmpPolicies.plan(existing: [userReserve, oldOurs], managed: [.codex: oldOurs], targets: [:])
    #expect(plan.policies == [userReserve])
    #expect(plan.managed.isEmpty)
}

@Test("omp's accounts are read from its store: enabled sign-ins only, never the credential payload")
func readsOmpAccountStore() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchOmp-\(UUID()).db")
    defer { try? FileManager.default.removeItem(at: url) }
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    // omp's own table, schema version 8.
    let sql = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT, provider TEXT NOT NULL, credential_type TEXT NOT NULL, data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL, identity_key TEXT DEFAULT NULL,
            created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0);
        INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause, identity_key) VALUES
            ('openai-codex', 'oauth', '{}', NULL, 'email:me@example.com|org:acct-team'),
            ('openai-codex', 'oauth', '{}', 'logged out by user', 'email:me@example.com|org:acct-personal'),
            ('anthropic', 'oauth', '{}', NULL, 'email:me@example.com|org:org-work'),
            ('openrouter', 'api_key', '{}', NULL, NULL),
            ('zai', 'oauth', '{}', NULL, 'email:me@example.com|org:z');
        """
    #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    #expect(Set(try OmpBridge.readAccounts(url)) == [team, claudeWork])
}

/// Stands in for omp: its signed-in accounts and its `auth.accountPolicies`.
private actor FakeOmp {
    var accounts: [OmpAccount]
    private(set) var policies: [OmpAccountPolicy]
    private(set) var writes = 0

    init(accounts: [OmpAccount], policies: [OmpAccountPolicy]) {
        self.accounts = accounts
        self.policies = policies
    }

    func signOut(_ account: OmpAccount) { accounts.removeAll { $0 == account } }

    func write(_ policies: [OmpAccountPolicy]) {
        self.policies = policies
        writes += 1
    }

    nonisolated var bridge: OmpBridge {
        OmpBridge(isAvailable: { true }, accounts: { await self.accounts }, readPolicies: { await self.policies },
                  writePolicies: { await self.write($0) })
    }
}

@Test("With Switch omp too on, omp prefers the CLI's account, follows a switch, and loses the rule when the account leaves omp")
@MainActor
func ompFollowsTheCLIAccount() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let work = profile(.claude, email: "me@example.com", organization: "org-work", directory: fixture.directory.appendingPathComponent("work"))
    let side = profile(.claude, email: "side@example.com", organization: "org-side", directory: fixture.directory.appendingPathComponent("side"))
    try fixture.save([work, side], active: ["claude": work.id])
    try writeCredential("work", of: work)
    try writeCredential("side", of: side)
    let sideInOmp = OmpAccount(provider: .claude, email: "side@example.com", orgId: "org-side")
    let userRule = OmpAccountPolicy(provider: "openai-codex", account: .init(email: "me@example.com", orgId: "acct-team"),
                                    priority: 5, reservePct: 10)
    let omp = FakeOmp(accounts: [claudeWork, sideInOmp, team], policies: [userRule])
    let live = LiveClaudeStub("work")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, liveClaude: await live.credential,
                             codexSessions: nil, omp: omp.bridge)

    await store.setOmpFollow(true)
    #expect(await omp.policies == [userRule, .preferring(claudeWork, priority: 100)])
    #expect(store.ompPreferredProfileIDs == [work.id])

    try await store.activate(side.id)
    await store.reconcileOmp()
    #expect(await omp.policies == [userRule, .preferring(sideInOmp, priority: 100)])
    #expect(store.ompPreferredProfileIDs == [side.id])

    // Nothing changed: omp isn't rewritten.
    let writes = await omp.writes
    await store.reconcileOmp()
    #expect(await omp.writes == writes)

    // omp would reject a rule for an account it no longer has.
    await omp.signOut(sideInOmp)
    await store.reconcileOmp()
    #expect(await omp.policies == [userRule])
    #expect(store.ompMissingProfileIDs == [side.id])

    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, codexSessions: nil, omp: omp.bridge)
    #expect(reopened.ompFollow)
    await store.setOmpFollow(false)
    #expect(await omp.policies == [userRule])
    #expect(store.ompPreferredProfileIDs.isEmpty)
}

@Test("Turning Switch omp too off removes AI Switch's rule and keeps the user's")
@MainActor
func turningOmpOffRemovesOnlyOurRule() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let work = profile(.claude, email: "me@example.com", organization: "org-work", directory: fixture.directory.appendingPathComponent("work"))
    try fixture.save([work], active: ["claude": work.id])
    let userRule = OmpAccountPolicy(provider: "anthropic", account: .init(email: "other@example.com"), priority: 1)
    let omp = FakeOmp(accounts: [claudeWork], policies: [userRule])
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, codexSessions: nil, omp: omp.bridge)
    await store.setOmpFollow(true)
    #expect(await omp.policies == [userRule, .preferring(claudeWork, priority: 100)])
    await store.setOmpFollow(false)
    #expect(await omp.policies == [userRule])
}
