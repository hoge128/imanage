import Foundation
import ImageIO

// MARK: - ExifReader
// core.py の get_exif_fields() / is_retouched() を ImageIO (CGImageSource) で移植。
// Pillow の代替として CGImageSource を使用することで RAW ファイルも読める。

enum ExifReader {

    // MARK: - EXIF 読み取り

    /// CGImageSource 経由で EXIF を読み ExifFields を返す。
    /// 読めないフィールドは "Unknown"。
    /// date は DateTimeOriginal → DateTimeDigitized → birthtime の順で解決する。
    static func read(from url: URL, config: ImanageConfig) -> ExifFields {
        let props = imageProperties(at: url)
        let tiff = props?[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = props?[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]

        var fields = ExifFields()

        // 文字列フィールド: TIFF Make(271), Model(272), Artist(315)
        fields.maker   = normalizeString(tiff[kCGImagePropertyTIFFMake  as String])
        fields.model   = normalizeString(tiff[kCGImagePropertyTIFFModel as String])
        fields.creator = normalizeString(tiff[kCGImagePropertyTIFFArtist as String])

        // EXIF LensModel(42036)
        fields.lens = normalizeString(exif[kCGImagePropertyExifLensModel as String])

        // EXIF FocalLength(37386): Double → "35mm"
        if let fl = exif[kCGImagePropertyExifFocalLength as String] {
            if let v = doubleValue(fl) {
                fields.focalLength = "\(Int(v))mm"
            } else {
                fields.focalLength = normalizeString(fl)
            }
        }

        // EXIF ExposureTime(33434): v >= 1 → "{n}s" / v < 1 → "1/{n}s"
        if let ss = exif[kCGImagePropertyExifExposureTime as String] {
            if let v = doubleValue(ss) {
                if v >= 1 {
                    fields.shutterSpeed = "\(Int(v))s"
                } else {
                    fields.shutterSpeed = "1/\(Int((1.0 / v).rounded()))s"
                }
            } else {
                fields.shutterSpeed = normalizeString(ss)
            }
        }

        // date: DateTimeOriginal → DateTimeDigitized → birthtime → modificationDate
        fields.date = resolveDate(exif: exif, url: url, dateFormat: config.dateFormat)

        return fields
    }

    // MARK: - レタッチ判定

    /// TIFF Software タグ (305) に RetouchKeywords が含まれるか（大文字小文字無視）。
    static func isRetouched(_ url: URL) -> Bool {
        let props = imageProperties(at: url)
        let tiff  = props?[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        guard let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String else {
            return false
        }
        let lower = software.lowercased()
        return RetouchKeywords.all.contains { lower.contains($0.lowercased()) }
    }

    // MARK: - Private helpers

    /// CGImageSource でプロパティ辞書を取得する。
    private static func imageProperties(at url: URL) -> [String: Any]? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, options as CFDictionary) as? [String: Any]
    }

    /// 文字列正規化: trim → \0 除去 → "/" を "-" に → " " を "_" に。空なら "Unknown"。
    private static func normalizeString(_ value: Any?) -> String {
        guard let v = value else { return "Unknown" }
        let s = (v as? String ?? "\(v)")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        return s.isEmpty ? "Unknown" : s
    }

    /// Any から Double を取り出す。
    private static func doubleValue(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int    { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// EXIF 日時文字列 "yyyy:MM:dd HH:mm:ss" をパースして dateFormat で整形する。
    private static func parseExifDate(_ str: String?, dateFormat: String) -> String? {
        guard let s = str, s.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: String(s.prefix(19))) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = dateFormat
        return out.string(from: date)
    }

    /// date フィールドを解決する:
    /// DateTimeOriginal → DateTimeDigitized → birthtime → modificationDate → "Unknown"
    private static func resolveDate(exif: [String: Any], url: URL, dateFormat: String) -> String {
        // DateTimeOriginal (36867)
        if let d = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                                 dateFormat: dateFormat) {
            return d
        }
        // DateTimeDigitized (36868)
        if let d = parseExifDate(exif[kCGImagePropertyExifDateTimeDigitized as String] as? String,
                                 dateFormat: dateFormat) {
            return d
        }

        // ファイル属性から取得
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = dateFormat

        if let creation = attrs?[.creationDate] as? Date {
            return out.string(from: creation)
        }
        if let modified = attrs?[.modificationDate] as? Date {
            return out.string(from: modified)
        }
        return "Unknown"
    }
}
