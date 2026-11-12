import XCTest
@testable import CodeIslandCore

final class ClaudeUsageScannerTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "usage-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: home + "/projects/p1", withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func assistantLine(id: String, at date: Date, input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) -> String {
        """
        {"type":"assistant","timestamp":"\(iso(date))","message":{"id":"\(id)","role":"assistant","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    /// Noon local time keeps "1h ago" and "8h ago" unambiguously on today's
    /// date regardless of when the test runs.
    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testParseAssistantUsageLine() {
        let parsed = ClaudeUsageScanner.parseAssistantUsage(
            assistantLine(id: "m1", at: noon, input: 10, output: 20, cacheWrite: 5, cacheRead: 100))
        XCTAssertEqual(parsed?.messageId, "m1")
        XCTAssertEqual(parsed?.usage.inputTokens, 10)
        XCTAssertEqual(parsed?.usage.outputTokens, 20)
        XCTAssertEqual(parsed?.usage.cacheCreationTokens, 5)
        XCTAssertEqual(parsed?.usage.cacheReadTokens, 100)

        XCTAssertNil(ClaudeUsageScanner.parseAssistantUsage(#"{"type":"user","timestamp":"2026-07-10T01:00:00Z"}"#))
        XCTAssertNil(ClaudeUsageScanner.parseAssistantUsage("not json"))
    }

    func testScanAggregatesWindowsAndDedupes() throws {
        let now = noon
        let lines = [
            // In both windows.
            assistantLine(id: "recent", at: now.addingTimeInterval(-3600), input: 100, output: 10),
            // Duplicate message id (tool-use continuation) — counted once.
            assistantLine(id: "recent", at: now.addingTimeInterval(-3600), input: 100, output: 10),
            // Today but outside the 5h window (04:00 local).
            assistantLine(id: "morning", at: now.addingTimeInterval(-8 * 3600), input: 1000, output: 50),
            // Yesterday — in neither window.
            assistantLine(id: "old", at: now.addingTimeInterval(-30 * 3600), input: 7777, output: 999),
        ]
        try lines.joined(separator: "\n")
            .write(toFile: home + "/projects/p1/s.jsonl", atomically: true, encoding: .utf8)

        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now)

        XCTAssertEqual(snap.last5h.inputTokens, 100)
        XCTAssertEqual(snap.last5h.outputTokens, 10)
        XCTAssertEqual(snap.last5h.messageCount, 1)
        XCTAssertEqual(snap.today.inputTokens, 1100)
        XCTAssertEqual(snap.today.outputTokens, 60)
        XCTAssertEqual(snap.today.messageCount, 2)

        // Hourly sparkline: index (last - hoursAgo) carries that hour's output.
        let last = ClaudeUsageScanner.sparklineHours - 1
        XCTAssertEqual(snap.hourlyOutputTokens.count, ClaudeUsageScanner.sparklineHours)
        XCTAssertEqual(snap.hourlyOutputTokens[last - 1], 10)  // 1h ago
        XCTAssertEqual(snap.hourlyOutputTokens[last - 8], 50)  // 8h ago
        XCTAssertEqual(snap.hourlyOutputTokens.reduce(0, +), 60)
    }

    func testIncrementalScanReadsOnlyAppendedBytes() throws {
        let now = noon
        let path = home + "/projects/p1/s.jsonl"
        try (assistantLine(id: "a", at: now.addingTimeInterval(-3600), input: 100, output: 10) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = ClaudeUsageScanner.FileCache()
        let first = ClaudeUsageScanner.scan(claudeHome: home, now: now, cache: &cache)
        XCTAssertEqual(first.last5h.inputTokens, 100)
        let consumedAfterFirst = try XCTUnwrap(cache.files[path]?.consumedBytes)
        XCTAssertGreaterThan(consumedAfterFirst, 0)

        // Append a second message; rescan must consume only the new bytes.
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((assistantLine(id: "b", at: now.addingTimeInterval(-1800), input: 7, output: 3) + "\n").utf8))
        handle.closeFile()

        let second = ClaudeUsageScanner.scan(claudeHome: home, now: now, cache: &cache)
        XCTAssertEqual(second.last5h.inputTokens, 107)
        XCTAssertEqual(second.last5h.messageCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(cache.files[path]?.consumedBytes), consumedAfterFirst)
    }

    func testHistoryUsesCalendarDaysAcrossDaylightSavingAndDeduplicates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let days = UsageHistoryDays.dates(endingAt: now, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[6].timeIntervalSince(days[5]), 23 * 3600)
        let old = assistantLine(id: "old", at: days[0].addingTimeInterval(-1), input: 1000, output: 500)
        let first = assistantLine(id: "first", at: days[0], input: 12, output: 4, cacheWrite: 6, cacheRead: 8)
        let midnight = assistantLine(id: "midnight", at: days[6], input: 5, output: 7)
        try ([old, first, first, midnight].joined(separator: "\n") + "\n")
            .write(toFile: home + "/projects/p1/s.jsonl", atomically: true, encoding: .utf8)

        var cache = ClaudeUsageScanner.FileCache()
        let snapshot = ClaudeUsageScanner.scan(claudeHomes: [home], now: now, calendar: calendar,
                                              includeHistory: true, cache: &cache)
        XCTAssertEqual(Set(snapshot.dailyTotals.keys), [days[0], days[6]])
        XCTAssertEqual(snapshot.dailyTotals[days[0]]?.recordedTokens, 30)
        XCTAssertEqual(snapshot.dailyTotals[days[6]], snapshot.today)
        XCTAssertTrue(snapshot.last5h.isEmpty)
    }

    func testLaterSnapshotUpdatesExistingMessage() throws {
        let path = home + "/projects/p1/s.jsonl"
        try (assistantLine(id: "a", at: noon, input: 100, output: 1) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        var cache = ClaudeUsageScanner.FileCache()
        XCTAssertEqual(ClaudeUsageScanner.scan(claudeHome: home, now: noon, cache: &cache).today.outputTokens, 1)
        let file = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        file.seekToEndOfFile()
        file.write(Data((assistantLine(id: "a", at: noon, input: 100, output: 300) + "\n").utf8))
        file.closeFile()
        let result = ClaudeUsageScanner.scan(claudeHome: home, now: noon, cache: &cache).today
        XCTAssertEqual(result.messageCount, 1)
        XCTAssertEqual(result.outputTokens, 300)
    }

    func testIncrementalScanIgnoresPartialTrailingLine() throws {
        let now = noon
        let path = home + "/projects/p1/s.jsonl"
        let full = assistantLine(id: "a", at: now.addingTimeInterval(-3600), input: 100, output: 10) + "\n"
        let partial = "{\"type\":\"assistant\",\"timest"  // writer mid-append
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        var cache = ClaudeUsageScanner.FileCache()
        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.last5h.messageCount, 1)
        // Offset stops at the last complete line so the partial line is retried.
        XCTAssertEqual(cache.files[path]?.consumedBytes, UInt64(full.utf8.count))
    }

    func testTruncatedFileIsRescannedFromStart() throws {
        let now = noon
        let path = home + "/projects/p1/s.jsonl"
        try (assistantLine(id: "a", at: now.addingTimeInterval(-3600), input: 100, output: 10) + "\n"
             + assistantLine(id: "b", at: now.addingTimeInterval(-1800), input: 50, output: 5) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        var cache = ClaudeUsageScanner.FileCache()
        _ = ClaudeUsageScanner.scan(claudeHome: home, now: now, cache: &cache)

        // Replace with a shorter file (e.g. transcript rewritten).
        try (assistantLine(id: "c", at: now.addingTimeInterval(-600), input: 1, output: 2) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let snap = ClaudeUsageScanner.scan(claudeHome: home, now: now, cache: &cache)
        XCTAssertEqual(snap.last5h.inputTokens, 1)
        XCTAssertEqual(snap.last5h.messageCount, 1)
    }

    func testScanEmptyHome() {
        let snap = ClaudeUsageScanner.scan(claudeHome: home + "/nonexistent", now: noon)
        XCTAssertTrue(snap.last5h.isEmpty)
        XCTAssertTrue(snap.today.isEmpty)
    }

    func testFormatTokens() {
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(950), "950")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(32_500), "32.5K")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(1_400_000), "1.4M")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(2_000_000), "2M")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(1000), "1K")
        // Rounding must roll the unit over, never render "1000K"/"1000M".
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(999_949), "999.9K")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(999_950), "1M")
        XCTAssertEqual(ClaudeUsageScanner.formatTokens(999_950_000), "1B")
    }
}
