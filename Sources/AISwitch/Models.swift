import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

struct UsageWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var fetchedAt: Date
    var note: String?

    static let empty = UsageSnapshot(
        session: nil,
        weekly: nil,
        fetchedAt: .distantPast,
        note: "Usage is not available yet"
    )
}

struct AccountProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: AIProvider
    var displayName: String
    var email: String?
    var plan: String?
    let profileDirectory: String
    let createdAt: Date
    var lastActivatedAt: Date?
    var usage: UsageSnapshot?
    var authIssue: String?
    var needsKeychainAccess: Bool? = nil

    var subtitle: String {
        if let email, !email.isEmpty { return email }
        if let plan, !plan.isEmpty { return plan.capitalized }
        return "Signed-in account"
    }
}

struct StoredState: Codable, Sendable {
    var profiles: [AccountProfile]
    var activeProfileIDs: [String: UUID]

    static let empty = StoredState(profiles: [], activeProfileIDs: [:])
}

struct ProviderInspection: Sendable {
    var email: String?
    var plan: String?
    var usage: UsageSnapshot?
}

enum AISwitchError: LocalizedError, Sendable {
    case cliNotFound(AIProvider)
    case commandFailed(String)
    case loginDidNotCreateCredentials(AIProvider)
    case credentialsMissing(AIProvider)
    case invalidResponse(String)
    case keychain(Int32)
    case keychainAccessRequired
    case claudeSessionExpired

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let provider):
            "\(provider.displayName) CLI was not found. Install it, then reopen AI Switch."
        case .commandFailed(let message):
            message
        case .loginDidNotCreateCredentials(let provider):
            "\(provider.displayName) login finished without creating credentials."
        case .credentialsMissing(let provider):
            "No \(provider.displayName) credentials were found to import."
        case .invalidResponse(let message):
            message
        case .keychain(let status):
            "Keychain returned error \(status)."
        case .keychainAccessRequired:
            "Keychain access is needed. Automatic checks are paused; choose Grant Keychain access."
        case .claudeSessionExpired:
            "Claude rejected this session. Sign in to Claude Code again, then refresh this account."
        }
    }
}
