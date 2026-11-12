import XCTest
@testable import CodeIslandCore

final class CodexUsageScannerTests: XCTestCase {
    func testHistoryIncludesArchivedRolloutsOnlyOnce() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let previousDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: day))
        let timestamp = ISO8601DateFormatter().string(from: previousDay.addingTimeInterval(60))
        let line = #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":700,"output_tokens":200}}}}"#
        for (folder, filename) in [("sessions", "rollout-copy"), ("archived_sessions", "rollout-copy"),
                                   ("archived_sessions", "rollout-only-in-archive")] {
            let dir = root.appendingPathComponent(folder)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try (line + "\n").write(to: dir.appendingPathComponent(filename + ".jsonl"), atomically: true, encoding: .utf8)
        }

        var cache = CodexUsageScanner.FileCache()
        let snapshot = CodexUsageScanner.scan(codexHomes: [root.path, root.path], now: now,
                                              includeHistory: true, cache: &cache)
        XCTAssertEqual(snapshot.dailyTotals[previousDay]?.recordedTokens, 2400)
        XCTAssertEqual(snapshot.dailyTotals[previousDay]?.cacheReadTokens, 1400)
        XCTAssertTrue(snapshot.today.isEmpty)
    }

    func testWindowsIncrementalSnapshotsAndDuplicateRoots() throws {
        let root = NSTemporaryDirectory() + "codex-usage-" + UUID().uuidString
        let dir = root + "/sessions/2026/11/02"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = dir + "/rollout.jsonl"
        let now = Date()
        let formatter = ISO8601DateFormatter()
        func line(_ date: Date, _ input: Int, _ cached: Int, _ output: Int) -> String {
            #"{"type":"event_msg","timestamp":""# + formatter.string(from: date) + #"","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"#
        }
        let first = line(now.addingTimeInterval(-120), 1000, 600, 300)
        try (first + "\n" + first + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        var cache = CodexUsageScanner.FileCache()
        var result = CodexUsageScanner.scan(codexHomes: [root, root], now: now, cache: &cache)
        XCTAssertEqual(result.last5h.inputTokens, 400)
        XCTAssertEqual(result.last5h.cacheReadTokens, 600)
        XCTAssertEqual(result.last5h.outputTokens, 300)
        XCTAssertEqual(result.last5h.messageCount, 1)
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        file.seekToEndOfFile()
        file.write(Data((line(now, 1400, 800, 500) + "\n").utf8))
        file.closeFile()
        result = CodexUsageScanner.scan(codexHomes: [root], now: now.addingTimeInterval(1), cache: &cache)
        XCTAssertEqual(result.last5h.inputTokens, 600)
        XCTAssertEqual(result.last5h.cacheReadTokens, 800)
        XCTAssertEqual(result.last5h.outputTokens, 500)
        XCTAssertEqual(result.last5h.messageCount, 2)
    }
}
