import SwiftUI

/// One account in the grid: who it is, its limits as rings, its resets, and Switch.
struct AccountCardView: View {
    /// What omp does with this account while "Switch omp too" is on.
    enum OmpState {
        case none
        /// omp prefers this account for new sessions.
        case preferred
        /// The CLI uses this account, but omp can't: it isn't signed in to omp.
        case notSignedIn
    }

    let profile: AccountProfile
    let isActive: Bool
    let isSwitching: Bool
    let isRefreshing: Bool
    let activate: () -> Void
    let refresh: () -> Void
    let renew: () -> Void
    /// Opens the browser sign-in that replaces this account's saved sign-in.
    let signInAgain: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    let useReset: () async throws -> LimitResetOutcome
    var omp: OmpState = .none

    @State private var isHovered = false
    @State private var confirmsRemoval = false
    @State private var showsRename = false
    @State private var showsIssue = false
    @State private var editedName = ""

    private var isStale: Bool { profile.authIssue != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            rings
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(AppPalette.line, lineWidth: 1) }
        .shadow(color: .black.opacity(isHovered ? 0.07 : 0), radius: 12, y: 4)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProviderMark(provider: profile.provider, size: 36)
                .help(profile.provider.displayName)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                badges.padding(.top, 4)
            }
            Spacer(minLength: 4)
            menu
        }
    }

    /// Always one line tall, so cards line up whether or not they carry badges.
    private var badges: some View {
        HStack(spacing: 5) {
            if isActive { ActiveBadge() }
            if let plan = profile.plan, !plan.isEmpty { PlanBadge(plan: plan) }
            switch omp {
            case .preferred:
                OmpBadge()
            case .notSignedIn:
                Text("Not in omp")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .help("omp keeps choosing its own account: sign \(profile.displayName) in to omp with /login so omp can use it.")
            case .none:
                EmptyView()
            }
        }
        .fixedSize()
        .frame(height: 18, alignment: .leading)
    }

    private var rings: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(UsageRing.limits(of: profile.usage)) { limit in
                UsageRing(title: limit.title, window: limit.window, isStale: isStale)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let resets = profile.usage?.resets {
                LimitResetsButton(accountName: profile.displayName, provider: profile.provider,
                                  resets: resets, use: useReset)
            }
            FreshnessLabel(fetchedAt: profile.usage?.fetchedAt, labelled: true)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer(minLength: 6)
            action
        }
        .frame(height: 28)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(AppPalette.line).frame(height: 1).padding(.horizontal, -16)
        }
    }

    @ViewBuilder
    private var action: some View {
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

    private var menu: some View {
        Menu {
            Button("Refresh usage", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isRefreshing || isSwitching)
            Button("Renew sign-in", systemImage: "key.horizontal", action: renew)
                .disabled(isRefreshing || isSwitching)
            Button("Sign in again…", systemImage: "person.crop.circle.badge.checkmark", action: signInAgain)
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
                Text("The rings show the last usage AI Switch saw.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
            HStack(spacing: 8) {
                Button("Renew sign-in") {
                    showsIssue = false
                    renew()
                }
                .buttonStyle(AppButtonStyle(compact: true))
                .help("Ask \(profile.provider.displayName) to renew this account's sign-in")
                Button("Sign in again…") {
                    showsIssue = false
                    signInAgain()
                }
                .buttonStyle(AppButtonStyle(compact: true))
                .help("Sign this account in again in your browser, replacing its saved sign-in")
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
