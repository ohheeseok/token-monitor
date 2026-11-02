import Foundation
import Testing
import TokenMonitorCore

@Suite struct PresentationTests {
    let policy = RefreshPolicy()

    func window(_ id: String, group: String? = nil, used: Double, minutes: Int?) -> UsageWindow {
        UsageWindow(id: id, label: minutes == 300 ? "5h" : "wk", group: group, usedPercent: used,
                    resetsAt: referenceNow.addingTimeInterval(3600), windowMinutes: minutes)
    }

    @Test func countdownMatchesOrcaStyle() {
        #expect(UsageFormat.countdown(to: referenceNow.addingTimeInterval(59 * 60), now: referenceNow) == "59m")
        #expect(UsageFormat.countdown(to: referenceNow.addingTimeInterval(4 * 3600 + 59 * 60), now: referenceNow) == "4h 59m")
        #expect(UsageFormat.countdown(to: referenceNow.addingTimeInterval(5 * 86400 + 17 * 3600), now: referenceNow) == "5d 17h")
        #expect(UsageFormat.countdown(to: referenceNow.addingTimeInterval(-10), now: referenceNow) == "곧")
    }

    @Test func percentFormatting() {
        #expect(UsageFormat.percent(0) == "0%")
        #expect(UsageFormat.percent(0.4) == "<1%")
        #expect(UsageFormat.percent(24.6) == "25%")
        #expect(UsageFormat.percent(130) == "130%")
    }

    @Test func groupNamesDropTrailingModels() {
        #expect(UsageFormat.groupName("Claude and GPT models") == "Claude and GPT")
        #expect(UsageFormat.groupName("Gemini 4 Argon") == "Gemini 4 Argon")
    }

    @Test func loneWeeklyWindowUsesTheWeeklySlot() {
        let lines = AccountPresentation.lines([window("argon", group: "Gemini 4 Argon", used: 1, minutes: 10080)])
        #expect(lines.count == 1)
        #expect(lines[0].slots.count == 2)
        #expect(lines[0].slots[0] == nil)
        #expect(lines[0].slots[1]?.id == "argon")
    }

    @Test func ungroupedWindowsGoTwoPerLineShortestFirst() {
        let lines = AccountPresentation.lines([
            window("weekly", used: 10, minutes: 10080), window("session", used: 5, minutes: 300),
            window("weekly:opus", used: 50, minutes: 10080),
        ])
        #expect(lines.map { $0.slots.map { $0?.id } } == [["session", "weekly"], ["weekly:opus", nil]])
    }

    @Test func failureWithoutDataShowsStatusInsteadOfNumbers() {
        var state = AccountState()
        state.failure = .expiredCredentials
        let account = AccountConfig(id: "c", kind: .claude, label: "Claude")
        let item = AccountPresentation.make(account: account, state: state, policy: policy, now: referenceNow)
        #expect(item.subtitle == "로그인 만료")
        #expect(!item.hasData)
        #expect(item.compactPercent == nil)
    }

    @Test func compactShowsTightestWindowAndSeverity() {
        var state = AccountState()
        state.lastGood = UsageSnapshot(windows: [window("s", used: 20, minutes: 300), window("w", used: 93, minutes: 10080)],
                                       fetchedAt: referenceNow)
        state.lastSuccessAt = referenceNow
        let account = AccountConfig(id: "c", kind: .claude, label: "Claude")
        let item = AccountPresentation.make(account: account, state: state, policy: policy, now: referenceNow)
        #expect(item.compactPercent == "93%")
        #expect(item.compactSeverity == .critical)
        #expect(item.resetText == "1h 후 초기화")
        #expect(!item.isStale)
    }

    @Test func openRouterLeadsWithAccountBalance() {
        var state = AccountState()
        state.lastGood = UsageSnapshot(money: MoneyUsage(
            currency: "USD", spent: Decimal(string: "23.16")!, limit: nil, remaining: nil,
            creditsPurchased: 40, creditsUsed: Decimal(string: "23.19")!
        ), fetchedAt: referenceNow)
        state.lastSuccessAt = referenceNow
        let account = AccountConfig(id: "o", kind: .openRouter, label: "OpenRouter")
        let item = AccountPresentation.make(account: account, state: state, policy: policy, now: referenceNow)
        #expect(item.compactTrailing == "$16.81 남음")
        #expect(item.moneyLines == ["잔액 $16.81 · 충전 $40.00", "이 키 $23.16 사용 · 한도 없음"])
    }
}
