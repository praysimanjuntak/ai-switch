import Foundation

/// `aiswitch` lists the accounts saved in AI Switch and switches between them,
/// for people and agents in a terminal. It is the app's own executable started
/// under that name. The running app does the work, so the window and the
/// command never write accounts at the same time; `use` starts the app in the
/// background when it isn't running.
struct AgentCLI {
    enum Command: Equatable {
        case list(provider: AIProvider?, json: Bool)
        case use(account: String, provider: AIProvider?, json: Bool)
        case help
        case version
        case invalid(String)
    }

    static let name = "aiswitch"
    let command: Command

    /// Nil when the executable was started as the app: not under the `aiswitch`
    /// name, and without a command as its first argument.
    init?(arguments: [String]) {
        let invokedAs = URL(fileURLWithPath: arguments.first ?? "").lastPathComponent
        let words = Array(arguments.dropFirst())
        let commands: Set = ["list", "ls", "use", "switch", "help", "-h", "--help", "version", "--version"]
        guard invokedAs == Self.name || words.first.map(commands.contains) == true else { return nil }
        command = Self.parse(words)
    }

    func run() -> Int32 {
        switch command {
        case .help:
            print(Self.usage)
            return 0
        case .version:
            print("\(Self.name) \(Self.appBundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppInfo.version)")
            return 0
        case .invalid(let message):
            Self.printError("\(message)\nRun “aiswitch help” for usage.")
            return 2
        case .list(let provider, let json):
            do {
                let request = AgentRequest(command: .list, provider: provider)
                do {
                    return output(try AgentSocket.send(request, to: Self.socketPath), json: json)
                } catch AgentSocket.Failure.notRunning {
                    return output(try Self.savedAccounts(provider: provider), json: json)
                }
            } catch {
                return output(.failure(error.localizedDescription), json: json)
            }
        case .use(let account, let provider, let json):
            do {
                return output(try Self.sendStartingApp(AgentRequest(command: .use, account: account, provider: provider)), json: json)
            } catch {
                return output(.failure(error.localizedDescription), json: json)
            }
        }
    }

    static let usage = """
    aiswitch — list the accounts saved in AI Switch and switch between them.

    Usage:
      aiswitch list [--provider claude|codex] [--json]
      aiswitch use <account> [--provider claude|codex] [--json]

    <account> is an account's name, email, or id; the start of its id is enough.
    use switches the account new Claude Code or Codex sessions sign in with, like
    Switch in the app. Sessions already running keep their account.

    --json prints the answer as JSON, for scripts and agents. Percentages are
    what's left of each limit. Sign-ins are never printed.

    AI Switch does the work: use starts it in the background if it isn't running.
    """

    private static func parse(_ words: [String]) -> Command {
        guard let first = words.first else { return .help }
        var json = false
        var provider: AIProvider?
        var operands: [String] = []
        var rest = words.dropFirst()[...]
        while let word = rest.popFirst() {
            switch word {
            case "--json":
                json = true
            case "--provider", "-p":
                guard let value = rest.popFirst() else { return .invalid("--provider needs claude or codex.") }
                guard let parsed = Self.provider(value) else { return .invalid("Unknown provider “\(value)”: use claude or codex.") }
                provider = parsed
            case _ where word.hasPrefix("--provider="):
                let value = String(word.dropFirst("--provider=".count))
                guard let parsed = Self.provider(value) else { return .invalid("Unknown provider “\(value)”: use claude or codex.") }
                provider = parsed
            case _ where word.hasPrefix("-") && word.count > 1:
                return .invalid("Unknown option “\(word)”.")
            default:
                operands.append(word)
            }
        }
        switch first {
        case "help", "-h", "--help": return .help
        case "version", "--version": return .version
        case "list", "ls":
            return operands.isEmpty ? .list(provider: provider, json: json) : .invalid("list takes no account.")
        case "use", "switch":
            let account = operands.joined(separator: " ")
            return account.isEmpty ? .invalid("Name the account to use.") : .use(account: account, provider: provider, json: json)
        default:
            return .invalid("Unknown command “\(first)”.")
        }
    }

    private static func provider(_ value: String) -> AIProvider? {
        switch value.lowercased() {
        case "claude", "claude-code", "claudecode": .claude
        case "codex": .codex
        default: nil
        }
    }

    /// The AI Switch app this command belongs to. Started through the `aiswitch`
    /// link, Foundation takes the link's folder for the program's bundle, so the
    /// executable is resolved through the link first.
    private static var appBundle: Bundle? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? Bundle(url: bundle) : nil
    }

    private static var socketPath: String {
        AccountStore.defaultSupportDirectory.appendingPathComponent(AgentSocket.fileName).path
    }

    /// The accounts as AI Switch last saved them, for when it isn't running.
    private static func savedAccounts(provider: AIProvider?) throws -> AgentResponse {
        let file = AccountStore.defaultSupportDirectory.appendingPathComponent(AccountStore.stateFileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AgentResponse(ok: true, accounts: [], note: "AI Switch has no saved accounts yet.")
        }
        let state = try JSONDecoder.storedState.decode(StoredState.self, from: Data(contentsOf: file))
        return AgentResponse(ok: true,
                             accounts: AccountSummary.list(state.profiles, activeProfileIDs: state.activeProfileIDs, provider: provider),
                             note: "AI Switch isn't running, so this is as of its last check.")
    }

    /// Sends `request`, first starting the app in the background if nothing
    /// answers. A request is only sent again when it couldn't be delivered.
    private static func sendStartingApp(_ request: AgentRequest) throws -> AgentResponse {
        do {
            return try AgentSocket.send(request, to: socketPath)
        } catch AgentSocket.Failure.notRunning {}
        try startApp()
        let deadline = Date().addingTimeInterval(20)
        while true {
            do {
                return try AgentSocket.send(request, to: socketPath)
            } catch AgentSocket.Failure.notRunning where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            } catch AgentSocket.Failure.notRunning {
                throw AgentSocket.Failure.message("AI Switch was started but didn't answer. Open it, then try again.")
            }
        }
    }

    /// Opens the AI Switch this command belongs to, hidden and in the background.
    private static func startApp() throws {
        let bundle = appBundle?.bundleURL
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j"] + (bundle.map { [$0.path] } ?? ["-b", "com.pray.AISwitch"])
        let output = Pipe()
        open.standardOutput = output
        open.standardError = output
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            let reason = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentSocket.Failure.message("AI Switch isn't running and couldn't be started\(reason.isEmpty ? "" : ": \(reason)").")
        }
    }

    private func output(_ response: AgentResponse, json: Bool) -> Int32 {
        if json {
            if let data = try? AgentSocket.encoder(pretty: true).encode(response) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else if !response.ok {
            Self.printError(response.error ?? "Something went wrong.")
        } else if let accounts = response.accounts {
            print(Self.table(accounts))
            if let note = response.note { print("\n\(note)") }
        } else if let note = response.note {
            print(note)
        }
        return response.ok ? 0 : 1
    }

    static func table(_ accounts: [AccountSummary]) -> String {
        guard !accounts.isEmpty else { return "No accounts yet. Add one in AI Switch." }
        let header = ["", "ACCOUNT", "PROVIDER", "EMAIL", "PLAN", "5-HOUR", "WEEKLY", "OTHER LIMITS"]
        let rows = accounts.map { account -> [String] in
            func left(_ name: String) -> String {
                account.limits.first { $0.name == name }.map { "\($0.leftPercent)%" } ?? "—"
            }
            let others = account.limits.filter { $0.name != "5-hour" && $0.name != "Weekly" }
                .map { "\($0.name) \($0.leftPercent)%" }
            return [account.active ? "*" : "", account.name, account.provider.displayName, account.email ?? "—",
                    account.plan ?? "—", left("5-hour"), left("Weekly"), others.joined(separator: ", ")]
        }
        let widths = header.indices.map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
        let lines = ([header] + rows).map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var text = lines.joined(separator: "\n") + "\n\n* New sessions sign in with this account. Percentages are what's left."
        for account in accounts {
            if let issue = account.needsAttention { text += "\n! \(account.name): \(issue)" }
        }
        return text
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("aiswitch: \(message)\n".utf8))
    }
}
