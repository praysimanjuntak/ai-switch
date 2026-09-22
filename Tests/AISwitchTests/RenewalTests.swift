import Darwin
import Foundation
import Testing
@testable import AISwitch

/// Records renewal requests and lets a test hold one open.
private actor RenewalProbe {
    private(set) var calls: [(AIProvider, URL)] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func record(_ provider: AIProvider, _ directory: URL) {
        calls.append((provider, directory))
        started?.resume()
        started = nil
    }

    func hold() async {
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilStarted() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

/// Suspends one inspection so a test can observe the store mid-check.
private actor SuspendedInspection {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func inspect() async -> ProviderInspection {
        calls += 1
        started?.resume()
        started = nil
        await withCheckedContinuation { pending = $0 }
        return ProviderInspection()
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume()
        pending = nil
    }
}

private func writeCredential(_ text: String, of profile: AccountProfile) throws {
    try FileManager.default.writeOwnerOnly(Data(text.utf8), to: ClaudeCredentialStore.credentialURL(
        configDirectory: URL(fileURLWithPath: profile.profileDirectory)))
}

private let renewedUsage = ProviderInspection(
    usage: UsageSnapshot(session: UsageWindow(usedPercent: 25, resetsAt: nil), weekly: nil, fetchedAt: Date(), note: nil)
)

@Test("Renewing the active Claude account renews the CLI's latest credential and makes the renewed one live")
@MainActor
func renewingActiveClaudeAccountExchangesCredentials() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("stale", of: fixture.profile)
    let live = LiveClaudeStub("live-refreshed")
    let expectedDirectory = URL(fileURLWithPath: fixture.profile.profileDirectory)
    let store = AccountStore(
        supportDirectory: fixture.directory, startsAutomatically: false,
        inspect: { _ in renewedUsage },
        renew: { provider, directory in
            #expect(provider == .claude)
            #expect(directory == expectedDirectory)
            // The CLI's newest credential, not the stale saved one, is what gets renewed.
            #expect(savedCredential(of: fixture.profile) == "live-refreshed")
            try writeCredential("renewed", of: fixture.profile)
        },
        liveClaude: await live.credential
    )
    await store.renew(fixture.profile.id)
    #expect(await live.writes.map { String(decoding: $0, as: UTF8.self) } == ["renewed"])
    #expect(savedCredential(of: fixture.profile) == "renewed")
    #expect(store.profiles.first?.authIssue == nil)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 25)
    #expect(!store.isRefreshing)
}

@Test("Renewing an inactive account never touches the live credential")
@MainActor
func renewingInactiveAccountLeavesLiveCredential() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    try writeCredential("stale", of: fixture.profile)
    let live = LiveClaudeStub("live")
    let store = AccountStore(
        supportDirectory: fixture.directory, startsAutomatically: false,
        inspect: { _ in renewedUsage },
        renew: { _, _ in try writeCredential("renewed", of: fixture.profile) },
        liveClaude: await live.credential
    )
    await store.renew(fixture.profile.id)
    #expect(await live.writes.isEmpty)
    #expect(savedCredential(of: fixture.profile) == "renewed")
    #expect(store.profiles.first?.usage?.session?.usedPercent == 25)
}

@Test("A failed renewal reports the reason on the account, keeps cached usage and skips the usage check")
@MainActor
func failedRenewalReportsIssue() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let live = LiveClaudeStub("live")
    let store = AccountStore(
        supportDirectory: fixture.directory, startsAutomatically: false,
        inspect: { _ in
            Issue.record("A failed renewal must not check usage")
            return ProviderInspection()
        },
        renew: { _, _ in throw AISwitchError.commandFailed("Not logged in") },
        liveClaude: await live.credential
    )
    await store.renew(fixture.profile.id)
    #expect(store.profiles.first?.authIssue == "Not logged in")
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
    #expect(await live.writes.isEmpty)
    #expect(!store.isRefreshing)
}

@Test("Renewal is skipped while the same account is already being checked")
@MainActor
func renewalDeduplicatesWithRefresh() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let inspection = SuspendedInspection()
    let renewals = RenewalProbe()
    let store = AccountStore(
        supportDirectory: fixture.directory, startsAutomatically: false,
        inspect: { _ in await inspection.inspect() },
        renew: { await renewals.record($0, $1) }
    )
    let refresh = Task { await store.refresh(fixture.profile.id) }
    await inspection.waitUntilStarted()
    await store.renew(fixture.profile.id)
    #expect(await renewals.calls.isEmpty)
    await inspection.finish()
    await refresh.value
    #expect(!store.isRefreshing)
}

@Test("Cancelling a renewal leaves the account untouched")
@MainActor
func cancelledRenewalKeepsCachedState() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    let live = LiveClaudeStub("live")
    let renewals = RenewalProbe()
    let store = AccountStore(
        supportDirectory: fixture.directory, startsAutomatically: false,
        inspect: { _ in
            Issue.record("A cancelled renewal must not check usage")
            return ProviderInspection()
        },
        renew: { provider, directory in
            await renewals.record(provider, directory)
            await renewals.hold() // Deliberately ignores cancellation, like a CLI that keeps running.
            try Task.checkCancellation()
        },
        liveClaude: await live.credential
    )
    let renewal = Task { await store.renew(fixture.profile.id) }
    await renewals.waitUntilStarted()
    renewal.cancel()
    await renewals.release()
    await renewal.value
    #expect(store.profiles.first?.authIssue == nil)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 12)
    #expect(await live.writes.isEmpty)
    #expect(!store.isRefreshing)
}

// MARK: CLI seam

private struct FakeCLI {
    let directory: URL
    let profile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchRenewal-\(UUID())", isDirectory: true)
        profile = directory.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    }

    func install(_ name: String, script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func recorded(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

@Test("Claude renewal runs a one-line, tool-less Claude Code session in the profile directory and adopts what it saved")
func claudeRenewalDrivesClaudeCode() async throws {
    let fake = try FakeCLI()
    defer { try? fake.remove() }
    let claude = try fake.install("claude", script: """
    #!/bin/sh
    printf '%s\\n' "$CLAUDE_CONFIG_DIR" > "\(fake.directory.path)/config-dir"
    printf '%s\\n' "$PWD" > "\(fake.directory.path)/cwd"
    printf '[%s]\\n' "$@" > "\(fake.directory.path)/arguments"
    printf '%s' '{"claudeAiOauth":{"accessToken":"renewed","refreshToken":"r2","expiresAt":1900000000000}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
    echo OK
    """)
    try FileManager.default.writeOwnerOnly(Data(#"{"claudeAiOauth":{"accessToken":"expired"}}"#.utf8),
                                           to: ClaudeCredentialStore.credentialURL(configDirectory: fake.profile))

    try await AccountLoginService.renew(provider: .claude, directory: fake.profile, executable: claude)

    #expect(try fake.recorded("config-dir") == fake.profile.path)
    #expect(URL(fileURLWithPath: try fake.recorded("cwd")).resolvingSymlinksInPath() == fake.profile.resolvingSymlinksInPath())
    #expect(try fake.recorded("arguments").components(separatedBy: "\n") == ["[-p]", "[Reply with the single word OK.]", "[--tools]", "[]"])
    let saved = try ClaudeCredentialStore.readProfile(directory: fake.profile.path)
    #expect(try ClaudeCredentialStore.accessToken(from: saved) == "renewed")
}

@Test("A Claude renewal that fails surfaces the CLI's message")
func failedClaudeRenewalReportsCLIMessage() async throws {
    let fake = try FakeCLI()
    defer { try? fake.remove() }
    let claude = try fake.install("claude", script: """
    #!/bin/sh
    echo 'Not logged in. Please run /login.' >&2
    exit 1
    """)
    do {
        try await AccountLoginService.renew(provider: .claude, directory: fake.profile, executable: claude)
        Issue.record("Expected the CLI failure to be reported")
    } catch AISwitchError.commandFailed(let message) {
        #expect(message.contains("Not logged in"))
    }
}

@Test("Codex renewal asks the app-server to refresh the token")
func codexRenewalRequestsTokenRefresh() async throws {
    let fake = try FakeCLI()
    defer { try? fake.remove() }
    let codex = try fake.install("codex", script: """
    #!/bin/sh
    echo $$ > "\(fake.directory.path)/fake.pid"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "\(fake.directory.path)/requests"
      case "$line" in
        *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"account":{"email":"fake@example.com","planType":"plus"}}}' ;;
        *'"id":3'*) printf '%s\\n' '{"id":3,"result":{}}'
                    sleep 30 ;;
      esac
    done
    """)

    try await AccountLoginService.renew(provider: .codex, directory: fake.profile, executable: codex)

    let requests = try fake.recorded("requests").components(separatedBy: "\n")
    let accountRead = try #require(requests.first { $0.contains("\"id\":2") })
    #expect(accountRead.contains("\"refreshToken\":true"))
    let pid = try #require(pid_t(try fake.recorded("fake.pid")))
    #expect(kill(pid, 0) == -1)
}
