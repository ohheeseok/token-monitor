import SwiftUI
import TokenMonitorCore

/// 압축: one line per account.
struct CompactRow: View {
    let item: AccountPresentation
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProviderIcon(kind: item.kind)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if item.hasData {
                    if let trailing = item.compactTrailing {
                        // Money (OpenRouter) is the headline value, so it gets the percent's weight.
                        let isHeadline = item.compactPercent == nil
                        Text(trailing)
                            .font(.system(size: isHeadline ? 14 : 12, weight: isHeadline ? .medium : .regular).monospacedDigit())
                            .foregroundStyle(isHeadline ? .primary : .secondary)
                            .fixedSize()
                    }
                    if let percent = item.compactPercent {
                        Text(percent)
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(item.compactSeverity == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(item.compactSeverity.tint))
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
                Chevron()
            }
            .opacity(item.isStale ? 0.55 : 1)
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// 상세: header plus one line per window group.
struct DetailCard: View {
    let item: AccountPresentation
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    header
                    if item.hasData {
                        ForEach(item.lines) { line in
                            LineView(line: line)
                        }
                        ForEach(item.moneyLines, id: \.self) { text in
                            Text(text)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.leading, Metrics.iconSize + 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(item.isStale ? 0.55 : 1)
                Chevron()
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProviderIcon(kind: item.kind)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).fixedSize()
            if let plan = item.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            if let status = item.statusText {
                Text(status).font(.system(size: 12)).foregroundStyle(item.hasData ? .orange : .secondary).lineLimit(1)
            } else if let reset = item.resetText {
                Text(reset).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct LineView: View {
    let line: AccountPresentation.Line

    var body: some View {
        HStack(spacing: 8) {
            Text(line.title ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(line.slots.enumerated()), id: \.offset) { _, meter in
                Group {
                    if let meter { MeterView(meter: meter) } else { Color.clear }
                }
                .frame(width: Metrics.meterSlotWidth, height: 16)
            }
        }
        .padding(.leading, Metrics.iconSize + 8)
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
