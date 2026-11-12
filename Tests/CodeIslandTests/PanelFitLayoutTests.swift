import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Every expanded surface has to fit the panel window: what doesn't is cut
/// off by the window's bottom edge, out of reach. Rendered offscreen on a red
/// backdrop (PanelHost) so the panel's bottom edge can be read from pixels.
@MainActor
final class PanelFitLayoutTests: XCTestCase {
    private var sandbox: DefaultsSandbox?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        MascotAnimationGate.shared.setPanelVisible(true)
        sandbox?.restore()
        super.tearDown()
    }

    // MARK: - Session list

    func testListScrollsByHeightNotOnlyBySessionCount() {
        let budget = SessionListMetrics.scrollHeight(maxVisibleSessions: 5)
        XCTAssertEqual(budget, 450)
        XCTAssertFalse(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 4, contentHeight: 300, maxVisibleSessions: 5))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 4, contentHeight: 620, maxVisibleSessions: 5))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 6, contentHeight: 0, maxVisibleSessions: 5))
        // The completion card sizes its own reply instead.
        XCTAssertFalse(SessionListMetrics.needsScroll(isCompletionCard: true, sessionCount: 6, contentHeight: 900, maxVisibleSessions: 5))
    }

    func testFewTallSessionsStayInsideTheWindow() throws {
        // Four sessions — under the five the window is sized for — but with
        // a task list, an approval row and a recap they ran ~150pt past the
        // 510pt window, footer and all.
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testTallSessionsAtALargeFontStayInsideTheWindow() throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testSessionUsageFitsInTallSessionList() throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.showSessionUsage)
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = try tallSessions(count: 4)
        defer { state.release() }
        var summary = ClaudeUsageTotals()
        summary.messageCount = 1
        summary.outputTokens = 9_000
        let snapshot = ClaudeUsageScanner.Snapshot(last5h: summary, today: summary, hourlyOutputTokens: [1, 2, 3], scannedAt: Date())
        state.state.claudeUsage = snapshot
        state.state.codexUsage = snapshot
        UserDefaults.standard.set(true, forKey: SettingsKey.showUsageStats)
        for id in state.state.sessions.keys {
            var usage = SessionUsageSnapshot()
            usage.inputTokens = 125_000
            usage.outputTokens = 9_000
            usage.estimatedTokensPerSecond = 42
            state.state.sessionUsage[id] = usage
        }
        let panel = try PanelHost(state.state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0)
    }

    func testUsageDetailsOpenWithoutSessionsAndFitTheSmallestPanel() throws {
        let defaults = UserDefaults.standard
        defaults.set(3, forKey: SettingsKey.maxVisibleSessions)
        defaults.set(false, forKey: SettingsKey.showUsageStats)
        defaults.set(false, forKey: SettingsKey.showClaudeQuota)
        defaults.set(true, forKey: SettingsKey.showCodexQuota)
        let state = AppState()
        let days = UsageHistoryDays.dates(endingAt: Date())
        var claude = ClaudeUsageTotals()
        claude.messageCount = 2
        claude.inputTokens = 22_000
        claude.outputTokens = 9_000
        claude.cacheReadTokens = 43_000
        var codex = claude
        codex.outputTokens = 16_000
        let history = UsageHistory(days: days,
                                   claude: [days[1]: claude, days[3]: claude, days[6]: claude],
                                   codex: [days[1]: codex, days[4]: codex, days[6]: codex])
        var account = CodexAccountUsage()
        account.applyLimits([
            "rateLimits": .object([
                "primary": .object(["usedPercent": .int(41), "windowDurationMins": .int(300)]),
                "secondary": .object(["usedPercent": .int(19), "windowDurationMins": .int(10_080)]),
            ]),
            "rateLimitResetCredits": .object(["availableCount": .int(0)]),
        ])
        account.applyUsage(["summary": .object(["lifetimeTokens": .int(18_000_000)])])
        state.usageDetails.applyPreview(history, codex: account)
        state.surface = .sessionList
        state.usageDetailSource = .all
        defaults.set(true, forKey: SettingsKey.showUsageStats)
        let panel = try PanelHost(state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()

        let gap = try panel.gapUnderPanel()
        XCTAssertGreaterThan(gap, 0, "用量详情不应超出窗口底边")
        XCTAssertLessThan(gap, panel.height / 2, "无会话时也应显示用量详情")
    }

    func testCodexFooterShowsQuotaWhenAvailableAndFallsBackToLocalUsage() throws {
        let defaults = UserDefaults.standard
        defaults.set(3, forKey: SettingsKey.maxVisibleSessions)
        defaults.set(true, forKey: SettingsKey.showUsageStats)
        defaults.set(true, forKey: SettingsKey.showCodexQuota)
        defaults.set(true, forKey: SettingsKey.showClaudeQuota)
        let state = AppState()
        let now = Date()
        state.claudeQuota.applyPreview(ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 83, resetsAt: now.addingTimeInterval(7_200)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 65, resetsAt: now.addingTimeInterval(28_800)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 1, resetsAt: now.addingTimeInterval(28_800), scopeLabel: "Fable"),
        ], fetchedAt: now))
        var session = SessionSnapshot()
        session.source = "codex"
        session.cwd = "/Users/dev/code/web-app"
        state.sessions = ["c": session]
        state.activeSessionId = "c"
        state.refreshDerivedState()
        state.surface = .sessionList
        var totals = ClaudeUsageTotals()
        totals.messageCount = 1
        totals.outputTokens = 123_456
        state.codexUsage = ClaudeUsageScanner.Snapshot(last5h: totals, today: totals,
                                                      hourlyOutputTokens: [0, 0, 1, 2, 3], scannedAt: Date())
        state.claudeUsage = ClaudeUsageScanner.Snapshot(last5h: totals, today: totals,
                                                       hourlyOutputTokens: [0, 0, 3, 2, 1], scannedAt: Date())
        let panel = try PanelHost(state, notchHeight: 37)
        defer { panel.close() }

        func renderedWarningBars(saveAs filename: String) throws -> Int {
            panel.settle()
            let rep = try XCTUnwrap(panel.host.bitmapImageRepForCachingDisplay(in: panel.host.bounds))
            panel.host.cacheDisplay(in: panel.host.bounds, to: rep)
            let image = try XCTUnwrap(rep.cgImage)
            let w = image.width, h = image.height
            let scale = CGFloat(h) / panel.height
            let bottom = h - Int(try panel.gapUnderPanel() * scale)
            if let folder = ProcessInfo.processInfo.environment["CODEISLAND_RENDER_QUOTA_FOOTER"] {
                let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: w, height: bottom + 4)))
                try OffscreenRender.writePNG(cropped, to: folder + "/" + filename)
            }
            let context = try XCTUnwrap(CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let minBarWidth = Int(24 * scale)
            // 扫底栏的橙色进度条，长度要求排除了文字和其他小图标。
            return (max(0, bottom - Int(64 * scale))..<bottom).map { y in
                var run = 0
                var bars = 0
                for x in 0..<w {
                    let p = pixels + (y * w + x) * 4
                    if p[0] > 215 && (130...210).contains(p[1]) && p[2] < 110 {
                        run += 1
                        if run == minBarWidth { bars += 1 }
                    } else {
                        run = 0
                    }
                }
                return bars
            }.max() ?? 0
        }

        XCTAssertEqual(try renderedWarningBars(saveAs: "fallback.png"), 1, "没有 Codex 额度时只显示 Claude 进度条")

        let epoch = Int64(now.timeIntervalSince1970)
        let windows: [String: AnyCodableLike] = [
            "primary": .object(["usedPercent": .int(86), "windowDurationMins": .int(300),
                                "resetsAt": .int(epoch + 3_600)]),
            "secondary": .object(["usedPercent": .int(91), "windowDurationMins": .int(10_080),
                                  "resetsAt": .int(epoch + 86_400)]),
        ]
        var account = CodexAccountUsage()
        account.applyLimits(["rateLimits": .object(windows)], at: now)
        state.usageDetails.applyPreview(UsageHistory(days: [], claude: [:], codex: [:]), codex: account)

        XCTAssertEqual(try renderedWarningBars(saveAs: "quota.png"), 2, "Codex 两个额度窗口应在同一行显示")
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0)
    }

    func testSqueezedBranchKeepsAFewCharacters() {
        // A long project name used to leave the branch an icon and "…".
        let short = BranchLabelMetrics.minimumWidth(for: "main", fontSize: 11)
        let long = BranchLabelMetrics.minimumWidth(for: "feature/very-long-branch-name-for-onboarding-flow", fontSize: 11)
        let twelve = BranchLabelMetrics.minimumWidth(for: String(repeating: "x", count: 12), fontSize: 11)
        XCTAssertLessThan(short, twelve, "a short branch must not be padded")
        XCTAssertEqual(long, twelve, accuracy: 1, "a long branch keeps room for twelve characters")
    }

    // MARK: - Question card

    func testQuestionWithManyOptionsKeepsItsButtonsInsideTheWindow() async throws {
        // Ten options with descriptions used to push option 10, "Other" and
        // the Dismiss / Skip row past the bottom of the 510pt window.
        let state = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.cwd = "/Users/dev/code/web-app"
        s.status = .waitingQuestion
        state.sessions = ["q": s]
        state.activeSessionId = "q"
        let regions = (1...10).map { ("region-\($0)", Optional("Latency to the team: medium")) }
        let release = try await DemoRequests.enqueueQuestion(state, sessionId: "q", cwd: "/Users/dev/code/web-app", items: [
            ("Which region should the staging stack deploy to?", "Region", regions, false),
        ])
        defer { release() }
        state.refreshDerivedState()
        state.surface = .questionCard(sessionId: "q")
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the question card runs off the bottom of the window")
    }

    // MARK: - Approval card

    func testApprovalCardHeadsItselfWithTheSessionAsking() async throws {
        // With several sessions queued, the card said only "! Bash" — not
        // which project's command it was about to allow. It now opens with
        // the same context row as a question card (agent icon + project),
        // which only a card whose session is gone goes without.
        func cardHeight(sessionKnown: Bool) async throws -> CGFloat {
            let state = AppState()
            var s = SessionSnapshot()
            s.source = "codex"
            s.cwd = "/Users/dev/code/api-server"
            s.status = .waitingApproval
            if sessionKnown { state.sessions = ["c": s] }
            state.activeSessionId = "c"
            let release = await DemoRequests.enqueuePermission(state, event: try DemoRequests.hookEvent([
                "hook_event_name": "PermissionRequest", "session_id": "c", "cwd": "/Users/dev/code/api-server",
                "_source": "codex", "tool_name": "Bash", "tool_input": ["command": "cargo test"],
            ]))
            defer { release() }
            state.refreshDerivedState()
            state.surface = .approvalCard(sessionId: "c")
            let panel = try PanelHost(state, notchHeight: 32)
            defer { panel.close() }
            panel.settle()
            return panel.height - (try panel.gapUnderPanel())
        }
        let withRow = try await cardHeight(sessionKnown: true)
        let withoutRow = try await cardHeight(sessionKnown: false)
        XCTAssertGreaterThan(withRow - withoutRow, 14, "the approval card has no session context row")
    }

    // MARK: - Fixtures

    private struct Demo {
        let state: AppState
        let release: () -> Void
    }

    private func tallSessions(count: Int) throws -> Demo {
        let state = AppState()
        var usage = ClaudeUsageTotals()
        usage.outputTokens = 96_000
        state.claudeUsage = ClaudeUsageScanner.Snapshot(last5h: usage, today: usage, hourlyOutputTokens: [1, 2, 3], scannedAt: Date())
        for index in 0..<count {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-600))
            s.source = "claude"
            s.cwd = "/Users/dev/code/project-\(index)"
            s.gitBranch = "feat/branch-\(index)"
            s.status = .running
            s.currentTool = "Edit"
            s.toolDescription = "src/components/Dashboard.tsx"
            s.lastUserPrompt = "Add filters to the dashboard page"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Add filters to the dashboard page"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Adding a date-range and status filter bar above the orders table."))
            s.agentTasks = AgentTaskList(items: (1...5).map {
                AgentTaskItem(id: "t\($0)", title: "Task \($0)", status: $0 < 3 ? .completed : ($0 == 3 ? .inProgress : .pending))
            })
            state.sessions["s\(index)"] = s
        }
        state.activeSessionId = "s0"
        state.refreshDerivedState()
        state.surface = .sessionList
        return Demo(state: state, release: {})
    }
}
