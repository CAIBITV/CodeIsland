import XCTest
@testable import CodeIslandCore

final class CodexAccountUsageTests: XCTestCase {
    func testFetchKeepsQuotaWhenAccountTotalsFail() async throws {
        let stub = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stub) }
        let script = #"""
        #!/bin/sh
        IFS= read -r init || exit 1
        case "$init" in *'"method":"initialize"'*) ;; *) exit 2 ;; esac
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r ready || exit 1
        case "$ready" in *'"method":"initialized"'*) ;; *) exit 2 ;; esac
        IFS= read -r limits || exit 1
        case "$limits" in *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*) ;; *) exit 2 ;; esac
        IFS= read -r usage || exit 1
        case "$usage" in *'"method":"account/usage/read"'*|*'"method":"account\/usage\/read"'*) ;; *) exit 2 ;; esac
        printf '%s\n' '{"id":3,"error":{"code":-32601,"message":"Unavailable"}}'
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1900000000}},"rateLimitResetCredits":{"availableCount":0}}}'
        IFS= read -r stop
        """#
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        let result = await CodexAccountUsage.fetch(executableURL: stub, timeout: .seconds(3))
        XCTAssertEqual(result.resetCount, 0)
        XCTAssertEqual(result.windows.first?.usedPercent, 1)
        XCTAssertEqual(result.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(result.lifetimeTokens)
    }

    func testAbsentResetCountAndZeroLifetimeRemainDistinct() throws {
        let payload = Data(#"{"id":3,"result":{"summary":{"lifetimeTokens":0}}}"#.utf8)
        let message = try XCTUnwrap(CodexAppServerClient.parseMessage(payload))
        var snapshot = CodexAccountUsage()
        snapshot.applyUsage(try XCTUnwrap(message.raw["result"]?.asObject))
        XCTAssertEqual(snapshot.lifetimeTokens, 0)
        XCTAssertNil(snapshot.resetCount)
    }

    func testRefreshingLimitsCanSkipTheLifetimeRequest() async throws {
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stub) }
        try PrivateFiles.write(Data(#"""
        #!/bin/sh
        IFS= read -r init || exit 1
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r ready || exit 1
        IFS= read -r limits || exit 1
        case "$limits" in *'"method":"account/rateLimits/read"'*|*'"method":"account\/rateLimits\/read"'*) ;; *) exit 2 ;; esac
        printf '%s\n' '{"id":2,"result":{"rateLimitResetCredits":{"availableCount":2}}}'
        if IFS= read -r extra; then
            printf '%s\n' '{"id":3,"result":{"summary":{"lifetimeTokens":100}}}'
            IFS= read -r stop
        fi
        """#.utf8), to: stub.path, mode: 0o700)

        let result = await CodexAccountUsage.fetch(executableURL: stub, includeLifetime: false, timeout: .seconds(3))
        XCTAssertEqual(result.resetCount, 2)
        XCTAssertNil(result.lifetimeAt)
    }

    func testWindowNotificationDoesNotReplaceCreditsOrLifetime() throws {
        let before = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = CodexAccountUsage()
        snapshot.applyLimits(["rateLimitResetCredits": .object(["availableCount": .int(2)])], at: before)
        snapshot.applyUsage(["summary": .object(["lifetimeTokens": .int(100)])], at: before)
        let after = before.addingTimeInterval(60)
        let update = try XCTUnwrap(CodexAccountUsage.notification(["rateLimits": .object([
            "primary": .object(["usedPercent": .int(40), "windowDurationMins": .int(300)])
        ])], at: after))
        snapshot.merge(update)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 40)
        XCTAssertEqual(snapshot.windowsAt, after)
        XCTAssertEqual(snapshot.resetCount, 2)
        XCTAssertEqual(snapshot.lifetimeTokens, 100)
        XCTAssertEqual(snapshot.limitsAt, before)
        XCTAssertEqual(snapshot.lifetimeAt, before)
    }
}
