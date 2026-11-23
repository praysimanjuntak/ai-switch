import Foundation

/// Serializes operations that temporarily swap Antigravity CLI's single global
/// Keychain entry (`gemini` / `antigravity`), so login and renewal never race.
private actor AntigravityKeychainGate {
    static let shared = AntigravityKeychainGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            busy = false
        }
    }
}

enum AccountLoginService {
    /// Environment variables that would bypass Antigravity's Google OAuth flow
    /// or stop it from opening a browser.
    private static let antigravityUnsetEnvironment: Set<String> = [
        "GEMINI_API_KEY",
        "ANTIGRAVITY_API_KEY",
        "AGY_ADC_AUTH",
        "NO_BROWSER",
        "CI",
    ]

    static func authenticate(
        provider: AIProvider,
        directory: URL,
        executable: URL? = nil,
        liveAntigravity: LiveAntigravityCredential = .system
    ) async throws {
        try Task.checkCancellation()
        guard let executable = executable ?? CommandRunner.locate(provider.cliName) else {
            throw AISwitchError.cliNotFound(provider)
        }

        switch provider {
        case .codex:
            try Data("cli_auth_credentials_store = \"file\"\n".utf8)
                .write(to: directory.appendingPathComponent("config.toml"), options: .atomic)
            let result = try await CommandRunner.run(
                executable: executable,
                arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""],
                environment: ["CODEX_HOME": directory.path], timeout: 600
            )
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "\(provider.displayName) sign-in did not finish. Please try again." : result.output
                )
            }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path) else {
                throw AISwitchError.loginDidNotCreateCredentials(provider)
            }
        case .claude:
            let result = try await CommandRunner.run(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: ["CLAUDE_CONFIG_DIR": directory.path], timeout: 600
            )
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "\(provider.displayName) sign-in did not finish. Please try again." : result.output
                )
            }
            try await ClaudeCredentialStore.adoptLoginCredential(configDirectory: directory)
        case .antigravity:
            // `agy` keeps a single global login in the macOS Keychain (`gemini`/`antigravity`).
            // Snapshot it before running `agy acp --login`, capture the new sign-in into
            // `directory`, and always restore the prior live sign-in afterwards so cancelling
            // or signing into the wrong account never disturbs the active `agy` session.
            await AntigravityKeychainGate.shared.acquire()
            let previous = try? await liveAntigravity.read()
            await liveAntigravity.delete()
            let run: Result<CommandResult, any Error>
            do {
                run = .success(try await CommandRunner.run(
                    executable: executable,
                    arguments: ["acp", "--login"],
                    unsetEnvironment: antigravityUnsetEnvironment,
                    directory: directory,
                    timeout: 600
                ))
            } catch {
                run = .failure(error)
            }
            // Capture and restore inside an uncancelled Task so cancellation never
            // leaves the user's prior live Antigravity session signed out.
            let fresh: Data? = await Task {
                let captured = (try? run.get().exitCode == 0) == true ? (try? await liveAntigravity.read()) : nil
                if let previous {
                    try? await liveAntigravity.write(previous)
                } else {
                    await liveAntigravity.delete()
                }
                await AntigravityKeychainGate.shared.release()
                return captured
            }.value

            let result = try run.get()
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "Antigravity sign-in did not finish. Please try again." : result.output
                )
            }
            guard let fresh, !fresh.isEmpty else {
                throw AISwitchError.loginDidNotCreateCredentials(.antigravity)
            }
            try FileManager.default.writeOwnerOnly(
                AntigravityCredentialStore.unwrapKeyringPayload(fresh),
                to: AntigravityCredentialStore.credentialURL(profileDirectory: directory)
            )
        }
        try Task.checkCancellation()
    }

    /// Makes the provider's own CLI renew the credential saved in `directory`,
    /// the way a user would by starting a session with that account. AI Switch
    /// never calls an OAuth token endpoint itself. `executable`, `adopt`, and
    /// `liveAntigravity` only exist so tests can point at a fake CLI and Keychain.
    static func renew(
        provider: AIProvider,
        directory: URL,
        executable: URL? = nil,
        adopt: @escaping @Sendable (URL) async throws -> Void = { try await ClaudeCredentialStore.adoptLoginCredential(configDirectory: $0) },
        liveAntigravity: LiveAntigravityCredential = .system
    ) async throws {
        try Task.checkCancellation()
        guard let executable = executable ?? CommandRunner.locate(provider.cliName) else {
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
            let run: Result<CommandResult, any Error>
            do {
                run = .success(try await CommandRunner.run(
                    executable: executable,
                    arguments: ["-p", "Reply with the single word OK.", "--tools", ""],
                    environment: ["CLAUDE_CONFIG_DIR": directory.path],
                    directory: directory,
                    timeout: 120
                ))
            } catch {
                run = .failure(error)
            }
            // Claude Code can move the profile's credential into the Keychain item
            // keyed by this directory as soon as it starts, even when the run then
            // fails (offline, timed out, cancelled), so it is brought back whatever
            // the outcome; otherwise the profile is left without its sign-in.
            let adoption = await Task { try await adopt(directory) }.result
            let result = try run.get()
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "Claude Code could not renew this sign-in. Please try again." : result.output
                )
            }
            try adoption.get()
        case .antigravity:
            let credentialURL = AntigravityCredentialStore.credentialURL(profileDirectory: directory)
            let prior = try AntigravityCredentialStore.readProfile(directory: directory.path)
            await AntigravityKeychainGate.shared.acquire()
            let previousLive = try? await liveAntigravity.read()
            try await liveAntigravity.write(prior)

            // Try `agy models` first (zero inference quota); if that didn't produce
            // an unexpired token, fall back to a one-word print-mode turn.
            let outcome: (result: Result<CommandResult, any Error>, refreshed: Data?)
            do {
                var commandResult = try await CommandRunner.run(
                    executable: executable,
                    arguments: ["models"],
                    unsetEnvironment: antigravityUnsetEnvironment,
                    directory: directory,
                    timeout: 60
                )
                var current = try? await liveAntigravity.read()
                let stillExpired = current.map { (try? AntigravityCredentialStore.accessToken(from: $0)) == nil } ?? true
                if commandResult.exitCode != 0 || stillExpired {
                    commandResult = try await CommandRunner.run(
                        executable: executable,
                        arguments: ["-p", "Reply with the single word OK.", "--disable-slash-commands", "--print-timeout", "60s"],
                        unsetEnvironment: antigravityUnsetEnvironment,
                        directory: directory,
                        timeout: 90
                    )
                    current = try? await liveAntigravity.read()
                }
                outcome = (.success(commandResult), current)
            } catch {
                outcome = (.failure(error), try? await liveAntigravity.read())
            }

            // Always restore the prior live credential before returning or throwing.
            await Task {
                if let previousLive {
                    try? await liveAntigravity.write(previousLive)
                } else {
                    await liveAntigravity.delete()
                }
                await AntigravityKeychainGate.shared.release()
            }.value

            let result = try outcome.result.get()
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw AISwitchError.commandFailed(
                    result.output.isEmpty ? "Antigravity could not renew this sign-in. Please try again." : result.output
                )
            }
            if let refreshed = outcome.refreshed {
                let merged = AntigravityCredentialStore.merge(newer: refreshed, into: prior)
                try FileManager.default.writeOwnerOnly(merged, to: credentialURL)
            }
        }
        try Task.checkCancellation()
    }
}
