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

/// The sign-in `agy` 1.5 keeps in the Keychain: Go's `oauth2.Token` under
/// `token`, with the account's email beside it.
private func agyCredential(
    access: String,
    refresh: String? = "1//refresh-default",
    email: String? = nil,
    expiry: String = "2030-05-01T19:00:00.123456+07:00"
) throws -> Data {
    var token: [String: Any] = ["access_token": access, "token_type": "Bearer", "expiry": expiry, "expires_in": 3599]
    if let refresh { token["refresh_token"] = refresh }
    var object: [String: Any] = ["token": token, "auth_method": "consumer"]
    if let email { object["id_token_email"] = email }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func wrapped(_ credential: Data) -> String {
    String(decoding: AntigravityCredentialStore.wrapKeyringPayload(credential), as: UTF8.self)
}

private func email(in credential: Data?) -> String? {
    credential.flatMap { AntigravityCredentialStore.parse($0)?.email }
}

/// Who Google says an access token belongs to. Like the real lookup, an
/// expired token gets no answer.
private let googleIdentity: @Sendable (AIProvider, Data) async -> AccountIdentity? = { _, data in
    guard (try? AntigravityCredentialStore.accessToken(from: data)) != nil,
          let email = AntigravityCredentialStore.parse(data)?.email else { return nil }
    return AccountIdentity(user: "google-\(email)", organization: nil, email: email)
}

/// The login Keychain item, kept in a file the way `agy` writes it.
private func fileKeychain(_ file: URL) -> LiveAntigravityCredential {
    LiveAntigravityCredential(
        read: {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            return data.isEmpty ? nil : AntigravityCredentialStore.unwrapKeyringPayload(data)
        },
        write: { data in try AntigravityCredentialStore.wrapKeyringPayload(data).write(to: file, options: .atomic) },
        delete: { try? FileManager.default.removeItem(at: file) }
    )
}

/// The stand-in `agy` every test here launches. macOS checks a new executable
/// the first time it runs, which takes a moment and slows every command launched
/// meanwhile, so there is just one, kept between runs. It logs its arguments to
/// `agy.log` and does what `agy.sh` says, both in the folder it runs in: the
/// profile folder, like the real `agy`.
private let fakeAgy: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchTests/agy")
    let script = Data("#!/bin/sh\necho \"$*\" >> agy.log\n. ./agy.sh\nexit 1\n".utf8)
    if (try? Data(contentsOf: url)) != script {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? script.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return url
}()

/// Tells the fake `agy` what to do when it runs in each of `directories`.
private func scriptAgy(_ script: String, in directories: URL...) throws {
    for directory in directories {
        try Data(script.utf8).write(to: directory.appendingPathComponent("agy.sh"))
    }
}

private struct TimedOut: Error {}

private func waitUntil(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut() }
        try await Task.sleep(for: .milliseconds(10))
    }
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
    func directory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Test("agy's Keychain sign-in round-trips through go-keyring-base64 and parses with its email, nanosecond expiry, and refresh merging")
func keyringEncodingAndTokenParsing() throws {
    let raw = try agyCredential(access: "ya29.valid", refresh: "1//refresh-a", email: "alice@gmail.com",
                                expiry: "2030-05-01T19:34:56.123456789+07:00")
    let wrappedRaw = AntigravityCredentialStore.wrapKeyringPayload(raw)
    #expect(String(decoding: wrappedRaw, as: UTF8.self).hasPrefix("go-keyring-base64:"))
    #expect(AntigravityCredentialStore.unwrapKeyringPayload(wrappedRaw) == raw)

    // Hex-encoded output as produced by macOS `security find-generic-password -w`
    let hexWrapped = Data(wrappedRaw.map { String(format: "%02x", $0) }.joined().utf8)
    #expect(AntigravityCredentialStore.unwrapKeyringPayload(hexWrapped) == raw)

    let parsed = try #require(AntigravityCredentialStore.parse(wrappedRaw))
    #expect(parsed.accessToken == "ya29.valid")
    #expect(parsed.refreshToken == "1//refresh-a")
    #expect(parsed.email == "alice@gmail.com")
    let expected = try #require(ISO8601DateFormatter().date(from: "2030-05-01T12:34:56Z")).addingTimeInterval(0.123)
    #expect(abs(try #require(parsed.expiresAt).timeIntervalSince(expected)) < 0.001)

    // Valid vs expired token check
    let beforeExpiry = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try AntigravityCredentialStore.accessToken(from: wrappedRaw, now: beforeExpiry) == "ya29.valid")
    let expiredRaw = try agyCredential(access: "ya29.old", expiry: "2020-01-01T00:00:00Z")
    do {
        _ = try AntigravityCredentialStore.accessToken(from: expiredRaw, now: beforeExpiry)
        Issue.record("Expected antigravitySessionExpired")
    } catch AISwitchError.antigravitySessionExpired {}

    // An older flat `oauth_token` shape still parses.
    let nested = Data(#"{"oauth_token":{"access_token":"ya29.nested","refresh_token":"1//nested-r","expiry":"2030-06-01T00:00:00Z"},"user_email":"nested@gmail.com"}"#.utf8)
    let parsedNested = try #require(AntigravityCredentialStore.parse(nested))
    #expect(parsedNested.accessToken == "ya29.nested")
    #expect(parsedNested.refreshToken == "1//nested-r")
    #expect(parsedNested.email == "nested@gmail.com")

    // A refresh saved without the refresh token or email keeps them, inside `token` where agy nests them.
    let refreshedOnly = try agyCredential(access: "ya29.refreshed", refresh: nil, email: nil)
    let merged = AntigravityCredentialStore.merge(newer: refreshedOnly, into: raw)
    let parsedMerged = try #require(AntigravityCredentialStore.parse(merged))
    #expect(parsedMerged.accessToken == "ya29.refreshed")
    #expect(parsedMerged.refreshToken == "1//refresh-a")
    #expect(parsedMerged.email == "alice@gmail.com")

    // Equivalence ignores keyring base64 wrapping
    #expect(AntigravityCredentialStore.areEquivalent(raw, wrappedRaw))
    #expect(!AntigravityCredentialStore.areEquivalent(raw, merged))
}

@Test("CredentialIdentity extracts offline Google sub and email from an Antigravity id_token")
func offlineIdentityFromIdToken() throws {
    let jwt = try makeJWT(claims: ["sub": "10987654321", "email": "dev@example.com"])
    let data = Data(#"{"access_token":"ya29.abc","refresh_token":"1//r","expiry":"2030-05-01T12:00:00Z","id_token":"\#(jwt)"}"#.utf8)
    let identity = try #require(CredentialIdentity.antigravity(credentialData: data))
    #expect(identity.user == "10987654321")
    #expect(identity.organization == nil)
    #expect(identity.email == "dev@example.com")
}

@Test("UsageService parses Antigravity quota groups, keeps Claude/GPT apart from Gemini's own limits, and reads subscription tiers")
func parseQuotaSummary() throws {
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

    // Without a Gemini group, Claude/GPT stays Claude/GPT instead of standing in for the 5-hour and weekly limits.
    let only3p = UsageService.parseAntigravityQuotaSummary([
        "groups": [[
            "id": "3p-models",
            "buckets": [
                ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.6],
                ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.85],
            ],
        ]],
    ], now: now)
    #expect(only3p.session == nil)
    #expect(only3p.weekly == nil)
    #expect(only3p.scoped.map(\.name) == ["Claude/GPT"])
    #expect(only3p.scoped.first?.window.usedPercent == 15)
    #expect(only3p.note == nil)

    // A 5-hour Claude/GPT bucket alone isn't shown as a weekly limit.
    let only3p5h = UsageService.parseAntigravityQuotaSummary([
        "groups": [["id": "3p-models", "buckets": [["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.6]]]],
    ], now: now)
    #expect(only3p5h.scoped.isEmpty)
    #expect(only3p5h.note?.contains("did not report") == true)

    // Empty groups note
    let empty = UsageService.parseAntigravityQuotaSummary(["groups": []], now: now)
    #expect(empty.session == nil && empty.weekly == nil && empty.scoped.isEmpty)
    #expect(empty.note?.contains("did not report") == true)

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

@Test("Antigravity sign-in takes the code the browser shows, then always puts the prior sign-in back")
@MainActor
func signInTakesPastedCode() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let keychain = temp.url.appendingPathComponent("keychain.txt")
    let codes = temp.url.appendingPathComponent("codes.log")
    let live = fileKeychain(keychain)
    let prior = try agyCredential(access: "ya29.prior-live", refresh: "1//prior", email: "prior@gmail.com")
    let newLogin = try agyCredential(access: "ya29.new-login", refresh: "1//new", email: "new@gmail.com")
    // Like `agy acp --login`: it prints the link, waits for the code on its input
    // after a prompt that ends without a newline, and reports a rejected code.
    let profile = try temp.directory("profile-new")
    let rejected = try temp.directory("profile-rejected")
    let closed = try temp.directory("profile-closed")
    let unattended = try temp.directory("profile-unattended")
    try scriptAgy("""
    if [ "$1" = "acp" ] && [ "$2" = "--login" ]; then
      if [ -n "$GEMINI_API_KEY" ] || [ -n "$ANTIGRAVITY_API_KEY" ]; then echo "API key env leaked"; exit 2; fi
      echo "Open this link in a browser to log in with Google:"
      echo
      echo "  https://accounts.google.com/o/oauth2/auth?client_id=test&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback"
      echo
      printf 'Then paste the authorization code, or the full URL of the page you land on, and press Enter: '
      read code
      echo "$code" >> "\(codes.path)"
      if [ "$code" = "good-code" ]; then
        printf '%s' '\(wrapped(newLogin))' > "\(keychain.path)"
        echo "Logged in as new@gmail.com."
        exit 0
      fi
      echo "couldn't log in: invalid_grant"
      exit 1
    fi
    """, in: profile, rejected, closed, unattended)
    try await live.write(prior)
    let prompt = SignInCodePrompt()

    // The code pasted into the window reaches agy, and the new sign-in is captured.
    let signIn = Task {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: profile, codePrompt: prompt,
                                                   executable: fakeAgy, liveAntigravity: live)
    }
    try await waitUntil { prompt.signInPage != nil }
    #expect(prompt.signInPage?.host == "accounts.google.com")
    prompt.submit("  good-code\n")
    try await signIn.value
    let captured = try AntigravityCredentialStore.readProfile(directory: profile.path)
    #expect(AntigravityCredentialStore.parse(captured)?.accessToken == "ya29.new-login")
    #expect(email(in: try await live.read()) == "prior@gmail.com")
    #expect(try String(contentsOf: codes, encoding: .utf8) == "good-code\n")

    // A code agy rejects fails with agy's reason, not its instructions; the prior sign-in is back.
    let rejectedSignIn = Task {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: rejected, codePrompt: prompt,
                                                   executable: fakeAgy, liveAntigravity: live)
    }
    try await waitUntil { prompt.signInPage != nil }
    prompt.submit("bad-code")
    do {
        try await rejectedSignIn.value
        Issue.record("A rejected code must fail the sign-in")
    } catch {
        #expect(error.localizedDescription == "couldn't log in: invalid_grant")
    }
    #expect(email(in: try await live.read()) == "prior@gmail.com")

    // Closing the window while agy waits for the code stops it and changes nothing.
    let closedSignIn = Task {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: closed, codePrompt: prompt,
                                                   executable: fakeAgy, liveAntigravity: live)
    }
    try await waitUntil { prompt.signInPage != nil }
    closedSignIn.cancel()
    await #expect(throws: CancellationError.self) { try await closedSignIn.value }
    try await waitUntil { prompt.signInPage == nil }
    #expect(email(in: try await live.read()) == "prior@gmail.com")
    #expect(!FileManager.default.fileExists(atPath: AntigravityCredentialStore.credentialURL(profileDirectory: closed).path))

    // With no window to ask, the sign-in fails at once instead of waiting for a code.
    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: unattended, executable: fakeAgy, liveAntigravity: live)
    }
    #expect(email(in: try await live.read()) == "prior@gmail.com")
}

@Test("Antigravity renewal refreshes through agy models alone, keeps what a refresh leaves out, and always puts the prior sign-in back")
func renewalThroughAgyModels() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let keychain = temp.url.appendingPathComponent("keychain.txt")
    let offline = temp.url.appendingPathComponent("offline")
    let otherAccount = temp.url.appendingPathComponent("other-account")
    let live = fileKeychain(keychain)
    let prior = try agyCredential(access: "ya29.prior-live", refresh: "1//prior", email: "prior@gmail.com")
    // A refresh saved without the refresh token, as an OAuth refresh can be.
    let refreshed = try agyCredential(access: "ya29.renewed", refresh: nil, email: "user@gmail.com", expiry: "2031-08-01T00:00:00Z")
    let stranger = try agyCredential(access: "ya29.other", refresh: "1//other", email: "other@gmail.com", expiry: "2031-08-01T00:00:00Z")
    let profile = try temp.directory("profile")
    let log = profile.appendingPathComponent("agy.log")
    try scriptAgy("""
    if [ "$1" = "models" ]; then
      if [ -f "\(offline.path)" ]; then
        echo "Error: Please sign in to view available models. Launch the CLI without arguments to sign in."
        exit 1
      fi
      if [ -f "\(otherAccount.path)" ]; then
        printf '%s' '\(wrapped(stranger))' > "\(keychain.path)"
        exit 0
      fi
      printf '%s' '\(wrapped(refreshed))' > "\(keychain.path)"
      exit 0
    fi
    """, in: profile)
    try await live.write(prior)
    let credentials = AntigravityCredentialStore.credentialURL(profileDirectory: profile)
    let expired = try agyCredential(access: "ya29.expired", refresh: "1//keep-me", email: "user@gmail.com", expiry: "2020-01-01T00:00:00Z")
    try expired.write(to: credentials)

    try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
    let renewed = try #require(AntigravityCredentialStore.parse(try Data(contentsOf: credentials)))
    #expect(renewed.accessToken == "ya29.renewed")
    #expect(renewed.refreshToken == "1//keep-me")
    #expect(renewed.email == "user@gmail.com")
    #expect(email(in: try await live.read()) == "prior@gmail.com")
    #expect(try String(contentsOf: log, encoding: .utf8) == "models\n")

    // When agy can't refresh (offline, or a sign-in Google no longer accepts), renewal says so plainly and changes nothing.
    try expired.write(to: credentials)
    try Data().write(to: offline)
    do {
        try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
        Issue.record("A renewal agy couldn't refresh must fail")
    } catch {
        #expect(error.localizedDescription.contains("couldn't refresh"))
        #expect(!error.localizedDescription.contains("Launch the CLI"))
    }
    #expect(try Data(contentsOf: credentials) == expired)
    #expect(email(in: try await live.read()) == "prior@gmail.com")
    try FileManager.default.removeItem(at: offline)

    // Another account's sign-in saved meanwhile is never taken for this account's.
    try Data().write(to: otherAccount)
    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
    }
    #expect(try Data(contentsOf: credentials) == expired)
    #expect(email(in: try await live.read()) == "prior@gmail.com")
    #expect(try String(contentsOf: log, encoding: .utf8) == "models\nmodels\nmodels\n")
}

@Test("A Keychain that can't be read stops Antigravity sign-in and renewal before agy's sign-in is touched")
func unreadableKeychainChangesNothing() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let login = try temp.directory("login")
    let profile = try temp.directory("profile")
    try scriptAgy("exit 0", in: login, profile)
    let changes = LockedCounter()
    let live = LiveAntigravityCredential(
        read: { throw AISwitchError.commandFailed("Keychain read failed: timed out") },
        write: { _ in changes.increment() },
        delete: { changes.increment() }
    )
    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.authenticate(provider: .antigravity, directory: login, executable: fakeAgy, liveAntigravity: live)
    }
    try agyCredential(access: "ya29.expired", refresh: "1//r", email: "user@gmail.com", expiry: "2020-01-01T00:00:00Z")
        .write(to: AntigravityCredentialStore.credentialURL(profileDirectory: profile))
    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
    }
    #expect(changes.value == 0)
    #expect(!FileManager.default.fileExists(atPath: login.appendingPathComponent("agy.log").path))
    #expect(!FileManager.default.fileExists(atPath: profile.appendingPathComponent("agy.log").path))
}

@Test("A Keychain write that fails during renewal doesn't leave later sign-ins and renewals waiting")
func failedWriteDoesNotBlockLaterRenewals() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let keychain = temp.url.appendingPathComponent("keychain.txt")
    let refreshed = try agyCredential(access: "ya29.renewed", refresh: "1//r", email: "user@gmail.com", expiry: "2031-01-01T00:00:00Z")
    let profile = try temp.directory("profile")
    try scriptAgy("""
    if [ "$1" = "models" ]; then
      printf '%s' '\(wrapped(refreshed))' > "\(keychain.path)"
      exit 0
    fi
    """, in: profile)
    let file = fileKeychain(keychain)
    let failNextWrite = LockedFlag(true)
    let live = LiveAntigravityCredential(
        read: file.read,
        write: { data in
            if failNextWrite.value {
                failNextWrite.value = false
                throw AISwitchError.commandFailed("Keychain write failed")
            }
            try await file.write(data)
        },
        delete: file.delete
    )
    let credentials = AntigravityCredentialStore.credentialURL(profileDirectory: profile)
    try agyCredential(access: "ya29.expired", refresh: "1//r", email: "user@gmail.com", expiry: "2020-01-01T00:00:00Z")
        .write(to: credentials)

    await #expect(throws: AISwitchError.self) {
        try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
    }
    let finished = LockedFlag(false)
    let next = Task {
        try await AccountLoginService.renew(provider: .antigravity, directory: profile, executable: fakeAgy, liveAntigravity: live)
        finished.value = true
    }
    try await waitUntil(timeout: .seconds(5)) { finished.value }
    try await next.value
    #expect(AntigravityCredentialStore.parse(try Data(contentsOf: credentials))?.accessToken == "ya29.renewed")
}

@Test("AccountStore imports, switches, preserves refreshed tokens, and guards automatic renewal while agy is running")
@MainActor
func accountStoreImportSwitchAndRenewalGuards() async throws {
    let temp = try TempDir()
    defer { temp.remove() }

    let credA = try agyCredential(access: "ya29.a1", refresh: "1//ra", email: "alice@gmail.com")
    let credARefreshed = try agyCredential(access: "ya29.a2", refresh: "1//ra", email: "alice@gmail.com")
    let credB = try agyCredential(access: "ya29.b1", refresh: "1//rb", email: "bob@gmail.com")

    let live = LiveAntigravityStub(AntigravityCredentialStore.wrapKeyringPayload(credA))
    let runningState = LockedFlag(false)
    let renewCalls = LockedCounter()
    let inspectCalls = LockedCounter()
    let expireNext = LockedFlag(false)

    let store = AccountStore(
        supportDirectory: temp.url,
        startsAutomatically: false,
        login: { _, dir, _ in
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
        identify: googleIdentity,
        liveClaude: LiveClaudeCredential(read: { nil }, write: { _ in }, deleteProfileItem: { _ in }),
        liveAntigravity: await live.credential,
        claudeCodeRunning: { false },
        antigravityRunning: { runningState.value },
        codexSessions: nil
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
    try await waitUntil { inspectCalls.value >= inspectsBeforeAdd + 2 && !store.isRefreshing }

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

/// Two Antigravity accounts saved in a store whose renewal runs the fake `agy`
/// against `live`; A is active.
@MainActor
private func twoAccounts(in temp: TempDir, live: LiveAntigravityCredential) async throws
    -> (store: AccountStore, a: AccountProfile, b: AccountProfile) {
    let credA = try agyCredential(access: "ya29.A", refresh: "1//A", email: "a@gmail.com")
    let credB = try agyCredential(access: "ya29.B", refresh: "1//B", email: "b@gmail.com")
    try await live.write(credA)
    let store = AccountStore(
        supportDirectory: temp.url,
        startsAutomatically: false,
        login: { _, dir, _ in try credB.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: dir)) },
        inspect: { profile in
            let data = try AntigravityCredentialStore.readProfile(directory: profile.profileDirectory)
            _ = try AntigravityCredentialStore.accessToken(from: data)
            return ProviderInspection(email: AntigravityCredentialStore.parse(data)?.email, plan: "pro", usage: nil)
        },
        renew: { provider, dir in
            try await AccountLoginService.renew(provider: provider, directory: dir, executable: fakeAgy, liveAntigravity: live)
        },
        identify: googleIdentity,
        liveClaude: LiveClaudeCredential(read: { nil }, write: { _ in }, deleteProfileItem: { _ in }),
        liveAntigravity: live,
        claudeCodeRunning: { false },
        antigravityRunning: { false },
        codexSessions: nil
    )
    try await store.importCurrent(provider: .antigravity)
    let a = try #require(store.profiles.first)
    try await store.addAccount(provider: .antigravity)
    let b = try #require(store.profiles.first { $0.id != a.id })
    try await waitUntil { !store.isRefreshing }
    try await store.activate(a.id)
    try await waitUntil { !store.isRefreshing }
    return (store, a, b)
}

@Test("Switching while another Antigravity account renews waits until agy's sign-in is back, and each account keeps its own")
@MainActor
func switchWaitsForRenewal() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let keychain = temp.url.appendingPathComponent("keychain.txt")
    let started = temp.url.appendingPathComponent("started")
    let release = temp.url.appendingPathComponent("release")
    let live = fileKeychain(keychain)
    let renewedB = try agyCredential(access: "ya29.B-new", refresh: "1//B", email: "b@gmail.com", expiry: "2031-01-01T00:00:00Z")
    let (store, a, b) = try await twoAccounts(in: temp, live: live)
    // `agy models` takes its time, as when Google is slow to answer.
    try scriptAgy("""
    if [ "$1" = "models" ]; then
      touch "\(started.path)"
      i=0
      while [ ! -f "\(release.path)" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
      printf '%s' '\(wrapped(renewedB))' > "\(keychain.path)"
      exit 0
    fi
    """, in: URL(fileURLWithPath: b.profileDirectory))

    // B's sign-in expires, and the scheduled check renews it in the background...
    let expiredB = try agyCredential(access: "ya29.B-old", refresh: "1//B", email: "b@gmail.com", expiry: "2020-01-01T00:00:00Z")
    try expiredB.write(to: AntigravityCredentialStore.credentialURL(profileDirectory: URL(fileURLWithPath: b.profileDirectory)))
    let renewal = Task { await store.refresh(b.id) }
    try await waitUntil { FileManager.default.fileExists(atPath: started.path) }
    // ...while the user switches to it. A switch that didn't wait would be done by now.
    let switching = Task { try await store.activate(b.id) }
    try await Task.sleep(for: .milliseconds(300))
    try Data().write(to: release)
    try await switching.value
    await renewal.value
    try await waitUntil { !store.isRefreshing }

    #expect(store.isActive(b))
    #expect(email(in: try await live.read()) == "b@gmail.com")
    let savedA = try AntigravityCredentialStore.readProfile(directory: a.profileDirectory)
    #expect(AntigravityCredentialStore.parse(savedA)?.accessToken == "ya29.A")
}

@Test("A live agy sign-in naming another email is never saved into the account switched away from")
@MainActor
func anotherEmailIsNeverKept() async throws {
    let temp = try TempDir()
    defer { temp.remove() }
    let live = fileKeychain(temp.url.appendingPathComponent("keychain.txt"))
    let (store, a, b) = try await twoAccounts(in: temp, live: live)

    // agy signs in to an account AI Switch doesn't have, and that token expires before the next check.
    let stranger = try agyCredential(access: "ya29.X", refresh: "1//X", email: "x@gmail.com", expiry: "2020-01-01T00:00:00Z")
    try await live.write(stranger)
    try await store.activate(b.id)

    let savedA = try AntigravityCredentialStore.readProfile(directory: a.profileDirectory)
    #expect(AntigravityCredentialStore.parse(savedA)?.email == "a@gmail.com")
    #expect(email(in: try await live.read()) == "b@gmail.com")
}

@Test("RemoteSync, OmpBridge, and AgentCLI handle Antigravity accounts cleanly without leaking refresh tokens")
func remoteSyncOmpAndAgentCLI() throws {
    let temp = try TempDir()
    defer { temp.remove() }

    let profileDir = try temp.directory("agy")
    let raw = try agyCredential(access: "ya29.sync-access", refresh: "1//top-secret-refresh", email: "pray@gmail.com")
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

    // RemoteSync pushes the access token and its expiry, never the refresh token
    let payload = RemoteSync.payload(profiles: [profile], activeProfileIDs: ["antigravity": profile.id])
    let pushed = try #require(payload.accounts.first)
    #expect(pushed.provider == .antigravity)
    #expect(pushed.token?.accessToken == "ya29.sync-access")
    #expect(pushed.token?.accountId == nil)
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
