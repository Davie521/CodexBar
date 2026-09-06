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
        if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
            Self.renderPreview(to: URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    private static func renderPreview(to url: URL) {
        // This path never constructs a live client or reads credentials.
        let model = UsageModel(client: PreviewClient(), example: .example())
        let renderer = ImageRenderer(content: UsagePanel(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
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
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model: UsageModel
    private var pollingTask: Task<Void, Never>?

    override init() {
        let authURL = CodexCredentials.authURL(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment)
        self.model = UsageModel(client: CodexUsageClient(
            credentials: { try CodexCredentials.read(from: authURL) },
            transport: EphemeralUsageTransport()))
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CodexBarLite"
        item.button?.target = self
        item.button?.action = #selector(self.togglePopover)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        self.statusItem = item
        self.popover.behavior = .transient
        self.popover.animates = false
        self.popover.contentViewController = NSHostingController(rootView: UsagePanel(model: self.model))
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }

    private func updateStatusItem() {
        guard let button = self.statusItem?.button else { return }
        let snapshot = self.model.snapshot
        let window = snapshot?.menuWindow
        let isFresh = snapshot.map { Date.now.timeIntervalSince($0.fetchedAt) < 600 } ?? false
        if let window, isFresh, !window.isAwaitingReset(at: .now) {
            let percent = self.model.showRemaining ? window.remainingPercent : window.usedPercent
            button.title = " \(Int(percent.rounded()))%"
            button.toolTip = "Codex · \(window.title)\(self.model.showRemaining ? "剩余" : "已用") \(Int(percent))%"
        } else {
            button.title = self.model.isRefreshing ? " …" : " —"
            button.toolTip = "Codex · \(self.model.failure?.message ?? "等待额度更新")"
        }
        button.image = Self.usageIcon(windows: snapshot?.windows ?? [], remaining: self.model.showRemaining)
        button.setAccessibilityLabel(button.toolTip)
    }

    private static func usageIcon(windows: [UsageWindow], remaining: Bool) -> NSImage {
        // Two stacked quota meters preserve CodexBar's compact menu-bar visual language.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for index in 0..<2 {
                let rect = NSRect(x: 1, y: index == 0 ? 10 : 3, width: 16, height: 4)
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                if windows.indices.contains(index) {
                    let window = windows[index]
                    let percent = remaining ? window.remainingPercent : window.usedPercent
                    NSColor.labelColor.setFill()
                    let filled = NSRect(
                        x: rect.minX,
                        y: rect.minY,
                        width: rect.width * percent / 100,
                        height: rect.height)
                    NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        if self.popover.isShown {
            self.popover.performClose(nil)
        } else if let button = self.statusItem?.button {
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
