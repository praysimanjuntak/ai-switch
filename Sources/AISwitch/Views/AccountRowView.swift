import SwiftUI

enum AccountColumns {
    static let meter: CGFloat = 104
    static let action: CGFloat = 110
    static let menu: CGFloat = 22
    static let spacing: CGFloat = 18
}

struct AccountRowView: View {
    let profile: AccountProfile
    let isActive: Bool
    let isSwitching: Bool
    let isRefreshing: Bool
    let activate: () -> Void
    let refresh: () -> Void
    let grantKeychainAccess: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var isHovered = false
    @State private var confirmsRemoval = false
    @State private var showsRename = false
    @State private var showsIssue = false
    @State private var editedName = ""

    var body: some View {
        HStack(spacing: AccountColumns.spacing) {
            identity.frame(maxWidth: .infinity, alignment: .leading)
            UsageMeter(window: profile.usage?.session, accent: profile.provider.accent, isStale: profile.authIssue != nil)
                .frame(width: AccountColumns.meter)
            UsageMeter(window: profile.usage?.weekly, accent: profile.provider.accent, isStale: profile.authIssue != nil)
                .frame(width: AccountColumns.meter)
            accountAction.frame(width: AccountColumns.action)
            accountMenu.frame(width: AccountColumns.menu)
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
        .background(isHovered ? AppPalette.sidebar.opacity(0.6) : Color.white)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
            Text("This removes the saved account from AI Switch. Your active account stays the same.")
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: profile.provider, size: 32)
                .help("\(profile.provider.displayName)\(isActive ? " · Active account" : "")")
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Circle().fill(AppPalette.success)
                            .frame(width: 7, height: 7)
                            .overlay { Circle().stroke(Color.white, lineWidth: 2) }
                            .offset(x: 1, y: 1)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = profile.plan, !plan.isEmpty { PlanBadge(plan: plan).fixedSize() }
                    if profile.authIssue != nil {
                        Button { showsIssue.toggle() } label: {
                            Image(systemName: profile.needsKeychainAccess == true ? "lock.fill" : "exclamationmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(AppPalette.warning)
                        }
                        .buttonStyle(.plain)
                        .help(profile.authIssue ?? "Account needs attention")
                        .accessibilityLabel("Account needs attention")
                        .popover(isPresented: $showsIssue) { issuePopover }
                    }
                }
                Text(profile.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(profile.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        } else if profile.needsKeychainAccess == true {
            Button(action: grantKeychainAccess) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.open").font(.system(size: 10))
                    Text("Grant access").lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(AppButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)
            .help("Grant Keychain access. Allow works for this app session; Always Allow remembers macOS authorization across launches.")
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
            Button("Rename…", systemImage: "pencil") {
                editedName = profile.displayName
                showsRename = true
            }
            if profile.needsKeychainAccess == true {
                Button("Grant Keychain access", systemImage: "lock.open", action: grantKeychainAccess)
                    .disabled(isRefreshing || isSwitching)
            }
            Divider()
            Button("Remove account…", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
                .disabled(isActive || isRefreshing || isSwitching)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(profile.displayName)")
    }

    private var issuePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(profile.needsKeychainAccess == true ? "Permission needed" : "Usage unavailable", systemImage: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
            Text(profile.needsKeychainAccess == true
                 ? "Choose Grant access, then approve the macOS Keychain prompt. Allow keeps usage checks working until you quit AI Switch. Always Allow remembers macOS authorization across launches."
                 : profile.authIssue ?? "")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if profile.usage != nil {
                Text("The meters show your last recorded usage.")
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.tertiaryInk)
            }
        }
        .padding(16)
        .frame(width: 270)
    }
}
