import Foundation

/// Tells which account a CLI credential belongs to, so a credential is only
/// ever saved into the profile of the account it signs in as.
enum CredentialIdentity {
    /// Who `credential` signs in as, or nil when that can't be told right now.
    /// Codex tokens name their user. A Claude credential doesn't, so Anthropic
    /// is asked, the way Claude Code attributes a refreshed credential; an
    /// expired Claude token can't be asked about.
    static func identify(_ provider: AIProvider, credential: Data) async -> AccountIdentity? {
        switch provider {
        case .codex:
            return codex(authData: credential)
        case .claude:
            guard let token = try? ClaudeCredentialStore.accessToken(from: credential) else { return nil }
            return try? await UsageService.fetchClaudeIdentity(accessToken: token)
        }
    }

    /// The user and ChatGPT account a Codex `auth.json` signs in as, from its
    /// unverified token claims.
    static func codex(authData: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        for key in ["id_token", "access_token"] {
            guard let token = tokens[key] as? String, let claims = jwtClaims(token) else { continue }
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            guard let user = auth?["chatgpt_user_id"] as? String ?? auth?["user_id"] as? String ?? claims["sub"] as? String
            else { continue }
            let profile = claims["https://api.openai.com/profile"] as? [String: Any]
            return AccountIdentity(
                user: user,
                organization: auth?["chatgpt_account_id"] as? String ?? tokens["account_id"] as? String,
                email: claims["email"] as? String ?? profile?["email"] as? String
            )
        }
        return nil
    }

    /// The account Claude Code recorded in `<directory>/.claude.json` when it
    /// signed in with that directory as `CLAUDE_CONFIG_DIR`.
    static func claudeConfig(directory: URL) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let user = account["accountUuid"] as? String else { return nil }
        return AccountIdentity(
            user: user,
            organization: account["organizationUuid"] as? String,
            email: account["emailAddress"] as? String
        )
    }

    /// A JWT's payload, unverified: only used to tell accounts apart and to know
    /// when a token expires, never to trust it.
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var segment = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
        guard let data = Data(base64Encoded: segment) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
