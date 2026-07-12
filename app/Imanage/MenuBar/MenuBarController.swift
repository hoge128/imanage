import AppKit
import Observation

// MARK: - MenuBarController
// フォルダ監視中に NSStatusItem を表示する。
// 自動振り分けの処理中は回転アニメーション（NSStatusItem は CAAnimation 非対応のため
// 事前生成した回転フレームを Timer で切り替える）。

@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private weak var store: WatcherStore?

    private var animationTimer: Timer?
    private var frameIndex = 0
    private let animationFrames: [NSImage]
    private let idleImage: NSImage?

    init(store: WatcherStore) {
        self.store = store
        self.idleImage = NSImage(systemSymbolName: "photo.stack",
                                 accessibilityDescription: "imanage")
        self.animationFrames = Self.makeRotationFrames()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = idleImage
        item.menu = buildMenu()
        statusItem = item

        observeProcessing()
    }

    func tearDown() {
        stopAnimation()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - 状態監視

    /// withObservationTracking で isProcessing の変化を監視しアニメーションを切り替える
    private func observeProcessing() {
        guard let store else { return }
        withObservationTracking {
            _ = store.isProcessing
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, let store = self.store else { return }
                store.isProcessing ? self.startAnimation() : self.stopAnimation()
                self.observeProcessing()  // 再登録（observationTracking は一回限り）
            }
        }
    }

    // MARK: - アニメーション

    private func startAnimation() {
        guard animationTimer == nil, !animationFrames.isEmpty else { return }
        frameIndex = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.frameIndex = (self.frameIndex + 1) % self.animationFrames.count
                button.image = self.animationFrames[self.frameIndex]
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        statusItem?.button?.image = idleImage
    }

    /// "arrow.triangle.2.circlepath" を 30° 刻みで回転させた 12 フレームを生成
    private static func makeRotationFrames() -> [NSImage] {
        guard let base = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                 accessibilityDescription: nil) else { return [] }
        let size = NSSize(width: 18, height: 18)
        return (0..<12).map { step in
            let angle = CGFloat(step) * (-30.0) * .pi / 180.0
            let frame = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: angle)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                base.draw(in: rect)
                return true
            }
            frame.isTemplate = true  // メニューバーのライト/ダーク追従
            return frame
        }
    }

    // MARK: - メニュー

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: String(localized: "フォルダ監視中"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let open = NSMenuItem(title: String(localized: "imanage を開く"),
                              action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let quit = NSMenuItem(title: String(localized: "終了"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
