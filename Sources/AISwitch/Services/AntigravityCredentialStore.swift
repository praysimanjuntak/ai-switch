import Foundation

/// Antigravity CLI's live credential outside the profile files (`gemini` /
/// `antigravity` in the login Keychain, or the fallback file). Injected so
/// tests never touch the login Keychain or `~/.gemini/antigravity-cli`.
struct LiveAntigravityCredential: Sendable {
    var read: @Sendable () async throws -> Data?
    var write: @Sendable (Data) async throws -> Void
    var delete: @Sendable () async -> Void
    /// Shared by every copy, so everyone using this live sign-in takes turns.
    let gate = AntigravityKeychainGate()

    static let system = LiveAntigravityCredential(
        read: { try await AntigravityCredentialStore.readLive() },
        write: { try await AntigravityCredentialStore.writeLive($0) },
        delete: { await AntigravityCredentialStore.deleteLive() }
    )

    /// Runs `body` while nothing else reads or replaces the live sign-in. `agy`
    /// has only one, so renewing another account makes that account's sign-in
    /// live for a moment; a switch or check that saw it then would save it into
    /// the wrong account, or be undone when the renewal puts the prior sign-in
    /// back. The turn ends however `body` does.
    func withExclusiveAccess<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await gate.acquire()
        do {
            let value = try await body()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }
}

/// Hands out turns at Antigravity's live sign-in in arrival order.
actor AntigravityKeychainGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    fileprivate func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    fileprivate func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Parsed Antigravity CLI (`agy`) OAuth token fields, normalized across
/// `go-keyring` payloads stored in the macOS Keychain (`service: gemini`,
/// `account: antigravity`) and fallback `~/.gemini/antigravity-cli/antigravity-oauth-token`.
struct AntigravityOAuthToken: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var email: String?
    var projectID: String?
    var expiresAt: Date?
}

/// Antigravity CLI (`agy`) stores its single active Google OAuth credential in
/// the macOS Keychain via `zalando/go-keyring` under service `"gemini"` and
/// account `"antigravity"`, encoded with the `"go-keyring-base64:"` prefix
/// through `/usr/bin/security`. When the Keychain isn't used, it falls back to
/// `~/.gemini/antigravity-cli/antigravity-oauth-token`.
///
/// Saved profiles never touch the Keychain: each keeps the exact decoded JSON
/// payload in an owner-only (`0600`) `credentials.json` inside its profile
/// directory.
enum AntigravityCredentialStore {
    static let fileName = "credentials.json"
    static let projectFileName = "project.txt"
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    static let keyringBase64Prefix = "go-keyring-base64:"

    static var liveFallbackFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    static func credentialURL(profileDirectory: URL) -> URL {
        profileDirectory.appendingPathComponent(fileName)
    }

    static func projectURL(profileDirectory: URL) -> URL {
        profileDirectory.appendingPathComponent(projectFileName)
    }

    // MARK: Live credential (macOS Keychain `gemini`/`antigravity` + fallback file)

    /// Reads the live Antigravity CLI credential, unwrapping `go-keyring-base64:`
    /// into raw JSON bytes. Returns nil when `agy` is signed out.
    static func readLive() async throws -> Data? {
        if let raw = try await SecurityTool.read(service: keychainService, account: keychainAccount) {
            return unwrapKeyringPayload(raw)
        }
        guard FileManager.default.fileExists(atPath: liveFallbackFile.path) else { return nil }
        let fileData = try Data(contentsOf: liveFallbackFile)
        return fileData.isEmpty ? nil : unwrapKeyringPayload(fileData)
    }

    /// Writes `data` (raw JSON) as the active credential for new `agy` sessions,
    /// using `go-keyring-base64:` in the login Keychain just like `agy` itself does.
    /// Keeps any existing fallback token file in sync and falls back to it if the
    /// Keychain rejects the write.
    static func writeLive(_ data: Data) async throws {
        let raw = unwrapKeyringPayload(data)
        let encoded = wrapKeyringPayload(raw)
        if try await SecurityTool.write(encoded, service: keychainService, account: keychainAccount) {
            if FileManager.default.fileExists(atPath: liveFallbackFile.path) {
                try FileManager.default.writeOwnerOnly(raw, to: liveFallbackFile)
            }
        } else {
            try FileManager.default.writeOwnerOnly(raw, to: liveFallbackFile)
            await SecurityTool.delete(service: keychainService, account: keychainAccount)
        }
    }

    /// Clears the live `agy` credential from Keychain and any fallback file.
    static func deleteLive() async {
        await SecurityTool.delete(service: keychainService, account: keychainAccount)
        if FileManager.default.fileExists(atPath: liveFallbackFile.path) {
            try? FileManager.default.removeItem(at: liveFallbackFile)
        }
    }

    // MARK: Profile credentials

    static func readProfile(directory: String) throws -> Data {
        let url = credentialURL(profileDirectory: URL(fileURLWithPath: directory))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AISwitchError.credentialsMissing(.antigravity)
        }
        return try Data(contentsOf: url)
    }

    // MARK: `go-keyring-base64:` encoding & decoding

    /// Unwraps `zalando/go-keyring`'s `go-keyring-base64:<base64>` encoding (and
    /// any hex encoding macOS `security find-generic-password -w` produces for
    /// multiline values) back into the underlying JSON bytes.
    static func unwrapKeyringPayload(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(keyringBase64Prefix) {
            let encoded = String(text.dropFirst(keyringBase64Prefix.count))
            if let decoded = Data(base64Encoded: encoded) { return decoded }
        }
        if let unhexed = decodeHexIfValid(text) {
            let inner = String(decoding: unhexed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.hasPrefix(keyringBase64Prefix),
               let decoded = Data(base64Encoded: String(inner.dropFirst(keyringBase64Prefix.count))) {
                return decoded
            }
            if (try? JSONSerialization.jsonObject(with: unhexed)) != nil {
                return unhexed
            }
        }
        return data
    }

    /// Encodes raw credential bytes in `zalando/go-keyring`'s `go-keyring-base64:`
    /// format so `agy` decodes them identically on macOS.
    static func wrapKeyringPayload(_ data: Data) -> Data {
        let raw = unwrapKeyringPayload(data)
        return Data((keyringBase64Prefix + raw.base64EncodedString()).utf8)
    }

    // MARK: Token parsing, merging, and equivalence

    /// Extracts OAuth fields from Antigravity's JSON payload: `agy`'s own
    /// `{"token": {…}, "id_token_email": …}`, or a flat Go `oauth2.Token`, or one
    /// wrapped under `oauth_token`.
    static func parse(_ data: Data) -> AntigravityOAuthToken? {
        let raw = unwrapKeyringPayload(data)
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        let nested = (root["oauth_token"] as? [String: Any]) ?? (root["token"] as? [String: Any])

        guard let access = nonEmpty(root["access_token"])
            ?? nonEmpty(root["accessToken"])
            ?? nonEmpty(nested?["access_token"])
            ?? nonEmpty(nested?["accessToken"]) else {
            return nil
        }

        let refresh = nonEmpty(root["refresh_token"])
            ?? nonEmpty(root["refreshToken"])
            ?? nonEmpty(nested?["refresh_token"])
            ?? nonEmpty(nested?["refreshToken"])

        let idToken = nonEmpty(root["id_token"])
            ?? nonEmpty(root["idToken"])
            ?? nonEmpty(nested?["id_token"])
            ?? nonEmpty(nested?["idToken"])

        let jwtEmail = idToken.flatMap { CredentialIdentity.jwtClaims($0)?["email"] as? String }
        let email = nonEmpty(root["id_token_email"])
            ?? nonEmpty(root["email"])
            ?? nonEmpty(root["user_email"])
            ?? nonEmpty(root["userEmail"])
            ?? nonEmpty(nested?["email"])
            ?? nonEmpty(jwtEmail)

        let projectID = nonEmpty(root["project_id"])
            ?? nonEmpty(root["projectId"])
            ?? nonEmpty(root["cloudaicompanionProject"])

        let expiresAt = parseExpiry(
            root["expiry"]
                ?? root["expired"]
                ?? root["expiry_date"]
                ?? root["expires_at"]
                ?? root["expiresAt"]
                ?? nested?["expiry"]
                ?? nested?["expired"]
                ?? nested?["expiry_date"]
                ?? nested?["expires_at"]
                ?? nested?["expiresAt"]
        )

        return AntigravityOAuthToken(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            email: email,
            projectID: projectID,
            expiresAt: expiresAt
        )
    }

    /// Merges a refreshed credential into an existing one for the same account so
    /// fields a token refresh omits (`refresh_token`, `id_token`, the account's
    /// email, `project_id`) are never lost, whether they sit at the top level or
    /// inside `agy`'s `token` object (or an `oauth_token` one).
    static func merge(newer: Data, into existing: Data?) -> Data {
        let normalized = unwrapKeyringPayload(newer)
        guard let existing,
              var updated = try? JSONSerialization.jsonObject(with: normalized) as? [String: Any],
              let prior = try? JSONSerialization.jsonObject(with: unwrapKeyringPayload(existing)) as? [String: Any] else {
            return normalized
        }
        func keep(_ keys: [String], from prior: [String: Any], in updated: inout [String: Any]) -> Bool {
            var kept = false
            for key in keys where nonEmpty(updated[key]) == nil {
                guard let preserved = nonEmpty(prior[key]) else { continue }
                updated[key] = preserved
                kept = true
            }
            return kept
        }
        var changed = keep(
            ["refresh_token", "id_token", "id_token_email", "email", "user_email", "project_id", "token_type", "auth_method"],
            from: prior, in: &updated
        )
        for wrapper in ["token", "oauth_token"] {
            guard var nested = updated[wrapper] as? [String: Any],
                  let priorNested = prior[wrapper] as? [String: Any] else { continue }
            if keep(["refresh_token", "id_token", "token_type"], from: priorNested, in: &nested) {
                updated[wrapper] = nested
                changed = true
            }
        }
        guard changed,
              let merged = try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return normalized
        }
        return merged
    }

    /// True when both payloads hold the same access token, refresh token, and
    /// expiry (even if one was wrapped in `go-keyring-base64:` or differed in
    /// JSON key order).
    static func areEquivalent(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        let aRaw = unwrapKeyringPayload(lhs)
        let bRaw = unwrapKeyringPayload(rhs)
        if aRaw == bRaw { return true }
        guard let a = parse(aRaw), let b = parse(bRaw) else { return false }
        return a.accessToken == b.accessToken && a.refreshToken == b.refreshToken && a.expiresAt == b.expiresAt
    }

    /// The bearer token for Cloud Code Assist requests. Expiry is checked locally
    /// first so an expired token is renewed through `agy`.
    static func accessToken(from data: Data, now: Date = Date()) throws -> String {
        guard let token = parse(data) else {
            throw AISwitchError.invalidResponse("The saved Antigravity credential is unreadable or has no access token.")
        }
        if let expiresAt = token.expiresAt, expiresAt <= now {
            throw AISwitchError.antigravitySessionExpired
        }
        return token.accessToken
    }

    /// Google OAuth refresh tokens stay constant across access-token refreshes,
    /// so two credentials sharing one are the same sign-in.
    static func refreshToken(from data: Data) -> String? {
        parse(data)?.refreshToken
    }

    /// Whether two credentials sign in to the same Google account: by the email
    /// they name, or else by their refresh token, which Google keeps across
    /// access-token refreshes.
    static func isSameAccount(_ credential: Data, as other: Data) -> Bool {
        guard let lhs = parse(credential), let rhs = parse(other) else { return false }
        if let a = lhs.email, let b = rhs.email { return a.caseInsensitiveCompare(b) == .orderedSame }
        if let a = lhs.refreshToken, let b = rhs.refreshToken { return a == b }
        return false
    }

    static func readProjectID(profileDirectory: URL) -> String? {
        if let text = try? String(contentsOf: projectURL(profileDirectory: profileDirectory), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let data = try? Data(contentsOf: credentialURL(profileDirectory: profileDirectory)) {
            return parse(data)?.projectID
        }
        return nil
    }

    static func saveProjectID(_ projectID: String, profileDirectory: URL) {
        let trimmed = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? Data((trimmed + "\n").utf8).write(to: projectURL(profileDirectory: profileDirectory), options: .atomic)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        // Go's `time.Time` can serialize nanoseconds (up to 9 fractional digits);
        // trim sub-millisecond digits so ISO8601DateFormatter parses cleanly.
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return fractional.date(from: trimmed)
    }

    private static func decodeHexIfValid(_ text: String) -> Data? {
        guard text.count >= 4, text.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
