import CryptoKit
import Foundation

public struct CodexAccountUsage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let name: String?
        public let minutes: Int?
        public let usedPercent: Int
        public let resetsAt: Date?
    }

    public private(set) var windows: [Window] = []
    public private(set) var resetCount: Int?
    public private(set) var earliestResetExpiry: Date?
    public private(set) var lifetimeTokens: Int?
    public private(set) var windowsAt: Date?
    public private(set) var limitsAt: Date?
    public private(set) var lifetimeAt: Date?

    public init() {}

    mutating func applyLimits(_ result: [String: AnyCodableLike], at date: Date = Date()) {
        applyWindows(result, at: date)
        limitsAt = date
        earliestResetExpiry = nil
        let resets = result["rateLimitResetCredits"]?.asObject
        resetCount = resets?["availableCount"]?.nonnegativeInteger
        if case .array(let credits) = resets?["credits"] {
            earliestResetExpiry = credits.compactMap { credit -> Date? in
                guard let entry = credit.asObject, entry["status"]?.asString == "available" else { return nil }
                return entry["expiresAt"]?.unixDate
            }.min()
        }
    }

    private mutating func applyWindows(_ result: [String: AnyCodableLike], at date: Date) {
        let buckets = result["rateLimitsByLimitId"]?.asObject ?? [:]
        let primary = buckets["codex"]?.asObject ?? result["rateLimits"]?.asObject
        windows = primary.map { Self.windows($0, name: nil) } ?? []
        for key in buckets.keys.sorted() where key != "codex" && key != primary?["limitId"]?.asString {
            guard let bucket = buckets[key]?.asObject else { continue }
            windows += Self.windows(bucket, name: bucket["limitName"]?.asString ?? key)
        }
        windowsAt = date
    }

    mutating func applyUsage(_ result: [String: AnyCodableLike], at date: Date = Date()) {
        lifetimeTokens = result["summary"]?.asObject?["lifetimeTokens"]?.nonnegativeInteger
        lifetimeAt = date
    }

    /// 通知只更新额度窗口，重置次数和账户累计各自保留原来的查询时间。
    public static func notification(_ params: [String: AnyCodableLike], at date: Date = Date()) -> Self? {
        if let limitID = params["rateLimits"]?.asObject?["limitId"]?.asString, limitID != "codex" {
            return nil
        }
        var update = Self()
        update.applyWindows(params, at: date)
        return update.windows.isEmpty ? nil : update
    }

    public mutating func merge(_ update: Self) {
        if let date = update.windowsAt, windowsAt.map({ $0 <= date }) ?? true {
            let extraWindows = update.limitsAt == nil ? windows.filter { $0.name != nil } : []
            windows = update.windows + extraWindows
            windowsAt = date
        }
        if let date = update.limitsAt, limitsAt.map({ $0 <= date }) ?? true {
            resetCount = update.resetCount
            earliestResetExpiry = update.earliestResetExpiry
            limitsAt = date
        }
        if let date = update.lifetimeAt, lifetimeAt.map({ $0 <= date }) ?? true {
            lifetimeTokens = update.lifetimeTokens
            lifetimeAt = date
        }
    }

    /// 只用文件登录的用户和工作区标识绑定缓存，凭据本身不进入缓存。
    public static func cacheKey(codexHome: String) -> String? {
        let root = URL(fileURLWithPath: codexHome, isDirectory: true).resolvingSymlinksInPath()
        if let config = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8),
           config.contains("cli_auth_credentials_store") {
            let fileSetting = #"(?m)^\s*["']?cli_auth_credentials_store["']?\s*=\s*["']file["']\s*(?:#.*)?$"#
            guard config.range(of: fileSetting, options: .regularExpression) != nil else { return nil }
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              document["auth_mode"] as? String != "apikey",
              let tokens = document["tokens"] as? [String: Any],
              let workspace = tokens["account_id"] as? String, !workspace.isEmpty,
              let token = tokens["id_token"] as? String else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.utf8.count % 4) % 4)
        guard let decoded = Data(base64Encoded: body),
              let claims = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any] else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        guard let user = (auth?["chatgpt_user_id"] ?? claims["sub"]) as? String, !user.isEmpty else { return nil }
        return SHA256.hash(data: Data([root.path, workspace, user].joined(separator: "\u{0}").utf8)).description
    }

    private static func windows(_ bucket: [String: AnyCodableLike], name: String?) -> [Window] {
        ["primary", "secondary"].compactMap { key in
            guard let window = bucket[key]?.asObject, let used = window["usedPercent"]?.nonnegativeInteger else { return nil }
            return Window(name: name, minutes: window["windowDurationMins"]?.nonnegativeInteger,
                          usedPercent: used, resetsAt: window["resetsAt"]?.unixDate)
        }
    }

    /// 在同一个临时连接中查询需要更新的字段，超时后仍返回已收到的数据。
    public static func fetch(executableURL: URL, includeLimits: Bool = true, includeLifetime: Bool = true,
                             timeout: Duration = .seconds(12)) async -> Self {
        let methods = [includeLimits ? "account/rateLimits/read" : nil,
                       includeLifetime ? "account/usage/read" : nil].compactMap { $0 }
        guard !methods.isEmpty else { return Self() }
        let client = CodexAppServerClient(executableURL: executableURL)
        let (messages, continuation) = AsyncStream.makeStream(of: CodexJSONRPCMessage.self)
        client.onMessage = { _ = continuation.yield($0) }
        client.onExit = { _ in continuation.finish() }

        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.finish()
        }
        defer {
            timer.cancel()
            continuation.finish()
            client.stop()
        }

        var snapshot = Self()
        do {
            try client.start()
            let handshake = try client.initializeHandshake(clientName: "CodeIsland", clientVersion: "1")
            var pending: [CodexRequestID: String] = [:]
            for await message in messages {
                switch message.kind {
                case .response(let id) where id == handshake:
                    try client.sendNotification(method: "initialized")
                    for method in methods {
                        pending[try client.sendRequest(method: method)] = method
                    }
                case .response(let id):
                    guard let method = pending.removeValue(forKey: id) else { continue }
                    if let result = message.raw["result"]?.asObject {
                        if method == "account/rateLimits/read" { snapshot.applyLimits(result) }
                        else { snapshot.applyUsage(result) }
                    }
                    if pending.isEmpty { return snapshot }
                case .error(let id, _, _):
                    if id == handshake { return snapshot }
                    if let id, pending.removeValue(forKey: id) != nil, pending.isEmpty { return snapshot }
                default: continue
                }
            }
        } catch {
            return snapshot
        }
        return snapshot
    }
}

private extension AnyCodableLike {
    var nonnegativeInteger: Int? {
        guard case .int(let value) = self, value >= 0 else { return nil }
        return Int(exactly: value)
    }

    var unixDate: Date? {
        guard let seconds = nonnegativeInteger, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }
}
