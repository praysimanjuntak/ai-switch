import Darwin
import Foundation
import Testing
@testable import AISwitch

@Test("Codex reset credits count the available ones, soonest to expire first")
func parsesCodexResetCredits() throws {
    let snapshot = UsageService.parseCodexUsage([
        "rateLimits": ["primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1_800_000_000]],
        "rateLimitResetCredits": [
            "availableCount": 2,
            "credits": [
                ["id": "a", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1, "expiresAt": 1_800_500_000, "title": "Full reset"],
                ["id": "b", "resetType": "codexRateLimits", "status": "redeemed", "grantedAt": 1, "expiresAt": 1_800_100_000, "title": "Full reset"],
                ["id": "c", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1, "expiresAt": 1_800_200_000, "title": "  "],
            ],
        ],
    ], now: Date(timeIntervalSince1970: 1))
    let resets = try #require(snapshot.resets)
    #expect(resets.available == 2)
    #expect(resets.credits.map(\.expiresAt) == [Date(timeIntervalSince1970: 1_800_200_000), Date(timeIntervalSince1970: 1_800_500_000)])
    #expect(resets.credits.first?.title == nil)
    #expect(UsageService.parseCodexUsage(["rateLimits": [String: Any]()]).resets == nil)
}

/// A stand-in `codex app-server` that answers the reset request with `answer`.
private func fakeResetServer(in directory: URL, answer: String) throws -> URL {
    let url = directory.appendingPathComponent("codex")
    try """
    #!/bin/sh
    echo $$ > "\(directory.path)/fake.pid"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "\(directory.path)/requests"
      case "$line" in
        *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"id":2'*) printf '%s\\n' '\(answer)'
                    sleep 30 ;;
      esac
    done
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Test("A Codex reset is spent through the app-server's consume request, once, and the server is stopped")
func codexResetUsesAppServer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchReset-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codex = try fakeResetServer(in: directory, answer: #"{"id":2,"result":{"outcome":"reset"}}"#)

    let outcome = try await UsageService.consumeCodexReset(profileDirectory: directory.path, executable: codex)

    #expect(outcome == .reset)
    let requests = try String(contentsOf: directory.appendingPathComponent("requests"), encoding: .utf8).split(separator: "\n")
    let consume = try #require(requests.first { $0.contains(#""id":2"#) })
    let object = try #require(JSONSerialization.jsonObject(with: Data(consume.utf8)) as? [String: Any])
    #expect(object["method"] as? String == "account/rateLimitResetCredit/consume")
    let key = (object["params"] as? [String: Any])?["idempotencyKey"] as? String
    #expect(key.flatMap(UUID.init(uuidString:)) != nil)
    let pid = try #require(pid_t(try String(contentsOf: directory.appendingPathComponent("fake.pid"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1)
}

@Test("A reset Codex refuses reports Codex's reason")
func codexResetErrorIsReported() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchReset-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codex = try fakeResetServer(in: directory, answer: #"{"id":2,"error":{"code":-32603,"message":"failed to consume rate limit reset: backend unavailable"}}"#)
    do {
        _ = try await UsageService.consumeCodexReset(profileDirectory: directory.path, executable: codex)
        Issue.record("Expected the refusal to be reported")
    } catch AISwitchError.invalidResponse(let message) {
        #expect(message.contains("backend unavailable"))
    }
}

@Test("Using a reset spends it on the profile's own sign-in, hands a renewed token back to the CLI, and re-reads usage")
@MainActor
func usingResetRefreshesAccount() async throws {
    let fixture = try RefreshFixture(active: true)
    defer { try? fixture.remove() }
    try writeCredential("mine", of: fixture.profile)
    let live = LiveClaudeStub("mine")
    let afterReset = ProviderInspection(usage: UsageSnapshot(
        session: UsageWindow(usedPercent: 0, resetsAt: nil), weekly: nil, fetchedAt: Date(), note: nil,
        resets: LimitResets(available: 1, credits: [])
    ))
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in afterReset },
                             resetLimits: { _, _ in
                                 // The app-server can renew the sign-in it ran on.
                                 try writeCredential("renewed-during-reset", of: fixture.profile)
                                 return .reset
                             },
                             liveClaude: await live.credential)

    let outcome = try await store.useReset(fixture.profile.id)

    #expect(outcome == .reset)
    #expect(await live.stored == Data("renewed-during-reset".utf8))
    #expect(store.profiles.first?.usage?.resets?.available == 1)
    #expect(store.profiles.first?.usage?.session?.usedPercent == 0)
    #expect(!store.isRefreshing)
}
