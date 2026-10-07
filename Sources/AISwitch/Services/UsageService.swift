import Foundation

enum UsageService {
    static func inspect(_ profile: AccountProfile) async throws -> ProviderInspection {
        switch profile.provider {
        case .codex:
            return try await inspectCodex(profileDirectory: profile.profileDirectory)
        case .claude:
            return try await inspectClaude(profileDirectory: profile.profileDirectory)
        }
    }

    /// `executable` only exists so tests can point the handshake at a fake
    /// app-server; the app always uses the located `codex` binary. With
    /// `refreshToken`, Codex renews the profile's token before answering.
    static func inspectCodex(profileDirectory: String, executable: URL? = nil, refreshToken: Bool = false) async throws -> ProviderInspection {
        guard let codex = executable ?? CommandRunner.locate("codex") else {
            throw AISwitchError.cliNotFound(.codex)
        }

        let readAccount = #"{"id":2,"method":"account/read","params":{"refreshToken":\#(refreshToken)}}"#
        // Detailed reads include the account's reset credits, with their expiry.
        let readRateLimits = #"{"id":3,"method":"account/rateLimits/read","params":null}"#

        return try await CommandRunner.interact(
            executable: codex,
            arguments: ["app-server", "--stdio"],
            environment: ["CODEX_HOME": profileDirectory],
            timeout: 12
        ) { session in
            try session.send(codexInitialize)
            var transcript: [String] = []
            var account: [String: Any]?
            var usageResult: [String: Any]?
            var accountAnswered = false
            var usageAnswered = false

            for await line in session.lines {
                transcript.append(line)
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                switch object["id"] as? Int {
                case 1:
                    try session.send(codexInitialized)
                    try session.send(readAccount)
                    try session.send(readRateLimits)
                case 2:
                    if let failure = object["error"] as? [String: Any] {
                        throw AISwitchError.invalidResponse(failure["message"] as? String ?? line)
                    }
                    account = (object["result"] as? [String: Any])?["account"] as? [String: Any]
                    accountAnswered = true
                case 3:
                    // A rate-limit error only means this account has no usage to show.
                    usageResult = object["error"] == nil ? object["result"] as? [String: Any] : nil
                    usageAnswered = true
                default:
                    continue
                }
                if accountAnswered, usageAnswered { break }
            }

            guard let account else {
                let output = transcript.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                throw AISwitchError.invalidResponse(output.isEmpty ? "Codex did not return account information." : output)
            }

            return ProviderInspection(
                email: account["email"] as? String,
                plan: account["planType"] as? String,
                usage: usageResult.map { parseCodexUsage($0) }
            )
        }
    }

    /// App-server speaks JSON-RPC over JSONL: its requests are only answered
    /// after the initialize response arrives.
    private static let codexInitialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-switch","title":"AI Switch","version":"\#(AppInfo.version)"},"capabilities":{"experimentalApi":true}}}"#
    private static let codexInitialized = #"{"method":"initialized","params":{}}"#

    /// Spends one of an account's usage limit resets. Only Codex offers resets an
    /// app can use; Claude Code's are an experiment it runs itself.
    static func useLimitReset(provider: AIProvider, directory: URL) async throws -> LimitResetOutcome {
        switch provider {
        case .codex: return try await consumeCodexReset(profileDirectory: directory.path)
        case .claude: throw AISwitchError.invalidResponse("Claude Code usage limit resets can only be used in Claude Code.")
        }
    }

    /// Spends one usage limit reset through the app-server's
    /// `account/rateLimitResetCredit/consume`, the call Codex's own reset makes; the
    /// backend picks the credit. `executable` only exists so tests can use a fake app-server.
    static func consumeCodexReset(profileDirectory: String, executable: URL? = nil) async throws -> LimitResetOutcome {
        guard let codex = executable ?? CommandRunner.locate("codex") else {
            throw AISwitchError.cliNotFound(.codex)
        }
        // One logical attempt. If its answer is lost, the user retries after seeing
        // the refreshed count, which is a new attempt.
        let consume = #"{"id":2,"method":"account/rateLimitResetCredit/consume","params":{"idempotencyKey":"\#(UUID().uuidString)"}}"#
        return try await CommandRunner.interact(
            executable: codex,
            arguments: ["app-server", "--stdio"],
            environment: ["CODEX_HOME": profileDirectory],
            timeout: 30
        ) { session in
            try session.send(codexInitialize)
            for await line in session.lines {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                switch object["id"] as? Int {
                case 1:
                    try session.send(codexInitialized)
                    try session.send(consume)
                case 2:
                    if let failure = object["error"] as? [String: Any] {
                        throw AISwitchError.invalidResponse(failure["message"] as? String ?? line)
                    }
                    switch (object["result"] as? [String: Any])?["outcome"] as? String {
                    case "reset": return .reset
                    case "nothingToReset": return .nothingToReset
                    case "noCredit": return .noneLeft
                    case "alreadyRedeemed": return .alreadyUsed
                    default: throw AISwitchError.invalidResponse("Codex answered the reset in a way AI Switch doesn't recognize.")
                    }
                default:
                    continue
                }
            }
            throw AISwitchError.invalidResponse("Codex did not answer the reset request.")
        }
    }

    static func parseCodexUsage(_ result: [String: Any], now: Date = Date()) -> UsageSnapshot {
        var rateLimit = result["rateLimits"] as? [String: Any]
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = buckets["codex"] as? [String: Any] {
            rateLimit = codex
        }

        var windows: [(duration: Double?, window: UsageWindow)] = []
        for key in ["primary", "secondary"] {
            guard let raw = rateLimit?[key] as? [String: Any],
                  let used = number(raw["usedPercent"]) else { continue }
            let duration = number(raw["windowDurationMins"])
            let resetSeconds = number(raw["resetsAt"])
            windows.append((
                duration,
                UsageWindow(
                    usedPercent: used,
                    resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
                )
            ))
        }

        let session = windows
            .filter { ($0.duration ?? .greatestFiniteMagnitude) <= 360 }
            .min { ($0.duration ?? 0) < ($1.duration ?? 0) }?.window
        let weekly = windows
            .filter { ($0.duration ?? 0) >= 6 * 24 * 60 }
            .max { ($0.duration ?? 0) < ($1.duration ?? 0) }?.window
            ?? (windows.count == 1 && (windows[0].duration ?? 0) > 360 ? windows[0].window : nil)

        let note: String? = windows.isEmpty ? "Codex did not report a rolling limit for this account." : nil
        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: now, note: note,
                             resets: (result["rateLimitResetCredits"] as? [String: Any]).flatMap(parseResetCredits))
    }

    /// `rateLimitResetCredits`: how many resets are available, and the credits Codex
    /// listed, soonest to expire first, as Codex's own reset picker orders them.
    private static func parseResetCredits(_ summary: [String: Any]) -> LimitResets? {
        guard let available = number(summary["availableCount"]) else { return nil }
        let credits = ((summary["credits"] as? [[String: Any]]) ?? [])
            .filter { $0["status"] as? String == "available" }
            .map { credit in
                LimitResets.Credit(
                    title: (credit["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                    expiresAt: number(credit["expiresAt"]).map { Date(timeIntervalSince1970: $0) }
                )
            }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return LimitResets(available: max(0, Int(available)), credits: credits)
    }

    static func inspectClaude(profileDirectory: String) async throws -> ProviderInspection {
        // Never launch `claude auth status` here: it starts the interactive
        // `security` helper, sometimes more than once for a single status check.
        let credential = try ClaudeCredentialStore.readProfile(directory: profileDirectory)
        let config = URL(fileURLWithPath: profileDirectory).appendingPathComponent(".claude.json")
        var inspection = claudeMetadata(configData: try? Data(contentsOf: config), credentialData: credential)
        let token = try ClaudeCredentialStore.accessToken(from: credential)
        inspection.usage = try await fetchClaudeUsage(accessToken: token)
        return inspection
    }

    static func claudeMetadata(configData: Data?, credentialData: Data? = nil) -> ProviderInspection {
        let config = configData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let credential = credentialData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let account = config?["oauthAccount"] as? [String: Any]
        let oauth = credential?["claudeAiOauth"] as? [String: Any]
        return ProviderInspection(
            email: account?["emailAddress"] as? String,
            plan: oauth?["subscriptionType"] as? String ?? account?["organizationName"] as? String,
            usage: nil
        )
    }

    static func fetchClaudeUsage(accessToken: String, now: Date = Date()) async throws -> UsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1") else {
            throw AISwitchError.invalidResponse("Claude usage URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ai-switch/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 401: throw AISwitchError.claudeSessionExpired
        case 429: throw AISwitchError.usageRateLimited(.claude)
        default: break
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AISwitchError.invalidResponse("Claude usage refresh failed (HTTP \(code)). Re-authenticate this profile if its login expired.")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AISwitchError.invalidResponse("Claude returned an unreadable usage response.")
        }
        return parseClaudeUsage(payload, now: now)
    }

    /// The account and organization an OAuth token belongs to, from the profile
    /// endpoint Claude Code uses to tell whose a refreshed credential is.
    static func fetchClaudeIdentity(accessToken: String) async throws -> AccountIdentity {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            throw AISwitchError.invalidResponse("Claude profile URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ai-switch/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = payload["account"] as? [String: Any],
              let user = account["uuid"] as? String else {
            throw AISwitchError.invalidResponse("Claude did not say which account this sign-in belongs to (HTTP \(status)).")
        }
        let organization = payload["organization"] as? [String: Any]
        return AccountIdentity(user: user, organization: organization?["uuid"] as? String, email: account["email"] as? String)
    }

    /// `five_hour` and `seven_day` are the account-wide windows. `limits[]` adds
    /// per-model weekly buckets (`kind: "weekly_scoped"`, e.g. "Fable").
    static func parseClaudeUsage(_ payload: [String: Any], now: Date = Date()) -> UsageSnapshot {
        func window(_ raw: Any?, usedKey: String) -> UsageWindow? {
            guard let limit = raw as? [String: Any], let used = number(limit[usedKey]) else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: parseISO8601(limit["resets_at"] as? String))
        }
        let scoped = ((payload["limits"] as? [[String: Any]]) ?? []).compactMap { limit -> ScopedUsageWindow? in
            guard limit["kind"] as? String == "weekly_scoped",
                  let window = window(limit, usedKey: "percent") else { return nil }
            let scope = limit["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
            return ScopedUsageWindow(name: model ?? surface ?? "Scoped", window: window)
        }
        return UsageSnapshot(
            session: window(payload["five_hour"], usedKey: "utilization"),
            weekly: window(payload["seven_day"], usedKey: "utilization"),
            scoped: scoped,
            fetchedAt: now,
            note: nil
        )
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

}
