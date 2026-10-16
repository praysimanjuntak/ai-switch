import Foundation

/// What `aiswitch` asks the running app: one JSON line per connection.
struct AgentRequest: Codable, Equatable, Sendable {
    enum Command: String, Codable, Sendable {
        case list, use
    }

    var command: Command
    /// For `use`: the account's name, email, or id, or the start of its id.
    var account: String?
    /// Only accounts of this provider.
    var provider: AIProvider?
}

/// The app's answer. It never carries a credential.
struct AgentResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?
    var accounts: [AccountSummary]?
    var account: AccountSummary?
    /// What changed, or why the answer may be dated.
    var note: String?

    static func failure(_ message: String) -> AgentResponse {
        AgentResponse(ok: false, error: message)
    }
}

/// A saved account as `aiswitch` shows it: who it is, whether new sessions sign
/// in with it, and how much of each limit is left. Built from what the window
/// shows, never from a credential.
struct AccountSummary: Codable, Equatable, Sendable {
    struct Limit: Codable, Equatable, Sendable {
        /// "5-hour", "Weekly", or a per-model weekly limit such as "Fable weekly".
        var name: String
        var leftPercent: Int
        var resetsAt: Date?
    }

    var id: UUID
    var provider: AIProvider
    var name: String
    var email: String?
    var plan: String?
    /// New sessions of `provider` sign in with this account.
    var active: Bool
    /// Why the account needs attention, such as a sign-in that couldn't be renewed.
    var needsAttention: String?
    /// When its usage was last read.
    var usageCheckedAt: Date?
    /// The limits its provider reported, in the order the window shows them.
    var limits: [Limit]

    init(_ profile: AccountProfile, active: Bool) {
        id = profile.id
        provider = profile.provider
        name = profile.displayName
        email = profile.email
        plan = profile.plan
        self.active = active
        needsAttention = profile.authIssue
        usageCheckedAt = profile.usage?.fetchedAt
        limits = UsageSnapshot.namedWindows(of: profile.usage).compactMap { name, window in
            window.map { Limit(name: name, leftPercent: Int($0.remainingPercent.rounded()), resetsAt: $0.resetsAt) }
        }
    }

    /// Every account, or one provider's, in the order the window lists them.
    static func list(_ profiles: [AccountProfile], activeProfileIDs: [String: UUID], provider: AIProvider? = nil) -> [AccountSummary] {
        profiles
            .filter { provider == nil || $0.provider == provider }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            .map { AccountSummary($0, active: activeProfileIDs[$0.provider.rawValue] == $0.id) }
    }
}

struct AccountQueryError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Finds the one account an `aiswitch use` query names.
enum AccountQuery {
    /// By whole id, then name, then email, then the start of an id, ignoring
    /// case. Names come before id starts, so an account named like hex digits
    /// still matches by name. Several matches at one step is an error that
    /// lists them, never a guess.
    static func resolve(_ query: String, provider: AIProvider?, in profiles: [AccountProfile]) throws -> AccountProfile {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AccountQueryError(message: "Name the account to use.") }
        let candidates = profiles.filter { provider == nil || $0.provider == provider }
        let rules: [(AccountProfile) -> Bool] = [
            { $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame },
            { $0.displayName.caseInsensitiveCompare(text) == .orderedSame },
            { $0.email?.caseInsensitiveCompare(text) == .orderedSame },
            { text.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(text.lowercased()) },
        ]
        for rule in rules {
            let matches = candidates.filter(rule)
            if matches.count == 1 { return matches[0] }
            guard matches.isEmpty else {
                throw AccountQueryError(message: "“\(text)” matches \(matches.count) accounts: "
                    + matches.map(describe).joined(separator: "; ")
                    + ". Use its name or id\(provider == nil && Set(matches.map(\.provider)).count > 1 ? ", or add --provider" : "").")
            }
        }
        throw AccountQueryError(message:
            "No \(provider.map { "\($0.displayName) " } ?? "")account matches “\(text)”. Run “aiswitch list” to see your accounts.")
    }

    private static func describe(_ profile: AccountProfile) -> String {
        "\(profile.displayName) (\(profile.provider.displayName)\(profile.email.map { ", \($0)" } ?? ""), "
            + "id \(profile.id.uuidString.prefix(8).lowercased()))"
    }
}

extension AccountStore {
    /// Answers an `aiswitch` request the way the window would act on it.
    func respond(to request: AgentRequest) async -> AgentResponse {
        switch request.command {
        case .list:
            return AgentResponse(ok: true, accounts: AccountSummary.list(profiles, activeProfileIDs: activeProfileIDs,
                                                                         provider: request.provider))
        case .use:
            let profile: AccountProfile
            do {
                profile = try AccountQuery.resolve(request.account ?? "", provider: request.provider, in: profiles)
            } catch {
                return .failure(error.localizedDescription)
            }
            guard switchingProfileID == nil else {
                return .failure("AI Switch is switching accounts right now. Try again in a moment.")
            }
            do {
                // The caller waits for the switch, not for the usage check after it.
                try await activate(profile.id, waitsForUsage: false)
            } catch {
                return .failure(error.localizedDescription)
            }
            let current = profiles.first { $0.id == profile.id } ?? profile
            var note = "New \(current.provider.displayName) sessions now sign in as \(current.displayName)"
                + "\(current.email.map { " (\($0))" } ?? ""). Sessions already running keep their account."
            if let issue = current.authIssue { note += " It needs attention: \(issue)" }
            return AgentResponse(ok: true, account: AccountSummary(current, active: isActive(current)), note: note)
        }
    }
}
