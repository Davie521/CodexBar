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
                dark: arguments.contains("--preview-dark"))
            return
        }
        let example: UsageSnapshot? = arguments.contains("--demo") || additionalDemo
            ? .example(includingAdditionalLimits: additionalDemo) : nil
        let delegate = AppDelegate(example: example)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    private static func renderPreview(to url: URL, additionalLimits: Bool, dark: Bool) {
        // This path never constructs a live client or reads credentials.
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = UsageModel(client: PreviewClient(), example: .example(includingAdditionalLimits: additionalLimits))
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
    private let model: UsageModel
    private var pollingTask: Task<Void, Never>?

    init(example: UsageSnapshot? = nil) {
        if let example {
            // Interactive UI validation uses the real native menu, but never reads a login or sends a request.
            self.model = UsageModel(client: PreviewClient(), example: example)
        } else {
            let authURL = CodexCredentials.authURL(
                home: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment)
            self.model = UsageModel(client: CodexUsageClient(
                credentials: { try CodexCredentials.read(from: authURL) },
                transport: EphemeralUsageTransport()))
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
        let snapshot = self.model.snapshot
        let window = snapshot?.menuWindow
        let isFresh = snapshot?.isFresh(at: now) ?? false
        if let window, isFresh, !window.isAwaitingReset(at: now) {
            let percent = self.model.showRemaining ? window.remainingPercent : window.usedPercent
            button.title = " \(Int(percent.rounded()))%"
            button.toolTip = "Codex · 每周\(self.model.showRemaining ? "剩余" : "已用") \(Int(percent.rounded()))%"
            if let countdown = window.resetCountdown(at: now, compact: true) {
                button.title += " · \(countdown)"
                button.toolTip = (button.toolTip ?? "") + "\n距离重置还有 \(window.resetCountdown(at: now) ?? countdown)"
            }
        } else {
            button.title = self.model.isRefreshing ? " …" : " —"
            button.toolTip = "Codex · \(self.model.failure?.message ?? "等待额度更新")"
        }
        let iconWindow = isFresh && window?.isAwaitingReset(at: now) == false ? window : nil
        button.image = Self.usageIcon(window: iconWindow, remaining: self.model.showRemaining)
        button.setAccessibilityLabel(button.toolTip)
    }

    private static func usageIcon(window: UsageWindow?, remaining: Bool) -> NSImage {
        // One ring represents the same weekly allowance as the panel.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let track = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
            track.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.2).setStroke()
            track.stroke()
            if let window {
                let percent = remaining ? window.remainingPercent : window.usedPercent
                guard percent > 0 else { return true }
                let arc = NSBezierPath()
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.appendArc(
                    withCenter: NSPoint(x: 9, y: 9),
                    radius: 6,
                    startAngle: 90,
                    endAngle: 90 - 360 * percent / 100,
                    clockwise: true)
                NSColor.labelColor.setStroke()
                arc.stroke()
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
        } else if let fetchedAt = self.model.snapshot?.fetchedAt {
            let minutes = max(0, Int(Date.now.timeIntervalSince(fetchedAt) / 60))
            let age = minutes == 0 ? "刚刚更新" : "\(minutes) 分钟前更新"
            self.refreshItem.title = "刷新额度 · \(age)"
        } else {
            self.refreshItem.title = "刷新额度"
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
        self.measuredSize = NSSize(width: 280, height: max(1, ceil(size.height)))
        self.setFrameSize(self.measuredSize ?? size)
        self.invalidateIntrinsicContentSize()
    }
}
