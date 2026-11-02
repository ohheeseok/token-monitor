import AppKit
import SwiftUI
import TokenMonitorCore

enum Metrics {
    static let popoverWidth: CGFloat = 400
    static let horizontalPadding: CGFloat = 16
    static let iconSize: CGFloat = 28
    static let meterSlotWidth: CGFloat = 96
}

extension AccountPresentation.Severity {
    var tint: Color {
        switch self {
        case .normal: .primary.opacity(0.75)
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Small rounded-square provider icon. Uses the installed app's icon when there is one.
struct ProviderIcon: View {
    let kind: ProviderKind

    var body: some View {
        Group {
            if let image = ProviderIcon.bundledIcon(for: kind) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else if let image = ProviderIcon.appIcon(for: kind) {
                // macOS app icons carry ~10% transparent margin; scale so the artwork fills the tile
                // like the edge-to-edge OpenRouter favicon does.
                Image(nsImage: image).resizable().interpolation(.high).scaleEffect(1.24)
            } else {
                Image(systemName: ProviderIcon.symbol(for: kind))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityHidden(true)
    }

    static let bundleIDs: [ProviderKind: String] = [
        .codex: "com.openai.codex",
        .claude: "com.anthropic.claudefordesktop",
        .antigravity: "com.google.antigravity",
    ]

    @MainActor static var cache: [ProviderKind: NSImage?] = [:]

    @MainActor static func appIcon(for kind: ProviderKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = bundleIDs[kind]
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[kind] = image
        return image
    }

    /// OpenRouter has no Mac app, so its site favicon (openrouter.ai/favicon/glyph.png) ships with us.
    static let bundledIcons: [ProviderKind: String] = [.openRouter: "openrouter"]

    /// SwiftPM's `Bundle.module` only looks next to the .app (not in Contents/Resources, where
    /// bundle.sh puts it) and then falls back to an absolute .build path, so look it up ourselves.
    static let resources: Bundle? = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        .compactMap { $0?.appendingPathComponent("TokenMonitor_TokenMonitor.bundle") }
        .lazy.compactMap { Bundle(url: $0) }.first

    static func bundledIcon(for kind: ProviderKind) -> NSImage? {
        bundledIcons[kind].flatMap { resources?.image(forResource: $0) }
    }

    static func symbol(for kind: ProviderKind) -> String {
        switch kind {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "asterisk"
        case .antigravity: "a.circle"
        case .openRouter: "arrow.triangle.branch"
        }
    }
}

/// `label ▬▬ 25%`
struct MeterView: View {
    let meter: AccountPresentation.Meter

    var body: some View {
        HStack(spacing: 6) {
            Text(meter.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 18, alignment: .leading)
            UsageBar(fraction: meter.fraction, tint: meter.severity.tint)
                .frame(minWidth: 16, maxWidth: .infinity)
                .frame(height: 4)
            Text(meter.percentText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(meter.severity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(meter.severity.tint))
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.label) \(meter.percentText) 사용")
    }
}

struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint).frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
            }
        }
    }
}

/// Capsule segmented control styled like Orca's 상세/압축 switch.
struct ModePicker: View {
    @Binding var mode: DisplayMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DisplayMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: mode == option ? .semibold : .regular))
                        .foregroundStyle(mode == option ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if mode == option { thumb }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    /// Light: white thumb with a soft shadow (native look). Dark: a lighter fill.
    private var thumb: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1, y: 1)
    }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case detail, compact
    var id: String { rawValue }
    var title: String { self == .detail ? "상세" : "압축" }
}

/// A full-width footer row: `title ›`.
struct FooterRow: View {
    let title: String
    var showsChevron = true
    var secondary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 14)).foregroundStyle(secondary ? .secondary : .primary)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// Subtle highlight on hover and press, like menu rows.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : (hovering ? 0.05 : 0)))
                .onHover { hovering = $0 }
        }
    }
}
