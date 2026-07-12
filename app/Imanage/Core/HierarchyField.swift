import Foundation

// MARK: - HierarchyField
// 振り分け階層に使えるフィールドの定義。config の hierarchy 文字列キーと
// ExifFields.value(for:) のキーは完全に一致させること。

enum HierarchyField: String, CaseIterable, Identifiable, Sendable {
    case maker
    case model
    case date
    case creator
    case lens
    case focalLength = "focal_length"
    case shutterSpeed = "shutter_speed"
    /// imanage ペアリング: jpg / raw / retouch に分けるフォルダ。
    /// 値は EXIF ではなくファイル種別（ScannedFile.dirName）から決まる特殊フィールド。
    case pairing = "imanage_pair"

    var id: String { rawValue }

    /// config / ExifFields で使うキー（rawValue と同一）
    var key: String { rawValue }

    /// UI 表示名（ローカライズ対象）
    var displayName: String {
        switch self {
        case .maker:        String(localized: "メーカー")
        case .model:        String(localized: "機種")
        case .date:         String(localized: "撮影日")
        case .creator:      String(localized: "作成者")
        case .lens:         String(localized: "レンズ")
        case .focalLength:  String(localized: "焦点距離")
        case .shutterSpeed: String(localized: "シャッター速度")
        case .pairing:      String(localized: "imanage ペアリング")
        }
    }

    var systemImage: String {
        switch self {
        case .maker:        "building.2"
        case .model:        "camera"
        case .date:         "calendar"
        case .creator:      "person"
        case .lens:         "camera.aperture"
        case .focalLength:  "arrow.left.and.right"
        case .shutterSpeed: "timer"
        case .pairing:      "rectangle.split.3x1"
        }
    }

    /// フォルダ名の例（プレビュー用）
    var example: String {
        switch self {
        case .maker:        "SONY"
        case .model:        "ILCE-7M4"
        case .date:         "20230807"
        case .creator:      "John_Doe"
        case .lens:         "FE_24-70mm"
        case .focalLength:  "35mm"
        case .shutterSpeed: "1/250s"
        case .pairing:      "jpg"
        }
    }

    /// config キーから HierarchyField を引く（未知キーは nil）
    static func from(key: String) -> HierarchyField? {
        HierarchyField(rawValue: key)
    }
}
