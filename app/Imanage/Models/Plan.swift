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
    var focalLength35mm: String = "Unknown"
    var shutterSpeed: String = "Unknown"
    var fNumber: String = "Unknown"
    var iso: String = "Unknown"
    /// XMP の星評価（xmp:Rating）。"rating-3" 形式。
    var rating: String = "Unknown"
    var date: String = "Unknown"
    /// 撮影日の表記違い A: "2023-08-07"
    var dateA: String = "Unknown"
    /// 撮影日の表記違い B: "2023/08/07"（年/月/日 の3階層に展開される）
    var dateB: String = "Unknown"
    /// 撮影年: "2023"
    var dateYear: String = "Unknown"
    /// 撮影月: "01"〜"12"
    var dateMonth: String = "Unknown"
    /// 撮影日（日のみ）: "01"〜"31"
    var dateDay: String = "Unknown"
    /// 撮影年月: "202607"
    var dateYM: String = "Unknown"
    /// 撮影年月の表記違い A: "2026-07"
    var dateYMA: String = "Unknown"
    /// 撮影年月の表記違い B: "2026/07"（年/月 の2階層に展開される）
    var dateYMB: String = "Unknown"
    /// 撮影月日: "0701"
    var dateMD: String = "Unknown"
    /// 撮影月日の表記違い A: "07-01"
    var dateMDA: String = "Unknown"
    /// 撮影月日の表記違い B: "07/01"（月/日 の2階層に展開される）
    var dateMDB: String = "Unknown"

    /// hierarchy フィールド名 ("maker" 等) から値を引く
    func value(for field: String) -> String {
        switch field {
        case "maker": return maker
        case "model": return model
        case "creator": return creator
        case "lens": return lens
        case "focal_length": return focalLength
        case "focal_length_35mm": return focalLength35mm
        case "shutter_speed": return shutterSpeed
        case "f_number": return fNumber
        case "iso": return iso
        case "rating": return rating
        // 評価_A: 評価の表記違い（rating-3 → ★3）。データソースは同じ XMP 評価。
        case "rating_a":
            return rating == "Unknown"
                ? "Unknown"
                : rating.replacingOccurrences(of: "rating-", with: "★")
        case "date": return date
        case "date_a": return dateA
        case "date_b": return dateB
        case "date_year": return dateYear
        case "date_month": return dateMonth
        case "date_day": return dateDay
        case "date_ym": return dateYM
        case "date_ym_a": return dateYMA
        case "date_ym_b": return dateYMB
        case "date_md": return dateMD
        case "date_md_a": return dateMDA
        case "date_md_b": return dateMDB
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
