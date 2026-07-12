import Foundation
import Observation

// MARK: - InputUnit
// N:1 入力の 1 ユニット。1 回のドロップ（フォルダ or ファイル群）に対応する。

struct InputUnit: Identifiable, Sendable {
    let id: UUID
    /// このユニットでドロップされた元の項目（出力先解決・ルート判定に使う）
    let droppedURLs: [URL]
    /// 「現在」表示のルート（ドラッグしたフォルダ自身、またはファイルの属する親フォルダ）
    let rootURL: URL
    /// EXIF スキャン済みファイル
    let scan: ScanResult

    var fileCount: Int { scan.scanned.count + scan.skipped.count }

    /// フォルダをドラッグした入力か（単一フォルダ → rootURL がそのフォルダ自身になる）。
    /// 空フォルダ掃除はこの場合のみ対象（ファイル直接ドロップ時に親フォルダを消さないため）。
    var isFolderInput: Bool {
        droppedURLs.count == 1 && droppedURLs[0].standardizedFileURL == rootURL
    }
}

// MARK: - OrganizeStore
// ドロップ → プレビュー → 実行 → undo のメイン状態管理。

@MainActor
@Observable
final class OrganizeStore {
    var settings: SettingsStore?

    private(set) var plan: OrganizePlan?
    private(set) var isScanning = false
    private(set) var isExecuting = false
    /// 実行完了後、結果（Before/After）を表示したまま undo を待つ状態
    private(set) var didExecute = false
    private(set) var lastResult: OrganizeResult?
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    private(set) var statusMessage: String?

    /// アプリ内多段 undo スタック（最後の要素が最新の操作）
    private(set) var undoStack: [Journal] = []

    /// 入力ユニット（N:1）。各ユニット = 1 回のドロップ。
    /// EXIF スキャン結果を保持するため、階層・出力先変更時は再読込せず再計算できる。
    private(set) var inputUnits: [InputUnit] = []

    var canUndo: Bool {
        // アプリ内スタックが空でも CLI / 前回起動分のジャーナルファイルがあれば undo 可能
        !undoStack.isEmpty || Journal.loadFromDisk() != nil
    }

    // MARK: - Drop & Preview

    /// ドロップ受付。入力ユニットを 1 つ追加する（N:1）。
    /// ファイルを含むフォルダはサブフォルダまで再帰的に収集する。
    func handleDrop(_ urls: [URL]) {
        guard let settings, !isExecuting else { return }
        if didExecute { reset() }  // 完了後の新規ドロップは作り直し
        // 新規セッション（入力なし）の初回ドロップは既定の出力先を初期選択に反映する。
        // 既定未設定なら何もしない（現在の選択を維持）。同一セッションへの追加では発火しない。
        if inputUnits.isEmpty { settings.applyDefaultAsCurrent() }

        let config = settings.config
        isScanning = true
        statusMessage = nil
        Task {
            // ファイル収集（再帰）・EXIF スキャンはディスク I/O のため main 外で実行
            let files = await Self.collectFiles(from: urls)
            guard !files.isEmpty else {
                self.isScanning = false
                self.statusMessage = String(localized: "ドロップにファイルが含まれていません")
                return
            }
            let scan = await Self.scan(files: files, config: config)
            guard !scan.scanned.isEmpty else {
                self.isScanning = false
                self.statusMessage = String(localized: "振り分け対象のファイルがありません（対応拡張子: JPG / RAW / XMP）")
                return
            }
            let root = Self.computeRootURL(droppedURLs: urls)
            self.inputUnits.append(InputUnit(
                id: UUID(), droppedURLs: urls, rootURL: root, scan: scan))
            self.isScanning = false
            self.rebuildPlan()
        }
    }

    /// 入力ユニットを削除する。
    func removeInput(_ id: UUID) {
        guard !isExecuting, !didExecute else { return }
        inputUnits.removeAll { $0.id == id }
        rebuildPlan()
        if inputUnits.isEmpty { statusMessage = nil }
    }

    /// 全入力ユニットを統合して 1 つのプラン（→ 単一出力先）を組み立てる。
    func rebuildPlan() {
        guard let settings, !didExecute, !isExecuting else { return }
        guard !inputUnits.isEmpty else { plan = nil; return }
        let combined = ScanResult(
            scanned: inputUnits.flatMap { $0.scan.scanned },
            skipped: inputUnits.flatMap { $0.scan.skipped })
        // 出力先は先頭ユニットのドロップ元から解決（fixed モードなら固定フォルダ）
        guard let destRoot = settings.resolveDestRoot(
            droppedItems: inputUnits.first?.droppedURLs ?? []) else { return }
        plan = PathCalculator(config: settings.config)
            .buildPlan(from: combined, destRoot: destRoot)
    }

    /// 階層・出力先が変わったときの再計算（EXIF 再読込なし）
    func recomputePlan() { rebuildPlan() }

    /// ドロップされた URL 群から「現在」表示のルートを決める。
    /// 単一フォルダ → そのフォルダ自身、それ以外 → 先頭項目の親フォルダ。
    nonisolated private static func computeRootURL(droppedURLs: [URL]) -> URL {
        if droppedURLs.count == 1 {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: droppedURLs[0].path, isDirectory: &isDir),
               isDir.boolValue {
                return droppedURLs[0].standardizedFileURL
            }
        }
        return droppedURLs.first?.standardizedFileURL.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/")
    }

    /// ドロップされた URL 群から対象ファイルを収集する。
    /// ディレクトリはサブフォルダまで再帰的に辿る（隠しファイル・パッケージ内部は除外）。
    nonisolated private static func collectFiles(from urls: [URL]) async -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let en = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                while let child = en.nextObject() as? URL {
                    let isRegular = (try? child.resourceValues(
                        forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                    if isRegular { files.append(child) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    nonisolated private static func scan(files: [URL], config: ImanageConfig) async -> ScanResult {
        PathCalculator(config: config).scanFiles(files)
    }

    /// 初期画面（ドロップゾーン）へ戻す
    func reset() {
        plan = nil
        didExecute = false
        lastResult = nil
        statusMessage = nil
        inputUnits = []
    }

    // MARK: - Execute

    func execute() {
        guard let plan, let settings, !isExecuting else { return }
        let config = settings.config
        // 実行後に空フォルダ掃除の対象にするルート（フォルダをドラッグした入力のみ）
        let folderRoots = inputUnits.filter { $0.isFolderInput }.map { $0.rootURL }
        isExecuting = true
        progressDone = 0
        progressTotal = plan.moves.count

        Task {
            let (result, journal) = await Self.run(plan: plan, config: config) { done, total in
                Task { @MainActor [weak self] in
                    self?.progressDone = done
                    self?.progressTotal = total
                }
            }
            // 移動後、元フォルダ内に残った空フォルダをゴミ箱へ移動する
            let removedDirs = await Self.cleanupEmptyDirs(folderRoots: folderRoots)
            journal.save()
            self.undoStack.append(journal)
            self.isExecuting = false
            // plan は残したまま完了状態にし、Before/After と undo を表示し続ける
            self.didExecute = true
            self.lastResult = result
            self.statusMessage = Self.summaryMessage(result, removedDirs: removedDirs)
        }
    }

    /// 指定ルート配下の空フォルダ（中身が無い／.DS_Store のみ）をゴミ箱へ移動する。
    /// 深い階層から処理し、子が消えて空になった親も対象にする。
    /// ポリシー: 削除は removeItem ではなく必ず trashItem（ゴミ箱）で行う。
    nonisolated private static func cleanupEmptyDirs(folderRoots: [URL]) async -> Int {
        let fm = FileManager.default
        var total = 0
        for root in folderRoots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            // ルート配下の全ディレクトリを収集（ルート自身も含む）
            var dirs: [URL] = [root.standardizedFileURL]
            if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                while let u = en.nextObject() as? URL {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        dirs.append(u.standardizedFileURL)
                    }
                }
            }
            // 深い順に処理（子を先に消して親を空にする）
            dirs.sort { $0.pathComponents.count > $1.pathComponents.count }
            for dir in dirs {
                let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                let meaningful = items.filter { $0 != ".DS_Store" }
                if meaningful.isEmpty {
                    if (try? fm.trashItem(at: dir, resultingItemURL: nil)) != nil { total += 1 }
                }
            }
        }
        return total
    }

    nonisolated private static func run(
        plan: OrganizePlan, config: ImanageConfig,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> (OrganizeResult, Journal) {
        let organizer = FileOrganizer(config: config)
        return organizer.execute(plan: plan, progress: progress)
    }

    private static func summaryMessage(_ result: OrganizeResult, removedDirs: Int = 0) -> String {
        var parts = [String(format: String(localized: "%d 件を振り分けました"), result.movedCount)]
        if !result.skippedExisting.isEmpty {
            parts.append(String(format: String(localized: "%d 件スキップ（移動先に同名ファイル）"), result.skippedExisting.count))
        }
        if removedDirs > 0 {
            parts.append(String(format: String(localized: "空フォルダ %d 件をゴミ箱へ"), removedDirs))
        }
        if !result.errors.isEmpty {
            parts.append(String(format: String(localized: "%d 件エラー"), result.errors.count))
        }
        return parts.joined(separator: " / ")
    }

    // MARK: - Undo

    func undo() {
        guard !isExecuting else { return }

        // アプリ内スタック優先、無ければジャーナルファイル（CLI 互換）から
        let journal: Journal
        let fromDisk: Bool
        if let last = undoStack.last {
            journal = last
            fromDisk = false
        } else if let disk = Journal.loadFromDisk() {
            journal = disk
            fromDisk = true
        } else {
            statusMessage = String(localized: "取り消す操作がありません")
            return
        }

        isExecuting = true
        Task {
            let result = await Self.runUndo(journal)
            if !fromDisk { self.undoStack.removeLast() }
            Journal.markUndoneOnDisk()
            self.isExecuting = false
            // 取り消し後: 実行済みフラグだけリセット。plan/inputUnits は保持し
            // BeforeAfterView（適用前/後の比較）は表示したまま再ドロップを受け付ける。
            self.didExecute = false
            self.lastResult = nil
            var parts = [String(format: String(localized: "取り消し: %d 件成功"), result.success)]
            if result.skipped > 0 {
                parts.append(String(format: String(localized: "%d 件スキップ"), result.skipped))
            }
            if result.needManualRestore > 0 {
                parts.append(String(format: String(localized: "%d 件はゴミ箱から手動で復元してください"), result.needManualRestore))
            }
            self.statusMessage = parts.joined(separator: " / ")
        }
    }

    nonisolated private static func runUndo(_ journal: Journal) async -> UndoResult {
        journal.executeUndo()
    }
}
