import Combine
import Foundation

/// The credential Claude Code reads for new sessions. Injected so tests never
/// touch the login Keychain.
struct LiveClaudeCredential: Sendable {
    var read: @Sendable () async throws -> Data?
    var write: @Sendable (Data) async throws -> Void

    static let system = LiveClaudeCredential(
        read: { try await ClaudeCredentialStore.readLive() },
        write: { try await ClaudeCredentialStore.writeLive($0) }
    )
}

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
    private let loginProfile: @Sendable (AIProvider, URL) async throws -> Void
    private let inspectProfile: @Sendable (AccountProfile) async throws -> ProviderInspection
    private let liveClaude: LiveClaudeCredential
    /// Optional self-hosted sync server that lets a phone read usage. Every
    /// persisted change is pushed, coalesced by the sync's debounce.
    let sync: RemoteSync

    var isRefreshing: Bool { refreshingAll || !refreshingProfileIDs.isEmpty }

    init(
        supportDirectory: URL? = nil,
        startsAutomatically: Bool = true,
        login: @escaping @Sendable (AIProvider, URL) async throws -> Void = {
            try await AccountLoginService.authenticate(provider: $0, directory: $1)
        },
        inspect: @escaping @Sendable (AccountProfile) async throws -> ProviderInspection = {
            try await UsageService.inspect($0)
        },
        liveClaude: LiveClaudeCredential = .system,
        sync: RemoteSync? = nil
    ) {
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Switch", isDirectory: true)
        inspectProfile = inspect
        loginProfile = login
        self.liveClaude = liveClaude
        self.sync = sync ?? RemoteSync(directory: support)
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
        try Task.checkCancellation()
        let id = UUID()
        let directory = profileURL(for: id, provider: provider)
        try secureCreateDirectory(directory)

        do {
            try await loginProfile(provider, directory)
            try Task.checkCancellation()

            var profile = newProfile(id: id, provider: provider, directory: directory)
            if let inspection = try? await inspectProfile(profile) {
                apply(inspection, to: &profile)
            }
            // A late OAuth callback or a metadata request that ignores task
            // cancellation must never resurrect a dismissed login.
            try Task.checkCancellation()
            try await switchCredentials(to: profile)
            try Task.checkCancellation()

            // Nothing is published until the switch succeeded, so a failure
            // leaves no half-activated account behind.
            profiles.append(profile)
            markActive(id)
            Task { [weak self] in await self?.refresh(id) }
        } catch {
            discard(directory: directory)
            throw error
        }
    }

    func importCurrent(provider: AIProvider, activateImported: Bool = true) async throws {
        let id = UUID()
        let directory = profileURL(for: id, provider: provider)
        try secureCreateDirectory(directory)

        do {
            switch provider {
            case .codex:
                let authData: Data
                if manager.fileExists(atPath: liveCodexCredential.path) {
                    authData = try Data(contentsOf: liveCodexCredential)
                } else if let keyring = try await SecurityTool.read(service: "Codex Auth", account: nil) {
                    authData = keyring
                } else {
                    throw AISwitchError.notSignedIn(.codex)
                }
                let config = directory.appendingPathComponent("config.toml")
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
                try manager.writeOwnerOnly(authData, to: directory.appendingPathComponent("auth.json"))
            case .claude:
                guard let data = try await liveClaude.read() else {
                    throw AISwitchError.notSignedIn(.claude)
                }
                try manager.writeOwnerOnly(data, to: ClaudeCredentialStore.credentialURL(configDirectory: directory))
            }

            var profile = newProfile(id: id, provider: provider, directory: directory)
            if provider == .claude {
                let config = ClaudeCredentialStore.liveConfigDirectory.appendingPathComponent(".claude.json")
                apply(UsageService.claudeMetadata(configData: try? Data(contentsOf: config)), to: &profile)
            }
            if let inspection = try? await inspectProfile(profile) {
                apply(inspection, to: &profile)
            }
            if activateImported {
                try await switchCredentials(to: profile)
            }
            profiles.append(profile)
            markActive(id)
            await refresh(id)
        } catch {
            discard(directory: directory)
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
                try await importCurrent(provider: provider, activateImported: false)
            } catch {
                // A missing CLI or credentials is a normal first-launch state;
                // leave the provider empty and let the UI offer Add account.
            }
        }
    }

    func activate(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try await switchCredentials(to: profile)
        markActive(id)
        await refresh(id)
    }

    /// Makes `profile` the account new CLI sessions use. The credential that was
    /// live until now is saved back into its own profile first, so a token the
    /// CLI refreshed meanwhile is not lost.
    private func switchCredentials(to profile: AccountProfile) async throws {
        switchingProfileID = profile.id
        defer { switchingProfileID = nil }
        let previous = activeProfile(for: profile.provider)

        switch profile.provider {
        case .codex:
            let source = URL(fileURLWithPath: profile.profileDirectory).appendingPathComponent("auth.json")
            guard manager.fileExists(atPath: source.path) else {
                throw AISwitchError.credentialsMissing(.codex)
            }
            if let previous { try? syncLiveCodexCredential(to: previous) }
            try CodexConfigEditor.ensureFileCredentialStore()
            try backupCurrentCodexCredential()
            try manager.writeOwnerOnly(Data(contentsOf: source), to: liveCodexCredential)
        case .claude:
            let data = try ClaudeCredentialStore.readProfile(directory: profile.profileDirectory)
            if let previous { try? await syncLiveClaudeCredential(to: previous) }
            try await liveClaude.write(data)
        }
    }

    private func markActive(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        activeProfileIDs[profiles[index].provider.rawValue] = id
        profiles[index].lastActivatedAt = Date()
        save()
    }

    /// Checks every account at once. Each provider check is a separate child
    /// process or request, so one slow account no longer delays the others.
    func refreshAll() async {
        guard !refreshingAll else { return }
        refreshingAll = true
        defer { refreshingAll = false }
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.refresh(profile.id) }
            }
        }
    }

    func refresh(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        guard !Task.isCancelled, !refreshingProfileIDs.contains(id) else { return }
        refreshingProfileIDs.insert(id)
        defer { refreshingProfileIDs.remove(id) }
        do {
            if isActive(profile) {
                // The CLI may have refreshed its token since the last check.
                switch profile.provider {
                case .codex: try? syncLiveCodexCredential(to: profile)
                case .claude: try? await syncLiveClaudeCredential(to: profile)
                }
            }
            let inspection = try await inspectProfile(profile)
            try Task.checkCancellation()
            if profile.provider == .codex, isActive(profile) {
                // The app-server check can refresh the profile's token in place.
                let refreshed = URL(fileURLWithPath: profile.profileDirectory).appendingPathComponent("auth.json")
                if manager.fileExists(atPath: refreshed.path) {
                    try? manager.writeOwnerOnly(Data(contentsOf: refreshed), to: liveCodexCredential)
                }
            }
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            apply(inspection, to: &profiles[index])
            profiles[index].authIssue = nil
            save()
        } catch is CancellationError {
            return
        } catch {
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].authIssue = error.localizedDescription
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

    /// Forgets the account and deletes its saved credentials. The CLI's live
    /// sign-in is left as it is, so removing the active account only clears the
    /// active marker here.
    func remove(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try? manager.removeItem(at: URL(fileURLWithPath: profile.profileDirectory).deletingLastPathComponent())
        profiles.removeAll { $0.id == id }
        if isActive(profile) { activeProfileIDs.removeValue(forKey: profile.provider.rawValue) }
        save()
        if profile.provider == .claude {
            // Versions before 0.3 kept the profile itself in the Keychain, and an
            // interrupted CLI login can leave its item behind too.
            await ClaudeCredentialStore.deleteKeychain(
                service: ClaudeCredentialStore.service(configDirectory: profile.profileDirectory)
            )
        }
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
        sync.schedulePush(profiles: profiles, activeProfileIDs: activeProfileIDs)
    }

    /// Sends the current accounts to the sync server without waiting for the debounce.
    func pushToSync() async {
        sync.schedulePush(profiles: profiles, activeProfileIDs: activeProfileIDs)
        await sync.flush()
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

    private func newProfile(id: UUID, provider: AIProvider, directory: URL) -> AccountProfile {
        AccountProfile(
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
    }

    /// Reverts a sign-in or import that did not complete. Nothing is published
    /// or saved before the credential switch succeeds, so only the directory,
    /// which holds every credential this app wrote for the account, remains.
    private func discard(directory: URL) {
        try? manager.removeItem(at: directory.deletingLastPathComponent())
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

    private var liveCodexCredential: URL {
        manager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    private func backupCurrentCodexCredential() throws {
        guard manager.fileExists(atPath: liveCodexCredential.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = backupsRoot.appendingPathComponent("codex-auth-\(formatter.string(from: Date())).json")
        try manager.writeOwnerOnly(Data(contentsOf: liveCodexCredential), to: destination)
    }

    private func syncLiveCodexCredential(to profile: AccountProfile) throws {
        guard manager.fileExists(atPath: liveCodexCredential.path) else { return }
        let destination = URL(fileURLWithPath: profile.profileDirectory).appendingPathComponent("auth.json")
        try manager.writeOwnerOnly(Data(contentsOf: liveCodexCredential), to: destination)
    }

    private func syncLiveClaudeCredential(to profile: AccountProfile) async throws {
        guard let data = try await liveClaude.read() else { return }
        let destination = ClaudeCredentialStore.credentialURL(configDirectory: URL(fileURLWithPath: profile.profileDirectory))
        try manager.writeOwnerOnly(data, to: destination)
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
