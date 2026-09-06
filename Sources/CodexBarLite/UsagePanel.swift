import AppKit
import CodexBarLiteCore
import SwiftUI

struct UsagePanel: View {
    @Bindable var model: UsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 17, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Codex").font(.system(size: 16, weight: .semibold))
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

                if let snapshot = self.model.snapshot {
                    ForEach(snapshot.windows) { window in
                        QuotaRow(window: window, showRemaining: self.model.showRemaining, now: context.date)
                    }
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

                Divider()
                HStack(spacing: 12) {
                    Text(self.updateText(at: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await self.model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(self.model.isRefreshing || self.model.isExample)
                    .help("刷新额度")
                    .accessibilityLabel("刷新额度")

                    if self.model.isExample {
                        // ImageRenderer cannot draw AppKit-backed Menu controls; render the same icon offline.
                        Image(systemName: "ellipsis")
                    } else {
                        Menu {
                            Toggle("显示剩余额度", isOn: self.$model.showRemaining)
                            Divider()
                            Button("打开 Codex") { AppActions.openCodex() }
                            Button("查看项目") { AppActions.openProject() }
                            Divider()
                            Button("退出 CodexBar Lite") { NSApplication.shared.terminate(nil) }
                                .keyboardShortcut("q")
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("更多选项")
                        .accessibilityLabel("更多选项")
                    }
                }
                .font(.system(size: 12))
            }
            .padding(16)
            .frame(width: 304)
        }
    }

    private func updateText(at date: Date) -> String {
        if self.model.isExample { return "预览数据" }
        if self.model.isRefreshing { return "正在刷新…" }
        guard let fetchedAt = self.model.snapshot?.fetchedAt else { return "每 5 分钟刷新" }
        let minutes = max(0, Int(date.timeIntervalSince(fetchedAt) / 60))
        if minutes == 0 { return "刚刚更新" }
        return "\(minutes) 分钟前更新"
    }
}

private struct QuotaRow: View {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(self.window.title).fontWeight(.medium)
                Spacer()
                Text(self.percent.formatted(.number.precision(.fractionLength(0))) + "%")
                    .monospacedDigit()
                Text(self.showRemaining ? "剩余" : "已用")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))

            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(self.color)
                    .frame(width: max(0, geometry.size.width * self.percent / 100))
            }
            .frame(height: 5)
            .accessibilityLabel(self.window.title)
            .accessibilityValue("\(Int(self.percent))% \(self.showRemaining ? "剩余" : "已用")")

            Text(self.resetText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        guard let resetsAt = self.window.resetsAt else { return "重置时间暂不可用" }
        let seconds = resetsAt.timeIntervalSince(self.now)
        if seconds <= 0 { return "已到重置时间，等待更新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return "\(days) 天 \(hours) 小时后重置"
        }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
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
