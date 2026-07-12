import Foundation

// MARK: - HierarchyField
// 振り分け階層に使えるフィールドの定義。config の hierarchy 文字列キーと
// ExifFields.value(for:) のキーは完全に一致させること。

enum HierarchyField: String, CaseIterable, Identifiable, Sendable {
    case maker
    case model
    case date
    /// 撮影日の表記違い A: "2023-08-07"
    case dateA = "date_a"
    /// 撮影日の表記違い B: "2023/08/07"（年/月/日 の3階層に展開）
    case dateB = "date_b"
    /// 撮影年のみ: "2023"
    case dateYear = "date_year"
    /// 撮影月のみ: "01"〜"12"
    case dateMonth = "date_month"
    /// 撮影日（日のみ）: "01"〜"31"
    case dateDay = "date_day"
    /// 撮影年月: "202607"
    case dateYM = "date_ym"
    /// 撮影年月の表記違い A: "2026-07"
    case dateYMA = "date_ym_a"
    /// 撮影年月の表記違い B: "2026/07"（年/月 の2階層に展開）
    case dateYMB = "date_ym_b"
    /// 撮影月日: "0701"
    case dateMD = "date_md"
    /// 撮影月日の表記違い A: "07-01"
    case dateMDA = "date_md_a"
    /// 撮影月日の表記違い B: "07/01"（月/日 の2階層に展開）
    case dateMDB = "date_md_b"
    case creator
    case lens
    case focalLength = "focal_length"
    case focalLength35mm = "focal_length_35mm"
    case shutterSpeed = "shutter_speed"
    case fNumber = "f_number"
    case iso
    /// XMP の星評価（xmp:Rating）。サイドカーまたは画像埋め込みから読む。
    case rating
    /// 評価の表記違い（★ 形式）。データソースは rating と同じ XMP 評価。
    case ratingA = "rating_a"
    /// imanage ペアリング: jpg / raw / retouch に分けるフォルダ。
    /// 値は EXIF ではなくファイル種別（ScannedFile.dirName）から決まる特殊フィールド。
    case pairing = "imanage_pair"

    var id: String { rawValue }

    /// config / ExifFields で使うキー（rawValue と同一）
    var key: String { rawValue }

    /// UI 表示名（ローカライズ対象）
    var displayName: String {
        switch self {
        case .maker:           String(localized: "メーカー")
        case .model:           String(localized: "機種")
        case .date:            String(localized: "撮影日")
        case .dateA:           String(localized: "撮影日_A")
        case .dateB:           String(localized: "撮影日_B")
        case .dateYear:        String(localized: "撮影年(Y)")
        case .dateMonth:       String(localized: "撮影月(M)")
        case .dateDay:         String(localized: "撮影日(D)")
        case .dateYM:          String(localized: "撮影年月(YM)")
        case .dateYMA:         String(localized: "撮影年月(YM)_A")
        case .dateYMB:         String(localized: "撮影年月(YM)_B")
        case .dateMD:          String(localized: "撮影月日(MD)")
        case .dateMDA:         String(localized: "撮影月日(MD)_A")
        case .dateMDB:         String(localized: "撮影月日(MD)_B")
        case .creator:         String(localized: "作成者")
        case .lens:            String(localized: "レンズ")
        case .focalLength:     String(localized: "焦点距離")
        case .focalLength35mm: String(localized: "35mm換算焦点距離")
        case .shutterSpeed:    String(localized: "シャッター速度")
        case .fNumber:         String(localized: "F値")
        case .iso:             String(localized: "ISO")
        case .rating:          String(localized: "評価")
        case .ratingA:         String(localized: "評価_A")
        case .pairing:         String(localized: "imanage ペアリング")
        }
    }

    var systemImage: String {
        switch self {
        case .maker:           "building.2"
        case .model:           "camera"
        case .date:            "calendar"
        case .dateA:           "calendar.circle"
        case .dateB:           "calendar.day.timeline.left"
        case .dateYear:        "y.square"
        case .dateMonth:       "m.square"
        case .dateDay:         "d.square"
        case .dateYM:          "calendar.badge.clock"
        case .dateYMA:         "calendar.badge.clock"
        case .dateYMB:         "calendar.badge.clock"
        case .dateMD:          "calendar.day.timeline.trailing"
        case .dateMDA:         "calendar.day.timeline.trailing"
        case .dateMDB:         "calendar.day.timeline.trailing"
        case .creator:         "person"
        case .lens:            "camera.aperture"
        case .focalLength:     "arrow.left.and.right"
        case .focalLength35mm: "arrow.left.and.right.square"
        case .shutterSpeed:    "timer"
        case .fNumber:         "f.cursive"
        case .iso:             "sun.max"
        case .rating:          "star.square"
        case .ratingA:         "star.circle"
        case .pairing:         "rectangle.split.3x1"
        }
    }

    /// フォルダ名の例（プレビュー用）。
    /// とりうる値が決まっているフィールドは [a, b, c] の集合表記で全候補を示す。
    var example: String {
        switch self {
        case .maker:           "SONY"
        case .model:           "ILCE-7M4"
        case .date:            "20230807"
        case .dateA:           "2023-08-07"
        case .dateB:           "2023/08/07"
        case .dateYear:        "2023"
        case .dateMonth:       "[01 … 12]"
        case .dateDay:         "[01 … 31]"
        case .dateYM:          "202607"
        case .dateYMA:         "2026-07"
        case .dateYMB:         "2026/07"
        case .dateMD:          "0701"
        case .dateMDA:         "07-01"
        case .dateMDB:         "07/01"
        case .creator:         "John_Doe"
        case .lens:            "FE_24-70mm"
        case .focalLength:     "35mm"
        case .focalLength35mm: "52mm"
        case .shutterSpeed:    "1/250s"
        case .fNumber:         "F2.8"
        case .iso:             "ISO400"
        case .rating:          "[rating-0 … rating-5]"
        case .ratingA:         "[★0 … ★5]"
        case .pairing:         "[jpg, raw, retouch]"
        }
    }

    /// example が集合表記（とりうる値の列挙）かどうか
    var exampleIsValueSet: Bool {
        switch self {
        case .rating, .ratingA, .pairing, .dateMonth, .dateDay: true
        default: false
        }
    }

    /// チップの説明（ヘルプカード用）
    var helpText: String {
        switch self {
        case .maker:           String(localized: "カメラの製造元。同じメーカーの写真をまとめます。")
        case .model:           String(localized: "カメラの機種名。ボディごとに分けられます。")
        case .date:            String(localized: "撮影した日付。日単位でフォルダに分けます。")
        case .dateA:           String(localized: "撮影日の表記違い（2023-08-07 形式）。")
        case .dateB:           String(localized: "撮影日の表記違い。年/月/日 の3階層のフォルダに展開します。")
        case .dateYear:        String(localized: "撮影した年（4桁の数字）。")
        case .dateMonth:       String(localized: "撮影した月（01〜12 の数字）。")
        case .dateDay:         String(localized: "撮影した日（01〜31 の数字）。")
        case .dateYM:          String(localized: "撮影した年月（202607 形式）。月単位でまとめます。")
        case .dateYMA:         String(localized: "撮影年月の表記違い（2026-07 形式）。")
        case .dateYMB:         String(localized: "撮影年月の表記違い。年/月 の2階層のフォルダに展開します。")
        case .dateMD:          String(localized: "撮影した月日（0701 形式）。年をまたいで同じ月日をまとめます。")
        case .dateMDA:         String(localized: "撮影月日の表記違い（07-01 形式）。")
        case .dateMDB:         String(localized: "撮影月日の表記違い。月/日 の2階層のフォルダに展開します。")
        case .creator:         String(localized: "作成者・著作者名。")
        case .lens:            String(localized: "撮影に使用したレンズ名。")
        case .focalLength:     String(localized: "撮影時の焦点距離。")
        case .focalLength35mm: String(localized: "35mm判換算の焦点距離。EXIF に記録がある場合のみ。")
        case .shutterSpeed:    String(localized: "シャッター速度（露光時間）。")
        case .fNumber:         String(localized: "撮影時の絞り値。")
        case .iso:             String(localized: "撮影時の ISO 感度。")
        case .rating:          String(localized: "星評価（0〜5）。XMP サイドカーまたは画像埋め込みの XMP から読み取ります。")
        case .ratingA:         String(localized: "評価の表記違い（★ 形式）。データソースは「評価」と同じ XMP の星評価です。")
        case .pairing:         String(localized: "jpg / raw / retouch などファイル種別ごとにサブフォルダへ分けます（EXIF ではなく拡張子で判定）。")
        }
    }

    /// 由来の EXIF フィールド名。EXIF 由来でない場合は nil。
    var exifKey: String? {
        switch self {
        case .maker:           "Make"
        case .model:           "Model"
        case .date:            "DateTimeOriginal"
        case .dateA:           "DateTimeOriginal"
        case .dateB:           "DateTimeOriginal"
        case .dateYear:        "DateTimeOriginal"
        case .dateMonth:       "DateTimeOriginal"
        case .dateDay:         "DateTimeOriginal"
        case .dateYM:          "DateTimeOriginal"
        case .dateYMA:         "DateTimeOriginal"
        case .dateYMB:         "DateTimeOriginal"
        case .dateMD:          "DateTimeOriginal"
        case .dateMDA:         "DateTimeOriginal"
        case .dateMDB:         "DateTimeOriginal"
        case .creator:         "Artist"
        case .lens:            "LensModel"
        case .focalLength:     "FocalLength"
        case .focalLength35mm: "FocalLengthIn35mmFilm"
        case .shutterSpeed:    "ExposureTime"
        case .fNumber:         "FNumber"
        case .iso:             "ISOSpeedRatings"
        case .rating:          nil
        case .ratingA:         nil
        case .pairing:         nil
        }
    }

    /// ヘルプカードの「由来」行（ラベル, 値）
    var sourceInfo: (label: String, value: String) {
        if let key = exifKey { return (String(localized: "EXIF"), key) }
        switch self {
        case .rating, .ratingA: return (String(localized: "XMP"), "Rating")
        default:      return (String(localized: "由来"), String(localized: "ファイル種別"))
        }
    }

    /// config キーから HierarchyField を引く（未知キーは nil）
    static func from(key: String) -> HierarchyField? {
        HierarchyField(rawValue: key)
    }
}
