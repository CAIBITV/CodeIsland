import XCTest
@testable import CodeIslandCore

final class ClaudeQuotaStatuslineTests: XCTestCase {
    func testRecordsOnlyWindowsForTheMatchingWorkspace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude.json")
        let root = home.appendingPathComponent(".claude").path
        try Data(#"{"oauthAccount":{"accountUuid":"test","organizationUuid":"personal"}}"#.utf8).write(to: settings)
        let personal = try XCTUnwrap(ClaudeQuotaStatusline.Profile(configDir: root, home: home.path))

        let data = Data(#"{"session_id":"ignored","rate_limits":{"five_hour":{"used_percentage":17.5,"resets_at":1900000000},"seven_day":{"used_percentage":0},"spend_limit":{"used_percentage":95}}}"#.utf8)
        let date = Date(timeIntervalSince1970: 1_899_999_900)
        personal.record(data, at: date)
        personal.record(data, at: date.addingTimeInterval(15))
        let snapshot = try XCTUnwrap(personal.read())
        XCTAssertEqual(snapshot.limit(.session)?.percent, 17.5)
        XCTAssertEqual(snapshot.limit(.session)?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(snapshot.limit(.weeklyAll)?.percent, 0)
        XCTAssertEqual(snapshot.limits.count, 2)
        XCTAssertEqual(snapshot.fetchedAt, date)

        try Data(#"{"oauthAccount":{"accountUuid":"test","organizationUuid":"work"}}"#.utf8).write(to: settings)
        let work = try XCTUnwrap(ClaudeQuotaStatusline.Profile(configDir: root, home: home.path))
        XCTAssertNotEqual(work.key, personal.key)
        XCTAssertNil(work.read())
    }
}
