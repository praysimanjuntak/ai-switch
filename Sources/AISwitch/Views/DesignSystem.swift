import AppKit
import SwiftUI

extension AIProvider {
    var accent: Color {
        switch self {
        case .codex: Color(red: 0.19, green: 0.39, blue: 0.33)
        case .claude: Color(red: 0.72, green: 0.37, blue: 0.26)
        }
    }

    var softAccent: Color { accent.opacity(0.08) }

    /// The vendor's mark as a template image, so it takes the current
    /// foreground style like an SF Symbol would.
    var logo: NSImage {
        switch self {
        case .codex: Self.openAI
        case .claude: Self.anthropic
        }
    }

    private static let openAI = templateImage("openai", extension: "svg")
    private static let anthropic = templateImage("anthropic", extension: "png")

    /// SwiftPM's generated `Bundle.module` only looks beside the executable and
    /// at the absolute build path, which is wrong for an app bundle and, when the
    /// checkout lives under Documents, triggers a folder-access prompt. Look in
    /// Contents/Resources first (built app), then beside the executable (`swift run`).
    private static let resources: Bundle = {
        let name = "AISwitch_AISwitch.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            if let bundle = candidate.flatMap({ Bundle(url: $0.appendingPathComponent(name)) }) { return bundle }
        }
        fatalError("Missing \(name); the build scripts copy it into Contents/Resources.")
    }()

    private static func templateImage(_ name: String, extension ext: String) -> NSImage {
        guard let url = resources.url(forResource: name, withExtension: ext, subdirectory: "Assets"),
              let image = NSImage(contentsOf: url) else {
            fatalError("Missing bundled logo \(name).\(ext) in \(resources.bundlePath).")
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16) // Intrinsic size for menus; views scale it explicitly.
        return image
    }
}

/// A provider's mark, sized like an SF Symbol of the given point size.
struct ProviderLogo: View {
    let provider: AIProvider
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: provider.logo)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum AppPalette {
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.17)
    static let secondaryInk = Color(red: 0.45, green: 0.47, blue: 0.45)
    static let tertiaryInk = Color(red: 0.62, green: 0.64, blue: 0.61)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.89)
    static let canvas = Color(red: 0.985, green: 0.984, blue: 0.976)
    static let sidebar = Color(red: 0.955, green: 0.958, blue: 0.944)
    static let success = Color(red: 0.25, green: 0.48, blue: 0.36)
    static let warning = Color(red: 0.68, green: 0.44, blue: 0.15)
}

struct Surface: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(AppPalette.line, lineWidth: 1) }
    }
}

extension View {
    func surface(radius: CGFloat = 12) -> some View { modifier(Surface(radius: radius)) }
}

struct AppButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 28 : 32)
            .foregroundStyle(prominent ? Color.white : AppPalette.ink)
            .background(prominent ? AppPalette.ink : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(prominent ? Color.clear : AppPalette.line, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.secondaryInk)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct AppMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "arrow.triangle.swap")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(AppPalette.ink.gradient)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct ProviderMark: View {
    let provider: AIProvider
    var size: CGFloat = 32

    var body: some View {
        ProviderLogo(provider: provider, size: size * 0.5)
            .foregroundStyle(provider.accent)
            .frame(width: size, height: size)
            .background(provider.softAccent)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityLabel(provider.displayName)
    }
}

struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan.replacingOccurrences(of: "_", with: " ").uppercased())
            .font(.system(size: 8, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(AppPalette.secondaryInk)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(AppPalette.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct UsageMeter: View {
    var title: String? = nil
    let window: UsageWindow?
    let accent: Color
    var isStale = false

    var body: some View {
        // Update local-day and elapsed-reset labels without fetching usage or credentials.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            meter(reset: UsageResetDisplay(window: window, isStale: isStale, now: context.date))
        }
    }

    private func meter(reset: UsageResetDisplay) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let title {
                    SectionCaption(title: title)
                    Spacer(minLength: 4)
                }
                Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.ink)
                if window != nil {
                    Text("left").font(.system(size: 9)).foregroundStyle(AppPalette.tertiaryInk)
                }
                if title == nil { Spacer(minLength: 0) }
                if isStale, window != nil {
                    Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(AppPalette.tertiaryInk)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppPalette.line.opacity(0.65))
                    Capsule().fill(barColor)
                        .frame(width: geometry.size.width * (window?.remainingPercent ?? 0) / 100)
                }
            }
            .frame(height: 4)
            Text(reset.compactText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(window?.remainingPercent == 0 ? AppPalette.warning : AppPalette.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .opacity(isStale ? 0.65 : 1)
        .help(reset.detailText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "\(Int($0.remainingPercent.rounded())) percent remaining. \(reset.detailText)" } ?? reset.detailText)
    }

    private var barColor: Color {
        guard let remaining = window?.remainingPercent else { return AppPalette.line }
        if remaining <= 10 { return Color(red: 0.76, green: 0.29, blue: 0.25) }
        if remaining <= 30 { return AppPalette.warning }
        return accent
    }
}

struct SectionCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.1)
            .foregroundStyle(AppPalette.tertiaryInk)
    }
}
