import Foundation

enum AccountLoginService {
    static func authenticate(provider: AIProvider, directory: URL) async throws {
        try Task.checkCancellation()
        let command = provider == .codex ? "codex" : "claude"
        guard let executable = CommandRunner.locate(command) else {
            throw AISwitchError.cliNotFound(provider)
        }

        let result: CommandResult
        switch provider {
        case .codex:
            try Data("cli_auth_credentials_store = \"file\"\n".utf8)
                .write(to: directory.appendingPathComponent("config.toml"), options: .atomic)
            result = try await CommandRunner.run(
                executable: executable,
                arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""],
                environment: ["CODEX_HOME": directory.path], timeout: 600
            )
        case .claude:
            result = try await CommandRunner.run(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: ["CLAUDE_CONFIG_DIR": directory.path], timeout: 600
            )
        }

        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw AISwitchError.commandFailed(
                result.output.isEmpty ? "\(provider.displayName) sign-in did not finish. Please try again." : result.output
            )
        }
        switch provider {
        case .codex:
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path) else {
                throw AISwitchError.loginDidNotCreateCredentials(provider)
            }
        case .claude:
            try await ClaudeCredentialStore.adoptLoginCredential(configDirectory: directory)
        }
        try Task.checkCancellation()
    }

    /// Makes the provider's own CLI renew the credential saved in `directory`,
    /// the way a user would by starting a session with that account. AI Switch
    /// never calls an OAuth token endpoint itself. `executable` only exists so
    /// tests can point at a fake CLI.
    static func renew(provider: AIProvider, directory: URL, executable: URL? = nil) async throws {
        try Task.checkCancellation()
        let command = provider == .codex ? "codex" : "claude"
        guard let executable = executable ?? CommandRunner.locate(command) else {
            throw AISwitchError.cliNotFound(provider)
        }

        switch provider {
        case .codex:
            _ = try await UsageService.inspectCodex(profileDirectory: directory.path, executable: executable, refreshToken: true)
        case .claude:
            // One tool-less print-mode turn is the smallest session that makes
            // Claude Code refresh an expired token; it runs inside the profile
            // directory so no project settings or CLAUDE.md are picked up. The
            // prompt comes first because `--tools` is variadic and would swallow it.
            let result = try await CommandRunner.run(
                executable: executable,
                arguments: ["-p", "Reply with the single word OK.", "--tools", ""],
                environment: ["CLAUDE_CONFIG_DIR": directory.path],
                directory: directory,
                timeout: 120
            )
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "Claude Code could not renew this sign-in. Please try again." : result.output
                )
            }
            try await ClaudeCredentialStore.adoptLoginCredential(configDirectory: directory)
        }
        try Task.checkCancellation()
    }
}
