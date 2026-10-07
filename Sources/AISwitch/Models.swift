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

/// Credits that reset an account's usage limits on request, like Codex's
/// "usage limit resets".
struct LimitResets: Codable, Equatable, Sendable {
    struct Credit: Codable, Equatable, Sendable {
        var title: String?
        var expiresAt: Date?
    }

    /// How many resets the account can use now.
    var available: Int
    /// The available credits the provider listed, soonest to expire first.
    var credits: [Credit]
}

/// How a reset request ended; mirrors Codex's own outcomes.
enum LimitResetOutcome: Equatable, Sendable {
    case reset, nothingToReset, noneLeft, alreadyUsed
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var scoped: [ScopedUsageWindow]
    var fetchedAt: Date
    var note: String?
    /// Nil when the provider doesn't offer resets for this account.
    var resets: LimitResets?

    init(session: UsageWindow?, weekly: UsageWindow?, scoped: [ScopedUsageWindow] = [], fetchedAt: Date, note: String?,
         resets: LimitResets? = nil) {
        self.session = session
        self.weekly = weekly
        self.scoped = scoped
        self.fetchedAt = fetchedAt
        self.note = note
        self.resets = resets
    }

    // Snapshots saved before 0.3 have no `scoped` key, and before 0.5 no `resets`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decodeIfPresent(UsageWindow.self, forKey: .session)
        weekly = try container.decodeIfPresent(UsageWindow.self, forKey: .weekly)
        scoped = try container.decodeIfPresent([ScopedUsageWindow].self, forKey: .scoped) ?? []
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        resets = try container.decodeIfPresent(LimitResets.self, forKey: .resets)
    }
    static let empty = UsageSnapshot(
        session: nil,
        weekly: nil,
        fetchedAt: .distantPast,
        note: "Usage is not available yet"
    )
}

/// Who a credential signs in as. Only a credential of the same account may
/// replace a profile's saved one.
struct AccountIdentity: Codable, Equatable, Sendable {
    /// Claude account UUID, or ChatGPT user ID.
    var user: String
    /// Claude organization UUID, or ChatGPT account (workspace) ID, when reported.
    var organization: String?
    /// For messages only; never compared.
    var email: String?

    /// Mirrors Claude Code's own check: the same user, and the same organization
    /// whenever both sides report one.
    func isSameAccount(as other: AccountIdentity) -> Bool {
        user == other.user && (organization == nil || other.organization == nil || organization == other.organization)
    }
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
    /// Who the saved credential signs in as, once known. Claude credentials
    /// don't say, so it is kept here rather than looked up every time.
    var identity: AccountIdentity?

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
    case usageRateLimited(AIProvider)

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
            "Claude's sign-in for this account needs renewing. Use Renew sign-in, or start a Claude Code session with it active, then refresh."
        case .usageRateLimited(let provider):
            "\(provider.displayName) is limiting how often this account's usage can be checked. AI Switch checks again later; the meters show the last usage."
        }
    }
}
