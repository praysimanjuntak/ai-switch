import Foundation
import Testing
@testable import AISwitch

private actor LoginGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var directory: URL?

    func pause(in directory: URL) async {
        self.directory = directory
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if directory != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@Test("A late successful login cannot add an account after cancellation")
@MainActor
func lateLoginDoesNotAddAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let gate = LoginGate()
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, login: { _, directory in
        await gate.pause(in: directory) // Deliberately ignores cancellation.
    }, inspect: { _ in
        Issue.record("A cancelled login must not start inspection")
        return ProviderInspection()
    })
    let profilesBefore = store.profiles
    let activeBefore = store.activeProfileIDs
    let stateBefore = try Data(contentsOf: fixture.directory.appendingPathComponent("profiles.json"))
    let task = Task { try await store.addAccount(provider: .codex) }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(store.profiles == profilesBefore)
    #expect(store.activeProfileIDs == activeBefore)
    #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("profiles.json")) == stateBefore)
    let directory = try #require(await gate.directory)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test("Cancellation during account inspection cannot save or activate the login")
@MainActor
func cancelledInspectionDoesNotActivateAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let gate = LoginGate()
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             login: { _, _ in }, inspect: { profile in
        await gate.pause(in: URL(fileURLWithPath: profile.profileDirectory))
        return ProviderInspection(email: "new@example.com", plan: "test", usage: nil)
    })
    let profilesBefore = store.profiles
    let activeBefore = store.activeProfileIDs
    let task = Task { try await store.addAccount(provider: .codex) }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(store.profiles == profilesBefore)
    #expect(store.activeProfileIDs == activeBefore)
    let directory = try #require(await gate.directory)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test("Failed sign-in can be retried without saving a ghost account")
@MainActor
func failedLoginCanBeRetried() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             login: { _, _ in throw AISwitchError.commandFailed("Test sign-in failure") },
                             inspect: { _ in ProviderInspection() })
    let profilesBefore = store.profiles
    let activeBefore = store.activeProfileIDs
    for _ in 0..<2 {
        do {
            try await store.addAccount(provider: .codex)
            Issue.record("Expected sign-in failure")
        } catch AISwitchError.commandFailed(let message) {
            #expect(message == "Test sign-in failure")
        }
    }
    #expect(store.profiles == profilesBefore)
    #expect(store.activeProfileIDs == activeBefore)
    let enumerator = FileManager.default.enumerator(at: fixture.directory.appendingPathComponent("Profiles"),
                                                    includingPropertiesForKeys: nil)
    let paths = (enumerator?.allObjects as? [URL] ?? []).map(\.lastPathComponent)
    #expect(paths.isEmpty)
}

@Test("Activation failure rolls back the newly added profile on disk")
@MainActor
func activationFailureDoesNotPersistGhostAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    // No auth file is produced, so activation stops before any live credential
    // writes. The existing fixture is Claude; no live Codex sync is attempted.
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             login: { _, _ in }, inspect: { _ in ProviderInspection() })
    let profilesBefore = store.profiles
    let activeBefore = store.activeProfileIDs
    do {
        try await store.addAccount(provider: .codex)
        Issue.record("Expected missing credentials")
    } catch AISwitchError.credentialsMissing(let provider) {
        #expect(provider == .codex)
    }
    let restored = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false)
    #expect(restored.profiles == profilesBefore)
    #expect(restored.activeProfileIDs == activeBefore)
}
