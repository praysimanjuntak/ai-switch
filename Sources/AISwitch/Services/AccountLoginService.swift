import Foundation

/// Hands the code a browser sign-in shows over to the CLI waiting for it.
/// Antigravity's `agy acp --login` can't hear back from the browser: Google
/// shows an authorization code on a web page, and `agy` reads it from its
/// input. The sign-in window answers through this.
@MainActor
final class SignInCodePrompt: ObservableObject {
    /// The sign-in page while the CLI waits for its code; nil otherwise.
    @Published private(set) var signInPage: URL?
    private var pending: CheckedContinuation<String, any Error>?

    /// Waits for `submit(_:)`. Ends with `CancellationError` when the waiting
    /// task is cancelled or `cancel()` is called.
    func code(signInPage page: URL) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending?.resume(throwing: CancellationError())
                pending = continuation
                signInPage = page
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Hands `code` to the waiting CLI; blank input is ignored.
    func submit(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pending else { return }
        self.pending = nil
        signInPage = nil
        pending.resume(returning: trimmed)
    }

    func cancel() {
        signInPage = nil
        pending?.resume(throwing: CancellationError())
        pending = nil
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

    /// `codePrompt` answers a CLI that asks for the code its browser sign-in
    /// shows (`agy`); without one, such a sign-in fails instead of waiting.
    static func authenticate(
        provider: AIProvider,
        directory: URL,
        codePrompt: SignInCodePrompt? = nil,
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
            // `agy` keeps one global sign-in in the macOS Keychain (`gemini`/`antigravity`).
            // `agy acp --login` runs with it signed out, the new sign-in is captured into
            // `directory`, and the prior one always comes back, so cancelling or signing
            // into the wrong account never disturbs the active `agy` session. A Keychain
            // that can't be read stops the sign-in before anything changed.
            let login: (run: Result<(exitCode: Int32, output: [String]), any Error>, fresh: Data?) =
                try await liveAntigravity.withExclusiveAccess {
                    let previous = try await liveAntigravity.read()
                    await liveAntigravity.delete()
                    let run: Result<(exitCode: Int32, output: [String]), any Error>
                    do {
                        run = .success(try await CommandRunner.interact(
                            executable: executable,
                            arguments: ["acp", "--login"],
                            unsetEnvironment: antigravityUnsetEnvironment,
                            directory: directory,
                            timeout: 600
                        ) { session in
                            try await Self.answerAntigravityLogin(session, codePrompt: codePrompt)
                        })
                    } catch {
                        run = .failure(error)
                    }
                    // Capture and restore inside an uncancelled Task so cancellation never
                    // leaves the user's prior live Antigravity session signed out.
                    let fresh: Data? = await Task {
                        let captured = (try? run.get().exitCode == 0) == true ? (try? await liveAntigravity.read()) : nil
                        await Self.restore(previous, to: liveAntigravity)
                        return captured
                    }.value
                    return (run, fresh)
                }

            let result = try login.run.get()
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                // The last line says why (`couldn't log in: …`), possibly right after the
                // prompt for the code; the lines before it are the link and instructions.
                let last = result.output.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let reason = last.map { line in line.range(of: "couldn't log in").map { String(line[$0.lowerBound...]) } ?? line }
                throw AISwitchError.commandFailed(reason ?? "Antigravity sign-in did not finish. Please try again.")
            }
            guard let fresh = login.fresh, !fresh.isEmpty else {
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
            // `agy` renews only its one global sign-in, so the profile's sign-in is made
            // live while `agy models` refreshes it (no inference quota), and the prior one
            // always comes back afterwards. A Keychain that can't be read stops here,
            // before anything changed.
            let credentialURL = AntigravityCredentialStore.credentialURL(profileDirectory: directory)
            let prior = try AntigravityCredentialStore.readProfile(directory: directory.path)
            let renewal: Result<Data?, any Error> = try await liveAntigravity.withExclusiveAccess {
                let previousLive = try await liveAntigravity.read()
                let renewal: Result<Data?, any Error>
                do {
                    try await liveAntigravity.write(prior)
                    _ = try await CommandRunner.run(
                        executable: executable,
                        arguments: ["models"],
                        unsetEnvironment: antigravityUnsetEnvironment,
                        directory: directory,
                        timeout: 60
                    )
                    renewal = .success(try? await liveAntigravity.read())
                } catch {
                    renewal = .failure(error)
                }
                // Restore inside an uncancelled Task so cancellation never leaves
                // this account's sign-in live in place of the prior one.
                await Task { await Self.restore(previousLive, to: liveAntigravity) }.value
                return renewal
            }

            let refreshed = try renewal.get()
            try Task.checkCancellation()
            // `agy models` fails without refreshing when Google can't be reached or
            // no longer accepts the sign-in; only an unexpired token counts.
            guard let refreshed, (try? AntigravityCredentialStore.accessToken(from: refreshed)) != nil else {
                throw AISwitchError.commandFailed(
                    "agy couldn't refresh this sign-in's token. Check your connection, or use Sign in again if it keeps failing."
                )
            }
            // Another `agy` session may have saved its own account's sign-in meanwhile.
            guard AntigravityCredentialStore.isSameAccount(refreshed, as: prior) else {
                throw AISwitchError.commandFailed(
                    "Another agy sign-in was saved while renewing, so this account was left as it was. Quit agy and try again."
                )
            }
            try FileManager.default.writeOwnerOnly(
                AntigravityCredentialStore.merge(newer: refreshed, into: prior), to: credentialURL
            )
        }
        try Task.checkCancellation()
    }

    /// Reads `agy acp --login` to its end. Once it prints the Google sign-in link,
    /// the code the browser then shows is asked for through `codePrompt` and typed
    /// into `agy`, and asked for again if `agy` rejects it.
    private static func answerAntigravityLogin(
        _ session: CommandSession,
        codePrompt: SignInCodePrompt?
    ) async throws -> (exitCode: Int32, output: [String]) {
        var output: [String] = []
        var signInPage: URL?
        var answering: Task<Void, Never>?
        for await line in session.lines {
            output.append(line)
            if signInPage == nil { signInPage = antigravitySignInPage(in: line) }
            guard let signInPage else { continue }
            let rejected = line.localizedCaseInsensitiveContains("invalid callback url")
                || line.localizedCaseInsensitiveContains("state mismatch")
            guard answering == nil || rejected else { continue }
            guard let codePrompt else {
                throw AISwitchError.commandFailed(
                    "Antigravity asks for the code your browser shows. Sign in from AI Switch's window to paste it."
                )
            }
            answering?.cancel()
            answering = Task {
                guard let code = try? await codePrompt.code(signInPage: signInPage) else { return }
                try? session.send(code)
            }
        }
        answering?.cancel()
        return (await session.exitStatus(), output)
    }

    /// The Google sign-in page a line of `agy` output links to.
    static func antigravitySignInPage(in line: String) -> URL? {
        guard let start = line.range(of: "https://accounts.google.com/") else { return nil }
        return URL(string: String(line[start.lowerBound...].prefix { !$0.isWhitespace }))
    }

    /// Puts `previous` back as `agy`'s live sign-in, or signs `agy` out when there was none.
    private static func restore(_ previous: Data?, to live: LiveAntigravityCredential) async {
        if let previous {
            try? await live.write(previous)
        } else {
            await live.delete()
        }
    }
}
