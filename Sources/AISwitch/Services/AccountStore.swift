import Combine
import Foundation

/// Claude Code's credentials outside the profile files: the live one new
/// sessions read, and the Keychain items earlier versions kept per profile.
/// Injected so tests never touch the login Keychain.
struct LiveClaudeCredential: Sendable {
    var read: @Sendable () async throws -> Data?
    var write: @Sendable (Data) async throws -> Void
    /// Deletes the Keychain item Claude Code keys by a profile's directory.
    var deleteProfileItem: @Sendable (String) async -> Void

    static let system = LiveClaudeCredential(
        read: { try await ClaudeCredentialStore.readLive() },
        write: { try await ClaudeCredentialStore.writeLive($0) },
        deleteProfileItem: {
            await ClaudeCredentialStore.deleteKeychain(service: ClaudeCredentialStore.service(configDirectory: $0))
        }
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
    private var codexFeedTask: Task<Void, Never>?
    private let loginProfile: @Sendable (AIProvider, URL) async throws -> Void
    private let inspectProfile: @Sendable (AccountProfile) async throws -> ProviderInspection
    private let renewProfile: @Sendable (AIProvider, URL) async throws -> Void
    private let identify: @Sendable (AIProvider, Data) async -> AccountIdentity?
    private let resetLimits: @Sendable (AIProvider, URL) async throws -> LimitResetOutcome
    private let liveClaude: LiveClaudeCredential
    private let codexFeed: CodexSessionFeed?
    /// Accounts whose provider is limiting usage checks, and when to try again.
    private var usageBackoff: [UUID: (retryAt: Date, delay: TimeInterval)] = [:]
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
        renew: @escaping @Sendable (AIProvider, URL) async throws -> Void = {
            try await AccountLoginService.renew(provider: $0, directory: $1)
        },
        identify: @escaping @Sendable (AIProvider, Data) async -> AccountIdentity? = {
            await CredentialIdentity.identify($0, credential: $1)
        },
        resetLimits: @escaping @Sendable (AIProvider, URL) async throws -> LimitResetOutcome = {
            try await UsageService.useLimitReset(provider: $0, directory: $1)
        },
        liveClaude: LiveClaudeCredential = .system,
        codexSessions: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        sync: RemoteSync? = nil
    ) {
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Switch", isDirectory: true)
        inspectProfile = inspect
        loginProfile = login
        renewProfile = renew
        self.identify = identify
        self.resetLimits = resetLimits
        self.liveClaude = liveClaude
        codexFeed = codexSessions.map { CodexSessionFeed(root: $0) }
        self.sync = sync ?? RemoteSync(directory: support)
        stateURL = support.appendingPathComponent("profiles.json")
        profilesRoot = support.appendingPathComponent("Profiles", isDirectory: true)
        backupsRoot = support.appendingPathComponent("Backups", isDirectory: true)
        load()
        guard startsAutomatically else { return }
        scheduleRefresh()
        scheduleCodexFeed()
        Task { [weak self] in
            await self?.discoverExistingAccounts()
        }
    }

    deinit {
        refreshTask?.cancel()
        codexFeedTask?.cancel()
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
            let credential: Data
            switch provider {
            case .codex:
                if manager.fileExists(atPath: liveCodexCredential.path) {
                    credential = try Data(contentsOf: liveCodexCredential)
                } else if let keyring = try await SecurityTool.read(service: "Codex Auth", account: nil) {
                    credential = keyring
                } else {
                    throw AISwitchError.notSignedIn(.codex)
                }
                let config = directory.appendingPathComponent("config.toml")
                try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
                try manager.writeOwnerOnly(credential, to: directory.appendingPathComponent("auth.json"))
            case .claude:
                guard let data = try await liveClaude.read() else {
                    throw AISwitchError.notSignedIn(.claude)
                }
                credential = data
                try manager.writeOwnerOnly(data, to: ClaudeCredentialStore.credentialURL(configDirectory: directory))
            }

            var profile = newProfile(id: id, provider: provider, directory: directory)
            // `~/.claude.json` can still name the previous account after a
            // switch, so the credential's own account is looked up instead.
            if let identity = await identify(provider, credential) {
                profile.identity = identity
                apply(ProviderInspection(email: identity.email), to: &profile)
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
    /// live until now is saved back into the outgoing profile first, so a token
    /// the CLI refreshed meanwhile is not lost.
    private func switchCredentials(to profile: AccountProfile) async throws {
        switchingProfileID = profile.id
        defer { switchingProfileID = nil }
        guard manager.fileExists(atPath: credentialURL(of: profile).path) else {
            throw AISwitchError.credentialsMissing(profile.provider)
        }
        if let previous = activeProfile(for: profile.provider) {
            await keepLiveCredential(for: previous)
        }
        if profile.provider == .codex {
            try CodexConfigEditor.ensureFileCredentialStore()
            try backupCurrentCodexCredential()
        }
        // Read after the outgoing credential was kept, in case it is this profile's.
        try await writeLiveCredential(savedCredential(of: profile), for: profile.provider)
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
        await check(id, renewing: false)
    }

    /// Asks the CLI to renew the account's credential, then re-reads usage.
    /// Nothing renews automatically: the CLI session this starts may spend a
    /// small amount of the account's quota.
    func renew(_ id: UUID) async {
        await check(id, renewing: true)
    }

    /// Spends one of the account's usage limit resets, then re-reads its usage.
    /// Only on request: resets are scarce, and some expire.
    func useReset(_ id: UUID) async throws -> LimitResetOutcome {
        guard let profile = profiles.first(where: { $0.id == id }) else { throw CancellationError() }
        guard !refreshingProfileIDs.contains(id) else {
            throw AISwitchError.commandFailed("This account is being checked. Try again in a moment.")
        }
        refreshingProfileIDs.insert(id)
        let outcome: LimitResetOutcome
        do {
            defer { refreshingProfileIDs.remove(id) }
            // The reset runs on the profile's own sign-in, which the CLI may have
            // renewed meanwhile; any token renewed during it goes back live.
            let live = isActive(profile) ? await adoptLiveCredential(into: profile, renewing: true) : nil
            outcome = try await resetLimits(profile.provider, URL(fileURLWithPath: profile.profileDirectory))
            if let live { _ = try? await publishCredential(of: profile, replacing: live) }
        }
        await refresh(id)
        return outcome
    }

    private func check(_ id: UUID, renewing: Bool) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        guard !Task.isCancelled, !refreshingProfileIDs.contains(id) else { return }
        refreshingProfileIDs.insert(id)
        defer { refreshingProfileIDs.remove(id) }
        do {
            // The live credential the profile was brought up to date with. Only
            // while it is still live may the profile's credential replace it.
            var live: Data?
            if isActive(profile) {
                live = await adoptLiveCredential(into: profile, renewing: renewing)
            }
            if renewing {
                try await renewProfile(profile.provider, URL(fileURLWithPath: profile.profileDirectory))
                try Task.checkCancellation()
                // Refresh tokens rotate, so the renewed credential must replace
                // the live one before the CLI's next session.
                if let current = live { live = try await publishCredential(of: profile, replacing: current) }
            }
            // A provider that is limiting usage checks gets fewer of them; a
            // renewal still checks, since it starts from a new token.
            if !renewing, let backoff = usageBackoff[id], backoff.retryAt > Date() { return }
            let inspection = try await inspectProfile(profile)
            try Task.checkCancellation()
            if profile.provider == .codex, let current = live {
                // The app-server check can refresh the profile's token in place.
                _ = try? await publishCredential(of: profile, replacing: current)
            }
            // A profile saved before identities were recorded learns its own
            // once its credential is known to work.
            let knowsIdentity = profiles.first(where: { $0.id == id })?.identity != nil
            let learned = knowsIdentity ? nil : await knownIdentity(of: profile)
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            apply(inspection, to: &profiles[index])
            if let learned, profiles[index].identity == nil {
                profiles[index].identity = learned
                if profiles[index].email == nil { apply(ProviderInspection(email: learned.email), to: &profiles[index]) }
            }
            profiles[index].authIssue = nil
            usageBackoff[id] = nil
            save()
        } catch is CancellationError {
            return
        } catch AISwitchError.usageRateLimited(let provider) {
            // Checking again on schedule would keep the limit exhausted, so each
            // refusal doubles the wait, up to an hour.
            let delay = min((usageBackoff[id]?.delay ?? 450) * 2, 3600)
            usageBackoff[id] = (Date().addingTimeInterval(delay), delay)
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].authIssue = AISwitchError.usageRateLimited(provider).localizedDescription
            save()
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
            await liveClaude.deleteProfileItem(profile.profileDirectory)
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

    /// Usage Codex records after each turn on this Mac shows up within seconds.
    /// Provider checks stay at five minutes: their usage endpoints are rate-limited.
    private func scheduleCodexFeed() {
        codexFeedTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollCodexSessions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Applies the rate limits Codex recorded since the last poll to the saved
    /// profile of the account each one belongs to.
    func pollCodexSessions(now: Date = Date()) async {
        guard let codexFeed else { return }
        let snapshots = await codexFeed.poll(now: now)
        var changed = false
        for snapshot in snapshots {
            for index in profiles.indices where profiles[index].provider == .codex {
                let profile = profiles[index]
                let identity = profile.identity
                    ?? (try? savedCredential(of: profile)).flatMap { CredentialIdentity.codex(authData: $0) }
                guard let identity, identity.isSameAccount(as: snapshot.identity),
                      snapshot.usage.fetchedAt > profile.usage?.fetchedAt ?? .distantPast else { continue }
                // Session logs carry no reset credits; keep the last known count.
                var usage = snapshot.usage
                usage.resets = profile.usage?.resets
                profiles[index].usage = usage
                profiles[index].plan = snapshot.plan ?? profile.plan
                changed = true
            }
        }
        if changed { save() }
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

    /// What the live credential is to a profile.
    private enum LiveCredential {
        /// The CLI is signed out.
        case none
        /// Identical to the profile's saved credential.
        case saved(Data)
        /// The profile's own account with a newer token. `identity` is set when
        /// it was looked up, so a profile that didn't know its own can record it.
        case newer(Data, identity: AccountIdentity?)
        /// Another account's.
        case foreign(Data, identity: AccountIdentity)
        /// Changed, but whose it is can't be checked right now: a Claude token
        /// that already expired, or no network.
        case unverified(Data)
    }

    /// Compares the live credential with the one saved in `profile`.
    private func liveCredential(for profile: AccountProfile) async -> LiveCredential {
        guard let live = try? await readLiveCredential(profile.provider) else { return .none }
        let saved = try? savedCredential(of: profile)
        if live == saved { return .saved(live) }
        if profile.provider == .claude, let saved, let token = ClaudeCredentialStore.refreshToken(from: live),
           token == ClaudeCredentialStore.refreshToken(from: saved) {
            // The same sign-in: only the access token or MCP sign-ins changed.
            return .newer(live, identity: nil)
        }
        guard let identity = await identify(profile.provider, live) else { return .unverified(live) }
        guard let own = await knownIdentity(of: profile) else {
            // Saved before identities were recorded: it held whatever was live.
            return .newer(live, identity: identity)
        }
        return own.isSameAccount(as: identity) ? .newer(live, identity: identity) : .foreign(live, identity: identity)
    }

    /// Who the profile's saved credential signs in as: recorded, or else the
    /// account Claude Code noted when it signed in there, or else asked.
    private func knownIdentity(of profile: AccountProfile) async -> AccountIdentity? {
        if let identity = profiles.first(where: { $0.id == profile.id })?.identity ?? profile.identity {
            return identity
        }
        if profile.provider == .claude,
           let identity = CredentialIdentity.claudeConfig(directory: URL(fileURLWithPath: profile.profileDirectory)) {
            return identity
        }
        guard let saved = try? savedCredential(of: profile) else { return nil }
        return await identify(profile.provider, saved)
    }

    /// Brings the active profile up to date with the live credential, which the
    /// CLI may have refreshed since the last check, and returns that credential.
    /// Returns nil and leaves the profile as it was when the CLI is signed out,
    /// signed in to another account (the profile then stops being active), or
    /// when whose credential it is can't be checked right now. A renewal adopts
    /// the latter anyway, since it has to start from the newest token.
    private func adoptLiveCredential(into profile: AccountProfile, renewing: Bool) async -> Data? {
        switch await liveCredential(for: profile) {
        case .none:
            return nil
        case .saved(let data):
            return data
        case .newer(let data, let identity):
            do { try writeCredential(data, into: profile, identity: identity) } catch { return nil }
            return data
        case .unverified(let data):
            guard renewing else { return nil }
            do { try writeCredential(data, into: profile, identity: nil) } catch { return nil }
            return data
        case .foreign(let data, let identity):
            await release(profile, toAccount: identity, credential: data)
            return nil
        }
    }

    /// Before the live credential is replaced, saves it into the outgoing profile
    /// so a token the CLI refreshed is not lost. Another account's credential is
    /// never saved there; one whose owner can't be checked right now is, since
    /// losing a refreshed token is the likelier harm.
    private func keepLiveCredential(for profile: AccountProfile) async {
        switch await liveCredential(for: profile) {
        case .newer(let data, let identity): try? writeCredential(data, into: profile, identity: identity)
        case .unverified(let data): try? writeCredential(data, into: profile, identity: nil)
        case .none, .saved, .foreign: break
        }
    }

    /// The CLI signed in to another account outside AI Switch. `profile` keeps
    /// its own saved credential and stops being active; if that account is saved
    /// here too, its profile takes the live credential and becomes active.
    private func release(_ profile: AccountProfile, toAccount identity: AccountIdentity, credential: Data) async {
        var owner: AccountProfile?
        for candidate in profiles where candidate.provider == profile.provider && candidate.id != profile.id {
            if let known = await knownIdentity(of: candidate), known.isSameAccount(as: identity) {
                owner = candidate
                break
            }
        }
        // A switch may have happened while identities were looked up.
        guard isActive(profile) else { return }
        if let owner {
            try? writeCredential(credential, into: owner, identity: identity)
            markActive(owner.id)
        } else {
            activeProfileIDs.removeValue(forKey: profile.provider.rawValue)
            save()
            errorMessage = "\(profile.provider.displayName) is now signed in to \(identity.email ?? "another account"), "
                + "which isn't saved in AI Switch. Use Import to add it; \(profile.displayName) keeps its own saved sign-in."
        }
    }

    /// Makes the profile's credential live after the CLI renewed it in the
    /// profile folder, unless the live credential changed since `expected` was
    /// adopted: the CLI then holds something newer, which the next check adopts.
    /// Returns what is live afterwards, or nil when it was left alone.
    private func publishCredential(of profile: AccountProfile, replacing expected: Data) async throws -> Data? {
        let saved = try savedCredential(of: profile)
        guard saved != expected else { return expected }
        guard try await readLiveCredential(profile.provider) == expected else { return nil }
        try await writeLiveCredential(saved, for: profile.provider)
        return saved
    }

    /// Saves `credential` into the profile, recording whose it is when the profile
    /// didn't know yet; the next `save()` persists that.
    private func writeCredential(_ credential: Data, into profile: AccountProfile, identity: AccountIdentity?) throws {
        try manager.writeOwnerOnly(credential, to: credentialURL(of: profile))
        guard let identity, let index = profiles.firstIndex(where: { $0.id == profile.id }),
              profiles[index].identity == nil else { return }
        profiles[index].identity = identity
    }

    /// The credential new CLI sessions use, or nil when the CLI is signed out.
    private func readLiveCredential(_ provider: AIProvider) async throws -> Data? {
        switch provider {
        case .codex:
            guard manager.fileExists(atPath: liveCodexCredential.path) else { return nil }
            return try Data(contentsOf: liveCodexCredential)
        case .claude:
            return try await liveClaude.read()
        }
    }

    private func writeLiveCredential(_ credential: Data, for provider: AIProvider) async throws {
        switch provider {
        case .codex: try manager.writeOwnerOnly(credential, to: liveCodexCredential)
        case .claude: try await liveClaude.write(credential)
        }
    }

    private func credentialURL(of profile: AccountProfile) -> URL {
        let directory = URL(fileURLWithPath: profile.profileDirectory)
        switch profile.provider {
        case .codex: return directory.appendingPathComponent("auth.json")
        case .claude: return ClaudeCredentialStore.credentialURL(configDirectory: directory)
        }
    }

    private func savedCredential(of profile: AccountProfile) throws -> Data {
        let url = credentialURL(of: profile)
        guard manager.fileExists(atPath: url.path) else { throw AISwitchError.credentialsMissing(profile.provider) }
        return try Data(contentsOf: url)
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
