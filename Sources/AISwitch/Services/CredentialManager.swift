import CryptoKit
import Foundation
import Security

enum KeychainInteraction: Sendable {
    case forbidden
    case allowed
}

enum CredentialManager {
    static let claudeDefaultService = "Claude Code-credentials"
    private static let interactionLock = NSRecursiveLock()
    static let claudeUsageCredentials = SessionCredentialReader { service, interaction in
        let credential = try read(service: service, interaction: interaction)
        return KeychainCredential(data: credential.data, account: credential.account)
    }

    // Claude uses the legacy login keychain. Per-query authentication flags alone
    // do not suppress its dialogs. Serialize this process-wide setting, restoring
    // it before returning; no asynchronous work may run inside this scope.
    static func withInteraction<T>(_ interaction: KeychainInteraction, _ operation: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { throw AISwitchError.keychain(readStatus) }
        let status = SecKeychainSetUserInteractionAllowed(interaction == .allowed)
        guard status == errSecSuccess else { throw AISwitchError.keychain(status) }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        do {
            return try operation()
        } catch AISwitchError.keychain(let status) where
            [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw AISwitchError.keychainAccessRequired
        }
    }

    static func claudeService(profileDirectory: String?) -> String {
        guard let profileDirectory else { return claudeDefaultService }
        let normalized = URL(fileURLWithPath: profileDirectory)
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(claudeDefaultService)-\(suffix)"
    }

    static func read(
        service: String, account: String? = nil, interaction: KeychainInteraction = .forbidden
    ) throws -> (data: Data, account: String) {
        try withInteraction(interaction) {
            try readItem(service: service, account: account)
        }
    }

    private static func readItem(service: String, account: String?) throws -> (data: Data, account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let dictionary = item as? [String: Any],
              let data = dictionary[kSecValueData as String] as? Data else {
            throw AISwitchError.keychain(status)
        }
        let resolvedAccount = dictionary[kSecAttrAccount as String] as? String
            ?? NSUserName()
        return (data, resolvedAccount)
    }

    static func save(
        data: Data, service: String, account: String, interaction: KeychainInteraction = .forbidden
    ) throws {
        try withInteraction(interaction) {
            try saveItem(data: data, service: service, account: account)
        }
        claudeUsageCredentials.invalidate(service: service)
    }

    private static func saveItem(data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AISwitchError.keychain(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AISwitchError.keychain(addStatus)
        }
    }

    static func delete(service: String, interaction: KeychainInteraction = .forbidden) throws {
        try withInteraction(interaction) { try deleteItem(service: service) }
        claudeUsageCredentials.invalidate(service: service)
    }

    private static func deleteItem(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AISwitchError.keychain(status)
        }
    }

    static func copyClaudeCredential(
        from source: String, to destination: String, interaction: KeychainInteraction = .forbidden
    ) throws {
        try withInteraction(interaction) {
            let credential = try readItem(service: source, account: nil)
            try saveItem(data: credential.data, service: destination, account: credential.account)
        }
        claudeUsageCredentials.invalidate(service: destination)
    }

    static func accessToken(from credentialData: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: credentialData) as? [String: Any] else {
            throw AISwitchError.invalidResponse("Claude Code returned an unreadable Keychain credential.")
        }
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            return token
        }
        if let token = root["accessToken"] as? String { return token }
        throw AISwitchError.invalidResponse("Claude Code's access token was not present in Keychain.")
    }
}

enum CodexConfigEditor {
    static func ensureFileCredentialStore() throws {
        let manager = FileManager.default
        let codexHome = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        try manager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let config = codexHome.appendingPathComponent("config.toml")
        let backup = codexHome.appendingPathComponent("config.toml.ai-switch-backup")
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""

        if manager.fileExists(atPath: config.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: config, to: backup)
        }

        let pattern = #"(?m)^\s*cli_auth_credentials_store\s*=.*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(existing.startIndex..<existing.endIndex, in: existing)
        let updated: String
        if regex.firstMatch(in: existing, range: range) != nil {
            updated = regex.stringByReplacingMatches(
                in: existing,
                range: range,
                withTemplate: "cli_auth_credentials_store = \"file\""
            )
        } else {
            updated = "cli_auth_credentials_store = \"file\"\n" + existing
        }
        try updated.data(using: .utf8)?.write(to: config, options: .atomic)
    }
}
