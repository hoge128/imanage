import Foundation
import AppKit
import os

// MARK: - SecurityScope
// App Sandbox 下で「ユーザーが明示的に選んだフォルダ」へのアクセス権を保持する。
//
// サンドボックスでは、ドロップや NSOpenPanel で得た URL のアクセス権はその場限りで、
// パス文字列を保存しても次回起動時には何の権限も持たない。そのため URL を
// app-scoped security-scoped bookmark に変換して UserDefaults に持ち、
// 起動時に解決し直してアクセスを開始する。
//
// アクセスはアプリの生存期間中ずっと開きっぱなしにする（フォルダ監視や undo が
// 任意のタイミングで走るため、begin/end のペアで囲える構造になっていない）。

@MainActor
final class SecurityScope {
    static let shared = SecurityScope()

    private static let defaultsKey = "securityScopedBookmarks"
    private static let log = Logger(subsystem: "com.itotsum.imanage", category: "SecurityScope")

    /// 標準化パス → ブックマーク
    private var bookmarks: [String: Data]
    /// startAccessingSecurityScopedResource() 済みの URL。
    /// stop する際は start したのと同一インスタンスを渡す必要があるため、
    /// パスだけでなく解決済み URL そのものを保持する。
    private var accessing: [String: URL] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bookmarks = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data]) ?? [:]
    }

    // MARK: - 起動時の復元

    /// 保存済みブックマークをすべて解決してアクセスを開始する。
    /// 解決に失敗しても削除はしない — 外付けドライブが未接続なだけの可能性があり、
    /// 接続後の resolve()（hasAccess / ensureAccess 経由）で復活できる余地を残す。
    func restoreAll() {
        // resolve() が bookmarks を書き換えるので、キーは先に取り出しておく
        for path in Array(bookmarks.keys) where !resolve(path) {
            Self.log.notice("bookmark を解決できませんでした（未接続ボリュームの可能性）: \(path, privacy: .public)")
        }
    }

    // MARK: - 記憶

    /// ユーザーが選んだ（＝この時点ではアクセス権がある）URL をブックマーク化して覚える。
    /// ドロップ由来の URL は権限が短命なので、受け取った直後に呼ぶこと。
    @discardableResult
    func remember(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        // 既に祖先ごと許可済みなら重複して覚えない
        if grantedAncestor(of: std) != nil { return true }
        do {
            bookmarks[std.path] = try std.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            persist()
            return resolve(std.path)
        } catch {
            // サンドボックス外（開発ビルド）では失敗しうるが、その場合は権限自体が不要
            Self.log.notice("bookmark を作成できません: \(std.path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        accessing.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
        bookmarks[path] = nil
        persist()
    }

    // MARK: - 問い合わせ

    /// url 自身か、その祖先にアクセス権を持っているか
    func hasAccess(to url: URL) -> Bool { grantedAncestor(of: url.standardizedFileURL) != nil }

    /// url への書き込みアクセスを確保する。権限が無ければ NSOpenPanel で許可を求める。
    /// ユーザーが拒否した場合は false。
    /// - Parameter message: パネル上部に出す説明文
    @discardableResult
    func ensureAccess(to url: URL, message: String) -> Bool {
        let std = url.standardizedFileURL
        if hasAccess(to: std) { return true }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = std
        panel.message = message
        panel.prompt = String(localized: "アクセスを許可")
        guard panel.runModal() == .OK, let picked = panel.url else { return false }

        remember(picked)
        // 別のフォルダを選ばれた場合、目的のフォルダの権限は得られていない
        return hasAccess(to: std)
    }

    // MARK: - Private

    /// path のブックマークを解決し、アクセスを開始する
    private func resolve(_ path: String) -> Bool {
        if accessing[path] != nil { return true }
        guard let data = bookmarks[path] else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        guard url.startAccessingSecurityScopedResource() else { return false }
        accessing[path] = url
        // フォルダが移動・改名されるとブックマークは stale になる。解決自体は成功して
        // いるので、この時点で作り直して次回以降に備える。
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil) {
            bookmarks[path] = fresh
        }
        return true
    }

    /// url 自身または祖先のうち、アクセス権を確保できているもの。
    /// 注意: deletingLastPathComponent() は "/" の親として "/.." を返し続けるため、
    /// パス比較でのループ終了判定は成立しない。"/" に到達したら明示的に打ち切る。
    private func grantedAncestor(of url: URL) -> String? {
        var candidate = url.standardizedFileURL
        while true {
            let path = candidate.path
            if accessing[path] != nil || resolve(path) { return path }
            if path == "/" || path.isEmpty { return nil }
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
    }

    private func persist() {
        defaults.set(bookmarks, forKey: Self.defaultsKey)
    }
}
