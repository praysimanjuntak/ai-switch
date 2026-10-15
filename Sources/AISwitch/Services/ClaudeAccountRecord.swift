import Foundation

/// The `oauthAccount` record in a Claude Code config file (`.claude.json`): the
/// account Claude Code shows, with its email, organization and plan details.
/// Claude Code keeps it apart from the sign-in. It writes the record when it
/// signs in, refetches it only when it is incomplete or a day old, and on a
/// token refresh merges the plan details of whoever is signed in into the
/// record it already has. After a switch it would show the new account's plan
/// with the previous account's email, so a switch replaces the record too.
enum ClaudeAccountRecord {
    /// Claude Code's own config when `CLAUDE_CONFIG_DIR` is unset.
    static var liveConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The account the config file at `config` names, if any.
    static func identity(inConfigAt config: URL) -> AccountIdentity? {
        record(in: try? Data(contentsOf: config)).flatMap(identity(of:))
    }

    /// Makes the record in `config` name the account `identity`. The record
    /// Claude Code saved in `profileDirectory` when that account signed in there
    /// is copied whole. Without one, the bare account is written, and Claude Code
    /// completes it from the sign-in at its next start, as it does for an account
    /// given through its environment. A record that already names the account is
    /// left alone, since Claude Code keeps it current. A missing config is left
    /// to Claude Code to create. Returns whether `config` changed.
    @discardableResult
    static func point(_ config: URL, at profileDirectory: URL, identity: AccountIdentity?) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: config.path) else { return false }
        let saved = record(in: try? Data(contentsOf: profileDirectory.appendingPathComponent(".claude.json")))
        let savedIdentity = saved.flatMap(identity(of:))
        guard let account = identity ?? savedIdentity else { return false }
        let replacement: [String: Any]
        if let saved, let savedIdentity, savedIdentity.isSameAccount(as: account) {
            replacement = saved
        } else {
            var bare: [String: Any] = ["accountUuid": account.user]
            bare["emailAddress"] = account.email
            bare["organizationUuid"] = account.organization
            replacement = bare
        }
        if let current = Self.identity(inConfigAt: config), current.isSameAccount(as: account) { return false }
        return try await withLock(on: config) {
            // Claude Code may have written meanwhile; decide on what is there now.
            guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else {
                throw AISwitchError.invalidResponse("Claude Code's settings file (~/.claude.json) is unreadable.")
            }
            if let current = (root["oauthAccount"] as? [String: Any]).flatMap(Self.identity(of:)),
               current.isSameAccount(as: account) {
                return false
            }
            root["oauthAccount"] = replacement
            let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
            try FileManager.default.writeOwnerOnly(updated, to: config.resolvingSymlinksInPath())
            return true
        }
    }

    static func identity(of record: [String: Any]) -> AccountIdentity? {
        guard let user = record["accountUuid"] as? String else { return nil }
        return AccountIdentity(user: user, organization: record["organizationUuid"] as? String,
                               email: record["emailAddress"] as? String)
    }

    private static func record(in data: Data?) -> [String: Any]? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }

    /// Claude Code takes `<config>.lock`, a directory, around each write to its
    /// config and rereads the file inside it (proper-lockfile), so holding the
    /// same lock means neither side overwrites the other's change. A lock left
    /// untouched for 10 seconds was abandoned, as proper-lockfile treats it.
    private static func withLock<T>(on config: URL, _ body: () throws -> T) async throws -> T {
        let lock = config.path + ".lock"
        let deadline = Date().addingTimeInterval(5)
        while mkdir(lock, 0o755) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let touched = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date
            if let touched, Date().timeIntervalSince(touched) > 10 {
                rmdir(lock)
                continue
            }
            guard Date() < deadline else {
                throw AISwitchError.commandFailed("Claude Code kept its settings file locked. Switch again to update the account it shows.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { rmdir(lock) }
        return try body()
    }
}
