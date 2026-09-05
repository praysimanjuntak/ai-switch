import Foundation
import Security
import Testing
@testable import AISwitch

private final class OneTimeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var interactiveReads = 0
    private var silentCredential: KeychainCredential?
    private var removed = false

    static let first = KeychainCredential(data: Data("first-test-credential".utf8), account: "test")
    static let rotated = KeychainCredential(data: Data("rotated-test-credential".utf8), account: "test")

    var prompts: Int { lock.withLock { interactiveReads } }

    func load(_ service: String, _ interaction: KeychainInteraction) throws -> KeychainCredential {
        try lock.withLock {
            if removed { throw AISwitchError.keychain(errSecItemNotFound) }
            if let silentCredential { return silentCredential }
            if interaction == .forbidden { throw AISwitchError.keychainAccessRequired }
            interactiveReads += 1
            guard interactiveReads == 1 else {
                throw AISwitchError.commandFailed("Unexpected repeated permission prompt")
            }
            return Self.first
        }
    }

    func rotateSilently() { lock.withLock { silentCredential = Self.rotated } }
    func requirePermission() { lock.withLock { silentCredential = nil } }
    func remove() { lock.withLock { removed = true } }
}

@Test("Allow Once supports subsequent usage refreshes without another prompt")
func oneTimeGrantIsRememberedForUsage() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    let service = "test-claude-profile"
    #expect(try reader.read(service: service, interaction: .allowed).data == OneTimeKeychain.first.data)
    for _ in 0..<5 {
        #expect(try reader.read(service: service).data == OneTimeKeychain.first.data)
    }
    #expect(try reader.read(service: service, interaction: .allowed).data == OneTimeKeychain.first.data)
    #expect(keychain.prompts == 1)
}

@Test("An approval for one service cannot authorize another profile")
func approvalIsIsolatedByService() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    _ = try reader.read(service: "first-profile", interaction: .allowed)
    do {
        _ = try reader.read(service: "second-profile")
        Issue.record("An unapproved profile must require its own permission")
    } catch AISwitchError.keychainAccessRequired {}
    #expect(keychain.prompts == 1)
}

@Test("Usage picks up a silently refreshed token and remembers the newer value")
func refreshedCredentialsReplaceSessionCache() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    _ = try reader.read(service: "profile", interaction: .allowed)
    keychain.rotateSilently()
    #expect(try reader.read(service: "profile").data == OneTimeKeychain.rotated.data)
    keychain.requirePermission()
    #expect(try reader.read(service: "profile").data == OneTimeKeychain.rotated.data)
    #expect(keychain.prompts == 1)
}

@Test("Removing a Keychain item prevents reuse of its remembered credential")
func removedCredentialsAreNotReused() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    _ = try reader.read(service: "profile", interaction: .allowed)
    keychain.remove()
    do {
        _ = try reader.read(service: "profile")
        Issue.record("A deleted credential must not be served from memory")
    } catch AISwitchError.keychain(let status) {
        #expect(status == errSecItemNotFound)
    }
    #expect(keychain.prompts == 1)
}

@Test("Rejected credentials are discarded without discarding a newer token")
func rejectedCredentialsAreInvalidatedConditionally() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    _ = try reader.read(service: "profile", interaction: .allowed)
    keychain.rotateSilently()
    _ = try reader.read(service: "profile")
    keychain.requirePermission()
    reader.invalidate(service: "profile", matching: OneTimeKeychain.first.data)
    #expect(try reader.read(service: "profile").data == OneTimeKeychain.rotated.data)
    reader.invalidate(service: "profile", matching: OneTimeKeychain.rotated.data)
    do {
        _ = try reader.read(service: "profile")
        Issue.record("Rejected credentials must not be reused")
    } catch AISwitchError.keychainAccessRequired {}
    #expect(keychain.prompts == 1)
}

@Test("One-time approvals are memory-only and do not survive a new app session")
func rememberedApprovalIsNotPersisted() throws {
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    _ = try reader.read(service: "profile", interaction: .allowed)
    let nextSession = SessionCredentialReader { try keychain.load($0, $1) }
    do {
        _ = try nextSession.read(service: "profile")
        Issue.record("A new session must check Keychain authorization")
    } catch AISwitchError.keychainAccessRequired {}
    #expect(keychain.prompts == 1)
}

@Test("Grant access followed by repeated active-account refreshes needs only one approval")
@MainActor
func activeAccountRefreshReusesOneTimeApproval() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let keychain = OneTimeKeychain()
    let reader = SessionCredentialReader { try keychain.load($0, $1) }
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { _, interaction, service in
        #expect(service == CredentialManager.claudeDefaultService)
        _ = try reader.read(service: #require(service), interaction: interaction)
        return ProviderInspection(email: nil, plan: nil, usage: nil)
    }
    await store.refreshAll()
    #expect(store.profiles.first?.needsKeychainAccess == true)
    #expect(keychain.prompts == 0)
    await store.grantKeychainAccess(fixture.profile.id)
    #expect(store.profiles.first?.authIssue == nil)
    for _ in 0..<5 { await store.refreshAll() }
    #expect(store.profiles.first?.needsKeychainAccess == nil)
    #expect(store.profiles.first?.authIssue == nil)
    #expect(keychain.prompts == 1)
}
