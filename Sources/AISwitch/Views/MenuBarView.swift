import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AppMark(size: 25)
                Text("AI Switch").font(.system(size: 13, weight: .semibold))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh active accounts", isWorking: store.isRefreshing) {
                    Task {
                        for provider in AIProvider.allCases {
                            if let profile = store.activeProfile(for: provider) {
                                await store.refresh(profile.id, userInitiated: true)
                            }
                        }
                    }
                }
                .disabled(store.isRefreshing)
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 8) {
                ForEach(AIProvider.allCases) { provider in
                    MenuProviderCard(provider: provider)
                }
                if let error = store.errorMessage {
                    HStack(alignment: .top) {
                        Text(error).font(.system(size: 10)).lineLimit(3)
                        Button { store.dismissError() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(AppPalette.warning)
                    .padding(10)
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
                    HStack(spacing: 6) {
                        Text("Manage accounts")
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.ink)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.secondaryInk)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 17)
            .padding(.vertical, 13)
        }
        .frame(width: 324)
        .background(AppPalette.canvas)
        .foregroundStyle(AppPalette.ink)
    }
}

private struct MenuProviderCard: View {
    @EnvironmentObject private var store: AccountStore
    let provider: AIProvider

    private var profile: AccountProfile? { store.activeProfile(for: provider) }

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 9) {
                ProviderMark(provider: provider, size: 29)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(.system(size: 9)).foregroundStyle(AppPalette.secondaryInk)
                    Text(profile?.displayName ?? "No active account")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
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
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.isRefreshing || store.switchingProfileID != nil || !store.profiles.contains { $0.provider == provider })
                .accessibilityLabel("Switch \(provider.shortName) account")
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionCaption(title: "5-hour")
                    UsageMeter(window: profile?.usage?.session, accent: provider.accent,
                               isStale: profile?.authIssue != nil)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionCaption(title: "Weekly")
                    UsageMeter(window: profile?.usage?.weekly, accent: provider.accent,
                               isStale: profile?.authIssue != nil)
                }
            }
            if profile?.authIssue != nil {
                Label(profile?.needsKeychainAccess == true ? "Grant access in Manage accounts" : "Usage needs attention",
                      systemImage: profile?.needsKeychainAccess == true ? "lock" : "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(AppPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(13)
        .surface(radius: 10)
    }
}
