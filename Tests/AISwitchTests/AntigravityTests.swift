import Foundation
import Testing
@testable import AISwitch

private func makeJWT(claims: [String: Any]) throws -> String {
    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    return "\(base64url(header)).\(base64url(payload)).sig"
}

private func antigravityTokenJSON(
    access: String,
    refresh: String? = "1//refresh-default",
    idToken: String? = nil,
    email: String? = nil,
    projectID: String? = nil,
    expiry: String = "2030-05-01T12:00:00.123456789Z"
) throws -> Data {
    var object: [String: Any] = [
        "access_token": access,
        "token_type": "Bearer",
        "expiry": expiry,
    ]
    if let refresh { object["refresh_token"] = refresh }
    if let idToken { object["id_token"] = idToken }
    if let email { object["email"] = email }
    if let projectID { object["project_id"] = projectID }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private actor LiveAntigravityStub {
    var current: Data?
    var writes: [Data] = []
    var deletes = 0

    init(_ initial: Data?) {
        current = initial
    }

    func set(_ value: Data?) {
        current = value
    }

    var credential: LiveAntigravityCredential {
        LiveAntigravityCredential(
            read: { [self] in await self.readValue() },
            write: { [self] data in await self.writeValue(data) },
            delete: { [self] in await self.deleteValue() }
        )
    }

    private func readValue() -> Data? { current }
    private func writeValue(_ data: Data) {
        current = data
        writes.append(data)
    }
    private func deleteValue() {
        current = nil
        deletes += 1
    }
}

private struct TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AISwitchAntigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Test("AntigravityCredentialStore wraps/unwraps go-keyring-base64, parses Go oauth2.Token nanosecond expiry, and merges refreshes")
func keyringEncodingAndTokenParsing() throws {
    let jwt = try makeJWT(claims: ["sub": "google-sub-1", "email": "alice@gmail.com"])
    let raw = try antigravityTokenJSON(
        access: "ya29.valid",
        refresh: "1//refresh-a",
        idToken: jwt,
        projectID: "proj-1",
        expiry: "2030-05-01T12:34:56.123456789Z"
    )
    let wrapped = AntigravityCredentialStore.wrapKeyringPayload(raw)
    #expect(String(decoding: wrapped, as: UTF8.self).hasPrefix("go-keyring-base64:"))
    #expect(AntigravityCredentialStore.unwrapKeyringPayload(wrapped) == raw)

    // Hex-encoded output as produced by macOS `security find-generic-password -w`
    let hexWrapped = Data(wrapped.map { String(format: "%02x", $0) }.joined().utf8)
    #expect(AntigravityCredentialStore.unwrapKeyringPayload(hexWrapped) == raw)

    let parsed = try #require(AntigravityCredentialStore.parse(wrapped))
    #expect(parsed.accessToken == "ya29.valid")
    #expect(parsed.refreshToken == "1//refresh-a")
    #expect(parsed.email == "alice@gmail.com")
    #expect(parsed.projectID == "proj-1")
    #expect(parsed.expiresAt != nil)

    // Valid vs expired token check
    let beforeExpiry = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try AntigravityCredentialStore.accessToken(from: wrapped, now: beforeExpiry) == "ya29.valid")
    let expiredRaw = try antigravityTokenJSON(access: "ya29.old", expiry: "2020-01-01T00:00:00Z")
    do {
        _ = try AntigravityCredentialStore.accessToken(from: expiredRaw, now: beforeExpiry)
        Issue.record("Expected antigravitySessionExpired")
    } catch AISwitchError.antigravitySessionExpired {}

    // Nested oauth_token shape
    let nested = Data(#"{"oauth_token":{"access_token":"ya29.nested","refresh_token":"1//nested-r","expiry":"2030-06-01T00:00:00Z"},"user_email":"nested@gmail.com"}"#.utf8)
    let parsedNested = try #require(AntigravityCredentialStore.parse(nested))
    #expect(parsedNested.accessToken == "ya29.nested")
    #expect(parsedNested.refreshToken == "1//nested-r")
    #expect(parsedNested.email == "nested@gmail.com")

    // Merge preserves refresh_token, id_token, project_id omitted in a refreshed token
    let refreshedOnly = try antigravityTokenJSON(access: "ya29.refreshed", refresh: nil, idToken: nil, projectID: nil)
    let merged = AntigravityCredentialStore.merge(newer: refreshedOnly, into: raw)
    let parsedMerged = try #require(AntigravityCredentialStore.parse(merged))
    #expect(parsedMerged.accessToken == "ya29.refreshed")
    #expect(parsedMerged.refreshToken == "1//refresh-a")
    #expect(parsedMerged.idToken == jwt)
    #expect(parsedMerged.projectID == "proj-1")

    // Equivalence ignores keyring base64 wrapping
    #expect(AntigravityCredentialStore.areEquivalent(raw, wrapped))
    #expect(!AntigravityCredentialStore.areEquivalent(raw, merged))
}

@Test("CredentialIdentity extracts offline Google sub and email from an Antigravity id_token")
func offlineIdentityFromIdToken() throws {
    let jwt = try makeJWT(claims: ["sub": "10987654321", "email": "dev@example.com"])
    let data = try antigravityTokenJSON(access: "ya29.abc", idToken: jwt)
    let identity = try #require(CredentialIdentity.antigravity(credentialData: data))
    #expect(identity.user == "10987654321")
    #expect(identity.organization == nil)
    #expect(identity.email == "dev@example.com")
}

@Test("UsageService parses Antigravity quota summary groups, 3p-only fallback, model buckets, and subscription tiers")
func parseQuotaSummaryAndFallback() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let summaryPayload: [String: Any] = [
        "groups": [
            [
                "id": "gemini-models",
                "displayName": "Gemini models",
                "buckets": [
                    ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.72, "resetTime": "2027-01-15T20:00:00Z"],
                    ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.45, "resetTime": "2027-01-20T00:00:00Z"],
                ],
            ],
            [
                "id": "3p-models",
                "displayName": "Claude and GPT models",
                "buckets": [
                    ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.2, "resetTime": "2027-01-21T00:00:00Z"],
                ],
            ],
        ],
    ]
    let snapshot = UsageService.parseAntigravityQuotaSummary(summaryPayload, now: now)
    #expect(snapshot.session?.usedPercent == 28)
    #expect(snapshot.weekly?.usedPercent == 55)
    #expect(snapshot.scoped.count == 1)
    #expect(snapshot.scoped[0].name == "Claude/GPT")
    #expect(snapshot.scoped[0].window.usedPercent == 80)
    #expect(snapshot.note == nil)

    // 3p-only response promotes 3p buckets to session/weekly without duplicating in scoped
    let only3p = UsageService.parseAntigravityQuotaSummary([
        "groups": [[
            "id": "3p-models",
            "buckets": [
                ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.6],
                ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.85],
            ],
        ]],
    ], now: now)
    #expect(only3p.session?.usedPercent == 40)
    #expect(only3p.weekly?.usedPercent == 15)
    #expect(only3p.scoped.isEmpty)

    // Empty groups note
    let empty = UsageService.parseAntigravityQuotaSummary(["groups": []], now: now)
    #expect(empty.session == nil && empty.weekly == nil && empty.scoped.isEmpty)
    #expect(empty.note?.contains("did not report") == true)

    // Fallback model buckets skip _vertex duplicates
    let buckets = UsageService.parseAntigravityModelBuckets([
        "buckets": [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.65, "resetTime": "2027-01-16T04:00:00Z"],
            ["modelId": "gemini-2.5-pro_vertex", "remainingFraction": 0.05, "resetTime": "2027-01-16T01:00:00Z"],
            ["modelId": "gemini-2.5-flash", "remainingFraction": 0.9, "resetTime": "2027-01-16T05:00:00Z"],
        ],
    ], now: now)
    #expect(buckets.session?.usedPercent == 35)
    #expect(buckets.weekly?.usedPercent == 10)

    // loadCodeAssist tier & project parsing
    let ultra = UsageService.parseAntigravityCodeAssist([
        "cloudaicompanionProject": "proj-ultra",
        "paidTier": ["id": "g1-ultra-tier"],
    ])
    #expect(ultra.projectID == "proj-ultra")
    #expect(ultra.plan == "ultra")

    let proObj = UsageService.parseAntigravityCodeAssist([
        "cloudaicompanionProject": ["id": "proj-pro"],
        "currentTier": ["id": "g1-pro-tier"],
    ])
    #expect(proObj.projectID == "proj-pro")
    #expect(proObj.plan == "pro")
    #expect(UsageService.parseAntigravityPlan(["id": "standard-tier"]) == "standard")
    #expect(UsageService.parseAntigravityPlan(["id": "free-tier"]) == "free")
    #expect(UsageService.parseAntigravityPlan(["id": "legacy-tier"]) == "legacy")
}

@Test("AccountLoginService authenticates and renews Antigravity via agy while always restoring the prior live credential")
func loginAndRenewalWithFakeAgyCLI() async throws {
    let temp = try TempDir()
    defer { temp.remove() }

    let keychainFile = temp.url.appendingPathComponent("fake-keychain.txt")
    let invocationsFile = temp.url.appendingPathComponent("invocations.log")
    let live = LiveAntigravityCredential(
        read: {
            guard FileManager.default.fileExists(atPath: keychainFile.path) else { return nil }
            let data = try Data(contentsOf: keychainFile)
            return data.isEmpty ? nil : AntigravityCredentialStore.unwrapKeyringPayload(data)
        },
        write: { data in
            try AntigravityCredentialStore.wrapKeyringPayload(data).write(to: keychainFile, options: .atomic)
        },
        delete: {
            try? FileManager.default.removeItem(at: keychainFile)
        }
    )

    let priorLive = try antigravityTokenJSON(access: "ya29.prior-live", refresh: "1//prior", email: "prior@gmail.com")
    let newLogin = try antigravityTokenJSON(access: "ya29.new-login", refresh: "1//new", email: "new@gmail.com")
    let newLoginWrapped = String(decoding: AntigravityCredentialStore.wrapKeyringPayload(newLogin), as: UTF8.self)
    let refreshedOnly = try antigravityTokenJSON(access: "ya29.renewed", refresh: nil, expiry: "2030-08-01T00:00:00Z")
    let refreshedWrapped = String(decoding: AntigravityCredentialStore.wrapKeyringPayload(refreshedOnly), as: UTF8.self)

    // Fake `agy` binary supporting `acp --login`, `models`, and `-p`
    let fakeAgy = temp.url.appendingPathComponent("agy")
    let script = """
    #!/bin/sh
    echo "$*" >> "\(invocationsFile.path)"
    if [ "$1" = "acp" ] && [ "$2" = "--login" ]; then
      if [ -n "$GEMINI_API_KEY" ] || [ -n "$ANTIGRAVITY_API_KEY" ]; then
        echo "API key env leaked" >&2
        exit 2
      fi
      if [ -f "\(temp.url.appendingPathComponent("fail-login").path)" ]; then
        echo "login failed" >&2
        exit 1
      fi
      printf '%s' '\(newLoginWrapped)' > "\(keychainFile.path)"
      exit 0
    fi
    if [ "$1" = "models" ]; then
      if [ -f "\(temp.url.appendingPathComponent("models-no-refresh").path)" ]; then
        exit 0
      fi
      printf '%s' '\(refreshedWrapped)' > "\(keychainFile.path)"
      exit 0
    fi
    if [ "$1" = "-p" ]; then
      printf '%s' '\(refreshedWrapped)' > "\(keychainFile.path)"
      echo "OK"
      exit 0
    fi
    exit 1
    """
    try Data(script.utf8).write(to: fakeAgy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

    // 1. Successful login captures new credential into profile and restores prior live credential
    try await live.write(priorLive)
    let profileDir = temp.url.appendingPathComponent("profile-new", isDirectory: true)
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
    try await AccountLoginService.authenticate(provider: .antigravity, directory: profileDir, executable: fakeAgy, liveAntigravity: live)

    let captured = try AntigravityCredentialStore.readProfile(directory: profileDir.path)
    #expect(AntigravityCredentialStore.parse(captured)?.accessToken == "ya29.new-login")
    let restoredAfterLogin = try #require(try await live.read())
    #expect(AntigravityCredentialStore.areEquivalent(restoredAfterLogin, priorLive))

    // 2. Failed login still restores prior live credential
    let failDir = temp.url.appendingPathComponent("profile-fail", isDirectory: true)
    try FileManager.default.createDirectory(at: failDir, withIntermediateDirectories: true)
    try Data().write(to: temp.url.appendingPathComponent("fail-login"))
    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: failDir, executable: fakeAgy, liveAntigravity: live)
    }
    try FileManager.default.removeItem(at: temp.url.appendingPathComponent("fail-login"))
    let restoredAfterFailure = try #require(try await live.read())
    #expect(AntigravityCredentialStore.areEquivalent(restoredAfterFailure, priorLive))

    // 3. Renewal via `agy models` (zero LLM quota) preserves refresh_token and restores prior live credential
    let expiredProfileDir = temp.url.appendingPathComponent("profile-expired", isDirectory: true)
    try FileManager.default.createDirectory(at: expiredProfileDir, withIntermediateDirectories: true)
    let expired = try antigravityTokenJSON(access: "ya29.expired", refresh: "1//keep-me", email: "user@gmail.com", expiry: "2020-01-01T00:00:00Z")
    try expired.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: expiredProfileDir))
    try Data().write(to: invocationsFile)

    try await AccountLoginService.renew(provider: .antigravity, directory: expiredProfileDir, executable: fakeAgy, liveAntigravity: live)
    let renewedProfile = try AntigravityCredentialStore.readProfile(directory: expiredProfileDir.path)
    let parsedRenewed = try #require(AntigravityCredentialStore.parse(renewedProfile))
    #expect(parsedRenewed.accessToken == "ya29.renewed")
    #expect(parsedRenewed.refreshToken == "1//keep-me")
    #expect(parsedRenewed.email == "user@gmail.com")
    let restoredAfterModels = try #require(try await live.read())
    #expect(AntigravityCredentialStore.areEquivalent(restoredAfterModels, priorLive))
    let logAfterModels = try String(contentsOf: invocationsFile, encoding: .utf8)
    #expect(logAfterModels.contains("models"))
    #expect(!logAfterModels.contains("-p "))

    // 4. When `agy models` leaves token expired, falls back to `agy -p`
    try expired.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: expiredProfileDir))
    try Data().write(to: temp.url.appendingPathComponent("models-no-refresh"))
    try Data().write(to: invocationsFile)

    try await AccountLoginService.renew(provider: .antigravity, directory: expiredProfileDir, executable: fakeAgy, liveAntigravity: live)
    let renewedFallback = try AntigravityCredentialStore.readProfile(directory: expiredProfileDir.path)
    #expect(AntigravityCredentialStore.parse(renewedFallback)?.accessToken == "ya29.renewed")
    #expect(AntigravityCredentialStore.parse(renewedFallback)?.refreshToken == "1//keep-me")
    let logAfterFallback = try String(contentsOf: invocationsFile, encoding: .utf8)
    #expect(logAfterFallback.contains("models"))
    #expect(logAfterFallback.contains("-p "))
    let restoredAfterFallback = try #require(try await live.read())
    #expect(AntigravityCredentialStore.areEquivalent(restoredAfterFallback, priorLive))
}

@Test("AccountStore imports, switches, preserves refreshed tokens, and guards automatic renewal while agy is running")
@MainActor
func accountStoreImportSwitchAndRenewalGuards() async throws {
    let temp = try TempDir()
    defer { temp.remove() }

    let jwtA = try makeJWT(claims: ["sub": "sub-a", "email": "alice@gmail.com"])
    let jwtB = try makeJWT(claims: ["sub": "sub-b", "email": "bob@gmail.com"])
    let credA = try antigravityTokenJSON(access: "ya29.a1", refresh: "1//ra", idToken: jwtA)
    let credARefreshed = try antigravityTokenJSON(access: "ya29.a2", refresh: "1//ra", idToken: jwtA)
    let credB = try antigravityTokenJSON(access: "ya29.b1", refresh: "1//rb", idToken: jwtB)

    let live = LiveAntigravityStub(AntigravityCredentialStore.wrapKeyringPayload(credA))
    let runningState = LockedFlag(false)
    let renewCalls = LockedCounter()
    let inspectCalls = LockedCounter()
    let expireNext = LockedFlag(false)

    let store = AccountStore(
        supportDirectory: temp.url,
        startsAutomatically: false,
        login: { _, dir in
            try credB.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: dir))
        },
        inspect: { profile in
            inspectCalls.increment()
            if expireNext.value { throw AISwitchError.antigravitySessionExpired }
            let data = try AntigravityCredentialStore.readProfile(directory: profile.profileDirectory)
            let email = AntigravityCredentialStore.parse(data)?.email
            return ProviderInspection(email: email, plan: "pro", usage: UsageSnapshot(
                session: UsageWindow(usedPercent: 25, resetsAt: nil),
                weekly: UsageWindow(usedPercent: 40, resetsAt: nil),
                scoped: [ScopedUsageWindow(name: "Claude/GPT", window: UsageWindow(usedPercent: 10, resetsAt: nil))],
                fetchedAt: Date(),
                note: nil
            ))
        },
        renew: { _, dir in
            renewCalls.increment()
            expireNext.value = false
            try credARefreshed.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: dir))
        },
        identify: { _, data in CredentialIdentity.antigravity(credentialData: data) },
        liveClaude: LiveClaudeCredential(read: { nil }, write: { _ in }, deleteProfileItem: { _ in }),
        liveAntigravity: await live.credential,
        claudeCodeRunning: { false },
        antigravityRunning: { runningState.value }
    )

    // Import Alice
    try await store.importCurrent(provider: .antigravity)
    #expect(store.profiles.count == 1)
    let alice = try #require(store.profiles.first)
    #expect(alice.email == "alice@gmail.com")
    #expect(alice.displayName == "alice")
    #expect(store.isActive(alice))
    let perms = try FileManager.default.attributesOfItem(
        atPath: AntigravityCredentialStore.credentialURL(profileDirectory: URL(fileURLWithPath: alice.profileDirectory)).path
    )[.posixPermissions] as? Int
    #expect(perms == 0o600)

    // Add Bob (becomes active) after Alice's live token was refreshed by `agy`
    await live.set(credARefreshed)
    let inspectsBeforeAdd = inspectCalls.value
    try await store.addAccount(provider: .antigravity)
    #expect(store.profiles.count == 2)
    let bob = try #require(store.profiles.first { $0.email == "bob@gmail.com" })
    #expect(store.isActive(bob))
    // Wait for addAccount's background refresh of Bob to settle before simulating expiry.
    for _ in 0..<200 where inspectCalls.value < inspectsBeforeAdd + 2 || store.isRefreshing {
        try await Task.sleep(for: .milliseconds(5))
    }

    // Outgoing Alice profile saved the refreshed live token, and Bob is now live
    let savedAlice = try AntigravityCredentialStore.readProfile(directory: alice.profileDirectory)
    #expect(AntigravityCredentialStore.parse(savedAlice)?.accessToken == "ya29.a2")
    let liveNow = try #require(await live.current)
    #expect(AntigravityCredentialStore.parse(liveNow)?.accessToken == "ya29.b1")

    // While `agy` is running, automatic renewal is skipped for BOTH active (Bob) and inactive (Alice) accounts
    runningState.value = true
    expireNext.value = true
    await store.refresh(bob.id)
    await store.refresh(alice.id)
    #expect(renewCalls.value == 0)
    #expect(store.profiles.first { $0.id == bob.id }?.authIssue?.contains("Antigravity is running with this account") == true)
    #expect(store.profiles.first { $0.id == alice.id }?.authIssue?.contains("Quit it or choose Renew sign-in") == true)

    // Once `agy` exits, automatic renewal proceeds for Alice
    runningState.value = false
    await store.refresh(alice.id)
    #expect(renewCalls.value == 1)
    #expect(store.profiles.first { $0.id == alice.id }?.authIssue == nil)

    // signInAgain refuses a different Google account without altering Alice's profile
    await #expect(throws: AISwitchError.self) {
        try await store.signInAgain(alice.id)
    }
    let aliceAfterRefused = try AntigravityCredentialStore.readProfile(directory: alice.profileDirectory)
    #expect(AntigravityCredentialStore.parse(aliceAfterRefused)?.email == "alice@gmail.com")
}

@Test("RemoteSync, OmpBridge, and AgentCLI handle Antigravity accounts cleanly without leaking refresh tokens")
func remoteSyncOmpAndAgentCLI() throws {
    let temp = try TempDir()
    defer { temp.remove() }

    let profileDir = temp.url.appendingPathComponent("agy", isDirectory: true)
    try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
    let raw = try antigravityTokenJSON(access: "ya29.sync-access", refresh: "1//top-secret-refresh", email: "pray@gmail.com")
    try raw.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: profileDir))
    AntigravityCredentialStore.saveProjectID("proj-agy-42", profileDirectory: profileDir)

    let profile = AccountProfile(
        id: UUID(),
        provider: .antigravity,
        displayName: "pray",
        email: "pray@gmail.com",
        plan: "ultra",
        profileDirectory: profileDir.path,
        createdAt: Date(),
        lastActivatedAt: Date(),
        usage: UsageSnapshot(
            session: UsageWindow(usedPercent: 20, resetsAt: nil),
            weekly: UsageWindow(usedPercent: 35, resetsAt: nil),
            scoped: [ScopedUsageWindow(name: "Claude/GPT", window: UsageWindow(usedPercent: 50, resetsAt: nil))],
            fetchedAt: Date(),
            note: nil
        ),
        authIssue: nil
    )

    // RemoteSync pushes access token + cached project ID + expiry, never refresh token
    let payload = RemoteSync.payload(profiles: [profile], activeProfileIDs: ["antigravity": profile.id])
    let pushed = try #require(payload.accounts.first)
    #expect(pushed.provider == .antigravity)
    #expect(pushed.token?.accessToken == "ya29.sync-access")
    #expect(pushed.token?.accountId == "proj-agy-42")
    #expect(pushed.token?.expiresAt != nil)
    let encoded = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)
    #expect(!encoded.contains("1//top-secret-refresh"))

    // OmpBridge matches google-antigravity by email & project
    let ompAccount = try #require(OmpAccount(provider: .antigravity, identityKey: "email:pray@gmail.com|project:proj-agy-42"))
    #expect(ompAccount.ompProvider == "google-antigravity")
    #expect(OmpAccount.matching(profile, in: [ompAccount]) == ompAccount)
    let policy = OmpAccountPolicy.preferring(ompAccount, priority: 10)
    #expect(policy.provider == "google-antigravity")
    #expect(policy.account.projectId == "proj-agy-42")
    #expect(policy.matches(ompAccount))

    // AgentCLI summary and table
    let summary = AccountSummary(profile, active: true)
    #expect(summary.provider.listLabel == "AGY")
    #expect(summary.limits.map(\.name) == ["5-hour", "Weekly", "Claude/GPT weekly"])
    #expect(summary.limits.map(\.leftPercent) == [80, 65, 50])
    let table = AgentCLI.table([summary])
    #expect(table.contains("AGY"))
    #expect(table.contains("80%"))
    #expect(table.contains("65%"))
    #expect(table.contains("Claude/GPT weekly 50%"))
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ initial: Bool) { storage = initial }
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}
