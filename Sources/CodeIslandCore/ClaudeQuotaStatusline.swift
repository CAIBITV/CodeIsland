import CryptoKit
import Foundation

/// 接收 Claude Code 状态栏已经取得的套餐额度，只落盘额度窗口和时间。
public enum ClaudeQuotaStatusline {
    public static let bridgeFlag = "--claude-quota-statusline"

    public struct Profile: Equatable, Sendable {
        public let key: String
        private let cacheFolder: String

        public init?(configDir: String, home: String = NSHomeDirectory()) {
            let root = ConfigPathIdentity.identity(of: configDir)
            let defaultRoot = ConfigPathIdentity.identity(of: home + "/.claude")
            let legacy = root + "/.config.json"
            let legacySize = (try? FileManager.default.attributesOfItem(atPath: legacy)[.size] as? NSNumber)?.intValue ?? 0
            let profilePath = legacySize > 0 ? legacy : (root == defaultRoot ? home : root) + "/.claude.json"
            guard let data = FileManager.default.contents(atPath: profilePath),
                  let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let account = document["oauthAccount"] as? [String: Any],
                  let user = account["accountUuid"] as? String, !user.isEmpty else { return nil }
            let organization = account["organizationUuid"] as? String ?? ""
            let digest = SHA256.hash(data: Data([root, user, organization].joined(separator: "\u{0}").utf8))
            key = digest.map { String(format: "%02x", $0) }.joined()
            cacheFolder = home + "/.codeisland"
        }

        private var path: String { cacheFolder + "/claude-quota-" + key + ".json" }

        public func read() -> ClaudeQuotaSnapshot? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? JSONDecoder().decode(ClaudeQuotaSnapshot.self, from: data)
        }

        public func record(_ data: Data, at date: Date = Date()) {
            guard let snapshot = ClaudeQuotaStatusline.parse(data, at: date),
                  read()?.limits != snapshot.limits,
                  PrivateFiles.prepareFolder(cacheFolder),
                  let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? PrivateFiles.write(encoded, to: path)
        }
    }

    public static func parse(_ data: Data, at date: Date = Date()) -> ClaudeQuotaSnapshot? {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let windows = document["rate_limits"] as? [String: [String: Any]] else { return nil }
        let kinds: [(String, ClaudeQuotaLimit.Kind)] = [("five_hour", .session), ("seven_day", .weeklyAll)]
        let limits = kinds.compactMap { key, kind -> ClaudeQuotaLimit? in
            guard let window = windows[key],
                  let percent = AnyCodableLike.from(window["used_percentage"]).finiteNumber,
                  percent >= 0, percent <= 100 else { return nil }
            let resetsAt = AnyCodableLike.from(window["resets_at"]).finiteNumber.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            }
            return ClaudeQuotaLimit(kind: kind, percent: percent, resetsAt: resetsAt)
        }
        return limits.isEmpty ? nil : ClaudeQuotaSnapshot(limits: limits, fetchedAt: date)
    }
}

private extension AnyCodableLike {
    var finiteNumber: Double? {
        switch self {
        case .int(let number): return Double(number)
        case .double(let number) where number.isFinite: return number
        default: return nil
        }
    }
}
