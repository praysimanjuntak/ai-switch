import Foundation
import Testing
@testable import AISwitch

/// Saves `credential` where the CLI for `provider` saves a sign-in made in `directory`.
private func write(_ credential: String, signedInBy provider: AIProvider, in directory: URL) throws {
    let file = provider == .codex ? directory.appendingPathComponent("auth.json")
        : ClaudeCredentialStore.credentialURL(configDirectory: directory)
    try FileManager.default.writeOwnerOnly(Data(credential.utf8), to: file)
}

/// A browser sign-in that signs in as `credential`.
private func signsIn(as credential: String) -> @Sendable (AIProvider, URL) async throws -> Void {
    { provider, directory in try write(credential, signedInBy: provider, in: directory) }
}

/// Sign-in folders left behind, each holding a copy of a sign-in.
private func signInFolders(of fixture: RefreshFixture) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("Profiles").path)) ?? []
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@MainActor
private func store(_ fixture: RefreshFixture, signingInAs credential: String, owners: [String: String],
                   live: LiveClaudeStub = LiveClaudeStub(nil)) async -> AccountStore {
    AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, login: signsIn(as: credential),
                 inspect: { _ in ProviderInspection() }, identify: identities(owners), liveClaude: await live.credential)
}

private actor CallCounter {
    private(set) var value = 0
    func count() { value += 1 }
}

@Test("Signing in again replaces only the account's saved sign-in; it keeps its name and stops needing attention")
@MainActor
func signingInAgainReplacesSavedSignIn() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    var account = fixture.profile
    account.authIssue = "Unable to renew sign-in: Not logged in. Please run /login."
    try fixture.save([account], active: [:])
    try writeCredential("mine-old", of: account)
    let store = await store(fixture, signingInAs: "mine-new", owners: ["mine-old": "me", "mine-new": "me"])

    try await store.signInAgain(account.id)

    #expect(savedCredential(of: account) == "mine-new")
    #expect(store.profiles.map(\.id) == [account.id])
    #expect(store.profiles.first?.displayName == "Saved account")
    #expect(store.profiles.first?.authIssue == nil)
    #expect(signInFolders(of: fixture).isEmpty)
}

@Test("Signing in again as another account changes nothing and says who was signed in")
@MainActor
func signingInAgainAsAnotherAccountChangesNothing() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine-old", of: fixture.profile)
    let live = LiveClaudeStub("mine-old")
    let store = await store(fixture, signingInAs: "someone-else", owners: ["mine-old": "me", "someone-else": "other"], live: live)

    do {
        try await store.signInAgain(fixture.profile.id)
        Issue.record("Another account's sign-in must be refused")
    } catch AISwitchError.commandFailed(let message) {
        #expect(message.contains("other@example.com"))
    }
    #expect(savedCredential(of: fixture.profile) == "mine-old")
    #expect(await live.writes.isEmpty)
    #expect(store.profiles.map(\.id) == [fixture.profile.id])
    #expect(signInFolders(of: fixture).isEmpty)
}

@Test("Signing in again to another organization of the same login changes nothing")
@MainActor
func signingInAgainToAnotherOrganizationChangesNothing() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    try writeCredential("personal", of: fixture.profile)
    let organizations = ["personal": "org-personal", "team": "org-team"]
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, login: signsIn(as: "team"),
                             inspect: { _ in ProviderInspection() }, identify: { _, credential in
                                 organizations[text(credential)].map {
                                     AccountIdentity(user: "me", organization: $0, email: "me@example.com")
                                 }
                             }, liveClaude: await LiveClaudeStub(nil).credential)

    do {
        try await store.signInAgain(fixture.profile.id)
        Issue.record("A sign-in to another organization must be refused")
    } catch AISwitchError.commandFailed(let message) {
        #expect(message.contains("organization"))
    }
    #expect(savedCredential(of: fixture.profile) == "personal")
}

@Test("Signing the active account in again gives Claude Code the new sign-in")
@MainActor
func signingInActiveAccountAgainUpdatesClaudeCode() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine-old", of: fixture.profile)
    let live = LiveClaudeStub("mine-old")
    let store = await store(fixture, signingInAs: "mine-new", owners: ["mine-old": "me", "mine-new": "me"], live: live)

    try await store.signInAgain(fixture.profile.id)

    #expect(savedCredential(of: fixture.profile) == "mine-new")
    #expect(await live.writes.map(text) == ["mine-new"])
}

@Test("Signing the active account in again leaves alone another account Claude Code signed in to meanwhile")
@MainActor
func signingInAgainKeepsAnotherLiveAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine-old", of: fixture.profile)
    let live = LiveClaudeStub("someone-else")
    let store = await store(fixture, signingInAs: "mine-new",
                            owners: ["mine-old": "me", "mine-new": "me", "someone-else": "other"], live: live)

    try await store.signInAgain(fixture.profile.id)

    #expect(savedCredential(of: fixture.profile) == "mine-new")
    #expect(await live.writes.isEmpty)
}

@Test("Closing the sheet before the browser sign-in finishes changes nothing, even when the sign-in completes later")
@MainActor
func cancelledSignInAgainChangesNothing() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    try writeCredential("mine-old", of: fixture.profile)
    let gate = LoginGate()
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, login: { provider, directory in
        await gate.pause(in: directory) // Deliberately ignores cancellation, like a late browser callback.
        try write("mine-new", signedInBy: provider, in: directory)
    }, inspect: { _ in ProviderInspection() }, identify: identities(["mine-old": "me", "mine-new": "me"]),
       liveClaude: await LiveClaudeStub(nil).credential)

    let signIn = Task { try await store.signInAgain(fixture.profile.id) }
    await gate.waitUntilStarted()
    signIn.cancel()
    await gate.finish()

    await #expect(throws: CancellationError.self) { try await signIn.value }
    #expect(savedCredential(of: fixture.profile) == "mine-old")
    #expect(signInFolders(of: fixture).isEmpty)
}

@Test("While an account is being signed in again, checks and renewals leave it alone")
@MainActor
func checksWaitForSignInAgain() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    try writeCredential("mine-old", of: fixture.profile)
    let gate = LoginGate()
    let calls = CallCounter()
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, login: { provider, directory in
        await gate.pause(in: directory)
        try write("mine-new", signedInBy: provider, in: directory)
    }, inspect: { _ in
        await calls.count()
        return ProviderInspection()
    }, renew: { _, _ in await calls.count() }, identify: identities(["mine-old": "me", "mine-new": "me"]),
       liveClaude: await LiveClaudeStub(nil).credential)

    let signIn = Task { try await store.signInAgain(fixture.profile.id) }
    await gate.waitUntilStarted()
    await store.refresh(fixture.profile.id)
    await store.renew(fixture.profile.id)
    #expect(await calls.value == 0)
    await gate.finish()
    try await signIn.value

    #expect(savedCredential(of: fixture.profile) == "mine-new")
}

@Test("Signing a Codex account in again replaces its auth.json")
@MainActor
func signingCodexAccountInAgain() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let folder = fixture.directory.appendingPathComponent("codex", isDirectory: true)
    let account = AccountProfile(id: UUID(), provider: .codex, displayName: "Codex account", email: "me@example.com",
                                 plan: "team", profileDirectory: folder.path, createdAt: Date(), lastActivatedAt: nil,
                                 usage: nil, authIssue: nil)
    try fixture.save([account], active: [:])
    try write("codex-old", signedInBy: .codex, in: folder)
    let store = await store(fixture, signingInAs: "codex-new", owners: ["codex-old": "me", "codex-new": "me"])

    try await store.signInAgain(account.id)

    #expect(try String(contentsOf: folder.appendingPathComponent("auth.json"), encoding: .utf8) == "codex-new")
    #expect(signInFolders(of: fixture).isEmpty)
}
