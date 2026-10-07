import SwiftUI

/// An account's usage limit resets: how many are left, and using one. A reset
/// is spent only after a second, explicit confirmation.
struct LimitResetsButton: View {
    let accountName: String
    let provider: AIProvider
    let resets: LimitResets
    let use: () async throws -> LimitResetOutcome

    @State private var showsPopover = false
    @State private var phase: LimitResetsPanel.Phase = .idle

    var body: some View {
        Button {
            phase = .idle
            showsPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 9.5, weight: .semibold))
                Text(resets.available == 1 ? "1 reset" : "\(resets.available) resets")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(resets.available > 0 ? AppPalette.ink : AppPalette.tertiaryInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(AppPalette.line, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Usage limit resets left")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            LimitResetsPanel(accountName: accountName, provider: provider, resets: resets, phase: $phase, spend: spend)
        }
    }

    private func spend() {
        phase = .working
        Task {
            do {
                phase = .finished(try await use())
            } catch AISwitchError.commandTimedOut {
                // The reset may have gone through; a new attempt must wait for the real count.
                phase = .failed("Couldn't confirm the reset. Refresh this account to see how many are left.")
            } catch {
                phase = .failed("Couldn't reset usage: \(error.localizedDescription)")
            }
        }
    }
}

/// What the resets pill opens: the credits left, soonest to expire first, and
/// the two-step way to use one.
struct LimitResetsPanel: View {
    enum Phase: Equatable {
        case idle, confirming, working
        case finished(LimitResetOutcome)
        case failed(String)
    }

    let accountName: String
    let provider: AIProvider
    let resets: LimitResets
    @Binding var phase: Phase
    let spend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage limit resets")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text("Using one restores \(accountName)'s current \(provider.shortName) usage limits right away.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if resets.available == 0 {
                Text("No usage limit resets are available.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppPalette.secondaryInk)
            } else if !resets.credits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(resets.credits.enumerated()), id: \.offset) { index, credit in
                        if index > 0 { Rectangle().fill(AppPalette.line).frame(height: 1) }
                        HStack {
                            Text(credit.title ?? "Full reset").foregroundStyle(AppPalette.ink)
                            Spacer(minLength: 12)
                            Text(credit.expiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Does not expire")
                                .foregroundStyle(AppPalette.secondaryInk)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 7)
                    }
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .idle:
            Button("Use a reset") { phase = .confirming }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(resets.available == 0)
        case .confirming:
            VStack(alignment: .leading, spacing: 10) {
                Text("Use this reset? This can't be undone.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                HStack(spacing: 8) {
                    Button("Yes, use reset", action: spend)
                        .buttonStyle(AppButtonStyle(prominent: true))
                    Button("Cancel") { phase = .idle }
                        .buttonStyle(AppButtonStyle())
                }
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text("Resetting your usage…")
            }
            .font(.system(size: 12))
            .foregroundStyle(AppPalette.secondaryInk)
        case .finished(let outcome):
            Text(message(for: outcome))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(outcome == .reset ? AppPalette.success : AppPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Codex's own wording for each outcome; the count is read after the refresh.
    private func message(for outcome: LimitResetOutcome) -> String {
        switch outcome {
        case .reset: "Usage reset. \(resets.available == 1 ? "1 reset" : "\(resets.available) resets") left."
        case .nothingToReset: "This account's usage doesn't need a reset right now."
        case .noneLeft: "No usage limit resets are available."
        case .alreadyUsed: "That reset was already used. The count above is current."
        }
    }
}
