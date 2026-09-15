import AppKit
import SwiftUI

struct AddAccountSheet: View {
    @EnvironmentObject private var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AIProvider = .codex
    @State private var isWorking = false
    @State private var localError: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var loginID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                AppMark(size: 32)
                Spacer()
                IconButton(symbol: "xmark", help: isWorking ? "Cancel sign-in and close" : "Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Make room for another.")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(AppPalette.ink)
                Text("Connect an account and switch to it whenever you need.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionCaption(title: "Choose your provider").padding(.bottom, 2)
                ForEach(AIProvider.allCases) { item in
                    ProviderChoice(provider: item, selected: provider == item, available: store.cliAvailable(for: item)) {
                        provider = item
                        localError = nil
                    }
                    .disabled(isWorking)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                signInDetail("safari", title: "Sign in with your browser", detail: "Use your existing \(provider.shortName) account.")
                signInDetail("lock.shield", title: "Saved on this Mac only",
                             detail: "Kept in an owner-only file inside this app's profile folder. Nothing is sent anywhere else.")
            }
            .padding(.vertical, 2)

            if let localError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sign-in didn't finish", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    ScrollView {
                        Text(localError)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
                .foregroundStyle(AppPalette.warning)
            }

            VStack(spacing: 10) {
                Button { beginLogin() } label: {
                    HStack(spacing: 8) {
                        if isWorking { ProgressView().controlSize(.mini).tint(.white) }
                        Text(isWorking ? "Waiting for sign-in…" : localError == nil
                             ? "Continue with \(provider.displayName)" : "Try again with \(provider.displayName)")
                        if !isWorking { Image(systemName: "arrow.right").font(.system(size: 10)) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(isWorking || !store.cliAvailable(for: provider))
                .keyboardShortcut(.defaultAction)
                if isWorking {
                    Button("Cancel sign-in", action: close)
                        .buttonStyle(AppButtonStyle())
                }
                Text(isWorking ? "Finish in your browser, or cancel here at any time."
                     : "Your other accounts stay connected.")
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(width: 442)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppPalette.canvas)
        .onDisappear(perform: cancelLogin)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            cancelLogin()
        }
    }

    private func signInDetail(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.secondaryInk)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(AppPalette.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(AppPalette.secondaryInk)
            }
        }
    }

    private func beginLogin() {
        guard loginTask == nil else { return }
        let attempt = UUID()
        let selectedProvider = provider
        loginID = attempt
        isWorking = true
        localError = nil
        loginTask = Task {
            defer {
                if loginID == attempt {
                    isWorking = false
                    loginTask = nil
                    loginID = nil
                }
            }
            do {
                try await store.addAccount(provider: selectedProvider)
                guard !Task.isCancelled, loginID == attempt else { return }
                dismiss()
            } catch is CancellationError {
                // Cancelling is a normal action, not a sign-in failure.
            } catch {
                guard !Task.isCancelled, loginID == attempt else { return }
                localError = error.localizedDescription
            }
        }
    }

    private func cancelLogin() {
        loginID = nil
        loginTask?.cancel()
        loginTask = nil
        isWorking = false
    }

    private func close() {
        cancelLogin()
        dismiss()
    }
}

private struct ProviderChoice: View {
    let provider: AIProvider
    let selected: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ProviderMark(provider: provider, size: 35)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppPalette.ink)
                    Text(provider == .codex ? "OpenAI" : "Anthropic")
                        .font(.system(size: 10)).foregroundStyle(AppPalette.secondaryInk)
                }
                Spacer()
                if !available {
                    Text("CLI not installed").font(.system(size: 9)).foregroundStyle(AppPalette.warning)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(selected ? provider.accent : AppPalette.line)
            }
            .padding(.horizontal, 14)
            .frame(height: 65)
            .background(selected ? provider.softAccent.opacity(0.4) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? provider.accent.opacity(0.65) : AppPalette.line, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
