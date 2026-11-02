import Foundation
import Testing
import TokenMonitorCore

@Suite struct ClaudeParserTests {
    @Test func teamPlanHasOnlySessionWindow() throws {
        let snapshot = try UsageParsers.claude(Fixture.data("claude-usage-team"), now: referenceNow)
        #expect(snapshot.windows.map(\.id) == ["session"])
        #expect(snapshot.windows[0].usedPercent == 13)
        #expect(snapshot.windows[0].label == "5h")
        #expect(snapshot.windows[0].resetsAt == date("2026-11-02T09:30:00Z"))
    }

    @Test func maxPlanUsesLimitsArrayIncludingModelScopedWindows() throws {
        let snapshot = try UsageParsers.claude(Fixture.data("claude-usage-max"), now: referenceNow)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly:opus", "weekly:sonnet"])
        #expect(snapshot.windows.map(\.label) == ["5h", "wk", "Opus wk", "Sonnet wk"])
        #expect(snapshot.mostConstrained?.id == "weekly:opus")
    }

    @Test func proPlanKeepsInactiveSessionAndMapsWeeklyAll() throws {
        let snapshot = try UsageParsers.claude(Fixture.data("claude-usage-pro"), now: referenceNow)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly"])
        #expect(snapshot.windows.map(\.label) == ["5h", "wk"])
        #expect(snapshot.windows.map(\.usedPercent) == [6, 12])
        #expect(snapshot.windows[1].resetsAt == date("2026-11-04T07:59:59Z"))
    }

    @Test func fallsBackToLegacyFields() throws {
        let snapshot = try UsageParsers.claude(Fixture.data("claude-usage-legacy"), now: referenceNow)
        #expect(snapshot.windows.map(\.id) == ["session", "weekly", "weekly:opus"])
        #expect(snapshot.windows[0].usedPercent == 24.5)
        #expect(snapshot.windows[2].resetsAt == nil)
    }

    @Test func rejectsUnrelatedJSON() {
        #expect(throws: ProviderFailure.self) {
            try UsageParsers.claude(Data(#"{"error": "nope"}"#.utf8), now: referenceNow)
        }
        #expect(throws: ProviderFailure.self) {
            try UsageParsers.claude(Data("<html>".utf8), now: referenceNow)
        }
    }
}

@Suite struct CodexParserTests {
    @Test func readsBothWindowsFromLimitMap() throws {
        let snapshot = try UsageParsers.codex(Fixture.data("codex-ratelimits"), now: referenceNow)
        #expect(snapshot.plan == "plus")
        #expect(snapshot.windows.map(\.label) == ["5h", "wk"])
        #expect(snapshot.windows.map(\.usedPercent) == [10, 27])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_612_059))
    }

    @Test func toleratesMissingSecondaryAndUnknownPlan() throws {
        let snapshot = try UsageParsers.codex(Fixture.data("codex-single"), now: referenceNow)
        #expect(snapshot.plan == "prolite")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].usedPercent == 100)
    }
}

@Suite struct AntigravityParserTests {
    @Test func convertsRemainingToUsedPerBucket() throws {
        let snapshot = try UsageParsers.antigravity(Fixture.data("agy-usage"), now: referenceNow)
        #expect(snapshot.windows.count == 5)
        let gemini5h = try #require(snapshot.windows.first { $0.id == "gemini-5h" })
        #expect(gemini5h.group == "Gemini Models")
        #expect(gemini5h.label == "5h")
        #expect(abs(gemini5h.usedPercent - 2.48311758) < 0.0001)
        #expect(snapshot.windows.first { $0.id == "3p-weekly" }?.usedPercent == 0)
        #expect(Set(snapshot.windows.compactMap(\.group)) == ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
    }

    @Test func refusesAReplyThatSpentATurn() {
        #expect(throws: ProviderFailure.self) {
            try UsageParsers.antigravity(Fixture.data("agy-prompt-reply"), now: referenceNow)
        }
        #expect(!UsageParsers.antigravityAnsweredAsCommand(Fixture.data("agy-prompt-reply")))
        #expect(UsageParsers.antigravityAnsweredAsCommand(Fixture.data("agy-usage")))
    }

    @Test func requiresAnExplicitZeroTurnCount() {
        let noTurns = Data(#"{"command": {"name": "usage", "data": {"groups": []}}}"#.utf8)
        #expect(!UsageParsers.antigravityAnsweredAsCommand(noTurns))
    }
}

@Suite struct OpenRouterParserTests {
    @Test func readsSpendAndLimit() throws {
        let snapshot = try UsageParsers.openRouter(Fixture.data("openrouter-key"), now: referenceNow)
        let money = try #require(snapshot.money)
        #expect(money.spent == Decimal(string: "17.55"))
        #expect(money.limit == 50)
        #expect(money.remaining == Decimal(string: "32.45"))
        #expect(money.spentToday == Decimal(string: "1.2"))
        #expect(abs((money.usedPercent ?? 0) - 35.1) < 0.0001)
        #expect(snapshot.windows.count == 1)
    }

    @Test func percentUsesCurrentLimitPeriodNotLifetimeSpend() throws {
        let json = #"{"data": {"usage": 200, "limit": 50, "limit_remaining": 40, "limit_reset": "monthly"}}"#
        let snapshot = try UsageParsers.openRouter(Data(json.utf8), now: referenceNow)
        #expect(snapshot.money?.usedPercent == 20)
        #expect(snapshot.money?.limitReset == "monthly")
        #expect(snapshot.money?.spent == 200)
    }

    @Test func nullLimitMeansUncappedNotZero() throws {
        let snapshot = try UsageParsers.openRouter(Fixture.data("openrouter-key-unlimited"), now: referenceNow)
        #expect(snapshot.money?.limit == nil)
        #expect(snapshot.money?.usedPercent == nil)
        #expect(snapshot.windows.isEmpty)
    }

    @Test func readsAccountCredits() throws {
        let credits = try UsageParsers.openRouterCredits(Fixture.data("openrouter-credits"))
        #expect(credits.purchased == 40)
        #expect(credits.used == Decimal(string: "23.190883689"))
    }
}
