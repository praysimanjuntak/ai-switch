import SwiftUI

/// The steps between the resets pill and spending a reset. A reset is spent only
/// after two separate confirmations, and the final button stays disabled briefly
/// after it appears, so neither a double-click nor a rushed click can spend one.
enum ResetConfirmation: Equatable {
    case idle
    /// First confirmation: use a reset on this account?
    case first
    /// Final confirmation; it can't be accepted before `armingDelay` has passed.
    case final(shownAt: Date)
    case working
    case finished(LimitResetOutcome)
    case failed(String)

    static let armingDelay: TimeInterval = 1.5

    mutating func begin() {
        if self == .idle { self = .first }
    }

    mutating func confirmFirst(at now: Date = Date()) {
        if self == .first { self = .final(shownAt: now) }
    }

    mutating func cancel() {
        self = .idle
    }

    func canSpend(at now: Date) -> Bool {
        guard case .final(let shownAt) = self else { return false }
        return now.timeIntervalSince(shownAt) >= Self.armingDelay
    }
}

/// An account's usage limit resets: how many are left, and using one.
struct LimitResetsButton: View {
    let accountName: String
    let provider: AIProvider
    let resets: LimitResets
    let use: () async throws -> LimitResetOutcome

    @State private var showsPopover = false
    @State private var confirmation: ResetConfirmation = .idle

    var body: some View {
        Button {
            confirmation = .idle
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
            LimitResetsPanel(accountName: accountName, provider: provider, resets: resets,
                             confirmation: $confirmation, spend: spend)
        }
        .onChange(of: showsPopover) { _, shown in
            // Closing the popover abandons a confirmation in progress.
            if !shown, confirmation != .working { confirmation = .idle }
        }
    }

    private func spend() {
        // Checked again at the moment of the click, not only by the button's state.
        guard confirmation.canSpend(at: Date()) else { return }
        confirmation = .working
        Task {
            do {
                confirmation = .finished(try await use())
            } catch AISwitchError.commandTimedOut {
                // The reset may have gone through; a new attempt must wait for the real count.
                confirmation = .failed("Couldn't confirm the reset. Refresh this account to see how many are left.")
            } catch {
                confirmation = .failed("Couldn't reset usage: \(error.localizedDescription)")
            }
        }
    }
}

/// What the resets pill opens: the credits left, soonest to expire first, and
/// the two confirmations that stand before using one.
struct LimitResetsPanel: View {
    let accountName: String
    let provider: AIProvider
    let resets: LimitResets
    @Binding var confirmation: ResetConfirmation
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
        switch confirmation {
        case .idle:
            Button("Use a reset…") { confirmation.begin() }
                .buttonStyle(AppButtonStyle(prominent: true))
                .disabled(resets.available == 0)
        case .first:
            VStack(alignment: .leading, spacing: 10) {
                Text("Use 1 of \(resets.available == 1 ? "your 1 reset" : "your \(resets.available) resets") on \(accountName)?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Cancel") { confirmation.cancel() }
                        .buttonStyle(AppButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Continue…") { confirmation.confirmFirst() }
                        .buttonStyle(AppButtonStyle(prominent: true))
                }
            }
        case .final:
            // The buttons swap sides, so a second click where Continue was lands on Cancel.
            VStack(alignment: .leading, spacing: 10) {
                Text("Last check: reset \(accountName)'s \(provider.shortName) usage now? This can't be undone.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.critical)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    HStack(spacing: 8) {
                        Button("Yes, reset now", action: spend)
                            .buttonStyle(AppButtonStyle(destructive: true))
                            .disabled(!confirmation.canSpend(at: context.date))
                        Button("Cancel") { confirmation.cancel() }
                            .buttonStyle(AppButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
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
