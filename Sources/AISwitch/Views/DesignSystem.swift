import AppKit
import SwiftUI

extension AIProvider {
    /// The vendor's mark as a template image, so it takes the current
    /// foreground style like an SF Symbol would.
    var logo: NSImage {
        switch self {
        case .codex: Self.openAI
        case .claude: Self.anthropic
        }
    }

    var vendorName: String {
        switch self {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
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

/// White surfaces, neutral grays, and color only where it carries meaning.
enum AppPalette {
    static let canvas = Color.white
    /// Hovered rows and quiet controls.
    static let raised = Color(white: 0.972)
    /// Logo tiles, badges, and the selected filter's track.
    static let fill = Color(white: 0.953)
    static let line = Color(white: 0.914)
    static let track = Color(white: 0.925)
    static let ink = Color(white: 0.09)
    static let secondaryInk = Color(white: 0.43)
    static let tertiaryInk = Color(white: 0.63)
    static let success = Color(red: 0.14, green: 0.62, blue: 0.37)
    static let warning = Color(red: 0.86, green: 0.53, blue: 0.09)
    static let critical = Color(red: 0.87, green: 0.25, blue: 0.22)

    /// A limit's bar: neutral while there is room, amber when running low, red near the end.
    static func meter(remaining: Double) -> Color {
        if remaining <= 10 { return critical }
        if remaining <= 30 { return warning }
        return ink
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

struct Surface: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(AppPalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(AppPalette.line, lineWidth: 1) }
    }
}

extension View {
    func surface(radius: CGFloat = 12) -> some View { modifier(Surface(radius: radius)) }
}

/// Black for the one primary action on a surface; white with a hairline otherwise.
struct AppButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 32)
            .foregroundStyle(prominent ? Color.white : AppPalette.ink)
            .background(prominent ? AppPalette.ink : AppPalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 8))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 7 : 8)
                    .strokeBorder(prominent ? Color.clear : AppPalette.line, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var isWorking = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                } else {
                    Image(systemName: symbol).font(.system(size: 13, weight: .regular))
                }
            }
            .frame(width: 30, height: 30)
            .background(isHovered ? AppPalette.raised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.secondaryInk)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct AppMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(AppPalette.ink)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

/// The provider's logo on a light tile; monochrome, so rows stay calm.
struct ProviderMark: View {
    let provider: AIProvider
    var size: CGFloat = 32

    var body: some View {
        ProviderLogo(provider: provider, size: size * 0.48)
            .foregroundStyle(AppPalette.ink)
            .frame(width: size, height: size)
            .background(AppPalette.fill)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(provider.displayName)
    }
}

struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(AppPalette.secondaryInk)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppPalette.fill)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct ActiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(AppPalette.success).frame(width: 6, height: 6)
            Text("Active")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(AppPalette.success)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppPalette.success.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// One limit: what is left, how full it is, and when it resets.
struct UsageMeter: View {
    let title: String
    let window: UsageWindow?
    var isStale = false

    var body: some View {
        // Update local-day and elapsed-reset labels without fetching usage or credentials.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            meter(reset: UsageResetDisplay(window: window, isStale: isStale, now: context.date))
        }
    }

    private func meter(reset: UsageResetDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.secondaryInk)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let window {
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppPalette.ink)
                    Text("left").font(.system(size: 11)).foregroundStyle(AppPalette.tertiaryInk)
                } else {
                    Text("—").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppPalette.tertiaryInk)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppPalette.track)
                    if let window {
                        Capsule().fill(AppPalette.meter(remaining: window.remainingPercent))
                            .frame(width: geometry.size.width * window.remainingPercent / 100)
                    }
                }
            }
            .frame(height: 5)
            Text(reset.compactText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(window?.remainingPercent == 0 ? AppPalette.critical : AppPalette.tertiaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .opacity(isStale ? 0.55 : 1)
        .help(reset.detailText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "\(title): \(Int($0.remainingPercent.rounded())) percent left. \(reset.detailText)" } ?? "\(title): \(reset.detailText)")
    }
}

struct SectionCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(AppPalette.secondaryInk)
    }
}

/// "Live" while usage is under a minute old, then how long ago it was read.
struct FreshnessLabel: View {
    let fetchedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            label(now: context.date)
        }
    }

    @ViewBuilder
    private func label(now: Date) -> some View {
        if let fetchedAt, fetchedAt > .distantPast {
            let age = now.timeIntervalSince(fetchedAt)
            if age < 60 {
                HStack(spacing: 4) {
                    Circle().fill(AppPalette.success).frame(width: 5, height: 5)
                    Text("Live")
                }
                .foregroundStyle(AppPalette.success)
                .help("Updated \(fetchedAt.formatted(date: .omitted, time: .standard))")
            } else {
                Text(age < 3600 ? "\(Int(age / 60)) min ago" : fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(AppPalette.tertiaryInk)
                    .help("Updated \(fetchedAt.formatted(date: .complete, time: .standard))")
            }
        } else {
            Text("Not checked yet").foregroundStyle(AppPalette.tertiaryInk)
        }
    }
}
