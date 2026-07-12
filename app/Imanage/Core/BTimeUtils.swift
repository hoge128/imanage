import Foundation
import Darwin

// MARK: - BTimeUtils
// btime_utils.py の移植。
// ポリシー: imanage はいかなる操作においてもファイルの btime を変更してはならない。
// すべてのファイル移動はこのモジュール経由で行い、移動後に btime を復元する。

enum BTimeUtils {

    // MARK: - btime 取得

    /// stat(2) 経由で st_birthtime を timespec として返す。
    /// btime が取得できない場合は nil。
    static func getBirthTime(atPath path: String) -> timespec? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_birthtimespec
    }

    // MARK: - btime 設定

    /// setattrlist(2) で birthtime を設定する（macOS 専用）。
    /// 失敗時は OSError をスロー。
    static func setBirthTime(atPath path: String, to time: timespec) throws {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr  = attrgroup_t(ATTR_CMN_CRTIME)

        // timespec (tv_sec: Int64 + tv_nsec: Int64) を連続メモリとして渡す
        var ts = time
        let ret = withUnsafeMutableBytes(of: &ts) { buf -> Int32 in
            setattrlist(path, &attrs, buf.baseAddress!, buf.count, 0)
        }
        if ret != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
    }

    // MARK: - btime 保持ファイル移動

    /// btime を保持したまま from を to へ移動する。
    /// to はフルパス（ファイル名込み）。親ディレクトリは存在する前提。
    /// to に同名ファイルが存在する場合は何もせず false を返す。
    /// 失敗時は throw する。
    @discardableResult
    static func safeMove(from src: URL, to dest: URL) throws -> Bool {
        // 移動先に同名ファイルが存在する場合はスキップ
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            return false
        }

        let btime = getBirthTime(atPath: src.path)

        try FileManager.default.moveItem(at: src, to: dest)

        // 移動後に btime を復元（失敗は silent）
        if let bt = btime {
            try? setBirthTime(atPath: dest.path, to: bt)
        }
        return true
    }
}
