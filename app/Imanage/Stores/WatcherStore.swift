import Foundation
import Observation

// MARK: - WatcherStore
// [応用1] フォルダ A を常駐監視し、追加されたファイルをフォルダ B へ自動振り分けする。
// 処理中はメニューバーアイコンがアニメーションする（MenuBarController が isProcessing を監視）。

@MainActor
@Observable
final class WatcherStore {
    var settings: SettingsStore?

    private(set) var isWatching = false
    private(set) var isProcessing = false
    private(set) var lastActivityMessage: String?
    private(set) var processedTotal = 0

    private var watcher: FolderWatcher?
    private var menuBar: MenuBarController?
    /// FSEvents 発火後の集約待ちタスク（連続コピー中の多重実行を防ぐ）
    private var pendingTask: Task<Void, Never>?

    /// フラグが無効なら、設定に true が残っていても監視は動かさない
    var isEnabled: Bool {
        FeatureFlags.folderWatcher && (settings?.watcherEnabled ?? false)
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    func start() {
        guard FeatureFlags.folderWatcher else { return }
        guard let settings,
              !settings.watcherSourcePath.isEmpty,
              !settings.watcherDestPath.isEmpty else { return }
        let source = URL(fileURLWithPath: (settings.watcherSourcePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        stop()
        let w = FolderWatcher { [weak self] _ in
            self?.scheduleProcess()
        }
        w.start(at: source)
        watcher = w
        isWatching = true
        menuBar = MenuBarController(store: self)

        // 起動時にすでにフォルダ A に溜まっているファイルも処理する
        scheduleProcess()
    }

    func stop() {
        pendingTask?.cancel()
        pendingTask = nil
        watcher?.stop()
        watcher = nil
        isWatching = false
        menuBar?.tearDown()
        menuBar = nil
    }

    func restart() {
        stop()
        startIfEnabled()
    }

    // MARK: - 処理本体

    /// イベント発火から 2 秒待って処理開始（コピー完了を待つ）。連続発火は最後の 1 回に集約。
    private func scheduleProcess() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.processSourceFolder()
        }
    }

    private func processSourceFolder() async {
        guard let settings, !isProcessing else { return }
        let source = URL(fileURLWithPath: (settings.watcherSourcePath as NSString).expandingTildeInPath)
        let dest = URL(fileURLWithPath: (settings.watcherDestPath as NSString).expandingTildeInPath)
        guard source.path != dest.path else { return }

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [])
            .filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }

        let config = settings.config
        isProcessing = true
        defer { isProcessing = false }

        let result = await Self.organize(files: files, destRoot: dest, config: config)
        processedTotal += result.movedCount
        lastActivityMessage = String(
            format: String(localized: "%d 件を自動振り分けしました"), result.movedCount)
    }

    nonisolated private static func organize(
        files: [URL], destRoot: URL, config: ImanageConfig
    ) async -> OrganizeResult {
        let plan = PathCalculator(config: config).makePlan(droppedFiles: files, destRoot: destRoot)
        guard !plan.isEmpty else { return OrganizeResult() }
        let (result, journal) = FileOrganizer(config: config).execute(plan: plan) { _, _ in }
        journal.save()
        return result
    }
}
