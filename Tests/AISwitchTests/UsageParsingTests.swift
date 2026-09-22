import Darwin
import Foundation
import Testing
@testable import AISwitch

@Test("Remaining percentage is clamped")
func remainingPercentageIsClamped() {
    #expect(UsageWindow(usedPercent: 37, resetsAt: nil).remainingPercent == 63)
    #expect(UsageWindow(usedPercent: 130, resetsAt: nil).remainingPercent == 0)
    #expect(UsageWindow(usedPercent: -5, resetsAt: nil).remainingPercent == 100)
}

@Test("Codex five-hour and weekly windows are classified by duration")
func parsesCodexWindows() {
    let response: [String: Any] = [
        "rateLimits": [
            "primary": [
                "usedPercent": 22,
                "windowDurationMins": 300,
                "resetsAt": 1_800_000_000
            ],
            "secondary": [
                "usedPercent": 76,
                "windowDurationMins": 10_080,
                "resetsAt": 1_800_100_000
            ]
        ]
    ]
    let snapshot = UsageService.parseCodexUsage(response, now: Date(timeIntervalSince1970: 1))
    #expect(snapshot.session?.usedPercent == 22)
    #expect(snapshot.session?.remainingPercent == 78)
    #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(snapshot.weekly?.usedPercent == 76)
    #expect(snapshot.weekly?.remainingPercent == 24)
    #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_800_100_000))
}

@Test("An exhausted Codex five-hour limit keeps its precise reset timestamp")
func exhaustedCodexLimitKeepsReset() {
    let response: [String: Any] = [
        "rateLimits": [
            "primary": [
                "usedPercent": 100,
                "windowDurationMins": 300,
                "resetsAt": 1_800_000_055
            ]
        ]
    ]
    let snapshot = UsageService.parseCodexUsage(response, now: Date(timeIntervalSince1970: 1))
    #expect(snapshot.session?.remainingPercent == 0)
    #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_800_000_055))
}

@Test("Claude account-wide windows and per-model weekly buckets are parsed from the usage response")
func parsesClaudeWindows() throws {
    let payload = try #require(JSONSerialization.jsonObject(with: Data(#"""
    {"five_hour":{"utilization":12.5,"resets_at":"2026-09-04T16:00:00.000000+00:00","locked_reason":null},
     "seven_day":{"utilization":51,"resets_at":"2026-09-06T07:00:00.154362+00:00"},
     "seven_day_opus":null,
     "limits":[
       {"kind":"session","group":"session","percent":12,"resets_at":"2026-09-04T16:00:00.000000+00:00","scope":null},
       {"kind":"weekly_all","group":"weekly","percent":51,"resets_at":"2026-09-06T07:00:00.154362+00:00","scope":null},
       {"kind":"weekly_scoped","group":"weekly","percent":8,"resets_at":"2026-09-06T07:00:00.726981+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
     ]}
    """#.utf8)) as? [String: Any])
    let snapshot = UsageService.parseClaudeUsage(payload, now: Date(timeIntervalSince1970: 1))
    #expect(snapshot.session?.remainingPercent == 87.5)
    #expect(snapshot.weekly?.remainingPercent == 49)
    #expect(snapshot.weekly?.resetsAt != nil)
    #expect(snapshot.scoped.map(\.name) == ["Fable"])
    #expect(snapshot.scoped.first?.window.usedPercent == 8)
    let scopedReset = try #require(snapshot.scoped.first?.window.resetsAt)
    #expect(abs(scopedReset.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-09-06T07:00:00Z")!)) < 1)

    let bare = UsageService.parseClaudeUsage(["five_hour": ["utilization": 3]], now: Date(timeIntervalSince1970: 1))
    #expect(bare.scoped.isEmpty)
    #expect(bare.weekly == nil)
}

@Test("Usage snapshots saved before per-model buckets existed still decode")
func legacySnapshotDecodes() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = Data(#"{"session":{"usedPercent":12},"fetchedAt":"2026-09-01T00:00:00Z"}"#.utf8)
    let snapshot = try decoder.decode(UsageSnapshot.self, from: legacy)
    #expect(snapshot.session?.usedPercent == 12)
    #expect(snapshot.scoped.isEmpty)
}

@Test("Claude Keychain service names match Claude Code's per-config-directory scheme")
func claudeKeychainServiceName() {
    #expect(ClaudeCredentialStore.service(configDirectory: nil) == "Claude Code-credentials")
    let first = ClaudeCredentialStore.service(configDirectory: "/tmp/AI Switch/one")
    let again = ClaudeCredentialStore.service(configDirectory: "/tmp/AI Switch/one")
    let second = ClaudeCredentialStore.service(configDirectory: "/tmp/AI Switch/two")
    #expect(first == again)
    #expect(first != second)
    // `printf '/tmp/AI Switch/one' | shasum -a 256 | cut -c1-8`, the scheme Claude Code keys its item with.
    #expect(first == "Claude Code-credentials-046a2eb0")
    #expect(ClaudeCredentialStore.service(configDirectory: "/tmp/e\u{301}")
            == ClaudeCredentialStore.service(configDirectory: "/tmp/\u{e9}"))
}

@Test("An access token past its expiry is reported as needing renewal, not as signed out")
func expiredClaudeTokenIsDetectedLocally() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func credential(expiresAt: Double?) -> Data {
        let expiry = expiresAt.map { "\"expiresAt\":\($0)," } ?? ""
        return Data(#"{"claudeAiOauth":{\#(expiry)"accessToken":"sk-ant-oat01-test"}}"#.utf8)
    }
    #expect(try ClaudeCredentialStore.accessToken(from: credential(expiresAt: 1_800_000_001_000), now: now) == "sk-ant-oat01-test")
    #expect(try ClaudeCredentialStore.accessToken(from: credential(expiresAt: nil), now: now) == "sk-ant-oat01-test")
    #expect(throws: AISwitchError.self) {
        try ClaudeCredentialStore.accessToken(from: credential(expiresAt: 1_800_000_000_000), now: now)
    }
    #expect(throws: AISwitchError.self) {
        try ClaudeCredentialStore.accessToken(from: Data(#"{"claudeAiOauth":{}}"#.utf8), now: now)
    }
}

@Test("Claude account metadata comes from local config and credential metadata")
func claudeMetadataDoesNotNeedCLIStatus() {
    let config = Data(#"{"oauthAccount":{"emailAddress":"account@example.com","organizationName":"Example"}}"#.utf8)
    let credential = Data(#"{"claudeAiOauth":{"subscriptionType":"max"}}"#.utf8)
    let result = UsageService.claudeMetadata(configData: config, credentialData: credential)
    #expect(result.email == "account@example.com")
    #expect(result.plan == "max")
    #expect(result.usage == nil)
    #expect(UsageService.claudeMetadata(configData: config).plan == "Example")
}

@Test("Missing or malformed Claude metadata does not imply a signed-out account")
func missingClaudeMetadataIsOptional() {
    let missing = UsageService.claudeMetadata(configData: nil)
    #expect(missing.email == nil)
    #expect(missing.plan == nil)
    let malformed = UsageService.claudeMetadata(configData: Data("invalid".utf8))
    #expect(malformed.email == nil)
    #expect(malformed.plan == nil)
}

@Test("Codex account and usage come from one app-server handshake, and the server is stopped afterwards")
func inspectsCodexOverAppServerSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchCodexTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Answers the JSONL handshake and then parks forever: only termination ends it.
    let fake = directory.appendingPathComponent("codex")
    try #"""
    #!/bin/sh
    printf '%s\n' "$CODEX_HOME" > "\#(directory.path)/codex-home"
    printf '%s\n' "$*" > "\#(directory.path)/arguments"
    echo $$ > "\#(directory.path)/fake.pid"
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        *'"id":2'*) printf '%s\n' '{"id":2,"result":{"account":{"email":"fake@example.com","planType":"plus"}}}' ;;
        *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800000000}}}}'
                    sleep 30 ;;
      esac
    done
    """#.write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let profileDirectory = directory.appendingPathComponent("profile").path
    let start = ContinuousClock.now
    let inspection = try await UsageService.inspectCodex(profileDirectory: profileDirectory, executable: fake)
    let elapsed = start.duration(to: .now)

    #expect(inspection.email == "fake@example.com")
    #expect(inspection.plan == "plus")
    #expect(inspection.usage?.session?.usedPercent == 40)
    #expect(inspection.usage?.session?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    let home = try String(contentsOf: directory.appendingPathComponent("codex-home"), encoding: .utf8)
    #expect(home.trimmingCharacters(in: .whitespacesAndNewlines) == profileDirectory)
    let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
    #expect(arguments.trimmingCharacters(in: .whitespacesAndNewlines) == "app-server --stdio")
    // The handshake now ends with the last answer; the old fixed-sleep pipeline
    // could not finish in under 3.25 seconds.
    #expect(elapsed < .seconds(3))

    let recorded = try String(contentsOf: directory.appendingPathComponent("fake.pid"), encoding: .utf8)
    let pid = try #require(pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1)
}
