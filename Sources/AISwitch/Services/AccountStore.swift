import Combine
import Foundation

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var profiles: [AccountProfile] = []
    @Published private(set) var activeProfileIDs: [String: UUID] = [:]
    @Published private(set) var refreshingProfileIDs: Set<UUID> = []
    @Published private var refreshingAll = false
    @Published var switchingProfileID: UUID?
    @Published var errorMessage: String?

    private let manager = FileManager.default
    private let stateURL: URL
    private let profilesRoot: URL
    private let backupsRoot: URL
    private var refreshTask: Task<Void, Never>?
    private let inspectProfile: @Sendable (AccountProfile, KeychainInteraction, String?) async throws -> ProviderInspection

    var isRefreshing: Bool { refreshingAll || !refreshingProfileIDs.isEmpty }

    init(
        supportDirectory: URL? = nil,
        startsAutomatically: Bool = true,
        inspect: @escaping @Sendable (AccountProfile, KeychainInteraction, String?) async throws -> ProviderInspection = {
            try await UsageService.inspect($0, interaction: $1, claudeService: $2)
        }
    ) {
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Switch", isDirectory: true)
        inspectProfile = inspect
        stateURL = support.appendingPathComponent("profiles.json")
        profilesRoot = support.appendingPathComponent("Profiles", isDirectory: true)
        backupsRoot = support.appendingPathComponent("Backups", isDirectory: true)
        load()
        guard startsAutomatically else { return }
        scheduleRefresh()
        Task { [weak self] in
            await self?.discoverExistingAccounts()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func isActive(_ profile: AccountProfile) -> Bool {
        activeProfileIDs[profile.provider.rawValue] == profile.id
    }

    func activeProfile(for provider: AIProvider) -> AccountProfile? {
        guard let id = activeProfileIDs[provider.rawValue] else { return nil }
        return profiles.first { $0.id == id }
    }

    func cliAvailable(for provider: AIProvider) -> Bool {
        CommandRunner.locate(provider == .codex ? "codex" : "claude") != nil
    }

    func addAccount(provider: AIProvider) async throws {
        let id = UUID()
        let directory = profileURL(for: id, provider: provider)
        try secureCreateDirectory(directory)

        do {
            switch provider {
            case .codex:
                guard let executable = CommandRunner.locate("codex") else {
                    throw AISwitchError.cliNotFound(.codex)
                }
                let config = directory.appendingPathComponent("config.toml")
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
                let result = try await CommandRunner.run(
                    executable: executable,
                    arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""],
                    environment: ["CODEX_HOME": directory.path],
                    timeout: 600
                )
                guard result.exitCode == 0 else {
                    throw AISwitchError.commandFailed(result.output.isEmpty ? "Codex login was cancelled." : result.output)
                }
                guard manager.fileExists(atPath: directory.appendingPathComponent("auth.json").path) else {
                    throw AISwitchError.loginDidNotCreateCredentials(.codex)
                }
            case .claude:
                guard let executable = CommandRunner.locate("claude") else {
                    throw AISwitchError.cliNotFound(.claude)
                }
                let result = try await CommandRunner.run(
                    executable: executable,
                    arguments: ["auth", "login", "--claudeai"],
                    environment: ["CLAUDE_CONFIG_DIR": directory.path],
                    timeout: 600
                )
                guard result.exitCode == 0 else {
                    throw AISwitchError.commandFailed(result.output.isEmpty ? "Claude Code login was cancelled." : result.output)
                }
                let service = CredentialManager.claudeService(profileDirectory: directory.path)
                _ = try CredentialManager.read(service: service, interaction: .allowed)
            }

            var profile = AccountProfile(
                id: id,
                provider: provider,
                displayName: "\(provider.displayName) account",
                email: nil,
                plan: nil,
                profileDirectory: directory.path,
                createdAt: Date(),
                lastActivatedAt: nil,
                usage: nil,
                authIssue: nil
            )
            if let inspection = try? await inspectProfile(profile, .allowed, nil) {
                apply(inspection, to: &profile)
            }
            profiles.append(profile)
            save()
            try await activate(profile.id)
        } catch {
            profiles.removeAll { $0.id == id }
            activeProfileIDs = activeProfileIDs.filter { $0.value != id }
            try? manager.removeItem(at: directory)
            if provider == .claude {
                try? CredentialManager.delete(service: CredentialManager.claudeService(profileDirectory: directory.path))
            }
            throw error
        }
    }

    func importCurrent(
        provider: AIProvider, activateImported: Bool = true, interaction: KeychainInteraction = .allowed
    ) async throws {
        let id = UUID()
        let directory = profileURL(for: id, provider: provider)
        try secureCreateDirectory(directory)

        do {
            switch provider {
            case .codex:
                let live = manager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex/auth.json")
                let authData: Data
                if manager.fileExists(atPath: live.path) {
                    authData = try Data(contentsOf: live)
                } else {
                    authData = try CredentialManager.read(service: "Codex Auth", interaction: interaction).data
                }
                let config = directory.appendingPathComponent("config.toml")
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
                try writeSecret(authData, to: directory.appendingPathComponent("auth.json"))
            case .claude:
                try CredentialManager.copyClaudeCredential(
                    from: CredentialManager.claudeDefaultService,
                    to: CredentialManager.claudeService(profileDirectory: directory.path),
                    interaction: interaction
                )
            }

            var profile = AccountProfile(
                id: id,
                provider: provider,
                displayName: "\(provider.displayName) account",
                email: nil,
                plan: nil,
                profileDirectory: directory.path,
                createdAt: Date(),
                lastActivatedAt: nil,
                usage: nil,
                authIssue: nil
            )
            if provider == .claude {
                let config = manager.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
                apply(UsageService.claudeMetadata(configData: try? Data(contentsOf: config)), to: &profile)
            }
            if let inspection = try? await inspectProfile(profile, interaction, nil) {
                apply(inspection, to: &profile)
            }
            profiles.append(profile)
            save()
            if activateImported {
                try await activate(id)
            } else {
                activeProfileIDs[provider.rawValue] = id
                profiles[profiles.count - 1].lastActivatedAt = Date()
                save()
                await refresh(id)
            }
        } catch {
            profiles.removeAll { $0.id == id }
            activeProfileIDs = activeProfileIDs.filter { $0.value != id }
            if provider == .claude {
                try? CredentialManager.delete(
                    service: CredentialManager.claudeService(profileDirectory: directory.path)
                )
            }
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// Discovers credentials that were already active in the user's CLIs before
    /// AI Switch was launched. This keeps first launch useful without requiring
    /// the user to manually import the currently signed-in account.
    private func discoverExistingAccounts() async {
        for provider in AIProvider.allCases {
            guard !profiles.contains(where: { $0.provider == provider }) else { continue }
            do {
                try await importCurrent(provider: provider, activateImported: false, interaction: .forbidden)
            } catch {
                // A missing CLI or credentials is a normal first-launch state;
                // leave the provider empty and let the UI offer Add account.
            }
        }
    }

    func activate(_ id: UUID) async throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = profiles[index]
        switchingProfileID = id
        defer { switchingProfileID = nil }

        switch profile.provider {
        case .codex:
            if let oldID = activeProfileIDs[AIProvider.codex.rawValue],
               oldID != profile.id,
               let old = profiles.first(where: { $0.id == oldID }) {
                try? syncLiveCodexCredential(to: old)
            }
            let source = URL(fileURLWithPath: profile.profileDirectory).appendingPathComponent("auth.json")
            guard manager.fileExists(atPath: source.path) else {
                throw AISwitchError.credentialsMissing(.codex)
            }
            try CodexConfigEditor.ensureFileCredentialStore()
            try backupCurrentCodexCredential()
            let destination = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
            try writeSecret(Data(contentsOf: source), to: destination)
        case .claude:
            if let oldID = activeProfileIDs[AIProvider.claude.rawValue],
               let old = profiles.first(where: { $0.id == oldID }) {
                try? CredentialManager.copyClaudeCredential(
                    from: CredentialManager.claudeDefaultService,
                    to: CredentialManager.claudeService(profileDirectory: old.profileDirectory),
                    interaction: .allowed
                )
            }
            try CredentialManager.copyClaudeCredential(
                from: CredentialManager.claudeService(profileDirectory: profile.profileDirectory),
                to: CredentialManager.claudeDefaultService,
                interaction: .allowed
            )
        }

        activeProfileIDs[profile.provider.rawValue] = id
        profiles[index].lastActivatedAt = Date()
        profiles[index].needsKeychainAccess = nil
        save()
        await refresh(id, userInitiated: true)
    }

    func refreshAll(userInitiated: Bool = false) async {
        guard !refreshingAll else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        for profile in profiles {
            guard !Task.isCancelled else { break }
            await refresh(profile.id, userInitiated: userInitiated)
        }
    }

    func grantKeychainAccess(_ id: UUID) async {
        await refresh(id, userInitiated: true, interaction: .allowed)
    }

    func refresh(
        _ id: UUID, userInitiated: Bool = false, interaction: KeychainInteraction = .forbidden
    ) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        guard !Task.isCancelled, !refreshingProfileIDs.contains(id) else { return }
        guard profile.needsKeychainAccess != true || userInitiated else { return }
        refreshingProfileIDs.insert(id)
        defer { refreshingProfileIDs.remove(id) }
        do {
            if isActive(profile) {
                switch profile.provider {
                case .codex:
                    try? syncLiveCodexCredential(to: profile)
                case .claude:
                    // Usage reads the live credential directly. Copying it into
                    // the saved profile here caused extra permission requests.
                    break
                }
            }
            let claudeService = profile.provider == .claude && isActive(profile)
                ? CredentialManager.claudeDefaultService : nil
            let inspection = try await inspectProfile(profile, interaction, claudeService)
            try Task.checkCancellation()
            if profile.provider == .codex, isActive(profile) {
                let refreshed = URL(fileURLWithPath: profile.profileDirectory)
                    .appendingPathComponent("auth.json")
                let live = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
                if manager.fileExists(atPath: refreshed.path) {
                    try? writeSecret(Data(contentsOf: refreshed), to: live)
                }
            }
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            apply(inspection, to: &profiles[index])
            profiles[index].authIssue = nil
            profiles[index].needsKeychainAccess = nil
            save()
        } catch is CancellationError {
            return
        } catch {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].authIssue = error.localizedDescription
            if case AISwitchError.keychainAccessRequired = error {
                profiles[index].needsKeychainAccess = true
            } else {
                profiles[index].needsKeychainAccess = nil
            }
            save()
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[index].displayName = trimmed
        save()
    }

    func remove(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !isActive(profile) else { return }
        if profile.provider == .claude {
            try? CredentialManager.delete(
                service: CredentialManager.claudeService(profileDirectory: profile.profileDirectory)
            )
        }
        try? manager.removeItem(at: URL(fileURLWithPath: profile.profileDirectory))
        profiles.removeAll { $0.id == id }
        save()
    }

    func dismissError() {
        errorMessage = nil
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func load() {
        do {
            let support = stateURL.deletingLastPathComponent()
            try secureCreateDirectory(support)
            try secureCreateDirectory(profilesRoot)
            try secureCreateDirectory(backupsRoot)
            guard manager.fileExists(atPath: stateURL.path) else { return }
            let state = try JSONDecoder.storedState.decode(StoredState.self, from: Data(contentsOf: stateURL))
            profiles = state.profiles
            activeProfileIDs = state.activeProfileIDs
        } catch {
            errorMessage = "Could not load saved profiles: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.pretty.encode(
                StoredState(profiles: profiles, activeProfileIDs: activeProfileIDs)
            )
            try data.write(to: stateURL, options: .atomic)
        } catch {
            errorMessage = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    private func scheduleRefresh() {
        refreshTask = Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await self?.refreshAll()
            }
        }
    }

    private func profileURL(for id: UUID, provider: AIProvider) -> URL {
        profilesRoot
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    private func secureCreateDirectory(_ url: URL) throws {
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func writeSecret(_ data: Data, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backupCurrentCodexCredential() throws {
        let source = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard manager.fileExists(atPath: source.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = backupsRoot.appendingPathComponent("codex-auth-\(formatter.string(from: Date())).json")
        try writeSecret(Data(contentsOf: source), to: destination)
    }

    private func syncLiveCodexCredential(to profile: AccountProfile) throws {
        let live = manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard manager.fileExists(atPath: live.path) else { return }
        let destination = URL(fileURLWithPath: profile.profileDirectory).appendingPathComponent("auth.json")
        try writeSecret(Data(contentsOf: live), to: destination)
    }

    private func apply(_ inspection: ProviderInspection, to profile: inout AccountProfile) {
        profile.email = inspection.email ?? profile.email
        profile.plan = inspection.plan ?? profile.plan
        profile.usage = inspection.usage ?? profile.usage
        if profile.displayName.hasSuffix(" account"), let email = inspection.email {
            profile.displayName = email.components(separatedBy: "@").first ?? profile.displayName
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var storedState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
