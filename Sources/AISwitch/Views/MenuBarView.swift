import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AppMark(size: 22)
                Text("AI Switch").font(.system(size: 13, weight: .semibold))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh active accounts", isWorking: store.isRefreshing) {
                    Task {
                        for provider in AIProvider.allCases {
                            if let profile = store.activeProfile(for: provider) {
                                await store.refresh(profile.id)
                            }
                        }
                    }
                }
                .disabled(store.isRefreshing)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 10)

            VStack(spacing: 10) {
                ForEach(AIProvider.allCases) { provider in
                    MenuProviderCard(provider: provider)
                }
                if let error = store.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppPalette.warning)
                        Text(error).font(.system(size: 11)).foregroundStyle(AppPalette.ink).lineLimit(4)
                        Spacer(minLength: 4)
                        Button { store.dismissError() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppPalette.secondaryInk)
                    }
                    .padding(12)
                    .surface(radius: 10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Rectangle().fill(AppPalette.line).frame(height: 1)
            HStack {
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 5) {
                        Text("Open AI Switch")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 340)
        .background(AppPalette.canvas)
        .foregroundStyle(AppPalette.ink)
    }
}

private struct MenuProviderCard: View {
    @EnvironmentObject private var store: AccountStore
    let provider: AIProvider

    private var profile: AccountProfile? { store.activeProfile(for: provider) }
    private var isStale: Bool { profile?.authIssue != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderMark(provider: provider, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 11)).foregroundStyle(AppPalette.secondaryInk)
                    Text(profile?.displayName ?? "No active account")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(profile == nil ? AppPalette.tertiaryInk : AppPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let profile {
                    FreshnessLabel(fetchedAt: profile.usage?.fetchedAt).font(.system(size: 10.5))
                }
                switchMenu
            }
            if let profile {
                HStack(spacing: 18) {
                    UsageMeter(title: "5-hour", window: profile.usage?.session, isStale: isStale)
                    UsageMeter(title: "Weekly", window: profile.usage?.weekly, isStale: isStale)
                }
                ForEach(profile.usage?.scoped ?? [], id: \.name) { limit in
                    UsageMeter(title: "\(limit.name) weekly", window: limit.window, isStale: isStale)
                }
                if let issue = profile.authIssue {
                    HStack(spacing: 8) {
                        Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                            .help(issue)
                        Spacer()
                        Button("Renew sign-in") { Task { await store.renew(profile.id) } }
                            .buttonStyle(.plain)
                            .fontWeight(.medium)
                            .disabled(store.isRefreshing || store.switchingProfileID != nil)
                            .help("Ask \(provider.displayName) to renew this account's sign-in")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.warning)
                }
            }
        }
        .padding(14)
        .surface(radius: 12)
    }

    private var switchMenu: some View {
        Menu {
            ForEach(store.profiles.filter { $0.provider == provider }) { account in
                Button {
                    Task {
                        do { try await store.activate(account.id) }
                        catch { store.report(error) }
                    }
                } label: {
                    if store.isActive(account) {
                        Label(account.displayName, systemImage: "checkmark")
                    } else {
                        Text(account.displayName)
                    }
                }
                .disabled(store.isActive(account))
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.isRefreshing || store.switchingProfileID != nil || !store.profiles.contains { $0.provider == provider })
        .accessibilityLabel("Switch \(provider.shortName) account")
    }
}
