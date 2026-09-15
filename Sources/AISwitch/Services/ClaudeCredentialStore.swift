import CryptoKit
import Foundation

/// Claude Code keeps the credential for new sessions in the login Keychain under
/// a service name derived from `CLAUDE_CONFIG_DIR`, and falls back to
/// `<config dir>/.credentials.json` (mode 0600) when the Keychain rejects a write.
/// Both locations are handled here through the same `security` tool Claude Code
/// itself uses, so the items stay readable by Claude Code and never trigger the
/// per-app authorization dialogs that Security framework access would.
///
/// Saved profiles never touch the Keychain: each is a `.credentials.json` inside
/// its own profile directory, exactly where Claude Code would look if that
/// directory were its `CLAUDE_CONFIG_DIR`.
enum ClaudeCredentialStore {
    static let fileName = ".credentials.json"

    static var liveConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func credentialURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(fileName)
    }

    /// Mirrors Claude Code: `Claude Code-credentials`, suffixed with the first
    /// eight hex characters of SHA-256 over the NFC-normalized `CLAUDE_CONFIG_DIR`.
    static func service(configDirectory: String?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(suffix)"
    }

    /// Mirrors Claude Code: `$USER`, restricted to `[A-Za-z0-9._-]`.
    static var account: String {
        let name = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let allowed = name.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
        return name.isEmpty || !allowed ? "claude-code-user" : name
    }

    // MARK: Live credential (Claude Code's default configuration directory)

    /// The credential new Claude Code sessions use, or nil when Claude Code is signed out.
    static func readLive() async throws -> Data? {
        if let data = try await readKeychain(service: service(configDirectory: nil)) { return data }
        return try readFile(credentialURL(configDirectory: liveConfigDirectory))
    }

    /// Makes `data` the credential for new Claude Code sessions, in Claude Code's
    /// own order: Keychain first, plaintext fallback only if the Keychain refuses.
    static func writeLive(_ data: Data) async throws {
        let service = service(configDirectory: nil)
        let fallback = credentialURL(configDirectory: liveConfigDirectory)
        if try await writeKeychain(data, service: service) {
            if FileManager.default.fileExists(atPath: fallback.path) {
                try FileManager.default.removeItem(at: fallback)
            }
        } else {
            try FileManager.default.writeOwnerOnly(data, to: fallback)
            await deleteKeychain(service: service)
        }
    }

    // MARK: Profile credentials

    /// Moves the credential a `CLAUDE_CONFIG_DIR` login left in the Keychain into
    /// that directory's `.credentials.json`, so the profile lives in one file.
    static func adoptLoginCredential(configDirectory: URL) async throws {
        let service = service(configDirectory: configDirectory.path)
        let file = credentialURL(configDirectory: configDirectory)
        if let data = try await readKeychain(service: service) {
            try FileManager.default.writeOwnerOnly(data, to: file)
            await deleteKeychain(service: service)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AISwitchError.loginDidNotCreateCredentials(.claude)
        }
    }

    static func readProfile(directory: String) throws -> Data {
        guard let data = try readFile(credentialURL(configDirectory: URL(fileURLWithPath: directory))) else {
            throw AISwitchError.credentialsMissing(.claude)
        }
        return data
    }

    // MARK: Credential contents

    /// The bearer token for usage requests. Expiry is checked locally first: an
    /// expired token is renewed by Claude Code itself on its next session, not
    /// by signing in again.
    static func accessToken(from data: Data, now: Date = Date()) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AISwitchError.invalidResponse("The saved Claude Code credential is unreadable.")
        }
        let oauth = root["claudeAiOauth"] as? [String: Any]
        guard let token = oauth?["accessToken"] as? String ?? root["accessToken"] as? String else {
            throw AISwitchError.invalidResponse("The saved Claude Code credential has no access token.")
        }
        if let expiry = (oauth?["expiresAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiry / 1000) <= now {
            throw AISwitchError.claudeSessionExpired
        }
        return token
    }

    // MARK: Keychain items, keyed the way Claude Code keys them

    static func readKeychain(service: String) async throws -> Data? {
        try await SecurityTool.read(service: service, account: account)
    }

    /// Returns false when the Keychain rejected the write, e.g. while locked.
    static func writeKeychain(_ data: Data, service: String) async throws -> Bool {
        try await SecurityTool.write(data, service: service, account: account)
    }

    static func deleteKeychain(service: String) async {
        await SecurityTool.delete(service: service, account: account)
    }

    private static func readFile(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}

extension FileManager {
    /// Writes a secret readable only by the current user, creating parent directories.
    func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
