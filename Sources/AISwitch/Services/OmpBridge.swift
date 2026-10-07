import Foundation
import SQLite3

/// An account signed in to omp, as omp identifies it: `email:<email>|org:<org>`.
/// For Codex the org is the ChatGPT account (workspace) id; for Claude, the
/// organization id.
struct OmpAccount: Codable, Equatable, Hashable, Sendable {
    var provider: AIProvider
    var email: String
    var orgId: String

    /// omp's provider ids for the accounts AI Switch manages.
    var ompProvider: String { Self.ompProvider(for: provider) }

    static func ompProvider(for provider: AIProvider) -> String {
        switch provider {
        case .codex: "openai-codex"
        case .claude: "anthropic"
        }
    }

    /// Reads omp's `identity_key` column.
    init?(provider: AIProvider, identityKey: String) {
        var fields: [String: String] = [:]
        for part in identityKey.split(separator: "|") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            fields[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard let email = fields["email"], !email.isEmpty, let org = fields["org"], !org.isEmpty else { return nil }
        self.init(provider: provider, email: email, orgId: org)
    }

    init(provider: AIProvider, email: String, orgId: String) {
        self.provider = provider
        self.email = email
        self.orgId = orgId
    }

    /// The omp account a saved profile signs in as: the same organization (Codex
    /// workspace) and email. A profile that doesn't know its identity yet is
    /// matched by email only when that is unambiguous.
    static func matching(_ profile: AccountProfile, in accounts: [OmpAccount]) -> OmpAccount? {
        let candidates = accounts.filter { $0.provider == profile.provider }
        let email = (profile.identity?.email ?? profile.email)?.lowercased()
        if let organization = profile.identity?.organization {
            let sameOrg = candidates.filter { $0.orgId == organization }
            return sameOrg.first { email == nil || $0.email.lowercased() == email } ?? (sameOrg.count == 1 ? sameOrg[0] : nil)
        }
        guard let email else { return nil }
        let sameEmail = candidates.filter { $0.email.lowercased() == email }
        return sameEmail.count == 1 ? sameEmail[0] : nil
    }
}

/// One entry of omp's `auth.accountPolicies`: a per-account routing rule. omp
/// prefers the healthy account with the highest `priority`.
struct OmpAccountPolicy: Codable, Equatable, Sendable {
    struct Selector: Codable, Equatable, Sendable {
        var email: String?
        var accountId: String?
        var projectId: String?
        var orgId: String?
    }

    var provider: String
    var account: Selector
    var priority: Double?
    var reservePct: Double?

    /// How omp matches a rule to an account: every field the rule names must be equal.
    func matches(_ target: OmpAccount) -> Bool {
        guard provider == target.ompProvider else { return false }
        // omp stores a Codex account's ChatGPT workspace as both accountId and org.
        let accountIdRulesOut = account.accountId.map { target.provider == .codex && $0 != target.orgId } ?? false
        return (account.email.map { $0.lowercased() == target.email.lowercased() } ?? true)
            && (account.orgId.map { $0 == target.orgId } ?? true)
            && !accountIdRulesOut
    }

    /// The rule AI Switch writes to make omp prefer `target`.
    static func preferring(_ target: OmpAccount, priority: Double) -> OmpAccountPolicy {
        OmpAccountPolicy(provider: target.ompProvider, account: Selector(email: target.email, orgId: target.orgId),
                         priority: priority)
    }
}

enum OmpPolicies {
    struct Plan: Equatable {
        var policies: [OmpAccountPolicy]
        /// The rules AI Switch now owns, by provider.
        var managed: [AIProvider: OmpAccountPolicy]
        /// Providers left alone because one of the user's own rules already
        /// targets the account; omp rejects two rules for one account.
        var conflicts: [AIProvider]
    }

    /// Replaces AI Switch's rules with ones preferring `targets`, keeping every
    /// rule the user wrote. Each new rule outranks the user's priorities for its provider.
    static func plan(existing: [OmpAccountPolicy], managed: [AIProvider: OmpAccountPolicy],
                     targets: [AIProvider: OmpAccount]) -> Plan {
        var policies = existing.filter { !managed.values.contains($0) }
        var newManaged: [AIProvider: OmpAccountPolicy] = [:]
        var conflicts: [AIProvider] = []
        for provider in AIProvider.allCases {
            guard let target = targets[provider] else { continue }
            let userRules = policies.filter { $0.provider == target.ompProvider }
            if userRules.contains(where: { $0.matches(target) }) {
                conflicts.append(provider)
                continue
            }
            let highest = userRules.compactMap(\.priority).max() ?? 0
            let rule = OmpAccountPolicy.preferring(target, priority: max(100, highest + 1))
            policies.append(rule)
            newManaged[provider] = rule
        }
        return Plan(policies: policies, managed: newManaged, conflicts: conflicts)
    }
}

/// omp's account store and settings, behind seams so tests never touch the real omp.
struct OmpBridge: Sendable {
    var isAvailable: @Sendable () -> Bool
    /// Enabled OAuth accounts signed in to omp for the providers AI Switch manages.
    var accounts: @Sendable () async throws -> [OmpAccount]
    var readPolicies: @Sendable () async throws -> [OmpAccountPolicy]
    var writePolicies: @Sendable ([OmpAccountPolicy]) async throws -> Void

    static let system = OmpBridge(
        isAvailable: {
            FileManager.default.fileExists(atPath: databaseURL.path) && CommandRunner.locate("omp") != nil
        },
        accounts: { try readAccounts(databaseURL) },
        readPolicies: {
            let result = try await runOmp(["config", "get", "auth.accountPolicies", "--json"])
            guard let data = result.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["value"] else {
                throw AISwitchError.invalidResponse("omp did not report its account policies.")
            }
            let json = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode([OmpAccountPolicy].self, from: json)
        },
        writePolicies: { policies in
            if policies.isEmpty {
                // Removes the key, so omp's default applies again.
                _ = try await runOmp(["config", "reset", "auth.accountPolicies"])
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let json = String(decoding: try encoder.encode(policies), as: UTF8.self)
                _ = try await runOmp(["config", "set", "auth.accountPolicies", json])
            }
        }
    )

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp/agent/agent.db")
    }

    /// Reads only `provider` and `identity_key`, never the credential payload.
    static func readAccounts(_ database: URL) throws -> [OmpAccount] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw AISwitchError.commandFailed("Couldn't read omp's accounts.")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)
        let sql = """
            SELECT provider, identity_key FROM auth_credentials
            WHERE disabled_cause IS NULL AND credential_type = 'oauth' AND identity_key IS NOT NULL
              AND provider IN ('openai-codex', 'anthropic')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AISwitchError.commandFailed("omp's account store has a layout AI Switch doesn't know.")
        }
        defer { sqlite3_finalize(statement) }
        var accounts: [OmpAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let providerText = sqlite3_column_text(statement, 0),
                  let keyText = sqlite3_column_text(statement, 1) else { continue }
            let provider: AIProvider? = switch String(cString: providerText) {
            case "openai-codex": .codex
            case "anthropic": .claude
            default: nil
            }
            if let provider, let account = OmpAccount(provider: provider, identityKey: String(cString: keyText)) {
                accounts.append(account)
            }
        }
        return accounts
    }

    private static func runOmp(_ arguments: [String]) async throws -> String {
        guard let omp = CommandRunner.locate("omp") else {
            throw AISwitchError.commandFailed("omp was not found.")
        }
        let result = try await CommandRunner.run(executable: omp, arguments: arguments, timeout: 20)
        guard result.exitCode == 0 else {
            throw AISwitchError.commandFailed(result.output.isEmpty ? "omp couldn't update its settings." : result.output)
        }
        return result.output
    }
}
