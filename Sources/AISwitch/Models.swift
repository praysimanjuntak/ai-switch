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

/// A weekly limit that applies to one model or surface, e.g. Claude's "Fable" bucket.
struct ScopedUsageWindow: Codable, Equatable, Sendable {
    var name: String
    var window: UsageWindow
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var scoped: [ScopedUsageWindow]
    var fetchedAt: Date
    var note: String?

    init(session: UsageWindow?, weekly: UsageWindow?, scoped: [ScopedUsageWindow] = [], fetchedAt: Date, note: String?) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
        self.fetchedAt = fetchedAt
        self.note = note
    }

    // Snapshots saved before 0.3 have no `scoped` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decodeIfPresent(UsageWindow.self, forKey: .session)
        weekly = try container.decodeIfPresent(UsageWindow.self, forKey: .weekly)
        scoped = try container.decodeIfPresent([ScopedUsageWindow].self, forKey: .scoped) ?? []
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

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

enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

enum AISwitchError: LocalizedError, Sendable {
    case cliNotFound(AIProvider)
    case commandFailed(String)
    case commandTimedOut
    case loginDidNotCreateCredentials(AIProvider)
    case notSignedIn(AIProvider)
    case credentialsMissing(AIProvider)
    case invalidResponse(String)
    case claudeSessionExpired

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let provider):
            "\(provider.displayName) CLI was not found. Install it, then reopen AI Switch."
        case .commandFailed(let message):
            message
        case .commandTimedOut:
            "The operation timed out. Close this window or try again."
        case .loginDidNotCreateCredentials(let provider):
            "\(provider.displayName) login finished without creating credentials."
        case .notSignedIn(let provider):
            "\(provider.displayName) is not signed in on this Mac. Sign in with the CLI first, or use Add account."
        case .credentialsMissing(let provider):
            "No saved \(provider.displayName) credentials were found for this account. Remove it, then add or import it again."
        case .invalidResponse(let message):
            message
        case .claudeSessionExpired:
            "Claude's sign-in for this account needs renewing. Start a Claude Code session with it active, then refresh."
        }
    }
}
