import XCTest
@testable import CodeIslandCore

final class CodexUsageScannerTests: XCTestCase {
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
