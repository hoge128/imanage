import SwiftUI

// MARK: - FolderNode
// Before/After 表示用のフォルダツリーモデル。
// directCount は「第一階層のみ」の件数（直下のサブフォルダ + 直下のファイル）。

struct FolderNode: Identifiable {
    let id: String
    let name: String
    var subfolders: [FolderNode]
    var files: [FileLeaf]

    /// 直下にファイルを持つフォルダ（= 末端カテゴリフォルダ）
    var containsFiles: Bool { !files.isEmpty }

    /// 第一階層のみの件数（直下の子の数）
    var directCount: Int { subfolders.count + files.count }
}

struct FileLeaf: Identifiable {
    let id: String
    let name: String
    let category: FileCategory?
    /// 振り分け対象外の理由（nil = 対象）
    var skipReason: SkipReason? = nil
}

// MARK: - ツリー構築

enum FolderTreeBuilder {

    /// 変更後（To-be）: plan の moves から relativeDir を辿ってツリーを組む
    static func buildDestination(_ plan: OrganizePlan) -> [FolderNode] {
        let root = MNode(name: "")
        var hasFlatFiles = false  // 空階層 → destRoot 直下に置くファイルがある
        for move in plan.moves {
            let components = move.relativeDir.split(separator: "/").map(String.init)
            if components.isEmpty { hasFlatFiles = true }
            var node = root
            for c in components {
                node = node.child(c)
            }
            node.files.append(FileLeaf(
                id: move.id.uuidString,
                name: move.source.lastPathComponent,
                category: move.category))
        }
        // 空階層: destRoot 直下にファイルが並ぶので destRoot を 1 ノードとして表示する
        if hasFlatFiles {
            let converted = root.toNode(path: plan.destRoot.path)
            let name = plan.destRoot.lastPathComponent.isEmpty ? "/" : plan.destRoot.lastPathComponent
            return [FolderNode(id: plan.destRoot.path, name: name,
                               subfolders: converted.subfolders, files: converted.files)]
        }
        return root.toForest(path: "")
    }

    /// 入力ユニットの「現在」ツリー。rootURL（ドラッグしたフォルダ／ファイルの親）を
    /// ルートとし、その配下の実ディスク構造をそのまま表示する。
    static func buildSourceTree(scan: ScanResult, rootURL: URL) -> FolderNode {
        var entries: [(url: URL, category: FileCategory?, skipReason: SkipReason?)] =
            scan.scanned.map { ($0.source.standardizedFileURL, $0.category, nil) }
        entries += scan.skipped.map { ($0.url.standardizedFileURL, nil, $0.reason) }

        let rootComps = Array(rootURL.standardizedFileURL.pathComponents)
        let rootName = rootURL.lastPathComponent.isEmpty ? "/" : rootURL.lastPathComponent
        let root = MNode(name: rootName)
        for entry in entries {
            let parentComps = Array(entry.url.deletingLastPathComponent().pathComponents)
            let rel = parentComps.count >= rootComps.count
                ? Array(parentComps.dropFirst(rootComps.count)) : []
            var node = root
            for c in rel { node = node.child(c) }
            node.files.append(FileLeaf(
                id: entry.url.path, name: entry.url.lastPathComponent,
                category: entry.category, skipReason: entry.skipReason))
        }
        return root.toNode(path: rootURL.path)
    }

    // 構築用の可変ノード
    private final class MNode {
        let name: String
        var subdirs: [String: MNode] = [:]
        var files: [FileLeaf] = []
        init(name: String) { self.name = name }

        func child(_ key: String) -> MNode {
            if let n = subdirs[key] { return n }
            let n = MNode(name: key)
            subdirs[key] = n
            return n
        }

        func toForest(path: String) -> [FolderNode] {
            subdirs.keys.sorted().map { key in
                subdirs[key]!.toNode(path: path + "/" + key)
            }
        }

        func toNode(path: String) -> FolderNode {
            FolderNode(
                id: path,
                name: name,
                subfolders: toForest(path: path),
                files: files.sorted { $0.name < $1.name })
        }
    }
}

// MARK: - 展開ポリシーと状態モデル

enum ExpandPolicy {
    case all          // すべて展開
    case exceptLeaves // 最下層（ファイルを含むフォルダ）以外を展開
    case none         // すべて閉じる
}

/// ツリーの展開状態を一元管理する。個別の開閉は overrides に記録し、
/// ポリシー切替（3 ボタン）で overrides をリセットする。
@MainActor
@Observable
final class TreeExpansionModel {
    private var overrides: [String: Bool] = [:]
    var policy: ExpandPolicy

    init(policy: ExpandPolicy) { self.policy = policy }

    func isExpanded(_ node: FolderNode) -> Bool {
        if let v = overrides[node.id] { return v }
        switch policy {
        case .all:          return true
        case .exceptLeaves: return !node.containsFiles
        case .none:         return false
        }
    }

    func toggle(_ node: FolderNode) {
        overrides[node.id] = !isExpanded(node)
    }

    func apply(_ p: ExpandPolicy) {
        policy = p
        overrides.removeAll()
    }
}

// MARK: - FolderNodeView（再帰）
// 深さに応じた明示的インデントで階層構造を表示する。
// 子（サブフォルダ or ファイル）を持つフォルダはすべて開閉可能。

private let indentStep: CGFloat = 16
/// シェブロン（幅 12）の中央。縦ガイド線をこの x に揃える。
private let chevronCenter: CGFloat = 6

struct FolderNodeView: View {
    let node: FolderNode
    var depth: Int = 0
    let expansion: TreeExpansionModel

    private var hasChildren: Bool { !node.subfolders.isEmpty || !node.files.isEmpty }
    private var isExpanded: Bool { expansion.isExpanded(node) }

    var body: some View {
        // 縦のガイド線を連続させるため行間は 0
        VStack(alignment: .leading, spacing: 0) {
            folderRow

            if isExpanded {
                ForEach(node.subfolders) { sub in
                    FolderNodeView(node: sub, depth: depth + 1, expansion: expansion)
                }
                ForEach(node.files) { leaf in
                    fileRow(leaf)
                }
            }
        }
    }

    /// 各インデント階層に通しの縦ガイド線を depth 本ぶん描く（VSCode 風）。
    /// 線はその列に対応する親フォルダのシェブロン（下矢印）中央の x に揃える。
    @ViewBuilder
    private func rails(_ count: Int) -> some View {
        ForEach(Array(0..<max(count, 0)), id: \.self) { _ in
            ZStack(alignment: .leading) {
                Color.clear.frame(width: indentStep)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1)
                    .padding(.leading, chevronCenter)
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: 0) {
            rails(depth)
            HStack(spacing: 4) {
                // 子を持つフォルダには開閉シェブロンを出す
                if hasChildren {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: node.containsFiles ? "folder.fill" : "folder")
                    .foregroundStyle(.tint)
                Text(node.name)
                    .font(.callout.monospaced())
                Spacer()
                Text(String(format: String(localized: "%d 件"), node.directCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if hasChildren { expansion.toggle(node) }
        }
    }

    private func fileRow(_ leaf: FileLeaf) -> some View {
        HStack(spacing: 0) {
            rails(depth + 1)
            HStack(spacing: 4) {
                Image(systemName: icon(for: leaf.category))
                    .foregroundStyle(leaf.skipReason != nil
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                Text(leaf.name)
                    .font(.callout.monospaced())
                    .foregroundStyle(leaf.skipReason != nil
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                if let reason = leaf.skipReason {
                    skipBadge(reason)
                }
                Spacer()
            }
            .padding(.vertical, 3)
        }
    }

    /// 対象外バッジ。移動されずその場に残ることを明示する。
    private func skipBadge(_ reason: SkipReason) -> some View {
        Text(reason == .noExif
             ? String(localized: "対象外 (EXIFなし)") : String(localized: "対象外"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
            .help(String(localized: "振り分け対象外のため移動されません（その場に残ります）"))
    }

    private func icon(for category: FileCategory?) -> String {
        switch category {
        case .jpg: "photo"
        case .raw: "camera.aperture"
        case .retouch: "paintbrush"
        case .xmp: "doc.badge.gearshape"
        case nil: "doc"
        }
    }
}
