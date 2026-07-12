import Foundation
import Observation

// MARK: - SettingsStore
// UserDefaults に永続化するアプリ設定。CLI の config.toml に相当する。

@MainActor
@Observable
final class SettingsStore {
    // 振り分け先の決め方
    enum DestinationMode: String {
        /// ドロップされたファイルの親フォルダ内で整理（CLI の in-place -o 相当）
        case droppedParent
        /// 固定フォルダへ整理（CLI の -O destination 相当）
        case fixed
    }

    var destinationMode: DestinationMode {
        didSet { defaults.set(destinationMode.rawValue, forKey: Keys.destinationMode) }
    }
    var fixedDestinationPath: String {
        didSet { defaults.set(fixedDestinationPath, forKey: Keys.fixedDestination) }
    }
    /// お気に入りの移動先（最大 3 件）
    var favoriteDestinations: [String] {
        didSet { defaults.set(favoriteDestinations, forKey: Keys.favoriteDestinations) }
    }
    /// 既定の出力先（お気に入りの 1 つ）。空 = 既定なし。
    /// 設定されていると、新規ドロップ時に自動でこの出力先が初期選択される。
    var defaultDestinationPath: String {
        didSet { defaults.set(defaultDestinationPath, forKey: Keys.defaultDestination) }
    }
    /// organize 階層（カンマ区切りで編集される）
    var hierarchy: [String] {
        didSet { defaults.set(hierarchy, forKey: Keys.hierarchy) }
    }
    var xmpPairIsJpg: Bool {
        didSet { defaults.set(xmpPairIsJpg, forKey: Keys.xmpPairIsJpg) }
    }

    // [応用1] フォルダ監視
    var watcherEnabled: Bool {
        didSet { defaults.set(watcherEnabled, forKey: Keys.watcherEnabled) }
    }
    var watcherSourcePath: String {
        didSet { defaults.set(watcherSourcePath, forKey: Keys.watcherSource) }
    }
    var watcherDestPath: String {
        didSet { defaults.set(watcherDestPath, forKey: Keys.watcherDest) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let destinationMode = "destinationMode"
        static let fixedDestination = "fixedDestinationPath"
        static let favoriteDestinations = "favoriteDestinations"
        static let defaultDestination = "defaultDestinationPath"
        static let hierarchy = "hierarchy"
        static let xmpPairIsJpg = "xmpPairIsJpg"
        static let watcherEnabled = "watcherEnabled"
        static let watcherSource = "watcherSourcePath"
        static let watcherDest = "watcherDestPath"
        static let pairingMigrated = "pairingMigrated_v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.destinationMode = DestinationMode(rawValue: defaults.string(forKey: Keys.destinationMode) ?? "") ?? .droppedParent
        self.fixedDestinationPath = defaults.string(forKey: Keys.fixedDestination) ?? ""
        self.favoriteDestinations = defaults.stringArray(forKey: Keys.favoriteDestinations) ?? []
        self.defaultDestinationPath = defaults.string(forKey: Keys.defaultDestination) ?? ""

        // imanage ペアリングを階層フィールド化した際の移行:
        // 既存ユーザーの保存済み階層に imanage_pair が無ければ一度だけ末尾に追加する
        // （従来の jpg/raw/retouch 振り分けを維持するため）。
        var savedHierarchy = defaults.stringArray(forKey: Keys.hierarchy) ?? ImanageConfig.default.hierarchy
        if !defaults.bool(forKey: Keys.pairingMigrated) {
            if !savedHierarchy.contains(HierarchyField.pairing.key) {
                savedHierarchy.append(HierarchyField.pairing.key)
                defaults.set(savedHierarchy, forKey: Keys.hierarchy)
            }
            defaults.set(true, forKey: Keys.pairingMigrated)
        }
        self.hierarchy = savedHierarchy

        self.xmpPairIsJpg = defaults.bool(forKey: Keys.xmpPairIsJpg)
        self.watcherEnabled = defaults.bool(forKey: Keys.watcherEnabled)
        self.watcherSourcePath = defaults.string(forKey: Keys.watcherSource) ?? ""
        self.watcherDestPath = defaults.string(forKey: Keys.watcherDest) ?? ""
    }

    /// Core へ渡す不変スナップショット
    var config: ImanageConfig {
        var c = ImanageConfig.default
        c.hierarchy = hierarchy
        c.xmpPairIsJpg = xmpPairIsJpg
        return c
    }

    /// お気に入りの最大件数
    static let maxFavorites = 3

    /// 現在のパスをお気に入りに追加（最大数まで、重複は無視）
    func addFavorite(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard !p.isEmpty,
              !favoriteDestinations.contains(p),
              favoriteDestinations.count < Self.maxFavorites else { return }
        favoriteDestinations.append(p)
    }

    func removeFavorite(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        favoriteDestinations.removeAll { $0 == path }
        // 既定にしていたお気に入りを削除したら既定も解除する
        if defaultDestinationPath == p { defaultDestinationPath = "" }
    }

    /// お気に入りを移動先として適用する（fixed モードへ切替）
    func applyFavorite(_ path: String) {
        destinationMode = .fixed
        fixedDestinationPath = path
    }

    // MARK: - 既定の出力先

    /// このパスが既定の出力先か
    func isDefault(_ path: String) -> Bool {
        let p = (path as NSString).expandingTildeInPath
        return !defaultDestinationPath.isEmpty && defaultDestinationPath == p
    }

    /// 既定の出力先に設定する（お気に入り未登録なら登録もする）
    func setDefault(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard !p.isEmpty else { return }
        if !favoriteDestinations.contains(p) { addFavorite(p) }
        defaultDestinationPath = p
    }

    func clearDefault() { defaultDestinationPath = "" }

    /// 既定の設定/解除をトグルする
    func toggleDefault(_ path: String) {
        if isDefault(path) { clearDefault() } else { setDefault(path) }
    }

    /// 新規ドロップ時に既定の出力先を「現在の選択」へ反映する。
    /// 既定未設定なら何もしない（従来どおり現在の選択・ドロップ元同一を維持）。
    func applyDefaultAsCurrent() {
        guard !defaultDestinationPath.isEmpty else { return }
        destinationMode = .fixed
        fixedDestinationPath = defaultDestinationPath
    }

    /// ドロップされた項目（ファイル/フォルダ）に対する振り分け先ルートを解決する
    func resolveDestRoot(droppedItems urls: [URL]) -> URL? {
        // fixed モードでフォルダ選択済みならそこへ。
        if destinationMode == .fixed, !fixedDestinationPath.isEmpty {
            return URL(fileURLWithPath: (fixedDestinationPath as NSString).expandingTildeInPath)
        }
        // droppedParent、または fixed だが未選択の場合はドロップ元から解決する。
        // （fixed 未選択でもプレビューを表示し、移動先パネルの「フォルダを選択…」で確定できる）
        guard let first = urls.first else { return nil }
        if urls.count == 1 {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir),
               isDir.boolValue {
                return first
            }
        }
        return first.deletingLastPathComponent()
    }
}
