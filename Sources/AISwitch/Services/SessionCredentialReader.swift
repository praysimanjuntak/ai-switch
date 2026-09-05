import Foundation

struct KeychainCredential: Sendable {
    let data: Data
    let account: String
}

/// Keeps a credential approved with macOS's Allow Once usable for this app
/// session. Fresh reads are always silent; only an explicit grant may prompt.
/// This cache is used for usage requests, never for account activation.
final class SessionCredentialReader: @unchecked Sendable {
    private let lock = NSLock()
    private var approvedCredentials: [String: KeychainCredential] = [:]
    private let load: @Sendable (String, KeychainInteraction) throws -> KeychainCredential

    init(load: @escaping @Sendable (String, KeychainInteraction) throws -> KeychainCredential) {
        self.load = load
    }

    func read(service: String, interaction: KeychainInteraction = .forbidden) throws -> KeychainCredential {
        lock.lock()
        defer { lock.unlock() }
        do {
            // Pick up credentials refreshed by Claude whenever Keychain permits
            // it, without prompting or writing to either Keychain entry.
            let credential = try load(service, .forbidden)
            approvedCredentials[service] = credential
            return credential
        } catch AISwitchError.keychainAccessRequired {
            if let credential = approvedCredentials[service] { return credential }
            guard interaction == .allowed else { throw AISwitchError.keychainAccessRequired }
            // Exactly one interactive read for this explicit grant.
            let credential = try load(service, .allowed)
            approvedCredentials[service] = credential
            return credential
        } catch {
            // A removed item or other failure must not resurrect old credentials.
            approvedCredentials.removeValue(forKey: service)
            throw error
        }
    }

    func invalidate(service: String, matching data: Data? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let data, approvedCredentials[service]?.data != data { return }
        approvedCredentials.removeValue(forKey: service)
    }
}
