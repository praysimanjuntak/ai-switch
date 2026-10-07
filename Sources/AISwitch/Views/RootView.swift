import SwiftUI

private enum ProviderFilter: Hashable {
    case all, provider(AIProvider)
}

struct RootView: View {
    @EnvironmentObject private var store: AccountStore
    @State private var filter: ProviderFilter = .all
    @State private var search = ""
    @State private var showsAddAccount = false
    @State private var showsPhoneSync = false
    @FocusState private var searchFocused: Bool

    private var matchingProfiles: [AccountProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.profiles.filter { profile in
            let matchesFilter = switch filter {
            case .all: true
            case .provider(let provider): profile.provider == provider
            }
            let matchesSearch = query.isEmpty || [profile.displayName, profile.email ?? "", profile.provider.displayName, profile.plan ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesFilter && matchesSearch
        }.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 34) // Below the window controls.
            filterBar
                .padding(.top, 22)
                .padding(.bottom, 14)
            list
            footer
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.canvas.ignoresSafeArea())
        .foregroundStyle(AppPalette.ink)
        .overlay(alignment: .bottom) {
            if let message = store.errorMessage {
                ErrorBanner(message: message, dismiss: store.dismissError)
                    .frame(maxWidth: 560)
                    .padding(.bottom, 54) // Above the footer.
            }
        }
        .sheet(isPresented: $showsAddAccount) {
            AddAccountSheet().environmentObject(store).preferredColorScheme(.light)
        }
        .sheet(isPresented: $showsPhoneSync) {
            PhoneSyncSheet(sync: store.sync).environmentObject(store).preferredColorScheme(.light)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Accounts")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.6)
                Text("Choose the account Codex and Claude Code use. Switches apply to new sessions.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            Spacer(minLength: 16)
            IconButton(symbol: "arrow.clockwise", help: "Refresh usage", isWorking: store.isRefreshing) {
                Task { await store.refreshAll() }
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            IconButton(symbol: store.sync.isConfigured ? "iphone.badge.checkmark" : "iphone",
                       help: store.sync.isConfigured ? "Phone sync connected" : "Show usage on your phone") {
                showsPhoneSync = true
            }
            importMenu
            Button { showsAddAccount = true } label: {
                Label("Add account", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(AppButtonStyle(prominent: true))
            .keyboardShortcut("n", modifiers: .command)
            .padding(.leading, 4)
        }
    }

    private var importMenu: some View {
        Menu {
            ForEach(AIProvider.allCases) { provider in
                Button {
                    Task {
                        do { try await store.importCurrent(provider: provider) }
                        catch { store.report(error) }
                    }
                } label: {
                    Label { Text("Import current \(provider.displayName) account") } icon: { Image(nsImage: provider.logo) }
                }
            }
        } label: {
            Text("Import")
        }
        .menuStyle(.button)
        .buttonStyle(AppButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save the account a CLI is signed in to now")
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                filterPill(.all, title: "All", count: store.profiles.count)
                ForEach(AIProvider.allCases) { provider in
                    filterPill(.provider(provider), title: provider.displayName,
                               count: store.profiles.filter { $0.provider == provider }.count)
                }
            }
            .padding(3)
            .background(AppPalette.fill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer()
            searchField
        }
    }

    private func filterPill(_ value: ProviderFilter, title: String, count: Int) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(selected ? AppPalette.secondaryInk : AppPalette.tertiaryInk)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AppPalette.ink : AppPalette.secondaryInk)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(selected ? AppPalette.canvas : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 1.5, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button { searchFocused = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Search accounts")
            TextField("Search accounts", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            } else {
                Text("⌘F").font(.system(size: 11)).foregroundStyle(AppPalette.tertiaryInk)
            }
        }
        .foregroundStyle(AppPalette.secondaryInk)
        .padding(.horizontal, 10)
        .frame(width: 230, height: 32)
        .surface(radius: 8)
    }

    @ViewBuilder
    private var list: some View {
        let profiles = matchingProfiles
        if profiles.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let active = profiles.filter { store.isActive($0) }
            let others = profiles.filter { !store.isActive($0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !active.isEmpty { section("Active", profiles: active) }
                    if !others.isEmpty { section(active.isEmpty ? "Accounts" : "Other accounts", profiles: others) }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func section(_ title: String, profiles: [AccountProfile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(title: title).padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 {
                        Rectangle().fill(AppPalette.line).frame(height: 1).padding(.leading, 64)
                    }
                    row(for: profile)
                }
            }
            .surface(radius: 12)
        }
    }

    private func row(for profile: AccountProfile) -> some View {
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
            refresh: { Task { await store.refresh(profile.id) } },
            renew: { Task { await store.renew(profile.id) } },
            rename: { store.rename(profile.id, to: $0) },
            remove: { Task { await store.remove(profile.id) } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "person.crop.circle.badge.plus" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppPalette.tertiaryInk)
                .padding(.bottom, 4)
            Text(store.profiles.isEmpty ? "No accounts yet" : "No matching accounts")
                .font(.system(size: 15, weight: .semibold))
            Text(store.profiles.isEmpty
                 ? "Add an account, or import the one a CLI is signed in to."
                 : "Try another search or provider.")
                .font(.system(size: 12.5))
                .foregroundStyle(AppPalette.secondaryInk)
            Group {
                if store.profiles.isEmpty {
                    Button("Add account") { showsAddAccount = true }.buttonStyle(AppButtonStyle(prominent: true))
                } else {
                    Button("Show all accounts") { search = ""; filter = .all }.buttonStyle(AppButtonStyle())
                }
            }
            .padding(.top, 6)
        }
        .padding(.bottom, 40)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            ForEach(AIProvider.allCases) { provider in
                let installed = store.cliAvailable(for: provider)
                HStack(spacing: 6) {
                    Circle().fill(installed ? AppPalette.success : AppPalette.tertiaryInk).frame(width: 6, height: 6)
                    Text(installed ? "\(provider.displayName) CLI" : "\(provider.displayName) CLI not found")
                }
            }
            Spacer()
            Text(store.isRefreshing ? "Checking usage…" : "Codex usage is live; all accounts are checked every 5 minutes")
            Label("Credentials stay on this Mac", systemImage: "lock")
                .labelStyle(.titleAndIcon)
        }
        .font(.system(size: 11))
        .foregroundStyle(AppPalette.tertiaryInk)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle().fill(AppPalette.line).frame(height: 1).padding(.horizontal, -32)
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(AppPalette.warning)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton(symbol: "xmark", help: "Dismiss", action: dismiss)
                .padding(.top, -6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 12)
        .surface(radius: 12)
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}
