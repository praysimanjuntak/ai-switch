import Foundation
import Testing
@testable import AISwitch

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// Claude accounts "Work" (active) and "Personal", each with its own saved
/// sign-in, and a store whose Claude Code is `live`.
@MainActor
private func workAndPersonal(_ fixture: RefreshFixture, personalEmail: String = "me@example.com",
                             extra: [AccountProfile] = []) async throws -> (AccountStore, LiveClaudeStub, AccountProfile, AccountProfile) {
    var work = RefreshFixture.claudeProfile(named: "Work", directory: fixture.directory.appendingPathComponent("work"))
    work.email = "work@example.com"
    var personal = RefreshFixture.claudeProfile(named: "Personal", directory: fixture.directory.appendingPathComponent("personal"))
    personal.email = personalEmail
    try fixture.save([work, personal] + extra, active: ["claude": work.id])
    try writeCredential("work", of: work)
    try writeCredential("personal", of: personal)
    let live = LiveClaudeStub("work")
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false,
                             inspect: { _ in ProviderInspection() }, identify: identities(["work": "w", "personal": "p"]),
                             liveClaude: await live.credential)
    return (store, live, work, personal)
}

@Test("The executable is aiswitch only under that name or given a command; otherwise the app starts")
func commandModeDetection() {
    let app = "/Applications/AI Switch.app/Contents/MacOS/AISwitch"
    #expect(AgentCLI(arguments: [app]) == nil)
    #expect(AgentCLI(arguments: [app, "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    #expect(AgentCLI(arguments: ["aiswitch"])?.command == .help)
    #expect(AgentCLI(arguments: ["/opt/homebrew/bin/aiswitch", "list", "--json"])?.command == .list(provider: nil, json: true))
    #expect(AgentCLI(arguments: [app, "use", "Claude", "Code", "account", "--provider", "claude"])?.command
            == .use(account: "Claude Code account", provider: .claude, json: false))
    for refused in [["aiswitch", "use"], ["aiswitch", "list", "--provider", "gemini"], ["aiswitch", "frobnicate"]] {
        guard case .invalid = AgentCLI(arguments: refused)?.command else {
            Issue.record("\(refused) should be refused")
            continue
        }
    }
}

@Test("aiswitch use switches by name, email, or the start of an id, like Switch in the app")
@MainActor
func useSwitchesAccounts() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let (store, live, work, personal) = try await workAndPersonal(fixture)

    let byName = await store.respond(to: AgentRequest(command: .use, account: "personal"))
    #expect(byName.ok && byName.account?.id == personal.id && byName.account?.active == true)
    #expect(store.activeProfileIDs["claude"] == personal.id)
    _ = await store.respond(to: AgentRequest(command: .use, account: String(work.id.uuidString.prefix(6)).lowercased()))
    #expect(store.activeProfileIDs["claude"] == work.id)
    _ = await store.respond(to: AgentRequest(command: .use, account: "ME@example.com"))
    #expect(store.activeProfileIDs["claude"] == personal.id)
    #expect(await live.writes.map(text) == ["personal", "work", "personal"])
}

@Test("An unknown or ambiguous account switches nothing, and the answer names the accounts that matched")
@MainActor
func useRefusesUnclearAccounts() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let (store, live, work, _) = try await workAndPersonal(fixture, personalEmail: "work@example.com")

    let ambiguous = await store.respond(to: AgentRequest(command: .use, account: "work@example.com"))
    #expect(!ambiguous.ok)
    #expect(ambiguous.error?.contains("Work (") == true && ambiguous.error?.contains("Personal (") == true)
    let unknown = await store.respond(to: AgentRequest(command: .use, account: "nobody"))
    #expect(!unknown.ok && unknown.error?.contains("nobody") == true)

    #expect(store.activeProfileIDs["claude"] == work.id)
    #expect(await live.writes.isEmpty)
}

@Test("--provider picks between accounts of different providers with the same name")
@MainActor
func useNarrowsByProvider() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let codex = AccountProfile(id: UUID(), provider: .codex, displayName: "Personal", email: "me@example.com", plan: "plus",
                               profileDirectory: fixture.directory.appendingPathComponent("codex").path, createdAt: Date(),
                               lastActivatedAt: nil, usage: nil, authIssue: nil)
    let (store, live, _, personal) = try await workAndPersonal(fixture, extra: [codex])

    let both = await store.respond(to: AgentRequest(command: .use, account: "Personal"))
    #expect(!both.ok)
    let claudeOnly = await store.respond(to: AgentRequest(command: .use, account: "Personal", provider: .claude))
    #expect(claudeOnly.ok && claudeOnly.account?.id == personal.id)
    #expect(await live.writes.map(text) == ["personal"])
}

@Test("aiswitch list shows what's left of each limit, which account is in use, and what needs attention, never a sign-in")
@MainActor
func listSummarizesAccounts() async throws {
    let fixture = try RefreshFixture()
    defer { try? fixture.remove() }
    let reset = Date(timeIntervalSince1970: 1_800_000_000)
    var work = RefreshFixture.claudeProfile(named: "Work", directory: fixture.directory.appendingPathComponent("work"))
    work.usage = UsageSnapshot(session: UsageWindow(usedPercent: 21, resetsAt: reset), weekly: UsageWindow(usedPercent: 68, resetsAt: nil),
                               scoped: [ScopedUsageWindow(name: "Fable", window: UsageWindow(usedPercent: 29, resetsAt: nil))],
                               fetchedAt: Date(), note: nil)
    var broken = RefreshFixture.claudeProfile(named: "Broken", directory: fixture.directory.appendingPathComponent("broken"))
    broken.usage = nil
    broken.authIssue = "Unable to renew sign-in: expired."
    try fixture.save([work, broken], active: ["claude": work.id])
    try writeCredential("secret-token-123", of: work)
    let store = AccountStore(supportDirectory: fixture.directory, startsAutomatically: false, liveClaude: await LiveClaudeStub(nil).credential)

    let response = await store.respond(to: AgentRequest(command: .list))

    let accounts = try #require(response.accounts)
    #expect(accounts.map(\.name) == ["Broken", "Work"])
    #expect(accounts[1].active && !accounts[0].active)
    #expect(accounts[1].limits.map(\.name) == ["5-hour", "Weekly", "Fable weekly"])
    #expect(accounts[1].limits.map(\.leftPercent) == [79, 32, 71])
    #expect(accounts[1].limits.first?.resetsAt == reset)
    #expect(accounts[0].needsAttention == "Unable to renew sign-in: expired." && accounts[0].limits.isEmpty)
    #expect(!text(try AgentSocket.encoder().encode(response)).contains("secret-token-123"))
}

// MARK: Putting aiswitch on the PATH

private struct Home {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISwitchHome-\(UUID().uuidString)", isDirectory: true)
    var link: URL { directory.appendingPathComponent(".local/bin/aiswitch") }

    func destination(of url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
    func symlink(_ url: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }
    func remove() throws { try FileManager.default.removeItem(at: directory) }
}

private let app = URL(fileURLWithPath: "/Applications/AI Switch.app/Contents/MacOS/AISwitch")

@Test("AI Switch puts aiswitch in ~/.local/bin, moves a link to another copy of itself, and never replaces another program's")
func installsCommand() throws {
    let home = Home()
    defer { try? home.remove() }

    #expect(CommandLineTool.install(executable: app, home: home.directory, linkedElsewhere: []) == home.link)
    #expect(home.destination(of: home.link) == app.path)

    try FileManager.default.removeItem(at: home.link)
    try home.symlink(home.link, to: "/Users/me/Applications/AI Switch.app/Contents/MacOS/AISwitch")
    #expect(CommandLineTool.install(executable: app, home: home.directory, linkedElsewhere: []) == home.link)
    #expect(home.destination(of: home.link) == app.path)

    try FileManager.default.removeItem(at: home.link)
    try home.symlink(home.link, to: "/usr/local/lib/other-tool/aiswitch")
    #expect(CommandLineTool.install(executable: app, home: home.directory, linkedElsewhere: []) == nil)
    #expect(home.destination(of: home.link) == "/usr/local/lib/other-tool/aiswitch")

    try FileManager.default.removeItem(at: home.link)
    try Data("#!/bin/sh\n".utf8).write(to: home.link)
    #expect(CommandLineTool.install(executable: app, home: home.directory, linkedElsewhere: []) == nil)
    #expect(try Data(contentsOf: home.link) == Data("#!/bin/sh\n".utf8))
}

@Test("A Homebrew link replaces AI Switch's own in ~/.local/bin, and a disk image or translocated copy changes nothing")
func homebrewAndTemporaryCopies() throws {
    let home = Home()
    defer { try? home.remove() }
    let brew = home.directory.appendingPathComponent("homebrew/bin/aiswitch")
    try home.symlink(brew, to: app.path)
    try home.symlink(home.link, to: "/Users/me/Applications/AI Switch.app/Contents/MacOS/AISwitch")

    #expect(CommandLineTool.install(executable: app, home: home.directory, linkedElsewhere: [brew]) == nil)
    #expect(home.destination(of: home.link) == nil)

    for temporary in ["/Volumes/AI Switch 0.10.0/AI Switch.app/Contents/MacOS/AISwitch",
                      "/private/var/folders/xy/T/AppTranslocation/1A2B/d/AI Switch.app/Contents/MacOS/AISwitch"] {
        #expect(CommandLineTool.install(executable: URL(fileURLWithPath: temporary), home: home.directory, linkedElsewhere: []) == nil)
    }
    #expect(home.destination(of: home.link) == nil)
}
