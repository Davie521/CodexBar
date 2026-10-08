import AppKit
import CodexBarLiteCore
import SwiftUI

struct UsagePanel: View {
    // Match Claude Reset's 420-point menu and 26-point account rows.
    static let width: CGFloat = 420
    let model: AccountsUsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(self.model.accounts.enumerated()), id: \.element.id) { index, entry in
                    CompactAccountRow(
                        entry: entry,
                        color: index.isMultiple(of: 2) ? .green : .blue,
                        showRemaining: self.model.showRemaining,
                        now: context.date)
                }
                if self.model.isExample {
                    Text("示例数据")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CompactAccountRow: View {
    let entry: AccountUsage
    let color: Color
    let showRemaining: Bool
    let now: Date

    private var snapshot: UsageSnapshot? {
        guard let snapshot = self.entry.usage.snapshot, snapshot.isFresh(at: self.now) else { return nil }
        return snapshot
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(self.color).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(self.entry.account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(width: 30, alignment: .leading)
            if let snapshot = self.snapshot, !snapshot.windows.isEmpty {
                CompactQuotaValue(
                    title: "5h",
                    window: snapshot.sessionWindow,
                    showRemaining: self.showRemaining,
                    now: self.now)
                CompactQuotaValue(
                    title: "周",
                    window: snapshot.weeklyWindow,
                    showRemaining: self.showRemaining,
                    now: self.now)
                Text(self.resetText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(self.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(self.entry.usage.failure == nil ? Color.secondary : .orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 26)
        .help(self.details)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codex 账户 \(self.entry.account.label)")
        .accessibilityValue(self.details)
    }

    private var statusText: String {
        if self.entry.usage.failure == .signInRequired { return "请重新登录此账户，然后刷新" }
        if let failure = self.entry.usage.failure { return failure.message }
        if let snapshot = self.entry.usage.snapshot {
            return snapshot.isFresh(at: self.now) ? "暂未提供账户额度" : "额度已过期，等待更新"
        }
        return "正在读取额度…"
    }

    private var resetText: String {
        guard let window = self.snapshot?.weeklyWindow ?? self.snapshot?.sessionWindow else { return "重置时间未知" }
        if window.isAwaitingReset(at: self.now) { return "等待额度更新" }
        guard let countdown = window.resetCountdown(at: self.now) else { return "重置时间未知" }
        return countdown.replacingOccurrences(of: " 小时", with: "时")
            .replacingOccurrences(of: " 分钟", with: "分")
            .replacingOccurrences(of: " ", with: "") + "后重置"
    }

    private var details: String {
        var lines = ["账户 \(self.entry.account.label) · \(self.entry.account.home.path)"]
        guard let snapshot = self.snapshot else { return (lines + [self.statusText]).joined(separator: "\n") }
        if let plan = snapshot.plan { lines.append("套餐：" + plan) }
        if snapshot.windows.isEmpty { lines.append(self.statusText) }
        for window in snapshot.windows {
            if window.isAwaitingReset(at: self.now) {
                lines.append("\(window.title) · 等待额度更新")
                continue
            }
            let percent = self.showRemaining ? window.remainingPercent : window.usedPercent
            lines.append("\(window.title)\(self.showRemaining ? "剩余" : "已用") \(Int(percent.rounded()))%")
            if let reset = window.resetsAt {
                lines.append("重置：" + reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
        lines.append("更新于 " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
        if self.entry.usage.isRefreshing { lines.append("正在刷新…") }
        return lines.joined(separator: "\n")
    }
}

private struct CompactQuotaValue: View {
    let title: String
    let window: UsageWindow?
    let showRemaining: Bool
    let now: Date

    private var availableWindow: UsageWindow? {
        guard let window = self.window, !window.isAwaitingReset(at: self.now) else { return nil }
        return window
    }

    private var color: Color {
        guard let window = self.availableWindow else { return .secondary }
        if window.usedPercent >= 95 { return .red }
        if window.usedPercent >= 80 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(self.title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(self.value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(self.color)
        }
        .frame(width: 86)
    }

    private var value: String {
        guard let window = self.availableWindow else { return "—" }
        let percent = self.showRemaining ? window.remainingPercent : window.usedPercent
        return "\(self.showRemaining ? "剩" : "已用")\(Int(percent.rounded()))%"
    }
}

enum AppActions {
    @MainActor
    static func openCodex() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else if let url = URL(string: "https://chatgpt.com/codex") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openProject() {
        if let url = URL(string: "https://github.com/Davie521/CodexBar") {
            NSWorkspace.shared.open(url)
        }
    }
}
