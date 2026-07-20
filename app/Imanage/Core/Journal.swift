import Foundation

// MARK: - Journal
// journal.py の移植。CLI と同一の JSON 形式・同一のファイルパスを使用し、
// `imanage --undo` と相互運用できる。
// ポリシー: ファイル削除は絶対に FileManager.removeItem を使わず、
//           必ず FileManager.default.trashItem を使うこと。

// MARK: - UndoResult

struct UndoResult: Sendable {
    var success = 0
    var skipped = 0
    /// trash アクションの件数（ゴミ箱から手動復元が必要）
    var needManualRestore = 0
}

// MARK: - Journal

struct Journal: Sendable {

    struct Action: Codable, Sendable {
        var type: String   // "move" | "trash" | "sidecar_created" | "mkdir"
        var src: String?
        var dest: String?
        var path: String?
    }

    private(set) var actions: [Action] = []

    // MARK: - 記録

    mutating func recordMove(src: String, dest: String) {
        actions.append(Action(type: "move",
                              src: (src as NSString).standardizingPath,
                              dest: (dest as NSString).standardizingPath,
                              path: nil))
    }

    mutating func recordMkdir(path: String) {
        actions.append(Action(type: "mkdir",
                              src: nil,
                              dest: nil,
                              path: (path as NSString).standardizingPath))
    }

    // MARK: - 保存

    /// ~/.local/state/imanage/last_operation.json へアトミック書き込み。
    /// JSON: {"version": 1, "undone": false, "actions": [...]}
    func save() {
        do {
            let dir = journalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "version": 1,
                "undone": false,
                "actions": actions.map { actionToDict($0) },
            ]
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                 options: [.prettyPrinted, .sortedKeys])
            // Data.write(.atomic) 自体が tmp 書き込み + rename を行う
            try data.write(to: journalURL, options: .atomic)
        } catch {
            // ジャーナル書き込み失敗は主処理に影響させない
        }
    }

    // MARK: - 読み込み

    /// ジャーナルファイルを読み込む。存在しない / undone:true なら nil。
    static func loadFromDisk() -> Journal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        guard let data = try? Data(contentsOf: journalURL),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if obj["undone"] as? Bool == true { return nil }
        guard let rawActions = obj["actions"] as? [[String: Any]] else { return nil }

        let decoder = JSONDecoder()
        let actionsData = (try? JSONSerialization.data(withJSONObject: rawActions)) ?? Data()
        guard let decoded = try? decoder.decode([Action].self, from: actionsData) else {
            return nil
        }
        var j = Journal()
        j.actions = decoded
        return j
    }

    // MARK: - undone フラグ

    /// ジャーナルファイル上の undone フラグを true にする（二重 undo 防止）。
    static func markUndoneOnDisk() {
        guard FileManager.default.fileExists(atPath: journalURL.path),
              let data = try? Data(contentsOf: journalURL),
              var obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        obj["undone"] = true
        guard let newData = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? newData.write(to: journalURL, options: .atomic)
    }

    // MARK: - Undo 実行

    /// 操作を逆順に取り消す。journal.py execute_undo と同じロジック。
    /// - move: dest が無い→skip / src が既に有る→skip / それ以外は btime 保持で戻す
    /// - trash: 手動復元が必要な件数としてカウントのみ
    /// - sidecar_created: ファイルが有れば trashItem でゴミ箱へ
    /// - mkdir: ディレクトリが有れば trashItem でゴミ箱へ（失敗は無視）
    func executeUndo() -> UndoResult {
        var result = UndoResult()
        for action in actions.reversed() {
            switch action.type {
            case "move":
                guard let srcPath  = action.src,
                      let destPath = action.dest else { break }
                let destURL = URL(fileURLWithPath: destPath)
                let srcURL  = URL(fileURLWithPath: srcPath)
                // dest が存在しない → スキップ
                guard FileManager.default.fileExists(atPath: destPath) else {
                    result.skipped += 1
                    break
                }
                // src が既に存在する → スキップ
                guard !FileManager.default.fileExists(atPath: srcPath) else {
                    result.skipped += 1
                    break
                }
                // 親ディレクトリを作成
                let srcDir = srcURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: srcDir,
                                                         withIntermediateDirectories: true)
                do {
                    let moved = try BTimeUtils.safeMove(from: destURL, to: srcURL)
                    if moved {
                        result.success += 1
                    } else {
                        result.skipped += 1
                    }
                } catch {
                    result.skipped += 1
                }

            case "trash":
                // ゴミ箱に移動済みのファイルは手動復元が必要
                result.needManualRestore += 1

            case "sidecar_created":
                guard let p = action.path else { break }
                let url = URL(fileURLWithPath: p)
                if FileManager.default.fileExists(atPath: p) {
                    // ポリシー: removeItem 禁止。必ず trashItem を使う。
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        result.success += 1
                    } else {
                        result.skipped += 1
                    }
                } else {
                    result.skipped += 1
                }

            case "mkdir":
                guard let p = action.path else { break }
                let url = URL(fileURLWithPath: p)
                if FileManager.default.fileExists(atPath: p) {
                    // ポリシー: removeItem 禁止。必ず trashItem を使う。
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    // 失敗は無視（Python 版と同じ）
                }

            default:
                break
            }
        }
        return result
    }

    /// undo で書き戻す先のディレクトリ（move の src の親）を重複なく返す。
    /// サンドボックス下ではここへの書き込み権限が要るため、実行前に確認する。
    var undoTargetDirectories: [URL] {
        var seen = Set<String>()
        return actions.compactMap { action -> URL? in
            guard action.type == "move", let src = action.src else { return nil }
            let dir = URL(fileURLWithPath: src).deletingLastPathComponent()
            return seen.insert(dir.path).inserted ? dir : nil
        }
    }

    // MARK: - Private helpers

    private func actionToDict(_ a: Action) -> [String: Any] {
        var d: [String: Any] = ["type": a.type]
        if let v = a.src  { d["src"]  = v }
        if let v = a.dest { d["dest"] = v }
        if let v = a.path { d["path"] = v }
        return d
    }
}

// MARK: - ジャーナルファイルパス

/// ~/.local/state/imanage/last_operation.json
///
/// CLI 版 JOURNAL_PATH と同じ相対パスを使う。ただし App Sandbox 下では
/// homeDirectoryForCurrentUser がアプリコンテナ
/// (~/Library/Containers/com.itotsum.imanage/Data) を返すため、実体は
/// コンテナ内に置かれ、CLI の `imanage --undo` との相互運用はできない。
/// アプリ単体の undo（起動をまたぐものも含む）は従来どおり動作する。
private let journalURL: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent(".local/state/imanage/last_operation.json")
}()
