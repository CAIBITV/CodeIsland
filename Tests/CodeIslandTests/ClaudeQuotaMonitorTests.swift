import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class ClaudeQuotaMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClaudeQuotaMonitorTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set(true, forKey: SettingsKey.showClaudeQuota)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static let snapshot = ClaudeQuotaSnapshot(limits: [
        ClaudeQuotaLimit(kind: .session, percent: 3, resetsAt: Date().addingTimeInterval(3600)),
    ], fetchedAt: Date())

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    func testLaunchExpandAndStopUseLocalQuotaWithoutFetching() async {
        let counter = Counter()
        var reading = ClaudeQuotaMonitor.LocalReading(key: "account", snapshot: nil, setup: .connected)
        let monitor = ClaudeQuotaMonitor(defaults: defaults, readLocal: { reading }, fetcher: {
            await counter.bump()
            return Self.snapshot
        })

        monitor.noteExpanded()
        reading = .init(key: "account", snapshot: Self.snapshot, setup: .connected)
        monitor.noteStop()
        XCTAssertEqual(monitor.snapshot, Self.snapshot)
        XCTAssertTrue(monitor.isLocalSnapshot)
        let requests = await counter.value
        XCTAssertEqual(requests, 0)
    }

    func testFailedManualRefreshKeepsLocalSnapshot() async {
        let monitor = ClaudeQuotaMonitor(defaults: defaults, readLocal: {
            .init(key: "account", snapshot: Self.snapshot, setup: .connected)
        }, fetcher: { throw ClaudeQuotaClientError.rateLimited })
        monitor.fetchNow()
        for _ in 0..<100 where monitor.isLoading { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(monitor.lastError, .rateLimited)
        XCTAssertEqual(monitor.snapshot, Self.snapshot)
    }

    func testSwitchingWorkspaceDiscardsAnInFlightReading() async {
        var key = "personal"
        let monitor = ClaudeQuotaMonitor(defaults: defaults, readLocal: {
            .init(key: key, snapshot: nil, setup: .connected)
        }, fetcher: {
            try? await Task.sleep(for: .milliseconds(30))
            return Self.snapshot
        })
        monitor.fetchNow()
        key = "work"
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(monitor.isLoading)
        XCTAssertNil(monitor.snapshot)
    }
}
