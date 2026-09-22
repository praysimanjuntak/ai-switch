import SwiftUI

struct AccountCardView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isSwitching: Bool
    let isRefreshing: Bool
    let activate: () -> Void
    let refresh: () -> Void
    let renew: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var isHovered = false
    @State private var confirmsRemoval = false
    @State private var showsRename = false
    @State private var showsIssue = false
    @State private var editedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identity
            VStack(spacing: 12) {
                UsageMeter(title: "5-hour", window: profile.usage?.session,
                           accent: profile.provider.accent, isStale: profile.authIssue != nil)
                UsageMeter(title: "Weekly", window: profile.usage?.weekly,
                           accent: profile.provider.accent, isStale: profile.authIssue != nil)
                ForEach(profile.usage?.scoped ?? [], id: \.name) { scoped in
                    UsageMeter(title: "Weekly · \(scoped.name)", window: scoped.window,
                               accent: profile.provider.accent, isStale: profile.authIssue != nil)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        // Cards stretch to their grid row, so a card with an extra per-model
        // meter does not leave its neighbours shorter.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 216)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? profile.provider.accent.opacity(0.5) : AppPalette.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.06 : 0.02), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 1)
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

    private var identity: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderMark(provider: profile.provider, size: 32)
                .help("\(profile.provider.displayName)\(isActive ? " · Active account" : "")")
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Circle().fill(AppPalette.success)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().stroke(Color.white, lineWidth: 2) }
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(profile.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(profile.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accountMenu
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let plan = profile.plan, !plan.isEmpty { PlanBadge(plan: plan).fixedSize() }
            if profile.authIssue != nil {
                Button { showsIssue.toggle() } label: {
                    Label("Attention", systemImage: "exclamationmark.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppPalette.warning)
                }
                .buttonStyle(.plain)
                .help(profile.authIssue ?? "Account needs attention")
                .accessibilityLabel("Account needs attention")
                .popover(isPresented: $showsIssue) { issuePopover }
            }
            Spacer(minLength: 4)
            accountAction
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var accountAction: some View {
        if isSwitching || isRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(isSwitching ? "Switching" : "Updating")
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.secondaryInk)
            }
        } else if isActive {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppPalette.success)
        } else {
            Button(action: activate) {
                HStack(spacing: 7) {
                    Text("Switch")
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium))
                }
            }
            .buttonStyle(AppButtonStyle(compact: true))
            .help("Activate \(profile.displayName) for new \(profile.provider.shortName) sessions")
        }
    }

    private var accountMenu: some View {
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
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(profile.displayName)")
    }

    private var issuePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Usage unavailable", systemImage: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
            Text(profile.authIssue ?? "")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if profile.usage != nil {
                Text("The meters show your last recorded usage.")
                    .font(.system(size: 10))
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
        .frame(width: 270)
    }
}
