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

        // EXIF FocalLenIn35mmFilm(41989): Double → "52mm"
        if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String],
           let v = doubleValue(fl35), v > 0 {
            fields.focalLength35mm = "\(Int(v))mm"
        }

        // EXIF FNumber(33437): 整数なら "F4"、小数なら "F2.8"
        if let fn = exif[kCGImagePropertyExifFNumber as String], let v = doubleValue(fn), v > 0 {
            fields.fNumber = v == v.rounded()
                ? "F\(Int(v))"
                : String(format: "F%.1f", v)
        }

        // EXIF ISOSpeedRatings(34855): 配列の先頭 → "ISO400"
        if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any],
           let first = isoArr.first, let v = doubleValue(first), v > 0 {
            fields.iso = "ISO\(Int(v))"
        }

        // rating: XMP サイドカー（または .xmp 自身）→ 埋め込み（IPTC StarRating）
        fields.rating = readRating(url: url, props: props)

        // date: DateTimeOriginal → DateTimeDigitized → birthtime → modificationDate
        // 表記違い（date_a / date_b）も同じ生日時から整形する
        if let raw = resolveRawDate(exif: exif, url: url) {
            fields.date      = format(raw, config.dateFormat)
            fields.dateA     = format(raw, "yyyy-MM-dd")
            fields.dateB     = format(raw, "yyyy/MM/dd")   // 年/月/日 の3階層に展開される
            fields.dateYear  = format(raw, "yyyy")
            fields.dateMonth = format(raw, "MM")
            fields.dateDay   = format(raw, "dd")
            fields.dateYM    = format(raw, "yyyyMM")
            fields.dateYMA   = format(raw, "yyyy-MM")
            fields.dateYMB   = format(raw, "yyyy/MM")   // 年/月 の2階層に展開される
            fields.dateMD    = format(raw, "MMdd")
            fields.dateMDA   = format(raw, "MM-dd")
            fields.dateMDB   = format(raw, "MM/dd")     // 月/日 の2階層に展開される
        }

        return fields
    }

    // MARK: - XMP 評価（xmp:Rating）

    /// 星評価を読む。優先順:
    /// 1. .xmp ファイル自身、または同名サイドカー（stem.xmp）のテキスト解析
    /// 2. 画像埋め込みメタデータ（ImageIO が xmp:Rating を IPTC StarRating にマップ）
    /// 見つからなければ "Unknown"。
    private static func readRating(url: URL, props: [String: Any]?) -> String {
        let xmpURL: URL?
        if url.pathExtension.lowercased() == ImanageExtensions.xmp {
            xmpURL = url
        } else {
            let candidate = url.deletingPathExtension().appendingPathExtension("xmp")
            xmpURL = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        if let xmpURL,
           let text = try? String(contentsOf: xmpURL, encoding: .utf8),
           let rating = parseXMPRating(text) {
            return "rating-\(rating)"
        }

        let iptc = props?[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        if let r = iptc?[kCGImagePropertyIPTCStarRating as String], let v = doubleValue(r) {
            return "rating-\(Int(v))"
        }
        return "Unknown"
    }

    /// XMP テキストから xmp:Rating を取り出す。
    /// 属性形式 `xmp:Rating="3"` と要素形式 `<xmp:Rating>3</xmp:Rating>` の両方に対応。
    private static func parseXMPRating(_ text: String) -> Int? {
        for pattern in [#"xmp:Rating="(-?\d+)""#, #"<xmp:Rating>\s*(-?\d+)"#] {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let matched = String(text[match])
                if let numRange = matched.range(of: #"-?\d+"#, options: .regularExpression),
                   let n = Int(matched[numRange]) {
                    return n
                }
            }
        }
        return nil
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

    /// EXIF 日時文字列 "yyyy:MM:dd HH:mm:ss" をパースする。
    private static func parseExifDate(_ str: String?) -> Date? {
        guard let s = str, s.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(s.prefix(19)))
    }

    /// 撮影日時（生の Date）を解決する:
    /// DateTimeOriginal → DateTimeDigitized → birthtime → modificationDate → nil
    private static func resolveRawDate(exif: [String: Any], url: URL) -> Date? {
        // DateTimeOriginal (36867)
        if let d = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String) {
            return d
        }
        // DateTimeDigitized (36868)
        if let d = parseExifDate(exif[kCGImagePropertyExifDateTimeDigitized as String] as? String) {
            return d
        }
        // ファイル属性から取得
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let creation = attrs?[.creationDate] as? Date { return creation }
        if let modified = attrs?[.modificationDate] as? Date { return modified }
        return nil
    }

    /// Date を指定フォーマットで整形する。
    private static func format(_ date: Date, _ dateFormat: String) -> String {
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = dateFormat
        return out.string(from: date)
    }
}
