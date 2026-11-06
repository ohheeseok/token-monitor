import SwiftUI
import TokenMonitorCore

/// Everything the popover needs from the app, so the view can be rendered with demo data too.
@MainActor
struct PopoverActions {
    var refresh: () -> Void
    var openDashboard: (ProviderKind) -> Void
    var manageAccounts: () -> Void
    var quit: () -> Void
}

struct PopoverView: View {
    let store: UsageStore
    let actions: PopoverActions
    var now: () -> Date = Date.init
    @AppStorage("displayMode") private var mode: DisplayMode = .detail

    var body: some View {
        // Re-evaluate countdowns every 30 s while the popover is visible.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            content(items: items)
        }
        .frame(width: Metrics.popoverWidth)
    }

    private var items: [AccountPresentation] {
        AccountPresentation.makeAll(store: store, now: now())
    }

    private func content(items: [AccountPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("사용량").font(.system(size: 15, weight: .semibold))
                Spacer()
                RefreshButton(spinning: items.contains(where: \.isRefreshing), action: actions.refresh)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, 14)

            ModePicker(mode: $mode)
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().opacity(0.6).padding(.bottom, 4)

            if items.isEmpty {
                Text("표시할 계정이 없습니다.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(Metrics.horizontalPadding)
            }
            ForEach(items) { item in
                switch mode {
                case .compact: CompactRow(item: item) { actions.openDashboard(item.kind) }
                case .detail: DetailCard(item: item) { actions.openDashboard(item.kind) }
                }
            }

            Divider().opacity(0.6).padding(.top, 4)
            DashboardMenu(open: actions.openDashboard)
            FooterRow(title: "계정 관리…", action: actions.manageAccounts)
            FooterRow(title: "종료", showsChevron: false, secondary: true, action: actions.quit)
                .padding(.bottom, 6)
        }
    }
}

/// "사용량 세부 정보 및 기록": a footer row that opens each provider's own usage page.
private struct DashboardMenu: View {
    let open: (ProviderKind) -> Void

    var body: some View {
        Menu {
            Button("Claude 사용량") { open(.claude) }
            Button("Codex 사용량") { open(.codex) }
            Button("OpenRouter 활동") { open(.openRouter) }
        } label: {
            HStack {
                Text("사용량 세부 정보 및 기록").font(.system(size: 14))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(HoverRowStyle())
        .menuIndicator(.hidden)
    }
}

private struct RefreshButton: View {
    let spinning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: spinning)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("새로고침")
        .accessibilityLabel("새로고침")
    }
}
