import Foundation

// MARK: - FileOrganizer
// core.py の date_organize() (行 1027-1052) 移動実行部の移植。
// ポリシー: ファイル削除は絶対に FileManager.removeItem を使わず、
//           必ず BTimeUtils.safeMove または trashItem を使うこと。

struct FileOrganizer: Sendable {
    let config: ImanageConfig

    // MARK: - 実行

    /// plan を実行する。進捗は progress(完了数, 総数) で通知。
    /// 戻り値: (結果, ジャーナル)。ジャーナルには mkdir / move を記録済み。
    func execute(plan: OrganizePlan,
                 progress: @Sendable (Int, Int) -> Void) -> (OrganizeResult, Journal) {
        var result  = OrganizeResult()
        var journal = Journal()
        let total   = plan.moves.count

        for (index, move) in plan.moves.enumerated() {
            let destDir = move.destination.deletingLastPathComponent()

            // 新規作成するディレクトリを destRoot から親→子の順ですべて記録する。
            // undo は逆順（子→親）に処理するため空になった階層が順にゴミ箱へ移動できる。
            // （CLI 版は leaf のみ記録するが、ジャーナル形式は互換）
            let newDirs = Self.uncreatedAncestors(of: destDir, upTo: plan.destRoot)
            do {
                try FileManager.default.createDirectory(
                    at: destDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                for dir in newDirs {
                    journal.recordMkdir(path: dir.path)
                }
            } catch {
                result.errors.append(String(localized: "ディレクトリ作成失敗: \(destDir.path): \(error.localizedDescription)"))
                progress(index + 1, total)
                continue
            }

            // btime 保持で移動
            do {
                let moved = try BTimeUtils.safeMove(from: move.source, to: move.destination)
                if moved {
                    journal.recordMove(src: move.source.path, dest: move.destination.path)
                    result.movedCount += 1
                } else {
                    // 移動先に同名ファイルが存在 → スキップ
                    result.skippedExisting.append(move.source)
                }
            } catch {
                result.errors.append(String(localized: "移動失敗: \(move.source.path): \(error.localizedDescription)"))
            }

            progress(index + 1, total)
        }

        return (result, journal)
    }

    /// destDir から root まで遡り、まだ存在しないディレクトリを親→子の順で返す。
    /// root の外側へは遡らない。
    private static func uncreatedAncestors(of destDir: URL, upTo root: URL) -> [URL] {
        var missing: [URL] = []
        var current = destDir.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: current.path) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            // root に到達、またはこれ以上遡れない場合は終了
            if current.path == rootPath || parent.path == current.path { break }
            current = parent
        }
        return missing.reversed()
    }
}
