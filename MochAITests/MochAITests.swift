import XCTest
@testable import MochAICore

final class SessionReducerTests: XCTestCase {
    func testWorkingDoesNotIncludeWaiting() {
        XCTAssertTrue(AgentState.working.preventsSystemSleep)
        XCTAssertTrue(AgentState.runningCommand.preventsSystemSleep)
        XCTAssertFalse(AgentState.waitingForUser.preventsSystemSleep)
        XCTAssertFalse(AgentState.waitingForPermission.preventsSystemSleep)
        XCTAssertFalse(AgentState.waitingForReset.preventsSystemSleep)
        XCTAssertFalse(AgentState.resuming.preventsSystemSleep)
        XCTAssertFalse(AgentState.completed.preventsSystemSleep)
    }

    func testLifecycleFromHooks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var sessions: [AgentSession] = []
        sessions = SessionReducer.apply(event: event(.sessionStarted, at: start), to: sessions)
        sessions = SessionReducer.apply(event: event(.promptSubmitted, at: start.addingTimeInterval(5)), to: sessions)
        XCTAssertEqual(sessions.first?.state, .working)
        sessions = SessionReducer.apply(event: event(.commandStarted, at: start.addingTimeInterval(20), tool: "test"), to: sessions)
        XCTAssertEqual(sessions.first?.state, .runningCommand)
        sessions = SessionReducer.apply(event: event(.commandFinished, at: start.addingTimeInterval(40), tool: "test"), to: sessions)
        XCTAssertEqual(sessions.first?.state, .working)
        sessions = SessionReducer.apply(event: event(.generationStopped, at: start.addingTimeInterval(50)), to: sessions)
        XCTAssertEqual(sessions.first?.state, .idle)
        XCTAssertEqual(StatusPresentation.headline(sessions: sessions), "Everything's quiet.")
        XCTAssertFalse(sessions[0].preventsSleep)
        let working = sessions[0].workingTime(now: start.addingTimeInterval(50))
        XCTAssertGreaterThan(working, 30)
    }

    func testRateLimitQueuesAndReleasesSleep() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3 * 3600)
        var sessions = SessionReducer.apply(event: event(.promptSubmitted, at: now), to: [])
        sessions = SessionReducer.apply(event: NormalizedEvent(
            provider: .claude,
            kind: .rateLimitReached,
            sessionID: "s1",
            cwd: "/tmp/project",
            timestamp: now.addingTimeInterval(10),
            resetAt: reset,
            errorCode: "rate_limit"
        ), to: sessions)
        XCTAssertEqual(sessions.first?.state, .waitingForReset)
        XCTAssertFalse(sessions[0].state.preventsSystemSleep)
        XCTAssertEqual(sessions[0].limit?.resetAt, reset)
        XCTAssertEqual(sessions[0].outcome, .limited)
    }

    func testProcessExitDuringWorkFailsAndLimitSurvives() {
        let now = Date()
        var working = SessionReducer.apply(event: event(.promptSubmitted, at: now), to: [])
        working[0].processID = 42
        let failed = SessionReducer.reconcile(sessions: working, processes: [], now: now.addingTimeInterval(5))
        XCTAssertEqual(failed.first?.state, .failed)

        var limited = SessionReducer.apply(event: NormalizedEvent(provider: .codex, kind: .rateLimitReached, sessionID: "c1", timestamp: now), to: [])
        limited[0].processID = 7
        let kept = SessionReducer.reconcile(sessions: limited, processes: [], now: now.addingTimeInterval(5))
        XCTAssertEqual(kept.first?.state, .waitingForReset)
    }

    func testMultipleAgentsStayDistinct() {
        var sessions: [AgentSession] = []
        sessions = SessionReducer.apply(event: NormalizedEvent(provider: .claude, kind: .promptSubmitted, sessionID: "a", cwd: "/repo/a", timestamp: Date()), to: sessions)
        sessions = SessionReducer.apply(event: NormalizedEvent(provider: .codex, kind: .commandStarted, sessionID: "b", cwd: "/repo/b", toolCategory: "test", timestamp: Date()), to: sessions)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.provider)), [.claude, .codex])
    }

    private func event(_ kind: EventKind, at date: Date, tool: String? = nil) -> NormalizedEvent {
        NormalizedEvent(provider: .claude, kind: kind, sessionID: "s1", cwd: "/tmp/project", toolCategory: tool, timestamp: date)
    }
}

@MainActor
final class SleepManagerTests: XCTestCase {
    func testAcquiresAndReleasesASingleAssertion() {
        let power = MockPower()
        let sleep = SleepManager(controller: power)
        let working = makeSession(.working)
        let waiting = makeSession(.waitingForUser)
        sleep.update(sessions: [working, waiting], projects: [], mode: .automatic, until: nil, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 1)
        XCTAssertTrue(sleep.isHolding)
        sleep.update(sessions: [waiting], projects: [], mode: .automatic, until: nil, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 0)
        XCTAssertEqual(power.began, 1)
        XCTAssertEqual(power.ended, 1)
    }

    func testLimitedAgentDoesNotHoldWhileAnotherWorks() {
        let power = MockPower()
        let sleep = SleepManager(controller: power)
        sleep.update(sessions: [makeSession(.waitingForReset), makeSession(.runningTool)], projects: [], mode: .automatic, until: nil, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 1)
        sleep.update(sessions: [makeSession(.waitingForReset)], projects: [], mode: .automatic, until: nil, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 0)
    }

    func testNeverModeAndBatteryPolicy() {
        let power = MockPower()
        let sleep = SleepManager(controller: power)
        sleep.update(sessions: [makeSession(.working)], projects: [], mode: .never, until: nil, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 0)
        sleep.update(sessions: [makeSession(.working)], projects: [], mode: .automatic, until: nil, batteryPolicy: .neverOnBattery, battery: BatterySnapshot(onBattery: true, percent: 80, charging: false))
        XCTAssertEqual(power.active, 0)
        sleep.update(sessions: [makeSession(.working)], projects: [], mode: .automatic, until: nil, batteryPolicy: .aboveTwenty, battery: BatterySnapshot(onBattery: true, percent: 10, charging: false))
        XCTAssertEqual(power.active, 0)
        sleep.update(sessions: [makeSession(.working)], projects: [], mode: .automatic, until: nil, batteryPolicy: .aboveTwenty, battery: BatterySnapshot(onBattery: true, percent: 40, charging: false))
        XCTAssertEqual(power.active, 1)
    }

    func testManualOverrideReleasesWhenExpired() {
        let power = MockPower()
        let sleep = SleepManager(controller: power)
        let until = Date().addingTimeInterval(60)
        sleep.update(sessions: [], projects: [], mode: .thirtyMinutes, until: until, batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 1)
        sleep.update(sessions: [], projects: [], mode: .thirtyMinutes, until: Date().addingTimeInterval(-1), batteryPolicy: .always, battery: .pluggedIn)
        XCTAssertEqual(power.active, 0)
    }

    private func makeSession(_ state: AgentState) -> AgentSession {
        var session = AgentSession(provider: .claude, state: state, lastEventSummary: state.label, startedAt: Date(), lastActivityAt: Date())
        session.preventsSleep = state.preventsSystemSleep
        return session
    }
}

final class MockPower: PowerAssertionControlling {
    var began = 0
    var ended = 0
    var active = 0
    func begin(reason: String) -> PowerToken {
        began += 1
        active += 1
        return PowerToken()
    }
    func end(_ token: PowerToken) {
        ended += 1
        active -= 1
    }
}

final class UsageAndLimitTests: XCTestCase {
    func testCodexRateLimitShape() throws {
        let json = """
        {"primary":{"used_percent":78,"window_minutes":300,"resets_at":1791156477},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":1791597635}}
        """.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let usage = CodexUsageParser.parse(rateLimits: object, updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage?.confidence, .providerReported)
        XCTAssertEqual(usage?.windows.map(\.name), ["5-hour allowance", "Weekly"])
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 0.78, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[0].resetAt, Date(timeIntervalSince1970: 1_791_156_477))
    }

    func testCodexLiveUsageKeepsWeeklyAndSparkSeparate() throws {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":97,"reset_at":1791192662,"limit_window_seconds":18000},"secondary_window":{"used_percent":91,"reset_at":1791597635,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":12,"reset_at":1791192662,"limit_window_seconds":18000},"secondary_window":{"used_percent":4,"reset_at":1791597635,"limit_window_seconds":604800}}}]}
        """.data(using: .utf8)!
        let usage = try XCTUnwrap(CodexLiveUsageParser.parse(json, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(usage.allowanceWindows().map(\.name), ["5-hour allowance", "Weekly", "Spark 5-hour", "Spark weekly"])
        XCTAssertEqual(usage.windows[0].headline(reading: .remaining), "3% left")
        XCTAssertEqual(usage.windows[1].headline(reading: .remaining), "9% left")
        XCTAssertEqual(usage.windows[2].resolvedUsed ?? 0, 0.12, accuracy: 0.001)
    }

    func testClaudeLiveUsageReadsFractionsAndModelWindows() throws {
        let json = """
        {"five_hour":{"utilization":0.235,"resets_at":"2026-02-01T12:00:00Z"},"seven_day":{"utilization":41.2,"resets_at":"2026-02-06T12:00:00Z"},"seven_day_sonnet":{"utilization":10,"resets_at":"2026-02-06T12:00:00Z"}}
        """.data(using: .utf8)!
        let usage = try XCTUnwrap(ClaudeLiveUsageParser.parse(json, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(usage.allowanceWindows().map(\.name), ["5-hour allowance", "Weekly", "Sonnet"])
        XCTAssertEqual(usage.windows[0].resolvedUsed ?? 0, 0.235, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].resolvedUsed ?? 0, 0.412, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].headline(reading: .remaining), "77% left")
    }

    func testTokenCostPricesClaudeAndCodexDifferently() throws {
        let rate = ModelRate(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2)
        let tokens = TokenCounts(input: 1_000_000, output: 0, cacheRead: 200_000, cacheWrite: 0)
        XCTAssertEqual(TokenCostScanner.price(tokens, rate: rate, provider: .claude), 2.04, accuracy: 0.001)
        XCTAssertEqual(TokenCostScanner.price(tokens, rate: rate, provider: .codex), 1.64, accuracy: 0.001)

        let catalog = TokenCostCatalog(providers: ["anthropic": ["claude-sonnet-4-5": rate]])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochai-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = #"{"timestamp":"2026-10-08T04:00:00Z","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":200000}}}"#
        let old = #"{"timestamp":"2026-09-01T04:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":5000000}}}"#
        try Data((line + "\n" + old + "\n").utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let cost = try XCTUnwrap(TokenCostScanner.monthToDate(
            provider: .claude,
            directory: directory,
            catalog: catalog,
            now: ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        ))
        XCTAssertEqual(cost.usd, 2.04, accuracy: 0.001)
        XCTAssertEqual(cost.line, "This month · about $2.04")
    }

    func testCodexCostUsesTheLatestTurnNotTheRunningTotal() throws {
        let rate = ModelRate(input: 1, output: 4, cacheRead: 0.1, cacheWrite: nil)
        let catalog = TokenCostCatalog(providers: ["openai": ["gpt-5.4": rate]])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochai-codex-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = #"{"timestamp":"2026-10-08T04:00:00Z","model":"gpt-5.4","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000000,"output_tokens":9000000},"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":0,"output_tokens":0}}}}"#
        try Data(line.utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let cost = try XCTUnwrap(TokenCostScanner.monthToDate(
            provider: .codex,
            directory: directory,
            catalog: catalog,
            now: ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        ))
        XCTAssertEqual(cost.usd, 1, accuracy: 0.001)
    }

    func testCodexCostFindsTheModelOnAnEarlierLine() throws {
        let rate = ModelRate(input: 1, output: 4, cacheRead: 0.1, cacheWrite: 0.2)
        let catalog = TokenCostCatalog(providers: ["openai": ["gpt-6-astra": rate]])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochai-codex-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = [
            #"{"timestamp":"2026-10-08T01:00:00Z","type":"turn_context","payload":{"model":"gpt-6-astra"}}"#,
            #"{"timestamp":"2026-10-08T04:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":200000,"output_tokens":0,"cache_write_input_tokens":0}}}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let cost = try XCTUnwrap(TokenCostScanner.monthToDate(
            provider: .codex,
            directory: directory,
            catalog: catalog,
            now: ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!
        ))
        XCTAssertEqual(cost.usd, 0.82, accuracy: 0.001)
        XCTAssertTrue(cost.line.hasPrefix("This month · about "))
    }

    func testCursorMonthlyPools() throws {
        let json = """
        {"billingCycleEnd":"1771077734000","planUsage":{"autoPercentUsed":12.5,"apiPercentUsed":40}}
        """.data(using: .utf8)!
        let usage = CursorUsageParser.parse(json, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage?.windows.map(\.name), ["Cursor models", "Other models"])
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 0.125, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[1].resolvedUsed ?? 0, 0.40, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[0].resetAt, Date(timeIntervalSince1970: 1_771_077_734))
        XCTAssertEqual(usage?.allowanceWindows().map(\.shortLabel), ["Cursor models", "Other models"])
        XCTAssertEqual(usage?.windows[0].headline(reading: .remaining), "88% left")
        XCTAssertEqual(ProviderID.cursor.allowanceReading, .remaining)
    }

    func testCursorOnDemandAndTeamCap() throws {
        let onDemand = """
        {"billingCycleEnd":"1771077734000","individualUsage":{"plan":{"autoPercentUsed":20,"apiPercentUsed":0},"onDemand":{"enabled":true,"used":500,"limit":2000}}}
        """.data(using: .utf8)!
        let usage = try XCTUnwrap(CursorUsageParser.parse(onDemand, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(usage.windows.map(\.name), ["Cursor models", "Other models", "On-demand"])
        XCTAssertEqual(usage.windows[2].resolvedUsed ?? 0, 0.25, accuracy: 0.001)

        let team = """
        {"billingCycleEnd":"1771077734000","individualUsage":{"overall":{"enabled":true,"used":2500,"limit":10000}}}
        """.data(using: .utf8)!
        let capped = try XCTUnwrap(CursorUsageParser.parse(team, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(capped.windows.map(\.name), ["Included"])
        XCTAssertEqual(capped.windows[0].headline(reading: .remaining), "75% left")

        let spend = """
        {"billingCycleEnd":"1771077734000","individualUsage":{"plan":{"used":7384,"autoPercentUsed":20,"apiPercentUsed":0},"onDemand":{"enabled":true,"used":500,"limit":2000}}}
        """.data(using: .utf8)!
        let priced = try XCTUnwrap(CursorUsageParser.parse(spend, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(priced.tokenCost?.usd ?? 0, 78.84, accuracy: 0.001)
        XCTAssertEqual(priced.tokenCost?.line, "This cycle · $78.84")
    }

    func testTailIgnoresEarlierObjects() {
        let text = #"{"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":10}}} trailing {"rate_limits":{"primary":{"used_percent":63,"window_minutes":300,"resets_at":20}}}"#
        let usage = CodexUsageParser.parseTail(Data(text.utf8), updatedAt: Date())
        XCTAssertEqual(usage?.windows.first?.resolvedUsed ?? 0, 0.63, accuracy: 0.001)
    }

    func testLimitExceededAfterPercentCountsAsReached() {
        let text = #"{"rate_limits":{"primary":{"used_percent":97,"window_minutes":300,"resets_at":1791192662},"secondary":{"used_percent":91,"window_minutes":10080,"resets_at":1791597635}}}{"error":{"codex_error_info":"usage_limit_exceeded"}}"#
        let usage = CodexUsageParser.parseTail(Data(text.utf8), updatedAt: Date())
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[1].resolvedUsed ?? 0, 0.91, accuracy: 0.001)
        XCTAssertEqual(usage?.detail, "Codex reported the 5-hour limit is reached.")
    }

    func testOlderLimitErrorDoesNotOverrideANewerPercent() {
        let text = #"{"error":{"codex_error_info":"usage_limit_exceeded"}}{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":20}}}"#
        let usage = CodexUsageParser.parseTail(Data(text.utf8), updatedAt: Date())
        XCTAssertEqual(usage?.windows.first?.resolvedUsed ?? 0, 0.40, accuracy: 0.001)
    }

    func testTailSkipsEmptyLimitAfterRealWindows() {
        let text = #"{"rate_limits":{"primary":{"used_percent":96,"window_minutes":300,"resets_at":1791156477},"secondary":{"used_percent":73,"window_minutes":10080,"resets_at":1791597635}}}{"rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}"#
        let usage = CodexUsageParser.parseTail(Data(text.utf8), updatedAt: Date())
        XCTAssertEqual(usage?.windows.map(\.name), ["5-hour allowance", "Weekly"])
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 0.96, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[1].resolvedUsed ?? 0, 0.73, accuracy: 0.001)
    }

    func testUsageIsFoundBeyondTheFirstHalfMegabyte() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochai-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        var data = Data(#"{"rate_limits":{"plan_type":"plus","primary":{"used_percent":96,"window_minutes":300,"resets_at":1791156477},"secondary":{"used_percent":73,"window_minutes":10080,"resets_at":1791597635}}}"#.utf8)
        data.append(Data(repeating: 0x20, count: 700_000))
        data.append(Data(#"{"rate_limits":{"primary":null,"secondary":null}}"#.utf8))
        try data.write(to: file)
        let usage = CodexMetadata.currentUsage(sessionsDirectory: directory, now: Date(timeIntervalSince1970: 1_791_150_000))
        XCTAssertEqual(usage.windows.map(\.name), ["5-hour allowance", "Weekly"])
        XCTAssertEqual(usage.confidence, .providerReported)
    }

    func testDoesNotInventUsageFromProse() {
        XCTAssertNil(UsageTextParser.parse(providerText: "Claude is thinking about the keyboard bug"))
    }

    func testParsesExplicitStatusText() {
        let usage = UsageTextParser.parse(providerText: "5-hour allowance 22% remaining\nWeekly 44% used", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(usage?.windows.count, 2)
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 0.78, accuracy: 0.001)
        XCTAssertEqual(usage?.confidence, .providerReported)
    }

    func testLimitDetectorReadsResetWithoutStoringAPrompt() {
        let signal = LimitDetector.signal(errorCode: "rate_limit", message: "API Error: Rate limit reached. Try again at 3:00 AM", now: date(hour: 1))
        XCTAssertEqual(signal?.errorCode, "rate_limit")
        let reset = try! XCTUnwrap(signal?.resetAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(calendar.component(.hour, from: reset), 3)
        XCTAssertNil(LimitDetector.signal(errorCode: "server_error", message: "temporary outage"))
    }

    func testRelativeReset() {
        let now = Date(timeIntervalSince1970: 10_000)
        let reset = LimitDetector.parseReset(in: "available in 2h 17m", now: now)
        XCTAssertEqual(reset, now.addingTimeInterval(2 * 3600 + 17 * 60))
    }

    private func date(hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: hour, minute: 0))!
    }
}

final class ResetAndResumeTests: XCTestCase {
    func testRetryOffsetsThenStop() {
        let reset = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ResetSchedule.nextAttemptDate(attempt: 0, resetAt: reset), reset)
        XCTAssertEqual(ResetSchedule.nextAttemptDate(attempt: 1, resetAt: reset), reset.addingTimeInterval(15))
        XCTAssertEqual(ResetSchedule.nextAttemptDate(attempt: 2, resetAt: reset), reset.addingTimeInterval(60))
        XCTAssertEqual(ResetSchedule.nextAttemptDate(attempt: 3, resetAt: reset), reset.addingTimeInterval(180))
        XCTAssertEqual(ResetSchedule.nextAttemptDate(attempt: 4, resetAt: reset), reset.addingTimeInterval(300))
        XCTAssertNil(ResetSchedule.nextAttemptDate(attempt: 5, resetAt: reset))
    }

    func testDoesNotResumeWhenUsageStillLimited() {
        let usage = ProviderUsage(windows: [UsageWindow(name: "5-hour allowance", usedFraction: 1, resetAt: Date().addingTimeInterval(3600))], updatedAt: Date(), confidence: .providerReported)
        let decision = ResetCoordinator.decide(attempt: 0, resetAt: Date().addingTimeInterval(-10), usage: usage, resume: ResumeDecision(mode: .automatic, automaticAllowed: true), now: Date())
        guard case .stillLimited = decision.action else {
            return XCTFail("expected to keep waiting")
        }
    }

    func testUnknownUsageDoesNotAutoResume() {
        let decision = ResetCoordinator.decide(
            attempt: 0,
            resetAt: Date().addingTimeInterval(-5),
            usage: .unavailable(at: Date(), detail: "none"),
            resume: ResumeDecision(mode: .automatic, automaticAllowed: true),
            now: Date()
        )
        XCTAssertEqual(decision.action, .unconfirmed)
    }

    func testMenuShowsOneWindowPerProvider() {
        let usage = ProviderUsage(
            windows: [
                UsageWindow(name: "5-hour allowance", usedFraction: 0.4, resetAt: Date().addingTimeInterval(3600)),
                UsageWindow(name: "Weekly", usedFraction: 0.7, resetAt: Date().addingTimeInterval(86_400))
            ],
            updatedAt: Date(),
            confidence: .providerReported
        )
        XCTAssertEqual(usage.featuredWindow()?.name, "5-hour allowance")
        XCTAssertEqual(usage.allowanceWindows().map(\.name), ["5-hour allowance", "Weekly"])
    }

    func testCodexWeeklyIsShownAsWhatIsLeft() {
        let now = Date()
        let weekly = UsageWindow(name: "Weekly", usedFraction: 0.91, resetAt: now.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(weekly.headline(reading: .remaining), "9% left")
        XCTAssertTrue(weekly.menuLine(at: now, reading: .remaining).hasPrefix("9% left · "))
        let fiveHour = UsageWindow(name: "5-hour allowance", usedFraction: 1, resetAt: now.addingTimeInterval(3600))
        XCTAssertTrue(fiveHour.menuLine(at: now, reading: .remaining).hasPrefix("Limit reached"))
        XCTAssertEqual(ProviderID.codex.allowanceReading, .remaining)
        XCTAssertEqual(ProviderID.claude.allowanceReading, .remaining)
    }

    func testCountdownUsesDaysPastTwentyFourHours() {
        XCTAssertEqual(MochaiFormat.countdown(23 * 3600 + 30 * 60), "23h 30m")
        XCTAssertEqual(MochaiFormat.countdown(24 * 3600), "1d")
        XCTAssertEqual(MochaiFormat.countdown(4 * 86_400 + 21 * 3600), "4d 21h")
        XCTAssertEqual(MochaiFormat.duration(50 * 3600), "2d 2h")
    }

    func testPermissionBannerClearsWhenTheAllowanceIsSpent() {
        let now = Date()
        var sessions = SessionReducer.apply(
            event: NormalizedEvent(provider: .codex, kind: .permissionRequested, sessionID: "c1", timestamp: now.addingTimeInterval(-60)),
            to: []
        )
        XCTAssertEqual(sessions.first?.state, .waitingForPermission)
        let spent = ProviderUsage(
            windows: [UsageWindow(name: "5-hour allowance", usedFraction: 1, resetAt: now.addingTimeInterval(3600))],
            updatedAt: now,
            confidence: .providerReported
        )
        let released = SessionReducer.releaseExhaustedAttention(sessions: sessions, usage: [.codex: spent], now: now)
        XCTAssertEqual(released.first?.state, .waitingForReset)
        XCTAssertEqual(StatusPresentation.headline(sessions: released), "Codex is taking a quota nap.")

        sessions = SessionReducer.apply(
            event: NormalizedEvent(provider: .codex, kind: .permissionRequested, sessionID: "c2", timestamp: now),
            to: []
        )
        let open = ProviderUsage(
            windows: [UsageWindow(name: "5-hour allowance", usedFraction: 0.4, resetAt: now.addingTimeInterval(3600))],
            updatedAt: now,
            confidence: .providerReported
        )
        let kept = SessionReducer.releaseExhaustedAttention(sessions: sessions, usage: [.codex: open], now: now)
        XCTAssertEqual(kept.first?.state, .waitingForPermission)
        XCTAssertEqual(StatusPresentation.headline(sessions: kept), "Codex needs you.")
    }

    func testFinishedTurnIsNotAnApprovalRequest() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var sessions = SessionReducer.apply(
            event: NormalizedEvent(provider: .codex, kind: .generationStopped, sessionID: "c1", timestamp: now),
            to: []
        )
        XCTAssertEqual(sessions.first?.state, .idle)
        XCTAssertNotEqual(StatusPresentation.headline(sessions: sessions), "Codex needs you.")

        sessions = [AgentSession(provider: .codex, state: .waitingForUser, outcome: .ongoing, lastEventSummary: "Waiting for you", startedAt: now, lastActivityAt: now)]
        let cleared = SessionReducer.releaseFinishedTurns(sessions: sessions, now: now.addingTimeInterval(5))
        XCTAssertEqual(cleared.first?.state, .idle)
        XCTAssertEqual(StatusPresentation.headline(sessions: cleared), "Everything's quiet.")
    }

    func testPastResetIsNotTreatedAsTheCurrentAllowance() {
        let now = Date()
        let usage = ProviderUsage(
            windows: [UsageWindow(name: "5-hour allowance", usedFraction: 0.96, resetAt: now.addingTimeInterval(-60))],
            updatedAt: now.addingTimeInterval(-3600),
            confidence: .providerReported
        )
        XCTAssertFalse(usage.windows[0].isCurrent(at: now))
        XCTAssertEqual(AvailabilityCheck.evaluate(usage: usage, now: now), .unknown)
    }

    func testConfirmedUsageCanAutoResume() {
        let usage = ProviderUsage(windows: [UsageWindow(name: "5-hour allowance", usedFraction: 0.2)], updatedAt: Date(), confidence: .providerReported)
        let decision = ResetCoordinator.decide(attempt: 0, resetAt: Date().addingTimeInterval(-5), usage: usage, resume: ResumeDecision(mode: .automatic, automaticAllowed: true), now: Date())
        XCTAssertEqual(decision.action, .ready(automatic: true))
    }

    func testSensitiveProjectAsksEvenIfGlobalIsAutomatic() {
        let decision = ResumePolicy.evaluate(ResumeContext(globalMode: .automatic, sensitiveProject: true))
        XCTAssertEqual(decision.mode, .ask)
        XCTAssertFalse(decision.automaticAllowed)
    }

    func testExplicitProjectOverrideWins() {
        let decision = ResumePolicy.evaluate(ResumeContext(globalMode: .ask, projectMode: .notifyOnly))
        XCTAssertEqual(decision.mode, .notifyOnly)
        XCTAssertFalse(decision.automaticAllowed)
    }

    func testBlocksMissingRepositoryAndCancellation() {
        XCTAssertNotNil(ResumePolicy.blockReason(ResumeContext(globalMode: .automatic, repositoryExists: false)))
        XCTAssertNotNil(ResumePolicy.blockReason(ResumeContext(globalMode: .automatic, manuallyCancelled: true)))
        XCTAssertNotNil(ResumePolicy.blockReason(ResumeContext(globalMode: .automatic, providerLimited: true)))
        let allowed = ResumePolicy.evaluate(ResumeContext(globalMode: .automatic))
        XCTAssertTrue(allowed.automaticAllowed)
    }
}

final class HookConfigTests: XCTestCase {
    func testMergesWithoutRemovingUserHooks() throws {
        let original = """
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo stay"}]}]}}
        """.data(using: .utf8)!
        let plan = HookInstallPlan(events: ["PreToolUse", "Stop"], command: "/tmp/mochai-hook --provider claude", marker: "mochai-hook")
        let merged = try ConfigMerger.mergeHooks(into: original, plan: plan)
        let object = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        XCTAssertEqual(object["model"] as? String, "opus")
        let hooks = object["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        let commands = pre.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["command"] as? String } }
        XCTAssertTrue(commands.contains("echo stay"))
        XCTAssertTrue(commands.contains("/tmp/mochai-hook --provider claude"))
        XCTAssertNotNil(hooks["Stop"])
    }

    func testStatusLineWrapsAnExistingCommandAndRestoresIt() throws {
        let original = """
        {"theme":"dark","statusLine":{"type":"command","command":"echo stay","padding":2}}
        """.data(using: .utf8)!
        let plan = HookInstallPlan(
            events: ["Stop"],
            command: "/tmp/mochai-hook --provider claude",
            marker: "mochai-hook",
            statusLineCommand: "/tmp/mochai-hook --statusline"
        )
        let merged = try ConfigMerger.mergeHooks(into: original, plan: plan)
        let object = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        XCTAssertEqual(object["theme"] as? String, "dark")
        let status = object["statusLine"] as! [String: Any]
        XCTAssertEqual(status["command"] as? String, "/tmp/mochai-hook --statusline --then 'echo stay'")
        XCTAssertEqual(status["padding"] as? Int, 2)
        let stripped = try ConfigMerger.removeHooks(from: merged, marker: "mochai-hook")
        let restored = try JSONSerialization.jsonObject(with: stripped) as! [String: Any]
        let restoredStatus = restored["statusLine"] as! [String: Any]
        XCTAssertEqual(restoredStatus["command"] as? String, "echo stay")
        XCTAssertEqual(restored["theme"] as? String, "dark")
    }

    func testClaudeRateLimitsBecomeBothWindows() throws {
        let json = """
        {"updatedAt":1738420000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":"2026-02-06T12:00:00Z"}}}
        """.data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: json)
        let usage = ClaudeUsageReader.decode(object, updatedAt: Date(timeIntervalSince1970: 1_738_420_100))
        XCTAssertEqual(usage?.confidence, .providerReported)
        XCTAssertEqual(usage?.windows.map(\.name), ["5-hour allowance", "Weekly"])
        XCTAssertEqual(usage?.windows[0].resolvedUsed ?? 0, 0.235, accuracy: 0.001)
        XCTAssertEqual(usage?.windows[0].resetAt, Date(timeIntervalSince1970: 1_738_425_600))
        XCTAssertNotNil(usage?.windows[1].resetAt)
    }

    func testRemovalKeepsUnrelatedHooks() throws {
        let original = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/tmp/mochai-hook --provider codex"},{"type":"command","command":"echo mine"}]}]}}
        """.data(using: .utf8)!
        let stripped = try ConfigMerger.removeHooks(from: original, marker: "mochai-hook")
        let text = String(data: stripped, encoding: .utf8)!
        XCTAssertFalse(text.contains("mochai-hook"))
        XCTAssertTrue(text.contains("echo mine"))
    }

    func testInstallRestoresBackupWhenResultWouldBeInvalid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("settings.json")
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try original.write(to: config)
        let plan = HookInstallPlan(events: ["Stop"], command: "/opt/mochai-hook", marker: "mochai-hook")
        _ = try HookInstaller.install(configURL: config, plan: plan, backupDirectory: directory.appendingPathComponent("backups"))
        let installed = try Data(contentsOf: config)
        XCTAssertTrue(ConfigMerger.containsMarker(installed, marker: "mochai-hook"))
        let theme = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
        XCTAssertEqual(theme["theme"] as? String, "dark")
        try HookInstaller.uninstall(configURL: config, marker: "mochai-hook", createdFile: false, backupDirectory: directory.appendingPathComponent("backups"))
        let removed = try String(contentsOf: config)
        XCTAssertFalse(removed.contains("mochai-hook"))
        XCTAssertTrue(removed.contains("dark"))
    }

    func testEventTranslationDropsUnknownAndHugeFields() {
        let good = """
        {"version":1,"provider":"claude","event":"tool_started","session_id":"abc","cwd":"/tmp/demo","tool_category":"edit","timestamp":"2026-10-05T01:00:00Z"}
        """.data(using: .utf8)!
        let event = HookEventTranslator.translate(good)
        XCTAssertEqual(event?.kind, .toolStarted)
        XCTAssertEqual(event?.sessionID, "abc")
        let rejected = #"{"version":1,"provider":"claude","event":"eval","cwd":"relative"}"#.data(using: .utf8)!
        XCTAssertNil(HookEventTranslator.translate(rejected))
    }

    func testDuplicateEventsCollapse() {
        var dedup = EventDeduplicator(window: 2)
        let event = NormalizedEvent(provider: .codex, kind: .toolStarted, sessionID: "1", timestamp: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(dedup.accept(event, now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(dedup.accept(event, now: Date(timeIntervalSince1970: 101)))
        XCTAssertTrue(dedup.accept(event, now: Date(timeIntervalSince1970: 104)))
    }
}

@MainActor
final class PersistenceTests: XCTestCase {
    func testMemoryRoundTripAndPrune() throws {
        let store = MemoryRepository()
        var session = AgentSession(provider: .claude, projectDirectory: "/tmp/akshara", repositoryName: "Akshara", state: .completed, outcome: .completed, lastEventSummary: "Done", startedAt: Date().addingTimeInterval(-100), lastActivityAt: Date().addingTimeInterval(-10), completedAt: Date().addingTimeInterval(-10))
        session.awakeSeconds = 21
        try store.saveHistory([session])
        let loaded = try store.loadHistory()
        XCTAssertEqual(loaded.first?.repositoryName, "Akshara")
        XCTAssertEqual(loaded.first?.awakeSeconds, 21)
        try store.pruneHistory(before: Date())
        XCTAssertTrue(try store.loadHistory().isEmpty)
    }

    func testSwiftDataRestoresSessions() throws {
        let store = try SwiftDataRepository.make(inMemory: true)
        let session = AgentSession(provider: .codex, providerSessionID: "abc", projectDirectory: "/tmp/socioqueue", repositoryName: "SocioQueue", state: .working, lastEventSummary: "Working", startedAt: Date(), lastActivityAt: Date())
        try store.saveActive([session])
        let loaded = try store.loadActive()
        XCTAssertEqual(loaded.first?.providerSessionID, "abc")
        XCTAssertEqual(loaded.first?.state, .working)
        let project = ProjectPolicy(name: "SocioQueue", path: "/tmp/socioqueue", sensitive: true)
        try store.saveProjects([project])
        XCTAssertEqual(try store.loadProjects().first?.sensitive, true)
    }
}

final class HistoryAndQueueTests: XCTestCase {
    func testMetricsDoNotInventTokens() {
        let start = Date().addingTimeInterval(-120)
        var session = AgentSession(provider: .claude, state: .waitingForUser, outcome: .completed, lastEventSummary: "Done", startedAt: start, lastActivityAt: Date(), completedAt: Date())
        session.intervals = [
            StateInterval(state: .working, startedAt: start, endedAt: start.addingTimeInterval(80)),
            StateInterval(state: .waitingForUser, startedAt: start.addingTimeInterval(80), endedAt: Date())
        ]
        session.awakeSeconds = 80
        let metrics = HistoryCalculator.metrics(for: [session])
        XCTAssertEqual(metrics.activeTime, 80, accuracy: 1)
        XCTAssertEqual(metrics.awakeTime, 80, accuracy: 1)
        XCTAssertEqual(metrics.completed, 1)
    }

    func testQueueSeparatesWaitingAndReady() {
        var waiting = AgentSession(provider: .claude, repositoryName: "Akshara", state: .waitingForReset, outcome: .limited, lastEventSummary: "Limit", startedAt: Date(), lastActivityAt: Date())
        waiting.limit = LimitInfo(detectedAt: Date(), resetAt: Date().addingTimeInterval(3600))
        var ready = AgentSession(provider: .codex, repositoryName: "SocioQueue", state: .idle, lastEventSummary: "Ready", startedAt: Date(), lastActivityAt: Date())
        ready.resume.readiness = .ready
        let queue = StatusPresentation.queue(active: [waiting, ready], history: [], now: Date())
        XCTAssertEqual(queue.map(\.phase), [.waiting, .ready])
    }
}

final class CursorActivityTests: XCTestCase {
    func testCursorClassificationIgnoresTheIdleApp() {
        XCTAssertEqual(
            ProcessInspector.provider(commandName: "node", executablePath: "/Users/a/cursor-agent/versions/node"),
            .cursor
        )
        XCTAssertEqual(
            ProcessInspector.provider(
                commandName: "Cursor Helper (Plugin): extension-host Agents Window [1-1]",
                executablePath: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
            ),
            .cursor
        )
        XCTAssertNil(
            ProcessInspector.provider(
                commandName: "Cursor Helper (Plugin): extension-host app [1-3]",
                executablePath: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
            )
        )
        XCTAssertNil(ProcessInspector.provider(commandName: "Cursor", executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        XCTAssertEqual(ProcessInspector.provider(commandName: "codex", executablePath: "/usr/local/bin/codex"), .codex)
    }

    func testCursorCountsAsWorkingOnlyWhileBusy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"
        let idle = TrackedProcess(pid: 10, provider: .cursor, executablePath: path, cpuActive: false)
        XCTAssertTrue(SessionReducer.reconcile(sessions: [], processes: [idle], now: now).isEmpty)

        let busy = TrackedProcess(pid: 9, provider: .cursor, executablePath: path, cpuActive: true)
        let started = SessionReducer.reconcile(sessions: [], processes: [busy], now: now)
        XCTAssertEqual(started.first?.state, .working)
        XCTAssertEqual(StatusPresentation.headline(sessions: started), "Cursor is working.")

        let later = now.addingTimeInterval(4)
        let still = SessionReducer.reconcile(
            sessions: started,
            processes: [TrackedProcess(pid: 9, provider: .cursor, executablePath: path, cpuActive: true)],
            now: later
        )
        XCTAssertEqual(still.first?.state, .working)
        XCTAssertEqual(still.first?.lastActivityAt, later)

        let stillQuiet = SessionReducer.reconcile(sessions: still, processes: [TrackedProcess(pid: 9, provider: .cursor, executablePath: path, cpuActive: false)], now: later.addingTimeInterval(21))
        XCTAssertEqual(stillQuiet.first?.state, .working)

        let quiet = SessionReducer.reconcile(sessions: still, processes: [TrackedProcess(pid: 9, provider: .cursor, executablePath: path, cpuActive: false)], now: later.addingTimeInterval(46))
        XCTAssertEqual(quiet.first?.state, .idle)
        XCTAssertEqual(StatusPresentation.headline(sessions: quiet), "Everything's quiet.")
    }

    func testCursorNeedsMoreCpuThanAQuietWindow() {
        XCTAssertFalse(ProcessWatch.cpuActive(provider: .cursor, previous: 0, current: 20_000_000, elapsed: 2))
        XCTAssertTrue(ProcessWatch.cpuActive(provider: .cursor, previous: 0, current: 40_000_000, elapsed: 2))
        XCTAssertTrue(ProcessWatch.cpuActive(provider: .cursor, previous: 0, current: 200_000_000, elapsed: 2))
        XCTAssertTrue(ProcessWatch.cpuActive(provider: .claude, previous: 0, current: 60_000_000, elapsed: 8))
    }
}

final class OpenCodeGoAndAntigravityTests: XCTestCase {
    func testOpenCodeGoKeepsOnePercentAsOnePercentUsed() throws {
        let data = Data(#"""
        {"usage":{"rolling":{"status":"ok","percent":3,"resetsAt":"2026-08-14T07:20:04.810Z"},"weekly":{"status":"ok","percent":1,"resetsAt":"2026-08-17T00:00:00Z"},"monthly":{"status":"ok","percent":0,"resetsAt":"2026-09-09T00:41:03.810Z"}}}
        """#.utf8)
        let usage = try XCTUnwrap(OpenCodeGoUsageParser.parse(data, now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(usage.windows.map(\.name), ["5-hour allowance", "Weekly", "Monthly"])
        XCTAssertEqual(usage.windows[0].usedFraction ?? 0, 0.03, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].usedFraction ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[2].usedFraction ?? 0, 0, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[0].headline(reading: .remaining), "97% left")
        XCTAssertEqual(usage.windows[1].headline(reading: .remaining), "99% left")
        XCTAssertEqual(usage.windows[2].headline(reading: .remaining), "100% left")
        XCTAssertNotNil(usage.windows[0].resetAt)
    }

    func testOpenCodeGoIgnoresAMissingPercent() {
        let data = Data(#"{"usage":{"rolling":{"status":"ok"},"weekly":{"percent":12}}}"#.utf8)
        let usage = OpenCodeGoUsageParser.parse(data)
        XCTAssertEqual(usage?.windows.map(\.name), ["Weekly"])
        XCTAssertEqual(usage?.windows[0].usedFraction ?? 0, 0.12, accuracy: 0.0001)
    }

    func testOpenCodeGoKeyComesOnlyFromTheGoEntry() {
        let other = Data(#"{"opencode":{"type":"api","key":"sk-other-provider"},"anthropic":{"type":"api","key":"sk-not-opencode-go"}}"#.utf8)
        XCTAssertNil(OpenCodeGoLogin.apiKey(in: other))
        let placeholder = Data(#"{"opencode-go":{"type":"api","key":"${env:OPENCODE_API_KEY}"}}"#.utf8)
        XCTAssertNil(OpenCodeGoLogin.apiKey(in: placeholder))
        let connected = Data(#"{"opencode-go":{"type":"api","key":"sk-opencode-go-test"}}"#.utf8)
        XCTAssertEqual(OpenCodeGoLogin.apiKey(in: connected), "sk-opencode-go-test")
    }

    func testAntigravityReadsTheTwoFamilies() throws {
        let data = Data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"Five hour","remaining":{"remainingFraction":0.91}},{"displayName":"Weekly","remaining":{"remainingFraction":0.4}},{"displayName":"Five hour"}]},{"displayName":"Claude and GPT models","buckets":[{"displayName":"Session","remaining":{"remainingFraction":1}},{"displayName":"Weekly","remaining":{"remainingFraction":0.5}}]}]}
        """#.utf8)
        let usage = try XCTUnwrap(AntigravityUsageParser.parse(data))
        XCTAssertEqual(usage.windows.map(\.name), ["Gemini 5-hour", "Gemini weekly", "Claude and GPT 5-hour", "Claude and GPT weekly"])
        XCTAssertEqual(usage.windows[0].headline(reading: .remaining), "91% left")
        XCTAssertEqual(usage.windows[1].headline(reading: .remaining), "40% left")
        XCTAssertEqual(usage.windows[2].headline(reading: .remaining), "100% left")
        XCTAssertEqual(usage.windows[3].usedFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    func testAntigravityLegacyUsesTheLowestRemainingModel() throws {
        let data = Data(#"""
        {"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-10-09T00:00:00Z"}},{"label":"Gemini Flash","quotaInfo":{"remainingFraction":0.8}},{"label":"Claude Sonnet","quotaInfo":{"remainingFraction":0.5}}]}}}
        """#.utf8)
        let usage = try XCTUnwrap(AntigravityUsageParser.parse(data))
        XCTAssertEqual(usage.windows.map(\.name), ["Gemini", "Claude and GPT"])
        XCTAssertEqual(usage.windows[0].usedFraction ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].headline(reading: .remaining), "50% left")
        XCTAssertNotNil(usage.windows[0].resetAt)
    }

    func testAntigravityLocalLineRequiresTheApp() {
        let unrelated = AntigravityLocalServers.server(from: "4242 /usr/bin/language_server --csrf_token nope --extension_server_port 9")
        XCTAssertNil(unrelated)
        let server = AntigravityLocalServers.server(from: "999999 /Applications/Antigravity.app/Contents/MacOS/language_server --csrf_token local-token --extension_server_port 9")
        XCTAssertEqual(server?.csrfToken, "local-token")
        XCTAssertEqual(server?.httpPort, 9)
    }
}
