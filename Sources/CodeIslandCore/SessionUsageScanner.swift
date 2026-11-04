import Foundation

/// 单个本机会话的 token 用量；输入统一为未命中缓存的部分。
public struct SessionUsageSnapshot: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    /// 最近几次达标请求的 Σ输出 ÷ Σ耗时，含首字等待，仅供估算。
    /// 不逐条平均：逐条平均会被短请求带歪。
    public var estimatedTokensPerSecond: Double?
    /// 参与上面速度的请求数。
    public var speedSampleCount = 0
    /// 最近几次推得出首字的请求的首字时间中位数（秒）。首字长尾明显，用中位数。
    public var estimatedFirstTokenSeconds: Double?
    /// 整个会话里达标请求的输出与耗时累计，分子分母描述同一批请求；
    /// 比值不能相加，留着原始计数供做差求实时速度。
    public var timedOutputTokens = 0
    public var timedDurationMs = 0
    /// 最近一次达标请求结束的时刻，用来判断速度是否新鲜。
    public var lastTimedAt: Date?
    public init() {}

    /// "≈ 42 tok/s"：≥ 1 取整，否则一位小数；估不出为 nil。
    public var speedText: String? {
        estimatedTokensPerSecond.map { "≈ " + ($0 >= 1 ? String(format: "%.0f", $0) : String(format: "%.1f", $0)) + " tok/s" }
    }

    /// "≈ 1.2s"；推不出为 nil。
    public var firstTokenText: String? {
        estimatedFirstTokenSeconds.map { "≈ " + String(format: "%.1f", $0) + "s" }
    }
}

/// 一次从累计计数推导出的用量变化。
public struct TimedSessionUsage: Sendable {
    public let timestamp: Date
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
}

/// 一次按日志时间戳估出了耗时的请求。
struct TimedRequest: Equatable, Sendable {
    let end: Date
    let output: Int
    /// 起点到最后一块写完，含首字等待。
    let duration: TimeInterval
    /// 起点到开始输出；推不出来为 nil。
    let firstToken: TimeInterval?

    /// 输出越少首字占比越大、估出来越偏低，所以门槛比精确口径高（与 cc-switch 估算口径一致）。
    static let minSpeedOutputTokens = 200
    /// 输出 200 token 以上却不到 1 秒，多半是起点取晚了。
    static let minSpeedDuration: TimeInterval = 1
    /// 短于此值不可能是真实请求，长于此值多半夹了休眠或重试等待。
    static let plausibleDuration: ClosedRange<TimeInterval> = 0.1...3600

    var speedEligible: Bool { output >= Self.minSpeedOutputTokens && duration >= Self.minSpeedDuration }

    /// 起止时间落在合理范围之外返回 nil；首字必须落在 (0, 耗时] 之间，否则视为推不出。
    init?(start: Date, end: Date, firstOutput: Date?, output: Int) {
        let duration = end.timeIntervalSince(start)
        guard Self.plausibleDuration.contains(duration) else { return nil }
        self.end = end
        self.output = output
        self.duration = duration
        self.firstToken = firstOutput.map { $0.timeIntervalSince(start) }.flatMap { $0 > 0 && $0 <= duration ? $0 : nil }
    }
}

/// 达标请求的累计计数。
struct TimedTotals: Equatable, Sendable {
    var output = 0
    var duration: TimeInterval = 0
    var last: Date?

    mutating func add(_ request: TimedRequest) {
        guard request.speedEligible else { return }
        output += request.output
        duration += request.duration
        if last.map({ request.end > $0 }) ?? true { last = request.end }
    }
}

/// 只读取会话本身的 JSONL，缓存增量解析状态，不读取会话内容供展示。
public struct SessionUsageScanner: Sendable {
    private struct ClaudeMessage: Sendable {
        var usage: SessionUsageSnapshot
        var parent: String?
        var firstBlock = true
        /// 第一块是思考块时，块写完的时刻减去 `thinkingDurationMs` 即开始输出的时刻。
        var firstOutput: Date?
        var end: Date?
        var complete = false
    }
    private struct Node: Sendable {
        var parent: String?
        var timestamp: Date?
        var attachment: Bool
    }
    /// 新版 Codex 在响应结束时写的 `token_usage_record`。
    private struct CodexUsageRecord: Sendable {
        let end: Date
        let input: Int
        let cached: Int
        let output: Int
    }
    /// 速度取最近这么多次达标请求。
    static let recentSpeedRequests = 5
    /// 首字中位数取最近这么多次推得出首字的请求。
    static let recentFirstTokenRequests = 10
    /// Codex 增量解析只保留这么多次请求供上面两项使用。
    private static let retainedCodexRequests = 20

    private var consumed: UInt64 = 0
    private var inode: UInt64?
    private var claudeMessages: [String: ClaudeMessage] = [:]
    private var nodes: [String: Node] = [:]
    private var codexTotal = SessionUsageSnapshot()
    private var codexPrevious = SessionUsageSnapshot()
    private var codexBoundary: Date?
    private var codexRequestStart: Date?
    private var codexOutputEnd: Date?
    private var codexFirstOutput: Date?
    private var codexUsageRecord: CodexUsageRecord?
    private var codexToolAfterOutput = false
    private var codexAmbiguousTiming = false
    private var codexLastCount: Date?
    private var codexRequests: [TimedRequest] = []
    private var codexTimedTotals = TimedTotals()
    private var inheritedHistory = false
    private var cachedResult: SessionUsageSnapshot?
    public private(set) var codexEvents: [TimedSessionUsage] = []

    public init() {}

    /// 只消费完整行。文件截断或替换时重建状态，未完成行留待下次。
    public mutating func scan(path: String, source: String) -> SessionUsageSnapshot? {
        guard source == "claude" || source == "codex",
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let identity = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        if (inode != nil && inode != identity) || size < consumed { self = Self() }
        inode = identity
        if size == consumed { return cachedResult }
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { file.closeFile() }
        file.seek(toFileOffset: consumed)
        var pending = Data()
        while true {
            let chunk = file.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            pending.append(chunk)
            guard let last = pending.lastIndex(of: 10) else { continue }
            let complete = pending[...last]
            consumed += UInt64(complete.count)
            for line in complete.split(separator: 10) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if source == "claude" { consumeClaude(object) } else { consumeCodex(object) }
            }
            pending = Data(pending.dropFirst(complete.count))
        }
        if source == "codex" {
            guard !inheritedHistory, codexTotal.inputTokens + codexTotal.outputTokens + codexTotal.cacheReadTokens > 0 else { return nil }
            var result = codexTotal
            Self.applyTiming(codexRequests, totals: codexTimedTotals, to: &result)
            cachedResult = result
            return result
        }
        guard !claudeMessages.isEmpty else { return nil }
        var result = SessionUsageSnapshot()
        var requests: [TimedRequest] = []
        var totals = TimedTotals()
        for message in claudeMessages.values {
            result.inputTokens += message.usage.inputTokens
            result.outputTokens += message.usage.outputTokens
            result.cacheReadTokens += message.usage.cacheReadTokens
            result.cacheWriteTokens += message.usage.cacheWriteTokens
            // 只给写完整了、且看得到第一块的回复估时，否则起点对不上。
            guard message.complete, message.firstBlock, let end = message.end,
                  let start = claudeStart(message.parent),
                  let request = TimedRequest(start: start, end: end, firstOutput: message.firstOutput,
                                             output: message.usage.outputTokens) else { continue }
            requests.append(request)
            totals.add(request)
        }
        requests.sort { $0.end < $1.end }
        Self.applyTiming(requests, totals: totals, to: &result)
        cachedResult = result
        return result
    }

    /// 汇总窗口滚动后只保留仍可能参与统计的事件。
    public mutating func pruneCodexEvents(before cutoff: Date) {
        codexEvents.removeAll { $0.timestamp < cutoff }
    }

    /// `requests` 按结束时刻升序；速度只算最近几次达标请求，首字取最近几次的中位数。
    static func applyTiming(_ requests: [TimedRequest], totals: TimedTotals, to result: inout SessionUsageSnapshot) {
        result.timedOutputTokens = totals.output
        result.timedDurationMs = Int((totals.duration * 1000).rounded())
        result.lastTimedAt = totals.last
        let recent = requests.filter(\.speedEligible).suffix(recentSpeedRequests)
        let output = recent.reduce(0) { $0 + $1.output }
        let duration = recent.reduce(0) { $0 + $1.duration }
        result.estimatedTokensPerSecond = output > 0 && duration > 0 ? Double(output) / duration : nil
        result.speedSampleCount = recent.count
        result.estimatedFirstTokenSeconds = median(requests.compactMap(\.firstToken).suffix(recentFirstTokenRequests))
    }

    static func median<C: Collection>(_ values: C) -> Double? where C.Element == Double {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func claudeStart(_ parent: String?) -> Date? {
        var cursor = parent
        for _ in 0..<32 {
            guard let id = cursor, let node = nodes[id] else { return nil }
            if !node.attachment { return node.timestamp }
            cursor = node.parent
        }
        return nil
    }

    private mutating func consumeClaude(_ obj: [String: Any]) {
        let kind = obj["type"] as? String
        let timestamp = (obj["timestamp"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
        let parent = obj["parentUuid"] as? String
        if let uuid = obj["uuid"] as? String {
            nodes[uuid] = Node(parent: parent, timestamp: timestamp, attachment: kind == "attachment")
        }
        guard kind == "assistant", let message = obj["message"] as? [String: Any],
              let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] else { return }
        var row = claudeMessages[id] ?? {
            let firstBlock = (obj["apiBlockIndex"] as? Int ?? 0) == 0
            var row = ClaudeMessage(usage: .init(), parent: parent, firstBlock: firstBlock)
            if firstBlock, let timestamp { row.firstOutput = Self.thinkingStart(obj, message: message, blockEnd: timestamp) }
            return row
        }()
        // 后续块是同一消息的累计快照，不重复相加。
        row.usage.inputTokens = max(row.usage.inputTokens, nonnegative(usage["input_tokens"]))
        row.usage.outputTokens = max(row.usage.outputTokens, nonnegative(usage["output_tokens"]))
        row.usage.cacheReadTokens = max(row.usage.cacheReadTokens, nonnegative(usage["cache_read_input_tokens"]))
        row.usage.cacheWriteTokens = max(row.usage.cacheWriteTokens, nonnegative(usage["cache_creation_input_tokens"]))
        if let timestamp, row.end == nil || timestamp > row.end! { row.end = timestamp }
        if message["stop_reason"] is String { row.complete = true }
        claudeMessages[id] = row
    }

    /// 思考块开始的时刻：块写完的时刻减去 Claude Code 记的 `thinkingDurationMs`。
    /// 第一块是文字或工具调用时，时间戳只是它写完的时刻，推不出首字。
    private static func thinkingStart(_ obj: [String: Any], message: [String: Any], blockEnd: Date) -> Date? {
        guard let duration = (obj["thinkingDurationMs"] as? NSNumber)?.doubleValue, duration > 0,
              let content = message["content"] as? [[String: Any]],
              content.first?["type"] as? String == "thinking" else { return nil }
        return blockEnd.addingTimeInterval(-duration / 1000)
    }

    private mutating func consumeCodex(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let kind = payload["type"] as? String ?? ""
        let timestamp = (obj["timestamp"] as? String).flatMap(ClaudeUsageScanner.parseISO8601)
        // 分段继承历史时无法仅凭当前文件安全求会话增量。
        if type == "session_meta", payload["history_base"] != nil || payload["history_base_id"] != nil { inheritedHistory = true }
        if type == "event_msg", kind == "token_count", let info = payload["info"] as? [String: Any],
           let total = info["total_token_usage"] as? [String: Any] {
            let input = nonnegative(total["input_tokens"])
            let cached = min(input, nonnegative(total["cached_input_tokens"] ?? total["cache_read_input_tokens"]))
            let written = min(input - cached, nonnegative(total["cache_write_input_tokens"]))
            let output = nonnegative(total["output_tokens"])
            guard input >= codexPrevious.inputTokens + codexPrevious.cacheReadTokens + codexPrevious.cacheWriteTokens,
                  output >= codexPrevious.outputTokens, cached >= codexPrevious.cacheReadTokens,
                  written >= codexPrevious.cacheWriteTokens else { return }
            var current = SessionUsageSnapshot()
            current.inputTokens = input - cached - written
            current.outputTokens = output
            current.cacheReadTokens = cached
            current.cacheWriteTokens = written
            let outputDelta = output - codexPrevious.outputTokens
            let inputDelta = input - codexPrevious.inputTokens - codexPrevious.cacheReadTokens - codexPrevious.cacheWriteTokens
            let cacheDelta = cached - codexPrevious.cacheReadTokens
            let writeDelta = written - codexPrevious.cacheWriteTokens
            if let timestamp, inputDelta + outputDelta > 0 {
                codexEvents.append(TimedSessionUsage(timestamp: timestamp,
                    inputTokens: max(0, inputDelta - cacheDelta - writeDelta), outputTokens: outputDelta,
                    cacheReadTokens: cacheDelta, cacheWriteTokens: writeDelta))
            }
            if outputDelta > 0 {
                finishCodexRequest(at: timestamp, output: outputDelta, last: info["last_token_usage"] as? [String: Any])
            }
            codexPrevious = current
            codexTotal = current
            return
        }
        if type == "token_usage_record", let timestamp, let usage = payload["usage"] as? [String: Any] {
            codexUsageRecord = CodexUsageRecord(end: timestamp, input: nonnegative(usage["input_tokens"]),
                cached: nonnegative(usage["cached_input_tokens"]), output: nonnegative(usage["output_tokens"]))
            return
        }
        guard let timestamp else { return }
        if type == "turn_context" || (type == "response_item" && kind == "message" && payload["role"] as? String != "assistant") {
            codexBoundary = timestamp
        } else if type == "response_item", kind.hasSuffix("_output") {
            codexBoundary = timestamp
            if codexOutputEnd != nil { codexToolAfterOutput = true }
        } else if type == "response_item", kind == "reasoning" || kind.hasSuffix("_call") || (kind == "message" && payload["role"] as? String == "assistant") {
            if codexRequestStart == nil, let previous = codexLastCount,
               (0...0.1).contains(timestamp.timeIntervalSince(previous)) { return }
            if codexToolAfterOutput { codexAmbiguousTiming = true }
            if codexRequestStart == nil { codexRequestStart = codexBoundary }
            codexOutputEnd = timestamp
            codexToolAfterOutput = false
        } else if type == "event_msg", kind == "item_completed", let started = Self.codexOutputItemStart(payload) {
            // 一次响应里最早开始生成的思考或回复项即首字。
            codexFirstOutput = min(codexFirstOutput ?? started, started)
        } else if type == "event_msg", kind == "task_started" || kind == "turn_aborted" {
            codexBoundary = timestamp
            resetCodexRequest()
        }
    }

    /// 遇到一次有输出的 `token_count`：结算这次请求的耗时与首字，并把它记成下一次请求的起点。
    private mutating func finishCodexRequest(at timestamp: Date?, output: Int, last: [String: Any]?) {
        // `token_usage_record` 写在响应结束时，比可能等工具跑完才写的 `token_count` 准；
        // 用量要和这次请求自己的用量对得上才算同一次。
        let recordEnd = codexUsageRecord.flatMap { record -> Date? in
            guard let last else { return record.end }
            let matches = record.input == nonnegative(last["input_tokens"])
                && record.cached == nonnegative(last["cached_input_tokens"])
                && record.output == nonnegative(last["output_tokens"])
            return matches ? record.end : nil
        }
        let end = recordEnd ?? (codexToolAfterOutput ? codexOutputEnd : timestamp)
        if !codexAmbiguousTiming, let start = codexRequestStart ?? codexBoundary, let end,
           let request = TimedRequest(start: start, end: end, firstOutput: codexFirstOutput, output: output) {
            codexTimedTotals.add(request)
            codexRequests.append(request)
            if codexRequests.count > Self.retainedCodexRequests {
                codexRequests.removeFirst(codexRequests.count - Self.retainedCodexRequests)
            }
        }
        codexBoundary = timestamp
        codexLastCount = timestamp
        resetCodexRequest()
    }

    /// 没等到 `token_count` 的请求留下的线索要清掉，否则会被下一次请求沿用。
    private mutating func resetCodexRequest() {
        codexRequestStart = nil
        codexOutputEnd = nil
        codexFirstOutput = nil
        codexUsageRecord = nil
        codexToolAfterOutput = false
        codexAmbiguousTiming = false
    }

    /// 新版 Codex `item_completed` 里模型输出项（思考、回复）开始生成的时刻；工具执行等不算。
    private static func codexOutputItemStart(_ payload: [String: Any]) -> Date? {
        guard let item = payload["item"] as? [String: Any],
              let type = item["type"] as? String, type == "Reasoning" || type == "AgentMessage",
              let ms = (payload["started_at_ms"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func nonnegative(_ value: Any?) -> Int { max(0, value as? Int ?? 0) }
}
