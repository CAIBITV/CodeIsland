import Foundation

/// 从本地 Codex rollout 增量汇总用量；无法安全处理的继承历史不计入。
public enum CodexUsageScanner {
    public struct FileCache: Sendable {
        var scanners: [String: SessionUsageScanner] = [:]
        public init() {}
    }

    public static func scan(codexHomes: [String], now: Date = Date(), cache: inout FileCache) -> ClaudeUsageScanner.Snapshot {
        let midnight = Calendar.current.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let cutoff = min(midnight, fiveHoursAgo, now.addingTimeInterval(-12 * 3600))
        var today = ClaudeUsageTotals()
        var last5h = ClaudeUsageTotals()
        var hourly = [Int](repeating: 0, count: ClaudeUsageScanner.sparklineHours)
        var active = Set<String>()
        var roots = Set<String>()
        let fm = FileManager.default
        for home in codexHomes {
            let root = URL(fileURLWithPath: home).appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
            guard roots.insert(root.path).inserted,
                  let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let modified = values.contentModificationDate, modified >= cutoff else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard active.insert(path).inserted else { continue }
                var scanner = cache.scanners[path] ?? SessionUsageScanner()
                if scanner.scan(path: path, source: "codex") != nil {
                    for event in scanner.codexEvents where event.timestamp >= cutoff && event.timestamp <= now {
                        var usage = ClaudeUsageTotals()
                        usage.inputTokens = event.inputTokens
                        usage.outputTokens = event.outputTokens
                        usage.cacheReadTokens = event.cacheReadTokens
                        usage.cacheCreationTokens = event.cacheWriteTokens
                        usage.messageCount = 1
                        if event.timestamp >= midnight { today.add(usage) }
                        if event.timestamp >= fiveHoursAgo { last5h.add(usage) }
                        let hoursAgo = Int(now.timeIntervalSince(event.timestamp) / 3600)
                        if hoursAgo >= 0 && hoursAgo < hourly.count { hourly[hourly.count - 1 - hoursAgo] += event.outputTokens }
                    }
                }
                scanner.pruneCodexEvents(before: cutoff)
                cache.scanners[path] = scanner
            }
        }
        cache.scanners = cache.scanners.filter { active.contains($0.key) }
        return ClaudeUsageScanner.Snapshot(last5h: last5h, today: today, hourlyOutputTokens: hourly, scannedAt: now)
    }
}
