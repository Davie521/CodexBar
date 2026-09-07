import AppKit
import CodexBarLiteCore
import SwiftUI

struct UsagePanel: View {
    let model: UsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Codex").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if self.model.isExample {
                        Text("示例").font(.caption).foregroundStyle(.secondary)
                    }
                    if let plan = self.model.snapshot?.plan {
                        Text(plan)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                }

                if let snapshot = self.model.snapshot, !snapshot.isFresh(at: context.date) {
                    // A stale percentage must not read as the current allowance — an untouched
                    // quota would otherwise sit at 100% and a full bar long after it went stale.
                    Text("额度已过期，等待更新")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                } else if let window = self.model.snapshot?.menuWindow {
                    WeeklyQuotaView(window: window, showRemaining: self.model.showRemaining, now: context.date)
                } else if self.model.snapshot != nil {
                    Text("暂未提供周额度")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                } else if let failure = self.model.failure {
                    Text(failure.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取额度…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
            }
            .padding(16)
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WeeklyQuotaView: View {
    let window: UsageWindow
    let showRemaining: Bool
    let now: Date

    private var percent: Double {
        self.showRemaining ? self.window.remainingPercent : self.window.usedPercent
    }

    private var color: Color {
        if self.window.isAwaitingReset(at: self.now) { return .secondary }
        if self.window.usedPercent >= 95 { return .red }
        if self.window.usedPercent >= 80 { return .orange }
        return .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.showRemaining ? "每周剩余" : "每周已用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(self.percent.formatted(.number.precision(.fractionLength(0))) + "%")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("每周额度")
                .accessibilityValue("\(Int(self.percent.rounded()))% \(self.showRemaining ? "剩余" : "已用")")

                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(self.resetLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(self.resetText)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(self.color)
                        .frame(width: max(0, geometry.size.width * self.percent / 100))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)

            if let resetsAt = self.window.resetsAt {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                    (
                        Text(resetsAt.formatted(.dateTime.month().day().weekday(.abbreviated)
                                .hour().minute().locale(Locale(identifier: "zh_CN"))))
                            + Text(" 重置"))
                        .help("本地时间 · \(resetsAt.formatted(date: .complete, time: .shortened))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var resetText: String {
        self.window.resetCountdown(at: self.now)
            ?? (self.window.isAwaitingReset(at: self.now) ? "等待额度更新" : "暂不可用")
    }

    private var resetLabel: String {
        guard self.window.resetsAt != nil else { return "重置时间" }
        return self.window.isAwaitingReset(at: self.now) ? "已到重置时间" : "距离重置"
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
