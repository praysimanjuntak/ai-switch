import Foundation

enum UsageService {
    private struct ClaudeLimit: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct ClaudeUsageResponse: Decodable {
        let fiveHour: ClaudeLimit?
        let sevenDay: ClaudeLimit?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    static func inspect(_ profile: AccountProfile) async throws -> ProviderInspection {
        switch profile.provider {
        case .codex:
            return try await inspectCodex(profileDirectory: profile.profileDirectory)
        case .claude:
            return try await inspectClaude(profileDirectory: profile.profileDirectory)
        }
    }

    static func inspectCodex(profileDirectory: String) async throws -> ProviderInspection {
        guard let codex = CommandRunner.locate("codex") else {
            throw AISwitchError.cliNotFound(.codex)
        }

        // App-server requests must be sent after its initialize response. The small
        // delay mirrors the documented JSONL handshake while keeping this a short,
        // self-contained child process.
        let script = #"""
        (printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-switch","title":"AI Switch","version":"\#(AppInfo.version)"},"capabilities":{"experimentalApi":true}}}'; sleep 0.25; printf '%s\n' '{"method":"initialized","params":{}}' '{"id":2,"method":"account/read","params":{"refreshToken":false}}' '{"id":3,"method":"account/rateLimits/read","params":null}'; sleep 3) | "$1" app-server --stdio
        """#
        let result = try await CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", script, "ai-switch", codex.path],
            environment: ["CODEX_HOME": profileDirectory],
            timeout: 12
        )

        let objects = result.output.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let accountResult = objects.first { ($0["id"] as? Int) == 2 }?["result"] as? [String: Any]
        let account = accountResult?["account"] as? [String: Any]
        let usageResult = objects.first { ($0["id"] as? Int) == 3 }?["result"] as? [String: Any]

        guard account != nil else {
            let message = result.output.isEmpty ? "Codex did not return account information." : result.output
            throw AISwitchError.invalidResponse(message)
        }

        let snapshot = usageResult.map { parseCodexUsage($0) }
        return ProviderInspection(
            email: account?["email"] as? String,
            plan: account?["planType"] as? String,
            usage: snapshot
        )
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
        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: now, note: note)
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
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw AISwitchError.claudeSessionExpired
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AISwitchError.invalidResponse("Claude usage refresh failed (HTTP \(code)). Re-authenticate this profile if its login expired.")
        }
        let payload = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return parseClaudeUsage(
            fiveHourUsed: payload.fiveHour?.utilization,
            fiveHourReset: payload.fiveHour?.resetsAt,
            sevenDayUsed: payload.sevenDay?.utilization,
            sevenDayReset: payload.sevenDay?.resetsAt,
            now: now
        )
    }

    static func parseClaudeUsage(
        fiveHourUsed: Double?,
        fiveHourReset: String?,
        sevenDayUsed: Double?,
        sevenDayReset: String?,
        now: Date = Date()
    ) -> UsageSnapshot {
        let session = fiveHourUsed.map {
            UsageWindow(usedPercent: $0, resetsAt: parseISO8601(fiveHourReset))
        }
        let weekly = sevenDayUsed.map {
            UsageWindow(usedPercent: $0, resetsAt: parseISO8601(sevenDayReset))
        }
        return UsageSnapshot(session: session, weekly: weekly, fetchedAt: now, note: nil)
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
