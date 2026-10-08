import AppKit
import CodexBarLiteCore
import Observation
import SwiftUI

@main
enum CodexBarLiteMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        let additionalDemo = arguments.contains("--demo-additional-limits")
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
            Self.renderPreview(
                to: URL(fileURLWithPath: arguments[index + 1]),
                additionalLimits: additionalDemo,
                dark: arguments.contains("--preview-dark"),
                multipleAccounts: arguments.contains("--demo-accounts"))
            return
        }
        let example: UsageSnapshot? = arguments.contains("--demo") || additionalDemo || arguments
            .contains("--demo-accounts")
            ? .example(includingAdditionalLimits: additionalDemo) : nil
        let delegate = AppDelegate(example: example, multipleAccounts: arguments.contains("--demo-accounts"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    private static func renderPreview(to url: URL, additionalLimits: Bool, dark: Bool, multipleAccounts: Bool) {
        // This path never constructs a live client or reads credentials.
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = Self.exampleModel(
            snapshot: .example(includingAdditionalLimits: additionalLimits), multipleAccounts: multipleAccounts)
        let renderer = ImageRenderer(content: UsagePanel(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            fputs("Could not write preview.\n", stderr)
        }
    }

    @MainActor
    static func exampleModel(snapshot: UsageSnapshot, multipleAccounts: Bool) -> AccountsUsageModel {
        let first = AccountUsage(
            account: CodexAccount(label: "A", home: URL(fileURLWithPath: "/example/.codex")),
            usage: UsageModel(client: PreviewClient(), example: snapshot))
        let secondSnapshot = UsageSnapshot(
            plan: "Plus",
            windows: [UsageWindow(
                id: "weekly",
                usedPercent: 78,
                duration: 604_800,
                resetsAt: Date.now.addingTimeInterval(172_800))],
            fetchedAt: .now)
        let second = AccountUsage(
            account: CodexAccount(label: "B", home: URL(fileURLWithPath: "/example/.codex-b")),
            usage: UsageModel(client: PreviewClient(), example: secondSnapshot))
        return AccountsUsageModel(accounts: multipleAccounts ? [first, second] : [first])
    }
}

private struct PreviewClient: UsageFetching {
    func fetch() async throws -> UsageSnapshot {
        .example()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let refreshItem = NSMenuItem()
    private let remainingItem = NSMenuItem()
    private var cardHost: QuotaMenuHostingView?
    private let model: AccountsUsageModel
    private var pollingTask: Task<Void, Never>?

    init(example: UsageSnapshot? = nil, multipleAccounts: Bool = false) {
        if let example {
            self.model = CodexBarLiteMain.exampleModel(snapshot: example, multipleAccounts: multipleAccounts)
        } else {
            let accounts = CodexAccount.discover(
                home: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment,
                directoryExists: { url in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                        && isDirectory.boolValue
                })
            self.model = AccountsUsageModel(accounts: accounts.map { account in
                AccountUsage(account: account, usage: UsageModel(client: CodexUsageClient(
                    credentials: { try CodexCredentials.read(from: account.authURL) },
                    transport: EphemeralUsageTransport())))
            })
        }
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CodexBarLite"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        self.statusItem = item
        self.configureMenu()
        // Let NSStatusItem/NSMenu own positioning on every display, as in upstream CodexBar.
        item.menu = self.menu
        self.observeModel()
        self.pollingTask = Task { [weak self] in
            var nextRefresh = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date.now >= nextRefresh {
                    await self.model.refresh()
                    nextRefresh = Date.now.addingTimeInterval(300)
                }
                self.updateStatusItem()
                self.updateMenuPresentation()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch { return }
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        self.pollingTask?.cancel()
    }

    private func observeModel() {
        withObservationTracking {
            self.updateStatusItem()
            self.updateMenuPresentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    private func updateStatusItem() {
        guard let button = self.statusItem?.button else { return }
        let now = Date.now
        if self.model.accounts.count > 1 {
            self.updateMultipleAccountStatus(button: button, now: now)
            return
        }
        guard let usage = self.model.accounts.first?.usage else { return }
        let snapshot = usage.snapshot
        let isFresh = snapshot?.isFresh(at: now) ?? false
        let slots: [UsageWindow?] = isFresh
            ? [snapshot?.sessionWindow, snapshot?.weeklyWindow]
            : [nil, nil]
        let currentWindows: [UsageWindow] = slots.compactMap { window -> UsageWindow? in
            guard let window, !window.isAwaitingReset(at: now) else { return nil }
            return window
        }
        if !currentWindows.isEmpty {
            button.title = " " + currentWindows.map { window in
                let percent = self.model.showRemaining ? window.remainingPercent : window.usedPercent
                return "\(Self.compactTitle(for: window)) \(Int(percent.rounded()))%"
            }.joined(separator: " · ")
            if currentWindows.count == 1,
               let countdown = currentWindows[0].resetCountdown(at: now, compact: true)
            {
                button.title += " · \(countdown)"
            }
            button.toolTip = Self.usageToolTip(
                windows: slots,
                remaining: self.model.showRemaining,
                now: now)
        } else {
            button.title = self.model.isRefreshing ? " …" : " —"
            button.toolTip = isFresh
                ? Self.usageToolTip(windows: slots, remaining: self.model.showRemaining, now: now)
                : "Codex · \(usage.failure?.message ?? "等待额度更新")"
        }
        let iconWindows = slots.map { window in
            guard let window, !window.isAwaitingReset(at: now) else { return nil as UsageWindow? }
            return window
        }
        button.image = Self.usageIcon(windows: iconWindows, remaining: self.model.showRemaining)
        button.setAccessibilityLabel(button.toolTip)
    }

    private func updateMultipleAccountStatus(button: NSStatusBarButton, now: Date) {
        let title = NSMutableAttributedString()
        for (index, entry) in self.model.accounts.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ")) }
            let snapshot = entry.usage.snapshot.flatMap { $0.isFresh(at: now) ? $0 : nil }
            let windows = [snapshot?.sessionWindow, snapshot?.weeklyWindow].map { window in
                window.flatMap { $0.isAwaitingReset(at: now) ? nil : $0 }
            }
            let attachment = NSTextAttachment()
            attachment.image = Self.usageIcon(windows: windows, remaining: self.model.showRemaining)
            attachment.bounds = NSRect(x: 0, y: -3, width: 15, height: 15)
            title.append(NSAttributedString(attachment: attachment))
            let countdown = (snapshot?.weeklyWindow ?? snapshot?.sessionWindow)?
                .resetCountdown(at: now, compact: true) ?? "—"
            title.append(NSAttributedString(string: " \(entry.account.label) \(countdown)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        button.image = nil
        button.attributedTitle = title
        button.toolTip = self.model.accounts.map { entry in
            let title = "账户 \(entry.account.label) · \(entry.account.home.lastPathComponent)"
            guard let snapshot = entry.usage.snapshot, snapshot.isFresh(at: now) else {
                return title + "\n" + (entry.usage.failure?.message ?? "等待额度更新")
            }
            return title + "\n" + Self.usageToolTip(
                windows: snapshot.windows.map { Optional($0) }, remaining: self.model.showRemaining, now: now)
        }.joined(separator: "\n\n")
        button.setAccessibilityLabel(button.toolTip)
    }

    private static func compactTitle(for window: UsageWindow) -> String {
        switch window.duration {
        case 18000: "5h"
        case 604_800: "周"
        case 86400: "日"
        default: window.title
        }
    }

    private static func usageToolTip(windows: [UsageWindow?], remaining: Bool, now: Date) -> String {
        let lines = windows.compactMap { window -> String? in
            guard let window else { return nil }
            if window.isAwaitingReset(at: now) {
                return "\(window.title) · 等待额度更新"
            }
            let percent = remaining ? window.remainingPercent : window.usedPercent
            var line = "\(window.title)\(remaining ? "剩余" : "已用") \(Int(percent.rounded()))%"
            if let countdown = window.resetCountdown(at: now) {
                line += " · \(countdown)后重置"
            }
            return line
        }
        return (["Codex"] + (lines.isEmpty ? ["等待额度更新"] : lines)).joined(separator: "\n")
    }

    private static func usageIcon(windows: [UsageWindow?], remaining: Bool) -> NSImage {
        // Match Claude's compact visual language: top is the five-hour window, bottom is weekly.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for index in 0..<2 {
                let rect = NSRect(x: 1, y: index == 0 ? 10 : 3, width: 16, height: 4)
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                guard windows.indices.contains(index), let window = windows[index] else { continue }
                let percent = remaining ? window.remainingPercent : window.usedPercent
                guard percent > 0 else { continue }
                NSColor.labelColor.setFill()
                let filled = NSRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width * percent / 100,
                    height: rect.height)
                NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func configureMenu() {
        self.menu.autoenablesItems = false
        self.menu.delegate = self
        let host = QuotaMenuHostingView(rootView: UsagePanel(model: self.model))
        self.cardHost = host
        let card = NSMenuItem()
        card.view = host
        card.isEnabled = false
        self.menu.addItem(card)
        self.menu.addItem(.separator())
        self.refreshItem.target = self
        self.refreshItem.action = #selector(self.refreshUsage)
        self.refreshItem.keyEquivalent = "r"
        self.menu.addItem(self.refreshItem)

        let more = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        let actions = NSMenu()
        actions.autoenablesItems = false
        self.remainingItem.title = "显示剩余额度"
        self.remainingItem.target = self
        self.remainingItem.action = #selector(self.toggleRemaining)
        actions.addItem(self.remainingItem)
        actions.addItem(.separator())
        self.addAction("打开 Codex", selector: #selector(self.openCodex), to: actions)
        self.addAction("查看项目", selector: #selector(self.openProject), to: actions)
        actions.addItem(.separator())
        self.addAction("退出 CodexBar Lite", selector: #selector(self.quit), key: "q", to: actions)
        more.submenu = actions
        self.menu.addItem(more)
    }

    private func addAction(_ title: String, selector: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.appearance = NSApplication.shared.effectiveAppearance
        self.updateMenuPresentation()
    }

    private func updateMenuPresentation() {
        self.remainingItem.state = self.model.showRemaining ? .on : .off
        self.refreshItem.isEnabled = !self.model.isRefreshing && !self.model.isExample
        if self.model.isRefreshing {
            self.refreshItem.title = "正在刷新…"
        } else if self.model.isExample {
            self.refreshItem.title = "刷新额度 · 示例数据"
        } else {
            self.refreshItem.title = self.model.accounts.count > 1 ? "刷新全部账户" : "刷新额度"
        }
        self.cardHost?.fitContent()
    }

    @objc private func refreshUsage() {
        Task { await self.model.refresh() }
    }

    @objc private func toggleRemaining() {
        self.model.showRemaining.toggle()
    }

    @objc private func openCodex() {
        AppActions.openCodex()
    }

    @objc private func openProject() {
        AppActions.openProject()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// Reuses the measured intrinsic-size approach from upstream MenuHostingView.
private final class QuotaMenuHostingView: NSHostingView<UsagePanel> {
    private var measuredSize: NSSize?

    override var allowsVibrancy: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        self.measuredSize ?? super.intrinsicContentSize
    }

    func fitContent() {
        self.measuredSize = nil
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        let size = self.fittingSize
        self.measuredSize = NSSize(width: UsagePanel.width, height: max(1, ceil(size.height)))
        self.setFrameSize(self.measuredSize ?? size)
        self.invalidateIntrinsicContentSize()
    }
}
