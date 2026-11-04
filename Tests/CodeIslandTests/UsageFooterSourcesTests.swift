import XCTest
import CodeIslandCore
@testable import CodeIsland

final class UsageFooterSourcesTests: XCTestCase {
    private func entry(_ source: String, output: Int = 100) -> UsageFooterSources.Entry {
        var totals = ClaudeUsageTotals()
        totals.outputTokens = output
        totals.messageCount = 1
        let usage = ClaudeUsageScanner.Snapshot(last5h: totals, today: totals, hourlyOutputTokens: [output], scannedAt: Date())
        return .init(source: source, usage: usage)
    }

    private let all: (String) -> Bool = { _ in true }

    func testOnlySourcesWithASessionOnTheIslandAreListed() {
        let result = UsageFooterSources.resolve([entry("claude"), entry("codex")], sessionSources: ["claude"], isEnabled: all)
        XCTAssertEqual(result.lines.map(\.source), ["claude"])
        XCTAssertTrue(result.merged.isEmpty)
    }

    func testWithoutLocalSessionsOnlyClaudeIsListed() {
        let result = UsageFooterSources.resolve([entry("claude"), entry("codex")], sessionSources: [], isEnabled: all)
        XCTAssertEqual(result.lines.map(\.source), ["claude"])
    }

    func testDisabledSourceIsHiddenEvenWithASession() {
        let result = UsageFooterSources.resolve([entry("claude"), entry("codex")], sessionSources: ["claude", "codex"],
                                                isEnabled: { $0 != "codex" })
        XCTAssertEqual(result.lines.map(\.source), ["claude"])
    }

    func testClaudeFoldedIntoThePlanLimitsLineIsNotRepeated() {
        let result = UsageFooterSources.resolve([entry("claude"), entry("codex")], sessionSources: ["claude", "codex"],
                                                excluding: ["claude"], isEnabled: all)
        XCTAssertEqual(result.lines.map(\.source), ["codex"])
    }

    func testMoreThanTwoSourcesMergeIntoOneTotalLine() {
        let result = UsageFooterSources.resolve([entry("claude"), entry("codex"), entry("gemini")],
                                                sessionSources: ["claude", "codex", "gemini"], isEnabled: all)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.merged.map(\.source), ["claude", "codex", "gemini"])
        let tooltip = UsageFooterSources.mergedTooltip(result.merged, l10n: L10n.shared)
        XCTAssertTrue(tooltip.contains("Gemini"))
    }

    func testMergedSnapshotAddsWindowsAndHourlyBars() throws {
        let merged = try XCTUnwrap(ClaudeUsageScanner.Snapshot.merged([entry("claude", output: 100).usage, entry("codex", output: 50).usage]))
        XCTAssertEqual(merged.today.outputTokens, 150)
        XCTAssertEqual(merged.last5h.messageCount, 2)
        XCTAssertEqual(merged.hourlyOutputTokens, [150])
        XCTAssertNil(ClaudeUsageScanner.Snapshot.merged([]))
    }
}
