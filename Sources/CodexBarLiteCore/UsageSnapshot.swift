// Codex-only models adapted from CodexBar's CodexOAuthUsageFetcher and CodexRateWindowNormalizer (MIT).
import Foundation

public struct UsageWindow: Equatable, Sendable, Identifiable {
    public let id: String
    public let usedPercent: Double
    public let duration: Int
    public let resetsAt: Date?

    public var remainingPercent: Double {
        100 - self.usedPercent
    }

    public var title: String {
        switch self.duration {
        case 18000: "5 小时"
        case 604_800: "每周"
        case 86400: "每日"
        case 3600...: "\(self.duration / 3600) 小时"
        default: "额度"
        }
    }

    public init(id: String, usedPercent: Double, duration: Int, resetsAt: Date?) {
        self.id = id
        self.usedPercent = min(100, max(0, usedPercent.isFinite ? usedPercent : 0))
        self.duration = duration
        self.resetsAt = resetsAt
    }

    public func isAwaitingReset(at date: Date) -> Bool {
        self.resetsAt.map { $0 <= date } ?? false
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let plan: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date

    public var menuWindow: UsageWindow? {
        // Like upstream, an exhausted allowance takes priority over an otherwise healthy session.
        self.windows.first { $0.usedPercent >= 100 } ?? self.windows.first
    }

    public static func decode(_ data: Data, now: Date, expectedAccountID: String?) throws -> UsageSnapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageFailure.invalidResponse
        }
        if let expectedAccountID, let received = response.accountID, received != expectedAccountID {
            throw UsageFailure.accountChanged
        }
        let windows = [response.limits?.primary, response.limits?.secondary]
            .enumerated()
            .compactMap { index, window -> UsageWindow? in
                guard let window,
                      window.used.isFinite,
                      window.used >= 0,
                      window.duration > 0
                else { return nil }
                return UsageWindow(
                    id: index == 0 ? "primary" : "secondary",
                    usedPercent: window.used,
                    duration: window.duration,
                    resetsAt: window.reset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
            }
            .sorted { $0.duration < $1.duration }
        guard !windows.isEmpty else { throw UsageFailure.noQuota }
        return UsageSnapshot(plan: response.plan?.capitalized, windows: windows, fetchedAt: now)
    }

    public static func example(now: Date = .now) -> UsageSnapshot {
        UsageSnapshot(
            plan: "Pro",
            windows: [
                UsageWindow(
                    id: "primary",
                    usedPercent: 28,
                    duration: 18000,
                    resetsAt: now.addingTimeInterval(7980)),
                UsageWindow(
                    id: "secondary",
                    usedPercent: 46,
                    duration: 604_800,
                    resetsAt: now.addingTimeInterval(273_600)),
            ],
            fetchedAt: now)
    }
}

private struct Response: Decodable {
    let accountID: String?
    let plan: String?
    let limits: Limits?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case plan = "plan_type"
        case limits = "rate_limit"
    }
}

private struct Limits: Decodable {
    let primary: Window?
    let secondary: Window?

    enum CodingKeys: String, CodingKey {
        case primary = "primary_window"
        case secondary = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed optional window must not erase the other valid allowance.
        self.primary = try? container.decodeIfPresent(Window.self, forKey: .primary)
        self.secondary = try? container.decodeIfPresent(Window.self, forKey: .secondary)
    }
}

private struct Window: Decodable {
    let used: Double
    let duration: Int
    let reset: Double?

    enum CodingKeys: String, CodingKey {
        case used = "used_percent"
        case duration = "limit_window_seconds"
        case reset = "reset_at"
    }
}

public enum UsageFailure: Error, Equatable, Sendable {
    case signInRequired
    case credentialsUnreadable
    case subscriptionRequired
    case invalidResponse
    case noQuota
    case accountChanged
    case network
    case rateLimited
    case unavailable

    public var message: String {
        switch self {
        case .signInRequired: "请在 Codex 中登录，然后刷新。"
        case .credentialsUnreadable: "暂时无法读取 Codex 登录信息，请稍后刷新。"
        case .subscriptionRequired: "请使用 ChatGPT 账号登录 Codex，以查看订阅额度。"
        case .invalidResponse: "暂时无法读取额度，请稍后刷新。"
        case .noQuota: "这个账号暂未提供额度信息。"
        case .accountChanged: "Codex 账号已切换，请刷新。"
        case .network: "无法连接，请检查网络后刷新。"
        case .rateLimited: "刷新过于频繁，请稍后再试。"
        case .unavailable: "Codex 服务暂时不可用，请稍后再试。"
        }
    }
}
