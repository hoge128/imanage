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

struct ScanResult: Sendable {
    let scanned: [ScannedFile]
    let skipped: [URL]
}

struct PathCalculator: Sendable {
    let config: ImanageConfig

    // MARK: - 1. スキャン（EXIF 読み取り）

    func scanFiles(_ droppedFiles: [URL]) -> ScanResult {
        var skipped: [URL] = []
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
                skipped.append(url)
            }
        }

        // 処理順ソート: JPG(0) → RAW(1) → XMP(2)、同順位はファイル名昇順
        // XMP が同名 JPG の EXIF を参照できるようにするため
        let tagged: [(URL, Int)] =
            jpgFiles.map { ($0, 0) } +
            rawFiles.map { ($0, 1) } +
            xmpFiles.map { ($0, 2) }
        let orderedFiles = tagged.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }.map { $0.0 }

        // JPG の stem → ExifFields キャッシュ（XMP/RAW が同名 JPG の EXIF を参照する）
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
                dirName  = config.rawDirName
                category = .raw
                fields = resolveFields(url: url, stem: stem, cache: exifCache)
            } else {
                dirName  = config.xmpPairIsJpg ? config.jpgDirName : config.rawDirName
                category = .xmp
                fields   = resolveFields(url: url, stem: stem, cache: exifCache)
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
        return OrganizePlan(destRoot: destRoot, moves: moves, skipped: scan.skipped)
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
