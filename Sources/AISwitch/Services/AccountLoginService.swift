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
}
