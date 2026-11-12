import CodeIslandCore
import Foundation

enum UsageDetailSource: String, CaseIterable, Identifiable {
    case all, claude, codex

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return L10n.shared["usage_detail_all"]
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var providers: [Self] { self == .all ? [.claude, .codex] : [self] }
}

struct UsageHistory: Sendable {
    let days: [Date]
    let claude: [Date: ClaudeUsageTotals]
    let codex: [Date: ClaudeUsageTotals]

    func usage(on day: Date, source: UsageDetailSource) -> ClaudeUsageTotals {
        var total = ClaudeUsageTotals()
        if source != .codex, let value = claude[day] { total.add(value) }
        if source != .claude, let value = codex[day] { total.add(value) }
        return total
    }

    func total(for source: UsageDetailSource) -> ClaudeUsageTotals {
        days.reduce(into: ClaudeUsageTotals()) { $0.add(usage(on: $1, source: source)) }
    }
}

@MainActor
@Observable
final class UsageDetailMonitor {
    private(set) var history: UsageHistory?
    private(set) var codexAccount: CodexAccountUsage?
    private(set) var isLoadingCodex = false
    private(set) var codexLimitsRefreshFailed = false
    private var codexLifetimeRefreshFailed = false
    var codexRefreshFailed: Bool { codexLimitsRefreshFailed || codexLifetimeRefreshFailed }

    @ObservationIgnored private var historyCache = HistoryCache()
    @ObservationIgnored private var historyScannedAt: Date?
    @ObservationIgnored private var isLoadingHistory = false
    @ObservationIgnored private var codexAccountKey: String?
    @ObservationIgnored private var loadedCodexAccount = false
    @ObservationIgnored private var codexRequest: UUID?
    @ObservationIgnored private var fetchingLifetime = false
    @ObservationIgnored private var pendingLifetimeRefresh: Bool?
    @ObservationIgnored private var limitsAttemptedAt: Date?
    @ObservationIgnored private var lifetimeAttemptedAt: Date?

    private struct CachedCodexUsage: Codable {
        let accountKey: String
        let usage: CodexAccountUsage

        static let folder = NSHomeDirectory() + "/.codeisland"
        static let path = folder + "/codex-account-usage.json"

        static func read(_ accountKey: String) -> CodexAccountUsage? {
            guard let data = FileManager.default.contents(atPath: path),
                  let cache = try? JSONDecoder().decode(Self.self, from: data),
                  cache.accountKey == accountKey else { return nil }
            return cache.usage
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self), PrivateFiles.prepareFolder(Self.folder) else { return }
            try? PrivateFiles.write(data, to: Self.path)
        }
    }

    private struct HistoryCache: Sendable {
        var claude = ClaudeUsageScanner.FileCache()
        var codex = CodexUsageScanner.FileCache()
    }

    func refreshHistory(force: Bool = false) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showUsageStats), !isLoadingHistory,
              !RuntimeEnvironment.isRunningTests else { return }
        let now = Date()
        let calendar = Calendar.current
        let days = UsageHistoryDays.dates(endingAt: now, calendar: calendar)
        if !force, history?.days == days, let historyScannedAt, now.timeIntervalSince(historyScannedAt) < 60 { return }

        let claudeHomes = ConfigInstaller.isEnabled(source: "claude") ? ClaudeConfigPaths.allConfigDirs() : []
        let codexHomes = ConfigInstaller.isEnabled(source: "codex") ? ConfigInstaller.codexHomes() : []
        let previous = historyCache
        isLoadingHistory = true
        let scan = Task.detached(priority: .utility) {
            var cache = previous
            let claude = ClaudeUsageScanner.scan(claudeHomes: claudeHomes, now: now, calendar: calendar,
                                                includeHistory: true, cache: &cache.claude)
            let codex = CodexUsageScanner.scan(codexHomes: codexHomes, now: now, calendar: calendar,
                                              includeHistory: true, cache: &cache.codex)
            return (UsageHistory(days: days, claude: claude.dailyTotals, codex: codex.dailyTotals), cache)
        }
        Task { [weak self] in
            let (history, cache) = await scan.value
            self?.history = history
            self?.historyCache = cache
            self?.historyScannedAt = now
            self?.isLoadingHistory = false
        }
    }

    func refreshCodex(force: Bool = false, includeLifetime: Bool = true) {
        guard codexQuotaEnabled else { return }
        let accountKey = Self.currentCodexAccountKey()
        selectCodexAccount(accountKey)
        let now = Date()
        let windows = codexAccount?.windows ?? []
        let windowReset = windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
        let creditExpired = codexAccount?.earliestResetExpiry.map { $0 <= now } ?? false
        let limitsStale = !Self.isRecent(codexAccount?.windowsAt, at: now, for: 5 * 60)
            || !Self.isRecent(codexAccount?.limitsAt, at: now, for: 30 * 60)
        let limitsDue = force || ((limitsStale || windowReset || creditExpired)
            && !Self.isRecent(limitsAttemptedAt, at: now, for: 60))
        let lifetimeDue = includeLifetime && (force || (!Self.isRecent(codexAccount?.lifetimeAt, at: now, for: 24 * 3600)
            && !Self.isRecent(lifetimeAttemptedAt, at: now, for: 10 * 60)))
        guard limitsDue || lifetimeDue else { return }
        if isLoadingCodex {
            // 底栏在查额度时点进详情，额度返回后再查账户累计用量。
            if lifetimeDue, !fetchingLifetime { pendingLifetimeRefresh = (pendingLifetimeRefresh == true) || force }
            return
        }
        if limitsDue { limitsAttemptedAt = now }
        if lifetimeDue { lifetimeAttemptedAt = now }
        guard let executable = Self.codexExecutable() else {
            if limitsDue { codexLimitsRefreshFailed = true }
            if lifetimeDue { codexLifetimeRefreshFailed = true }
            return
        }
        let request = UUID()
        codexRequest = request
        fetchingLifetime = lifetimeDue
        isLoadingCodex = true
        Task { [weak self] in
            let update = await CodexAccountUsage.fetch(executableURL: executable,
                                                       includeLimits: limitsDue, includeLifetime: lifetimeDue)
            guard let self, self.codexRequest == request else { return }
            self.codexRequest = nil
            self.isLoadingCodex = false
            self.fetchingLifetime = false
            let pendingLifetime = self.pendingLifetimeRefresh
            self.pendingLifetimeRefresh = nil
            guard self.codexQuotaEnabled else { return }
            let current = Self.currentCodexAccountKey()
            guard current == accountKey else {
                self.selectCodexAccount(current)
                return
            }
            if limitsDue { self.codexLimitsRefreshFailed = update.limitsAt == nil }
            if lifetimeDue { self.codexLifetimeRefreshFailed = update.lifetimeAt == nil }
            self.mergeCodex(update, accountKey: accountKey)
            if let pendingLifetime { self.refreshCodex(force: pendingLifetime) }
        }
    }

    static func currentCodexAccountKey() -> String? {
        CodexAccountUsage.cacheKey(codexHome: ConfigInstaller.codexHome())
    }

    func receiveCodexLimits(_ params: [String: AnyCodableLike], accountKey: String) {
        guard codexQuotaEnabled, Self.currentCodexAccountKey() == accountKey,
              let update = CodexAccountUsage.notification(params) else { return }
        selectCodexAccount(accountKey)
        mergeCodex(update, accountKey: accountKey)
        codexLimitsRefreshFailed = false
    }

    func codexLoginDidChange() {
        guard codexQuotaEnabled else { return }
        let key = Self.currentCodexAccountKey()
        if key == nil { loadedCodexAccount = false }
        selectCodexAccount(key)
    }

    func endViewingCodex() {
        guard loadedCodexAccount, codexAccountKey == nil else { return }
        loadedCodexAccount = false
        selectCodexAccount(nil)
    }

    private var codexQuotaEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.showCodexQuota)
            && !RuntimeEnvironment.isRunningTests && !RuntimeEnvironment.isIsolated
    }

    private func selectCodexAccount(_ key: String?) {
        guard !loadedCodexAccount || key != codexAccountKey else { return }
        loadedCodexAccount = true
        codexAccountKey = key
        codexAccount = key.flatMap(CachedCodexUsage.read)
        codexLimitsRefreshFailed = false
        codexLifetimeRefreshFailed = false
        codexRequest = nil
        fetchingLifetime = false
        pendingLifetimeRefresh = nil
        isLoadingCodex = false
        limitsAttemptedAt = nil
        lifetimeAttemptedAt = nil
    }

    private func mergeCodex(_ update: CodexAccountUsage, accountKey: String?) {
        guard update.windowsAt != nil || update.lifetimeAt != nil else { return }
        var snapshot = codexAccount ?? CodexAccountUsage()
        snapshot.merge(update)
        codexAccount = snapshot
        if let accountKey {
            CachedCodexUsage(accountKey: accountKey, usage: snapshot).save()
        }
    }

    private static func isRecent(_ date: Date?, at now: Date, for interval: TimeInterval) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < interval
    }

    func applyPreview(_ history: UsageHistory, codex: CodexAccountUsage) {
        self.history = history
        codexAccount = codex
    }

    private static func codexExecutable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let locations = path.split(separator: ":").map(String.init) + [
            NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"
        ]
        for location in locations where location.hasPrefix("/") {
            let path = location + "/codex"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return AppState.codexAppServerExecutableURL()
    }
}
