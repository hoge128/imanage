import Foundation

// MARK: - PathCalculator
// core.py の _preview_single() ルーズファイル分岐 (行 175-215) と
// imagev() の振り分けルールを移植し、ドロップされたファイル群から OrganizePlan を作る。
//
// 2 段構成:
//   1. scanFiles(): EXIF を読み取り ScannedFile を作る（重い I/O）
//   2. buildPlan(): hierarchy を適用して OrganizePlan を作る（軽い、再計算可能）
// メイン画面で階層を編集したときは buildPlan のみ再実行すれば EXIF 再読込は不要。

/// EXIF 読み取り済みの中間表現（hierarchy 非依存）
struct ScannedFile: Sendable {
    let source: URL
    let exif: ExifFields
    let category: FileCategory
    /// 末端ディレクトリ名（jpg/raw/retouch、xmpPair 解決済み）
    let dirName: String
}

/// 振り分け対象外の理由
enum SkipReason: Sendable {
    /// 対応していない種類（動画・PNG・書類など）
    case unsupportedType
    /// カメラ EXIF（撮影日時・Make/Model）を持たない（スクリーンショット・Web 画像など）
    case noExif
}

/// 振り分け対象外のファイル（その場に残す）
struct SkippedFile: Sendable {
    let url: URL
    let reason: SkipReason
}

struct ScanResult: Sendable {
    let scanned: [ScannedFile]
    let skipped: [SkippedFile]
}

struct PathCalculator: Sendable {
    let config: ImanageConfig

    // MARK: - 1. スキャン（EXIF 読み取り）

    func scanFiles(_ droppedFiles: [URL]) -> ScanResult {
        var skipped: [SkippedFile] = []
        var jpgFiles: [URL] = []
        var rawFiles: [URL] = []
        var xmpFiles: [URL] = []

        for url in droppedFiles {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }  // 隠しファイル除外

            let ext = url.pathExtension.lowercased()
            if ImanageExtensions.jpg.contains(ext) {
                jpgFiles.append(url)
            } else if ImanageExtensions.raw.contains(ext) {
                rawFiles.append(url)
            } else if ext == ImanageExtensions.xmp {
                xmpFiles.append(url)
            } else {
                skipped.append(SkippedFile(url: url, reason: .unsupportedType))
            }
        }

        // 処理順ソート: JPG(0) → RAW(1) → XMP(2)、同順位はファイル名昇順
        // XMP/RAW が同名 JPG の EXIF を参照できるようにするため
        let tagged: [(URL, Int)] =
            jpgFiles.map { ($0, 0) } +
            rawFiles.map { ($0, 1) } +
            xmpFiles.map { ($0, 2) }
        let orderedFiles = tagged.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }.map { $0.0 }

        // stem → ExifFields キャッシュ（XMP/RAW が同名 JPG、XMP が同名 RAW の EXIF を参照する）
        var exifCache: [String: ExifFields] = [:]
        var scanned: [ScannedFile] = []

        for url in orderedFiles {
            let ext  = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent

            let dirName: String
            let category: FileCategory
            let fields: ExifFields

            if ImanageExtensions.jpg.contains(ext) {
                let f = ExifReader.read(from: url, config: config)
                // コンセプト = カメラで撮影された静止画のみ。
                // カメラ EXIF を持たない JPG/HEIC（スクリーンショット・Web 画像等）は
                // 対象外にしてその場に残す。キャッシュにも入れない（Unknown 値を
                // 同名 RAW/XMP に波及させないため）。
                guard f.hasCameraExif else {
                    skipped.append(SkippedFile(url: url, reason: .noExif))
                    continue
                }
                exifCache[stem] = f
                fields = f
                if ExifReader.isRetouched(url) {
                    dirName  = config.retouchDirName
                    category = .retouch
                } else {
                    dirName  = config.jpgDirName
                    category = .jpg
                }
            } else if ImanageExtensions.raw.contains(ext) {
                // RAW はカメラ生成物なので常に対象
                dirName  = config.rawDirName
                category = .raw
                let f = resolveFields(url: url, stem: stem, cache: exifCache)
                // RAW の EXIF もキャッシュし、同名 XMP（JPG 不在ペア）が参照できるようにする
                if exifCache[stem] == nil { exifCache[stem] = f }
                fields = f
            } else {
                let f = resolveFields(url: url, stem: stem, cache: exifCache)
                // ペア（同名 JPG/RAW）の EXIF を引けない XMP は、ペアと分離して
                // Unknown フォルダへ行くのを防ぐため対象外にする。
                guard f.hasCameraExif else {
                    skipped.append(SkippedFile(url: url, reason: .noExif))
                    continue
                }
                dirName  = config.xmpPairIsJpg ? config.jpgDirName : config.rawDirName
                category = .xmp
                fields   = f
            }

            scanned.append(ScannedFile(
                source: url, exif: fields, category: category, dirName: dirName))
        }

        return ScanResult(scanned: scanned, skipped: skipped)
    }

    // MARK: - 2. プラン生成（hierarchy 適用）

    func buildPlan(from scan: ScanResult, destRoot: URL) -> OrganizePlan {
        var moves: [PlannedMove] = []
        for sf in scan.scanned {
            // relativeDir = hierarchy の各フィールド値。
            // ペアリングフィールドは EXIF ではなく dirName（jpg/raw/retouch）を値にする。
            let parts = config.hierarchy.map { field in
                field == HierarchyField.pairing.key ? sf.dirName : sf.exif.value(for: field)
            }
            let relativeDir = parts.joined(separator: "/")
            let destDir  = parts.reduce(destRoot) { $0.appendingPathComponent($1) }
            let destFile = destDir.appendingPathComponent(sf.source.lastPathComponent)
            moves.append(PlannedMove(
                source: sf.source,
                destination: destFile,
                category: sf.category,
                relativeDir: relativeDir))
        }
        return OrganizePlan(destRoot: destRoot, moves: moves,
                            skipped: scan.skipped.map(\.url))
    }

    // MARK: - 便宜メソッド（スキャン + プランをまとめて実行）

    func makePlan(droppedFiles: [URL], destRoot: URL) -> OrganizePlan {
        buildPlan(from: scanFiles(droppedFiles), destRoot: destRoot)
    }

    // MARK: - Private helpers

    /// _resolve_fields と同じ: stem がキャッシュにあればそれ、なければファイル自身を読む。
    private func resolveFields(url: URL, stem: String, cache: [String: ExifFields]) -> ExifFields {
        if let cached = cache[stem] { return cached }
        return ExifReader.read(from: url, config: config)
    }
}
