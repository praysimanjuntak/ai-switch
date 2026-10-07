import SwiftUI

/// Widths every row shares, so meters line up down the list.
enum AccountColumns {
    static let meter: CGFloat = 148
    static let action: CGFloat = 112
    static let spacing: CGFloat = 26
}

struct AccountRowView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isSwitching: Bool
    let isRefreshing: Bool
    let activate: () -> Void
    let refresh: () -> Void
    let renew: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    let useReset: () async throws -> LimitResetOutcome

    @State private var isHovered = false
    @State private var confirmsRemoval = false
    @State private var showsRename = false
    @State private var showsIssue = false
    @State private var editedName = ""

    private var isStale: Bool { profile.authIssue != nil }

    var body: some View {
        HStack(alignment: .center, spacing: AccountColumns.spacing) {
            identity
                .frame(maxWidth: .infinity, alignment: .leading)
            UsageMeter(title: "5-hour", window: profile.usage?.session, isStale: isStale)
                .frame(width: AccountColumns.meter)
            UsageMeter(title: "Weekly", window: profile.usage?.weekly, isStale: isStale)
                .frame(width: AccountColumns.meter)
            modelMeters
                .frame(width: AccountColumns.meter)
            actions
                .frame(width: AccountColumns.action, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(isHovered ? AppPalette.raised : AppPalette.canvas)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .alert("Rename account", isPresented: $showsRename) {
            TextField("Account name", text: $editedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename(editedName) }
                .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a name that makes this account easy to find.")
        }
        .confirmationDialog("Remove \(profile.displayName)?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove account", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isActive
                 ? "This deletes the saved credentials for this account from AI Switch. \(profile.provider.displayName) keeps its current sign-in until you switch or sign out in the CLI."
                 : "This deletes the saved credentials for this account from AI Switch. Your active account stays the same.")
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ProviderMark(provider: profile.provider, size: 34)
                .help(profile.provider.displayName)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if isActive { ActiveBadge().fixedSize() }
                    if let plan = profile.plan, !plan.isEmpty { PlanBadge(plan: plan).fixedSize() }
                }
                if profile.authIssue != nil {
                    attention
                } else {
                    Text(profile.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppPalette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(profile.subtitle)
                }
                if let resets = profile.usage?.resets {
                    LimitResetsButton(accountName: profile.displayName, provider: profile.provider,
                                      resets: resets, use: useReset)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Per-model weekly limits, e.g. Claude's Fable bucket. Stacked so the
    /// columns after them stay aligned.
    @ViewBuilder
    private var modelMeters: some View {
        let scoped = profile.usage?.scoped ?? []
        if scoped.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(scoped, id: \.name) { limit in
                    UsageMeter(title: "\(limit.name) weekly", window: limit.window, isStale: isStale)
                }
            }
        }
    }

    private var attention: some View {
        Button { showsIssue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Needs attention")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppPalette.warning)
        }
        .buttonStyle(.plain)
        .help(profile.authIssue ?? "")
        .popover(isPresented: $showsIssue, arrowEdge: .bottom) { issuePopover }
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 4) {
                if isSwitching || isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text(isSwitching ? "Switching" : "Updating")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppPalette.secondaryInk)
                } else if !isActive {
                    Button("Switch", action: activate)
                        .buttonStyle(AppButtonStyle(compact: true))
                        .help("Use \(profile.displayName) for new \(profile.provider.shortName) sessions")
                }
                menu
            }
            FreshnessLabel(fetchedAt: profile.usage?.fetchedAt)
                .font(.system(size: 11))
        }
    }

    private var menu: some View {
        Menu {
            Button("Refresh usage", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isRefreshing || isSwitching)
            Button("Renew sign-in", systemImage: "key.horizontal", action: renew)
                .disabled(isRefreshing || isSwitching)
            Button("Rename…", systemImage: "pencil") {
                editedName = profile.displayName
                showsRename = true
            }
            Divider()
            Button("Remove account…", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                .disabled(isSwitching)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(profile.displayName)")
    }

    private var issuePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(profile.authIssue ?? "")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if profile.usage != nil {
                Text("The meters show the last usage AI Switch saw.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            Button("Renew sign-in") {
                showsIssue = false
                renew()
            }
            .buttonStyle(AppButtonStyle(compact: true))
            .help("Ask \(profile.provider.displayName) to renew this account's sign-in")
        }
        .padding(16)
        .frame(width: 280)
    }
}
