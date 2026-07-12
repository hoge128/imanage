import Foundation

// MARK: - Core data types shared across Core / Stores / Views

/// EXIF から解決したフィールド一式。取得できない値は "Unknown"。
/// CLI 版 `get_exif_fields()` (core.py) と同じ正規化規則:
/// - 文字列: trim, \0 除去, "/" → "-", " " → "_"
/// - focal_length: "35mm"
/// - shutter_speed: 1秒以上 "{n}s" / 未満 "1/{n}s"
/// - date: DateTimeOriginal → DateTimeDigitized → btime, "yyyyMMdd"
struct ExifFields: Sendable, Equatable {
    var maker: String = "Unknown"
    var model: String = "Unknown"
    var creator: String = "Unknown"
    var lens: String = "Unknown"
    var focalLength: String = "Unknown"
    var shutterSpeed: String = "Unknown"
    var date: String = "Unknown"

    /// hierarchy フィールド名 ("maker" 等) から値を引く
    func value(for field: String) -> String {
        switch field {
        case "maker": return maker
        case "model": return model
        case "creator": return creator
        case "lens": return lens
        case "focal_length": return focalLength
        case "shutter_speed": return shutterSpeed
        case "date": return date
        default: return "Unknown"
        }
    }
}

/// 振り分け先カテゴリ（= 末端ディレクトリ名の種別）
enum FileCategory: String, Sendable, Codable, CaseIterable {
    case jpg
    case raw
    case retouch
    case xmp  // サイドカー。実際の移動先は設定 xmpPair に従い jpg/ か raw/
}

/// 1 ファイルの移動計画
struct PlannedMove: Sendable, Identifiable, Equatable {
    let id: UUID
    /// 移動元（ドロップされたファイル）
    let source: URL
    /// 移動先のフルパス（ファイル名込み）
    let destination: URL
    let category: FileCategory
    /// プレビューツリー表示用: destRoot からの相対ディレクトリ (例: "SONY/ILCE-7M4/20230807/raw")
    let relativeDir: String

    init(source: URL, destination: URL, category: FileCategory, relativeDir: String) {
        self.id = UUID()
        self.source = source
        self.destination = destination
        self.category = category
        self.relativeDir = relativeDir
    }
}

/// ドロップされたファイル群に対する振り分け計画全体
struct OrganizePlan: Sendable, Equatable {
    /// 振り分け先のルートディレクトリ
    let destRoot: URL
    let moves: [PlannedMove]
    /// 対象外拡張子などでスキップされたファイル
    let skipped: [URL]

    var isEmpty: Bool { moves.isEmpty }
}

/// 実行結果
struct OrganizeResult: Sendable {
    var movedCount: Int = 0
    /// 移動先に同名ファイルが存在してスキップしたファイル
    var skippedExisting: [URL] = []
    var errors: [String] = []
}
