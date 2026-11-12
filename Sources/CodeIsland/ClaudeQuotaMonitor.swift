import CodeIslandCore
import Foundation

/// 套餐额度优先来自本机状态栏，只有用户点刷新时才查询服务端。
@MainActor
@Observable
final class ClaudeQuotaMonitor {
    private(set) var lastError: ClaudeQuotaClientError?
    private(set) var isExpanded = false
    private(set) var isLoading = false
    private(set) var statuslineSetup = ConfigInstaller.ClaudeQuotaStatuslineSetup.unavailable

    private var localSnapshot: ClaudeQuotaSnapshot?
    private var manualSnapshot: ClaudeQuotaSnapshot?
    @ObservationIgnored private var profileKey: String?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var manualRequest: UUID?
    @ObservationIgnored private let fetcher: @Sendable () async throws -> ClaudeQuotaSnapshot
    @ObservationIgnored private let readLocal: () -> LocalReading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    struct LocalReading {
        let key: String?
        let snapshot: ClaudeQuotaSnapshot?
        let setup: ConfigInstaller.ClaudeQuotaStatuslineSetup
    }

    init(
        defaults: UserDefaults = .standard,
        readLocal: @escaping () -> LocalReading = {
            guard !RuntimeEnvironment.isRunningTests else {
                return LocalReading(key: nil, snapshot: nil, setup: .unavailable)
            }
            let profile = ClaudeQuotaStatusline.Profile(configDir: ClaudeConfigPaths.configDir())
            return LocalReading(key: profile?.key, snapshot: profile?.read(),
                                setup: ConfigInstaller.claudeQuotaStatuslineSetup(profile: profile))
        },
        fetcher: @escaping @Sendable () async throws -> ClaudeQuotaSnapshot = {
            guard !RuntimeEnvironment.isRunningTests else { throw ClaudeQuotaClientError.noCredential }
            let root = ClaudeConfigPaths.configDir()
            let isDefault = ConfigPathIdentity.identity(of: root) == ConfigPathIdentity.identity(of: NSHomeDirectory() + "/.claude")
            return try await ClaudeQuotaClient.fetch(credential: {
                if isDefault { return ClaudeCredentialStore.load() }
                return ClaudeCredentialStore.readFile(claudeHome: root).flatMap(ClaudeCredentialStore.parse)
            })
        }
    ) {
        self.defaults = defaults
        self.readLocal = readLocal
        self.fetcher = fetcher
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateMonitoring() }
        }
        updateMonitoring()
    }

    deinit {
        readTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isEnabled: Bool { defaults.bool(forKey: SettingsKey.showClaudeQuota) }

    var chipMode: ClaudeQuotaChipMode {
        ClaudeQuotaChipMode(rawValue: defaults.string(forKey: SettingsKey.claudeQuotaChip) ?? "") ?? .auto
    }

    var chipVisible: Bool { isEnabled && chipMode != .off }
    var wantsLive: Bool { isEnabled && (chipVisible || isExpanded) }

    var isLocalSnapshot: Bool {
        guard let localSnapshot else { return false }
        return manualSnapshot.map { localSnapshot.fetchedAt >= $0.fetchedAt } ?? true
    }

    var snapshot: ClaudeQuotaSnapshot? { isLocalSnapshot ? localSnapshot : manualSnapshot }

    func noteStop() {
        if wantsLive { refreshLocal() }
    }

    func noteExpanded() {
        isExpanded = true
        updateMonitoring()
    }

    func noteCollapsed() {
        isExpanded = false
        updateMonitoring()
    }

    func refreshLocal() {
        guard isEnabled, !RuntimeEnvironment.isIsolated else { return }
        let reading = readLocal()
        if profileKey != reading.key {
            profileKey = reading.key
            manualSnapshot = nil
            lastError = nil
            manualRequest = nil
            isLoading = false
        }
        if localSnapshot != reading.snapshot { localSnapshot = reading.snapshot }
        if statuslineSetup != reading.setup { statuslineSetup = reading.setup }
    }

    private func updateMonitoring() {
        if !wantsLive {
            readTask?.cancel()
            readTask = nil
        }
        if !isEnabled {
            localSnapshot = nil
            manualSnapshot = nil
            manualRequest = nil
            isLoading = false
            lastError = nil
        }
        guard wantsLive, !RuntimeEnvironment.isIsolated else { return }
        refreshLocal()
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.refreshLocal()
            }
        }
    }

    func fetchNow() {
        guard isEnabled, !RuntimeEnvironment.isIsolated else { return }
        refreshLocal()
        guard !isLoading else { return }
        let request = UUID()
        manualRequest = request
        isLoading = true
        let fetcher = self.fetcher
        Task { [weak self] in
            let result: Result<ClaudeQuotaSnapshot, Error>
            do { result = .success(try await fetcher()) } catch { result = .failure(error) }
            guard let self, self.isEnabled else { return }
            self.refreshLocal()
            guard self.manualRequest == request else { return }
            self.manualRequest = nil
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                self.manualSnapshot = snapshot
                self.lastError = nil
            case .failure(let error):
                self.lastError = (error as? ClaudeQuotaClientError) ?? .transport(error.localizedDescription)
            }
        }
    }

    /// 供预览和离屏渲染注入读数。
    func applyPreview(_ snapshot: ClaudeQuotaSnapshot) {
        manualSnapshot = snapshot
        lastError = nil
    }
}
