import AppKit
import ServiceManagement
import SwiftUI
import TokenMonitorCore

struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// Snapshot rendering: skip the onAppear refresh so injected demo status stays put.
    var previewOnly = false
    @AppStorage("menuBarStyle") private var menuBarStyle: MenuBarStyle = .icon
    @State private var openRouterKey = ""

    var body: some View {
        Form {
            Section("계정") {
                ForEach(model.accounts) { account in
                    AccountRow(model: model, account: account)
                }
                Button {
                    model.addClaudeAccount()
                } label: {
                    Label("Claude 계정 추가…", systemImage: "plus")
                }
            }

            Section {
                HStack {
                    SecureField("API 키", text: $openRouterKey, prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("저장", action: saveKey).disabled(openRouterKey.isEmpty)
                }
                HStack {
                    KeyStatusText(status: model.openRouterKeyStatus)
                    Spacer()
                    if model.openRouterKeyStatus != .missing, model.openRouterKeyStatus != .unknown {
                        Button("키 삭제", role: .destructive) { Task { await model.deleteOpenRouterKey() } }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                Text("OpenRouter API 키")
            } footer: {
                Text("키는 macOS 키체인에만 저장되고 화면에 다시 표시되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("일반") {
                Toggle("로그인 시 자동 실행", isOn: Binding(
                    get: { model.loginItemStatus == .enabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("시스템 설정에서 허용해야 합니다.").font(.caption).foregroundStyle(.orange)
                        Button("로그인 항목 열기") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                    }
                }
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Picker("메뉴바 표시", selection: $menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 520)
        .onAppear { if !previewOnly { model.refresh() } }
    }

    private func saveKey() {
        let key = openRouterKey
        openRouterKey = ""
        Task { await model.saveOpenRouterKey(key) }
    }
}

private struct AccountRow: View {
    let model: SettingsModel
    let account: AccountConfig
    @State private var label: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProviderIcon(kind: account.kind)
                TextField("이름", text: $label, prompt: Text("이름"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit(commitLabel)
                    .onChange(of: label) { commitLabel() }
                Spacer()
                Toggle("표시", isOn: Binding(
                    get: { account.enabled },
                    set: { var copy = account; copy.enabled = $0; model.update(copy) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                Menu {
                    Button("위로") { model.move(account.id, by: -1) }
                    Button("아래로") { model.move(account.id, by: 1) }
                    if account.kind == .claude {
                        Divider()
                        Button("삭제", role: .destructive) { model.remove(account.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if account.kind == .claude {
                ClaudeDetails(model: model, account: account)
                    .padding(.leading, 38)
            }
        }
        .onAppear { label = account.label }
        .onChange(of: account.label) { label = account.label }
    }

    private func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.label else { return }
        var copy = account
        copy.label = trimmed
        model.update(copy)
    }
}

private struct ClaudeDetails: View {
    let model: SettingsModel
    let account: AccountConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.claudeConfigDir ?? "~/.claude (기본)")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch model.claudeStatus[account.id] {
                case .found?: Label("로그인됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing?: Label("로그인 정보 없음", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                default: ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 11))
            if model.claudeStatus[account.id] == .missing {
                HStack(spacing: 6) {
                    Text("터미널에서 실행 후 /login:").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.loginCommand(for: account))
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.loginCommand(for: account), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("명령 복사")
                }
            }
        }
    }
}

private struct KeyStatusText: View {
    let status: SettingsModel.KeyStatus

    var body: some View {
        switch status {
        case .unknown: Text("확인 중…").foregroundStyle(.secondary)
        case .missing: Text("저장된 키 없음").foregroundStyle(.secondary)
        case .saved: Label("키가 저장되어 있음", systemImage: "key.fill").foregroundStyle(.secondary)
        case .checking: HStack { ProgressView().controlSize(.mini); Text("확인 중…") }.foregroundStyle(.secondary)
        case .verified(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
