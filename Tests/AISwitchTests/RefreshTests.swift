import Foundation
import Security
import Testing
@testable import AISwitch

struct RefreshFixture {
    let directory: URL
    let profile: AccountProfile

    init(active: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profile = AccountProfile(
            id: UUID(), provider: .claude, displayName: "Saved account",
            email: "saved@example.com", plan: "max", profileDirectory: directory.path,
            createdAt: Date(), lastActivatedAt: nil,
            usage: UsageSnapshot(session: UsageWindow(usedPercent: 12, resetsAt: nil),
                                 weekly: nil, fetchedAt: Date(), note: nil),
            authIssue: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(StoredState(profiles: [profile], activeProfileIDs: active ? ["claude": profile.id] : [:]))
            .write(to: directory.appendingPathComponent("profiles.json"))
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

private actor InspectionProbe {
    var interactions: [KeychainInteraction] = []
    private let suspend: Bool
    private var permissionRequired: Bool
    private var pending: CheckedContinuation<ProviderInspection, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(suspend: Bool = false, permissionRequired: Bool = false) {
        self.suspend = suspend
        self.permissionRequired = permissionRequired
    }

    func inspect(_ profile: AccountProfile, _ interaction: KeychainInteraction) async throws -> ProviderInspection {
        interactions.append(interaction)
        started?.resume()
        started = nil
        if interaction == .allowed { permissionRequired = false }
        if permissionRequired { throw AISwitchError.keychainAccessRequired }
        if suspend {
            return await withCheckedContinuation { pending = $0 }
        }
        return result
    }

    func waitUntilStarted() async {
        if !interactions.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: result)
        pending = nil
    }

    private var result: ProviderInspection {
        ProviderInspection(email: nil, plan: nil,
                           usage: UsageSnapshot(session: UsageWindow(usedPercent: 25, resetsAt: nil),
                                                weekly: nil, fetchedAt: Date(), note: nil))
    }
}

@Test("Concurrent menu, card and scheduled refreshes check an account only once")
@MainActor
func refreshDeduplicatesInFlightWork() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = InspectionProbe(suspend: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { profile, interaction, _ in
        try await probe.inspect(profile, interaction)
    }
    let first = Task { await store.refresh(fixture.profile.id) }
    await probe.waitUntilStarted()
    #expect(store.isRefreshing)
    await store.refresh(fixture.profile.id, userInitiated: true)
    await store.refreshAll()
    #expect(await probe.interactions == [.forbidden])
    #expect(store.isRefreshing)
    await probe.finish()
    await first.value
    #expect(!store.isRefreshing)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 25)
    #expect(store.profiles.first?.email == "saved@example.com")
    #expect(store.profiles.first?.plan == "max")
}

@Test("Denied Keychain access pauses across restarts until an explicit retry")
@MainActor
func deniedKeychainAccessPausesRefresh() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = InspectionProbe(permissionRequired: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { profile, interaction, _ in
        try await probe.inspect(profile, interaction)
    }
    #expect(store.profiles.first?.needsKeychainAccess == nil)
    await store.refreshAll()
    #expect(store.profiles.first?.needsKeychainAccess == true)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
    #expect(store.profiles.first?.authIssue == AISwitchError.keychainAccessRequired.localizedDescription)
    await store.refreshAll()
    let reopened = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { profile, interaction, _ in
        try await probe.inspect(profile, interaction)
    }
    await reopened.refreshAll()
    #expect(await probe.interactions == [.forbidden])
    await reopened.refreshAll(userInitiated: true)
    #expect(await probe.interactions == [.forbidden, .forbidden])
    await reopened.grantKeychainAccess(fixture.profile.id)
    #expect(await probe.interactions == [.forbidden, .forbidden, .allowed])
    #expect(reopened.profiles.first?.needsKeychainAccess == nil)
    #expect(reopened.profiles.first?.authIssue == nil)
    await reopened.refreshAll()
    #expect(await probe.interactions == [.forbidden, .forbidden, .allowed, .forbidden])
}

@Test("Cancelling a refresh preserves cached usage and does not mark an account signed out")
@MainActor
func cancelledRefreshKeepsCachedState() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let probe = InspectionProbe(suspend: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { profile, interaction, _ in
        try await probe.inspect(profile, interaction)
    }
    let refresh = Task { await store.refresh(fixture.profile.id) }
    await probe.waitUntilStarted()
    refresh.cancel()
    await probe.finish()
    await refresh.value
    #expect(!store.isRefreshing)
    #expect(store.profiles.first?.authIssue == nil)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
}

@Test("An active Claude usage grant reads the live service without copying Keychain items")
@MainActor
func activeClaudeGrantReadsOnlyLiveCredential() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let probe = InspectionProbe(permissionRequired: true)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false) { profile, interaction, service in
        #expect(service == CredentialManager.claudeDefaultService)
        return try await probe.inspect(profile, interaction)
    }
    await store.refresh(fixture.profile.id)
    #expect(await probe.interactions == [.forbidden])
    #expect(store.profiles.first?.needsKeychainAccess == true)
    await store.grantKeychainAccess(fixture.profile.id)
    #expect(await probe.interactions == [.forbidden, .allowed])
    #expect(store.profiles.first?.authIssue == nil)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 25)
}

@Suite(.serialized)
struct KeychainInteractionTests {
    @Test("A silent Keychain scope disables legacy dialogs and restores the prior setting",
          arguments: [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled])
    func silentScopeRestoresInteraction(status: OSStatus) throws {
        var before = DarwinBoolean(false)
        #expect(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
        do {
            try CredentialManager.withInteraction(.forbidden) {
                var during = DarwinBoolean(true)
                #expect(SecKeychainGetUserInteractionAllowed(&during) == errSecSuccess)
                #expect(!during.boolValue)
                throw AISwitchError.keychain(status)
            }
            Issue.record("Expected permission-required error")
        } catch AISwitchError.keychainAccessRequired {
            // The app can offer permission without misreporting expired OAuth.
        }
        var after = DarwinBoolean(false)
        #expect(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
        #expect(after.boolValue == before.boolValue)
    }

    @Test("An explicit permission scope can allow interaction inside a silent scope")
    func explicitInteractionIsScoped() throws {
        try CredentialManager.withInteraction(.forbidden) {
            try CredentialManager.withInteraction(.allowed) {
                var allowed = DarwinBoolean(false)
                #expect(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess)
                #expect(allowed.boolValue)
            }
            var restored = DarwinBoolean(true)
            #expect(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess)
            #expect(!restored.boolValue)
        }
    }
}
