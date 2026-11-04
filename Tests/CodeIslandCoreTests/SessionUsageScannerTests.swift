import XCTest
@testable import CodeIslandCore

final class SessionUsageScannerTests: XCTestCase {
    private var path: String!
    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "session-usage-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: Data())
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }
    private func append(_ lines: String...) throws {
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { file.closeFile() }
        file.seekToEndOfFile()
        file.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
    func testClaudeMergesMessageSnapshotsAndEstimatesRequestSpeed() throws {
        try append(
          #"{"type":"user","uuid":"u","timestamp":"2026-01-01T00:00:00Z"}"#,
          #"{"type":"assistant","uuid":"a","parentUuid":"u","timestamp":"2026-01-01T00:00:02Z","message":{"id":"m","usage":{"input_tokens":100,"output_tokens":1}}}"#,
          #"{"type":"assistant","uuid":"b","parentUuid":"a","timestamp":"2026-01-01T00:00:10Z","message":{"id":"m","usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":50},"stop_reason":"end_turn"}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "claude"))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 300)
        XCTAssertEqual(usage.cacheReadTokens, 50)
        XCTAssertEqual(try XCTUnwrap(usage.estimatedTokensPerSecond), 30, accuracy: 0.001)
        XCTAssertEqual(scanner.scan(path: path, source: "claude"), usage)
    }
    func testClaudeShortOrIncompleteRequestDoesNotProduceSpeed() throws {
        try append(
          #"{"type":"user","uuid":"u","timestamp":"2026-01-01T00:00:00Z"}"#,
          #"{"type":"assistant","parentUuid":"u","timestamp":"2026-01-01T00:00:10Z","message":{"id":"m","usage":{"output_tokens":100},"stop_reason":"end_turn"}}"#)
        var scanner = SessionUsageScanner()
        XCTAssertNil(scanner.scan(path: path, source: "claude")?.estimatedTokensPerSecond)
    }
    func testCodexCumulativeSnapshotsAndRepeatedQuotaEvent() throws {
        try append(
          #"{"type":"turn_context","timestamp":"2026-01-01T00:00:00Z","payload":{}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:08Z","payload":{"type":"message","role":"assistant"}}"#,
          #"{"type":"event_msg","timestamp":"2026-01-01T00:00:10Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":300}}}}"#)
        var scanner = SessionUsageScanner()
        let first = try XCTUnwrap(scanner.scan(path: path, source: "codex"))
        XCTAssertEqual(first.inputTokens, 400)
        XCTAssertEqual(first.cacheReadTokens, 600)
        XCTAssertEqual(first.outputTokens, 300)
        XCTAssertEqual(try XCTUnwrap(first.estimatedTokensPerSecond), 30, accuracy: 0.001)
        try append(#"{"type":"event_msg","timestamp":"2026-01-01T00:00:11Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":300}}}}"#)
        XCTAssertEqual(scanner.scan(path: path, source: "codex"), first)
    }
    func testIncompleteLineAndReplacement() throws {
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        file.write(Data(#"{"type":"assistant""#.utf8))
        file.closeFile()
        var scanner = SessionUsageScanner()
        XCTAssertNil(scanner.scan(path: path, source: "claude"))
        try (#"{"type":"assistant","message":{"id":"m","usage":{"output_tokens":20}}}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(scanner.scan(path: path, source: "claude")?.outputTokens, 20)
    }
    func testCodexDoesNotEstimateSpeedAcrossToolExecution() throws {
        try append(
          #"{"type":"turn_context","timestamp":"2026-01-01T00:00:00Z","payload":{}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:02Z","payload":{"type":"function_call"}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:15Z","payload":{"type":"function_call_output"}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:20Z","payload":{"type":"message","role":"assistant"}}"#,
          #"{"type":"event_msg","timestamp":"2026-01-01T00:00:21Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"cache_write_input_tokens":100,"output_tokens":300}}}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "codex"))
        XCTAssertEqual(usage.inputTokens, 400)
        XCTAssertEqual(usage.cacheWriteTokens, 100)
        XCTAssertNil(usage.estimatedTokensPerSecond)
    }

    func testClaudeSpeedAggregatesRecentRequestsInsteadOfAveraging() throws {
        try append(
          #"{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00Z"}"#,
          #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-01-01T00:00:10Z","message":{"id":"m1","usage":{"output_tokens":300},"stop_reason":"end_turn"}}"#,
          #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:01:00Z"}"#,
          #"{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"2026-01-01T00:01:20Z","message":{"id":"m2","usage":{"output_tokens":900},"stop_reason":"end_turn"}}"#,
          // 短请求不参与速度，也不把已有的速度冲掉
          #"{"type":"user","uuid":"u3","timestamp":"2026-01-01T00:02:00Z"}"#,
          #"{"type":"assistant","uuid":"a3","parentUuid":"u3","timestamp":"2026-01-01T00:02:02Z","message":{"id":"m3","usage":{"output_tokens":20},"stop_reason":"tool_use"}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "claude"))
        // Σ输出 ÷ Σ耗时 = 1200 / 30，不是 (30 + 45) / 2
        XCTAssertEqual(try XCTUnwrap(usage.estimatedTokensPerSecond), 40, accuracy: 0.001)
        XCTAssertEqual(usage.speedSampleCount, 2)
        XCTAssertEqual(usage.timedOutputTokens, 1200)
        XCTAssertEqual(usage.timedDurationMs, 30_000)
        XCTAssertEqual(usage.lastTimedAt, ClaudeUsageScanner.parseISO8601("2026-01-01T00:01:20Z"))
        XCTAssertEqual(usage.speedText, "≈ 40 tok/s")
    }

    func testClaudeSpeedUsesOnlyTheMostRecentRequests() throws {
        var lines: [String] = []
        for i in 0..<7 {
            // 前两次 100 tok/s，后五次 10 tok/s
            let output = i < 2 ? 1000 : 200
            lines.append(#"{"type":"user","uuid":"u\#(i)","timestamp":"2026-01-01T00:0\#(i):00Z"}"#)
            lines.append(#"{"type":"assistant","uuid":"a\#(i)","parentUuid":"u\#(i)","timestamp":"2026-01-01T00:0\#(i):20Z","message":{"id":"m\#(i)","usage":{"output_tokens":\#(output)},"stop_reason":"end_turn"}}"#)
        }
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        file.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        file.closeFile()
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "claude"))
        XCTAssertEqual(try XCTUnwrap(usage.estimatedTokensPerSecond), 10, accuracy: 0.001)
        XCTAssertEqual(usage.speedSampleCount, SessionUsageScanner.recentSpeedRequests)
        XCTAssertEqual(usage.timedOutputTokens, 3000)
    }

    func testClaudeFirstTokenIsDerivedFromLeadingThinkingBlock() throws {
        try append(
          #"{"type":"user","uuid":"u","timestamp":"2026-01-01T00:00:00Z"}"#,
          #"{"type":"assistant","uuid":"a","parentUuid":"u","apiBlockIndex":0,"thinkingDurationMs":3000,"timestamp":"2026-01-01T00:00:04Z","message":{"id":"m","content":[{"type":"thinking"}],"usage":{"output_tokens":1}}}"#,
          #"{"type":"assistant","uuid":"b","parentUuid":"a","apiBlockIndex":1,"timestamp":"2026-01-01T00:00:10Z","message":{"id":"m","content":[{"type":"text"}],"usage":{"output_tokens":300},"stop_reason":"end_turn"}}"#,
          // 第一块是文字时推不出首字
          #"{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:01:00Z"}"#,
          #"{"type":"assistant","uuid":"c","parentUuid":"u2","apiBlockIndex":0,"thinkingDurationMs":3000,"timestamp":"2026-01-01T00:01:05Z","message":{"id":"m2","content":[{"type":"text"}],"usage":{"output_tokens":300},"stop_reason":"end_turn"}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "claude"))
        XCTAssertEqual(try XCTUnwrap(usage.estimatedFirstTokenSeconds), 1, accuracy: 0.001)
        XCTAssertEqual(usage.firstTokenText, "≈ 1.0s")
    }

    func testCodexPrefersUsageRecordEndAndReadsFirstToken() throws {
        // 2026-01-01T00:00:02Z 的毫秒时间戳
        let started = 1_767_225_602_000
        try append(
          #"{"type":"turn_context","timestamp":"2026-01-01T00:00:00Z","payload":{}}"#,
          #"{"type":"event_msg","timestamp":"2026-01-01T00:00:04Z","payload":{"type":"item_completed","item":{"type":"Reasoning"},"started_at_ms":\#(started)}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:04Z","payload":{"type":"reasoning"}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:06Z","payload":{"type":"function_call"}}"#,
          #"{"type":"token_usage_record","timestamp":"2026-01-01T00:00:08Z","payload":{"usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":400}}}"#,
          // 工具跑完才写 token_count：没有用量记录时会退回最后一个输出项的时刻
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:15Z","payload":{"type":"function_call_output"}}"#,
          #"{"type":"event_msg","timestamp":"2026-01-01T00:00:15.010Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":400},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":400}}}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "codex"))
        XCTAssertEqual(try XCTUnwrap(usage.estimatedTokensPerSecond), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(usage.estimatedFirstTokenSeconds), 2, accuracy: 0.001)
        XCTAssertEqual(usage.timedDurationMs, 8000)
    }

    func testCodexIgnoresUsageRecordOfAnotherRequest() throws {
        try append(
          #"{"type":"turn_context","timestamp":"2026-01-01T00:00:00Z","payload":{}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:04Z","payload":{"type":"reasoning"}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:10Z","payload":{"type":"function_call"}}"#,
          #"{"type":"token_usage_record","timestamp":"2026-01-01T00:00:08Z","payload":{"usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}}"#,
          #"{"type":"response_item","timestamp":"2026-01-01T00:00:15Z","payload":{"type":"function_call_output"}}"#,
          #"{"type":"event_msg","timestamp":"2026-01-01T00:00:15.010Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":400},"last_token_usage":{"input_tokens":1000,"output_tokens":400}}}}"#)
        var scanner = SessionUsageScanner()
        let usage = try XCTUnwrap(scanner.scan(path: path, source: "codex"))
        XCTAssertEqual(try XCTUnwrap(usage.estimatedTokensPerSecond), 40, accuracy: 0.001)
        XCTAssertNil(usage.estimatedFirstTokenSeconds)
    }

    func testMedianAndSpeedText() {
        XCTAssertNil(SessionUsageScanner.median([Double]()))
        XCTAssertEqual(SessionUsageScanner.median([3, 1, 2]), 2)
        XCTAssertEqual(SessionUsageScanner.median([4, 1, 2, 3]), 2.5)
        var usage = SessionUsageSnapshot()
        XCTAssertNil(usage.speedText)
        usage.estimatedTokensPerSecond = 0.44
        XCTAssertEqual(usage.speedText, "≈ 0.4 tok/s")
    }

    func testCodexInheritedHistoryIsNotAttributedToCurrentSession() throws {
        try append(
          #"{"type":"session_meta","payload":{"history_base_id":"parent"}}"#,
          #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":50}}}}"#)
        var scanner = SessionUsageScanner()
        XCTAssertNil(scanner.scan(path: path, source: "codex"))
    }
}
