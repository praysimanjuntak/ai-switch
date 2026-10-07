import Foundation

/// Follows the session logs Codex writes under `~/.codex/sessions`. After every
/// turn Codex appends a `token_count` event carrying its current rate limits, and
/// each log starts with a `session_meta` line naming the user and ChatGPT account
/// it runs as. Reading only what was appended gives usage seconds after a turn
/// on this Mac, attributed to the right account, without any network request.
actor CodexSessionFeed {
    struct Snapshot: Sendable {
        let identity: AccountIdentity
        let usage: UsageSnapshot
        let plan: String?
    }

    private struct Log {
        var offset: UInt64
        /// Nil until read; `.some(nil)` when the log names no account.
        var identity: AccountIdentity??
    }

    private let root: URL
    private var logs: [String: Log] = [:]
    private var primed = false
    /// A log Codex is still writing to sits in the folder of the day it started.
    private static let daysWatched = 2
    /// More unread than this is skipped down to the newest part of the log.
    private static let maxRead: UInt64 = 2 << 20

    init(root: URL) {
        self.root = root
    }

    /// Rate limits Codex recorded since the previous call, newest per account.
    /// The first call only notes where each log ends: history from before AI
    /// Switch started is covered by its regular usage check.
    func poll(now: Date = Date()) -> [Snapshot] {
        var newest: [Snapshot] = []
        for url in recentLogs(now: now) {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) else { continue }
            var log = logs[url.path] ?? Log(offset: primed ? 0 : size, identity: nil)
            if size < log.offset { log = Log(offset: 0, identity: nil) } // Replaced.
            defer { logs[url.path] = log }
            guard size > log.offset else { continue }

            let skipped = size - log.offset > Self.maxRead
            let start = skipped ? size - Self.maxRead : log.offset
            guard let chunk = read(url, from: start, count: size - start) else { continue }
            var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The last piece is a line Codex hasn't finished writing; it is read again next time.
            let unfinished = lines.removeLast()
            log.offset = size - UInt64(unfinished.count)
            if skipped, !lines.isEmpty { lines.removeFirst() } // Started mid-line.

            for line in lines {
                if log.identity == nil, line.firstRange(of: Self.metaMarker) != nil {
                    log.identity = .some(Self.identity(fromMeta: line))
                    continue
                }
                guard line.firstRange(of: Self.rateLimitsMarker) != nil,
                      let (usage, plan) = Self.rateLimits(from: line) else { continue }
                if log.identity == nil { log.identity = .some(firstLineIdentity(of: url)) }
                guard case .some(.some(let identity)) = log.identity else { break }
                newest.removeAll { $0.identity.isSameAccount(as: identity) && $0.usage.fetchedAt <= usage.fetchedAt }
                if !newest.contains(where: { $0.identity.isSameAccount(as: identity) }) {
                    newest.append(Snapshot(identity: identity, usage: usage, plan: plan))
                }
            }
        }
        primed = true
        return newest
    }

    private func recentLogs(now: Date) -> [URL] {
        let calendar = Calendar.current
        return (0..<Self.daysWatched).flatMap { daysAgo -> [URL] in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return [] }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root
                .appendingPathComponent(String(format: "%04d", parts.year ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.month ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.day ?? 0), isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".jsonl") }.map { folder.appendingPathComponent($0) }
        }
    }

    private func read(_ url: URL, from offset: UInt64, count: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return try? handle.read(upToCount: Int(count))
    }

    /// The `session_meta` line opens every log; it can be long, as it carries the
    /// session's instructions.
    private func firstLineIdentity(of url: URL) -> AccountIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var head = Data()
        while head.count < Self.maxRead, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            head.append(chunk)
            if let end = head.firstIndex(of: UInt8(ascii: "\n")) {
                return Self.identity(fromMeta: head[head.startIndex..<end])
            }
        }
        return nil
    }

    private static let metaMarker = Data(#""type":"session_meta""#.utf8)
    private static let rateLimitsMarker = Data(#""rate_limits":{"#.utf8)

    private static func identity(fromMeta line: some DataProtocol) -> AccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let user = payload["creator_user_id"] as? String else { return nil }
        return AccountIdentity(user: user, organization: payload["creator_account_id"] as? String, email: nil)
    }

    /// The account-wide `codex` limits of a `token_count` event, as the app-server
    /// would report them.
    private static func rateLimits(from line: some DataProtocol) -> (UsageSnapshot, String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              (limits["limit_id"] as? String ?? "codex") == "codex",
              let stamp = object["timestamp"] as? String, let recordedAt = parseTimestamp(stamp) else { return nil }
        var windows: [String: Any] = [:]
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            windows[key] = [
                "usedPercent": window["used_percent"],
                "windowDurationMins": window["window_minutes"],
                "resetsAt": window["resets_at"],
            ].compactMapValues { $0 }
        }
        guard !windows.isEmpty else { return nil }
        return (UsageService.parseCodexUsage(["rateLimits": windows], now: recordedAt), limits["plan_type"] as? String)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
