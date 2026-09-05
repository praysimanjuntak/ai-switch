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

@Test("Claude response values remain percentages used")
func parsesClaudeWindows() {
    let snapshot = UsageService.parseClaudeUsage(
        fiveHourUsed: 12.5,
        fiveHourReset: "2026-09-04T16:00:00.000000+00:00",
        sevenDayUsed: 51,
        sevenDayReset: "2026-09-06T07:00:00.154362+00:00",
        now: Date(timeIntervalSince1970: 1)
    )
    #expect(snapshot.session?.remainingPercent == 87.5)
    #expect(snapshot.weekly?.remainingPercent == 49)
    #expect(snapshot.weekly?.resetsAt != nil)
}

@Test("Claude Keychain service is isolated per config directory")
func claudeKeychainServiceName() {
    #expect(CredentialManager.claudeService(profileDirectory: nil) == "Claude Code-credentials")
    let first = CredentialManager.claudeService(profileDirectory: "/tmp/AI Switch/one")
    let again = CredentialManager.claudeService(profileDirectory: "/tmp/AI Switch/one")
    let second = CredentialManager.claudeService(profileDirectory: "/tmp/AI Switch/two")
    #expect(first == again)
    #expect(first != second)
    #expect(first.hasPrefix("Claude Code-credentials-"))
    #expect(first.count == "Claude Code-credentials-".count + 8)
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
