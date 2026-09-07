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

    /// Reset timestamps at or beyond 2100-01-01 are corrupt rather than merely distant. A finite
    /// but absurd `reset_at` decodes cleanly, so the guard has to live here.
    private static let maxResetTimestamp: TimeInterval = 4_102_444_800

    public init(id: String, usedPercent: Double, duration: Int, resetsAt: Date?) {
        self.id = id
        self.usedPercent = min(100, max(0, usedPercent.isFinite ? usedPercent : 0))
        self.duration = duration
        // A corrupt reset time must not discard the allowance itself — the quota stays usable and
        // only the countdown goes away. Keeping it would reach the trapping conversion below.
        self.resetsAt = resetsAt.flatMap { date in
            let seconds = date.timeIntervalSince1970
            return (0...Self.maxResetTimestamp).contains(seconds) ? date : nil
        }
    }

    public func isAwaitingReset(at date: Date) -> Bool {
        self.resetsAt.map { $0 <= date } ?? false
    }

    public func resetCountdown(at date: Date, compact: Bool = false) -> String? {
        guard let resetsAt = self.resetsAt, resetsAt > date else { return nil }
        // `Int(_: Double)` traps instead of throwing once the value exceeds `Int.max`, which kills
        // the process. Bound the conversion here too, so this stays safe independently of `init`.
        let elapsedMinutes = ceil(resetsAt.timeIntervalSince(date) / 60)
        guard elapsedMinutes.isFinite, elapsedMinutes < 1e18 else { return nil }
        let totalMinutes = max(1, Int(elapsedMinutes))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if compact {
            if days > 0 { return "\(days)d" }
            if hours > 0 { return "\(hours)h" }
            return "\(minutes)m"
        }
        var parts: [String] = []
        if days > 0 { parts.append("\(days) 天") }
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分钟") }
        return parts.joined(separator: " ")
    }
}

public struct AdditionalUsageLimit: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let windows: [UsageWindow]
}

public struct UsageSnapshot: Equatable, Sendable {
    public let plan: String?
    public let windows: [UsageWindow]
    public let additionalLimits: [AdditionalUsageLimit]
    public let fetchedAt: Date

    public init(
        plan: String?,
        windows: [UsageWindow],
        additionalLimits: [AdditionalUsageLimit] = [],
        fetchedAt: Date)
    {
        self.plan = plan
        self.windows = windows
        self.additionalLimits = additionalLimits
        self.fetchedAt = fetchedAt
    }

    /// A snapshot older than this stops being presented as the current allowance. The menu bar and
    /// the panel must share one definition — when they drifted apart, the status item rejected a
    /// stale snapshot while the card still rendered its percentage as if it were current.
    public static let freshnessWindow: TimeInterval = 600

    public func isFresh(at date: Date) -> Bool {
        date.timeIntervalSince(self.fetchedAt) < Self.freshnessWindow
    }

    public var menuWindow: UsageWindow? {
        // The Lite panel and menu bar track only the account's weekly allowance.
        self.windows.first { $0.duration == 604_800 }
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
        let windows = response.limits?.windows ?? []
        let additionalLimits = response.additionalLimits.enumerated()
            .compactMap { index, limit -> AdditionalUsageLimit? in
                guard let windows = limit.limits?.windows, !windows.isEmpty else { return nil }
                return AdditionalUsageLimit(
                    id: "additional-\(index)",
                    title: limit.title ?? "附加额度 \(index + 1)",
                    windows: windows)
            }
        guard !windows.isEmpty || !additionalLimits.isEmpty else { throw UsageFailure.noQuota }
        return UsageSnapshot(
            plan: response.plan?.capitalized,
            windows: windows,
            additionalLimits: additionalLimits,
            fetchedAt: now)
    }

    public static func example(now: Date = .now, includingAdditionalLimits: Bool = false) -> UsageSnapshot {
        let snapshot = UsageSnapshot(
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
        guard includingAdditionalLimits else { return snapshot }
        return UsageSnapshot(
            plan: snapshot.plan,
            windows: snapshot.windows.filter { $0.duration == 604_800 },
            additionalLimits: [AdditionalUsageLimit(
                id: "additional-0", title: "示例模型", windows: snapshot.windows)],
            fetchedAt: now)
    }
}

private struct Response: Decodable {
    let accountID: String?
    let plan: String?
    let limits: Limits?
    let additionalLimits: [AdditionalLimit]

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case plan = "plan_type"
        case limits = "rate_limit"
        case additionalLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan)
        self.limits = try container.decodeIfPresent(Limits.self, forKey: .limits)
        self.additionalLimits = (try? container.decode([AdditionalLimit].self, forKey: .additionalLimits)) ?? []
    }
}

private struct AdditionalLimit: Decodable {
    let title: String?
    let limits: Limits?

    enum CodingKeys: String, CodingKey {
        case name = "limit_name"
        case feature = "metered_feature"
        case limits = "rate_limit"
    }

    init(from decoder: Decoder) {
        // A malformed entry or label must not discard valid windows in this group or its siblings.
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let name = try? container?.decodeIfPresent(String.self, forKey: .name)
        let feature = try? container?.decodeIfPresent(String.self, forKey: .feature)
        self.title = [name, feature].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        self.limits = try? container?.decodeIfPresent(Limits.self, forKey: .limits)
    }
}

private struct Limits: Decodable {
    let primary: Window?
    let secondary: Window?

    var windows: [UsageWindow] {
        [self.primary, self.secondary].enumerated().compactMap { index, window -> UsageWindow? in
            guard let window, window.used.isFinite, window.used >= 0, window.duration > 0 else { return nil }
            return UsageWindow(
                id: index == 0 ? "primary" : "secondary",
                usedPercent: window.used,
                duration: window.duration,
                resetsAt: window.reset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
        .sorted { $0.duration < $1.duration }
    }

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
