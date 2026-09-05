import SwiftUI

private enum AccountFilter: Hashable {
    case all, active, provider(AIProvider)

    var title: String {
        switch self {
        case .all: "All accounts"
        case .active: "Active accounts"
        case .provider(let provider): provider.displayName
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var filter: AccountFilter = .all
    @State private var search = ""
    @State private var showsAddAccount = false
    @FocusState private var searchFocused: Bool

    private var filteredProfiles: [AccountProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.profiles.filter { profile in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .active: matchesFilter = store.isActive(profile)
            case .provider(let provider): matchesFilter = profile.provider == provider
            }
            let matchesSearch = query.isEmpty || [profile.displayName, profile.email ?? "", profile.provider.displayName, profile.plan ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesFilter && matchesSearch
        }.sorted { lhs, rhs in
            if store.isActive(lhs) != store.isActive(rhs) { return store.isActive(lhs) }
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(AppPalette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(spacing: 12) {
                    ForEach(AIProvider.allCases) { provider in
                        Button { filter = .provider(provider) } label: {
                            ActiveSummary(provider: provider, profile: store.activeProfile(for: provider))
                        }
                        .buttonStyle(.plain)
                        .help("Show \(provider.displayName) accounts")
                    }
                }
                accountsSection
                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.canvas.ignoresSafeArea())
        }
        .foregroundStyle(AppPalette.ink)
        .overlay(alignment: .top) {
            if let message = store.errorMessage {
                ErrorBanner(message: message, dismiss: store.dismissError)
                    .padding(.top, 12)
                    .padding(.horizontal, 40)
            }
        }
        .sheet(isPresented: $showsAddAccount) {
            AddAccountSheet().environmentObject(store).preferredColorScheme(.light)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AppMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Switch").font(.system(size: 15, weight: .semibold))
                    Text("Stay in your flow.").font(.system(size: 9)).foregroundStyle(AppPalette.secondaryInk)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 34)

            SectionCaption(title: "Workspace").padding(.horizontal, 20).padding(.bottom, 9)
            sidebarButton(.all, title: "All accounts", symbol: "square.stack", count: store.profiles.count)
            sidebarButton(.active, title: "Active now", symbol: "bolt", count: store.profiles.filter { store.isActive($0) }.count)

            SectionCaption(title: "Providers").padding(.horizontal, 20).padding(.top, 27).padding(.bottom, 9)
            ForEach(AIProvider.allCases) { provider in
                sidebarButton(.provider(provider), title: provider.shortName, symbol: provider.symbol,
                              count: store.profiles.filter { $0.provider == provider }.count)
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 12) {
                SectionCaption(title: "Connections")
                ForEach(AIProvider.allCases) { provider in
                    HStack(spacing: 7) {
                        Circle().fill(store.cliAvailable(for: provider) ? AppPalette.success : AppPalette.tertiaryInk)
                            .frame(width: 5, height: 5)
                        Text(provider.shortName).font(.system(size: 10))
                        Spacer()
                        Text(store.cliAvailable(for: provider) ? "Installed" : "Not found")
                            .font(.system(size: 9))
                            .foregroundStyle(AppPalette.tertiaryInk)
                    }
                }
                Rectangle().fill(AppPalette.line).frame(height: 1).padding(.vertical, 3)
                Label("Stored on this Mac", systemImage: "lock.shield")
                    .font(.system(size: 9))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            .padding(20)
        }
        .frame(width: 174)
        .frame(maxHeight: .infinity)
        .background(AppPalette.sidebar.ignoresSafeArea())
    }

    private func sidebarButton(_ value: AccountFilter, title: String, symbol: String, count: Int) -> some View {
        Button { filter = value } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 15)
                Text(title).font(.system(size: 11, weight: filter == value ? .semibold : .regular))
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(filter == value ? AppPalette.ink : AppPalette.tertiaryInk)
            }
            .foregroundStyle(filter == value ? AppPalette.ink : AppPalette.secondaryInk)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(filter == value ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(filter == value ? AppPalette.line.opacity(0.7) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Accounts").font(.system(size: 26, weight: .semibold)).tracking(-0.8)
                Text("One place for every account.").font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh all usage", isWorking: store.isRefreshing) {
                Task { await store.refreshAll(userInitiated: true) }
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button("Import current \(provider.shortName)", systemImage: provider.symbol) {
                        Task {
                            do { try await store.importCurrent(provider: provider) }
                            catch { store.report(error) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppPalette.secondaryInk)
                .padding(.horizontal, 8)
                .frame(height: 32)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { showsAddAccount = true } label: { Label("Add account", systemImage: "plus") }
                .buttonStyle(AppButtonStyle(prominent: true))
                .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(filter.title).font(.system(size: 13, weight: .semibold))
                Text("\(filteredProfiles.count)")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(AppPalette.secondaryInk)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(AppPalette.line.opacity(0.45))
                    .clipShape(Capsule())
                Spacer()
                searchField
            }
            .frame(height: 30)
            GeometryReader { geometry in
                if filteredProfiles.isEmpty {
                    emptyState.frame(width: geometry.size.width, height: min(240, geometry.size.height)).surface()
                } else {
                    VStack(spacing: 0) {
                        columnHeaders
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredProfiles) { profile in
                                    AccountRowView(
                                        profile: profile,
                                        isActive: store.isActive(profile),
                                        isSwitching: store.switchingProfileID == profile.id,
                                        isRefreshing: store.refreshingProfileIDs.contains(profile.id),
                                        activate: {
                                            Task {
                                                do { try await store.activate(profile.id) }
                                                catch { store.report(error) }
                                            }
                                        },
                                        refresh: { Task { await store.refresh(profile.id, userInitiated: true) } },
                                        grantKeychainAccess: { Task { await store.grantKeychainAccess(profile.id) } },
                                        rename: { store.rename(profile.id, to: $0) },
                                        remove: { store.remove(profile.id) }
                                    )
                                    if profile.id != filteredProfiles.last?.id {
                                        Rectangle().fill(AppPalette.line.opacity(0.7)).frame(height: 1)
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                    }
                    .frame(height: min(CGFloat(filteredProfiles.count) * 67 + 30, geometry.size.height))
                    .surface()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Search accounts")
            TextField("Search accounts", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.system(size: 9)).foregroundStyle(AppPalette.tertiaryInk)
            }
        }
        .foregroundStyle(AppPalette.secondaryInk)
        .padding(.horizontal, 9)
        .frame(width: 185, height: 29)
        .surface(radius: 7)
    }

    private var columnHeaders: some View {
        HStack(spacing: AccountColumns.spacing) {
            SectionCaption(title: "Account").frame(maxWidth: .infinity, alignment: .leading)
            SectionCaption(title: "5-hour limit").frame(width: AccountColumns.meter, alignment: .leading)
            SectionCaption(title: "Weekly limit").frame(width: AccountColumns.meter, alignment: .leading)
            SectionCaption(title: "Status").frame(width: AccountColumns.action)
            Color.clear.frame(width: AccountColumns.menu, height: 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(AppPalette.sidebar.opacity(0.5))
        .overlay(alignment: .bottom) { Rectangle().fill(AppPalette.line).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
            Text(store.isRefreshing ? "Updating usage…" : "Usage updates every 5 minutes")
            Spacer()
            Text("Switches apply to new sessions")
            Image(systemName: "arrow.up.right").font(.system(size: 8))
        }
        .font(.system(size: 9))
        .foregroundStyle(AppPalette.tertiaryInk)
        .frame(height: 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(AppPalette.tertiaryInk)
            Text(store.profiles.isEmpty ? "Your next account starts here" : "No matching accounts")
                .font(.system(size: 14, weight: .semibold))
            Text(store.profiles.isEmpty ? "Add an account or import one you already use." : "Try another search or choose a different provider.")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.secondaryInk)
            if store.profiles.isEmpty {
                Button("Add account") { showsAddAccount = true }.buttonStyle(AppButtonStyle(prominent: true))
            } else {
                Button("Show all accounts") { search = ""; filter = .all }.buttonStyle(AppButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActiveSummary: View {
    let provider: AIProvider
    let profile: AccountProfile?

    var body: some View {
        HStack(spacing: 11) {
            ProviderMark(provider: provider, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(provider.displayName).font(.system(size: 10)).foregroundStyle(AppPalette.secondaryInk)
                Text(profile?.displayName ?? "No active account")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(profile == nil ? AppPalette.tertiaryInk : AppPalette.success).frame(width: 4, height: 4)
                    Text(profile == nil ? "NOT CONNECTED" : "ACTIVE")
                        .font(.system(size: 8, weight: .medium)).tracking(0.7)
                }
                .foregroundStyle(AppPalette.secondaryInk)
                if profile?.needsKeychainAccess == true {
                    Label("Access needed", systemImage: "lock")
                        .font(.system(size: 9))
                        .foregroundStyle(AppPalette.warning)
                } else if let weekly = profile?.usage?.weekly {
                    Text("\(Int(weekly.remainingPercent.rounded()))% weekly left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(provider.accent)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .surface()
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppPalette.warning)
            Text(message).font(.system(size: 11)).lineLimit(3)
            Spacer(minLength: 8)
            IconButton(symbol: "xmark", help: "Dismiss error", action: dismiss)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .surface(radius: 10)
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}
