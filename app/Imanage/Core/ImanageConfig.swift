import Foundation

// MARK: - ImanageConfig
// CLI 版 config.toml と同じデフォルト値を持つ設定モデル。
// アプリでは UserDefaults に永続化する（SettingsStore 経由で読み書き）。

struct ImanageConfig: Sendable, Equatable {
    /// 末端ディレクトリ名
    var jpgDirName = "jpg"
    var rawDirName = "raw"
    var retouchDirName = "retouch"

    /// 日付フォルダの形式（CLI: date_format = "%Y%m%d"）
    var dateFormat = "yyyyMMdd"

    /// -o 整理時のフォルダ階層（使用可能: maker, model, creator, lens, focal_length, shutter_speed, date, imanage_pair）
    /// imanage_pair = jpg/raw/retouch の振り分け。末尾に置くと従来どおり。
    var hierarchy = ["maker", "model", "date", "imanage_pair"]

    /// XMP サイドカーの振り分け先: "raw"（デフォルト）または "jpg"
    var xmpPairIsJpg = false

    static let `default` = ImanageConfig()
}

// MARK: - 対象拡張子（config.toml と同一、小文字で保持し比較は lowercased）

enum ImanageExtensions {
    static let jpg: Set<String> = ["jpg", "jpeg", "jpe", "jfif"]

    static let raw: Set<String> = [
        "arw", "srf", "sr2",        // Sony
        "raf",                      // Fujifilm
        "cr3", "cr2", "crw",        // Canon
        "nef", "nrw",               // Nikon
        "orf",                      // Olympus / OM System
        "rw2", "raw",               // Panasonic
        "pef",                      // Pentax
        "dng",                      // Adobe / Leica / Pentax 等
        "rwl",                      // Leica
        "srw",                      // Samsung
        "x3f",                      // Sigma
        "dcr", "k25", "kdc",        // Kodak
        "erf",                      // Epson
        "mef",                      // Mamiya
        "3fr",                      // Hasselblad
        "iiq",                      // Phase One
        "mos",                      // Leaf
    ]

    static let xmp = "xmp"

    static func category(forExtension ext: String) -> FileCategory? {
        let lower = ext.lowercased()
        if jpg.contains(lower) { return .jpg }
        if raw.contains(lower) { return .raw }
        if lower == xmp { return .xmp }
        return nil
    }
}

// MARK: - レタッチ判定キーワード（core.py RETOUCH_KEYWORDS と同一）

enum RetouchKeywords {
    static let all = [
        "Lightroom", "Photoshop", "Capture One", "DxO", "Luminar",
        "ON1", "Darktable", "RawTherapee", "GIMP", "Affinity",
    ]
}
