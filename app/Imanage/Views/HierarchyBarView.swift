import SwiftUI
import UniformTypeIdentifiers

// MARK: - HierarchyBarView
// メインプレビュー画面の上部に置く振り分け階層エディタ。
// 左「適用」ボックス: 実際に使う階層（順序あり）。ドラッグで並べ替え/除外。
// 右「候補」ボックス: 未使用フィールド。ドラッグまたは + で追加。
//
// ドラッグ中は DropDelegate で「入りそうな位置」をライブで空ける（make-way）アニメーション。

struct HierarchyBarView: View {
    @Binding var hierarchy: [String]

    /// ドラッグ中のフィールドキー（適用/候補どちらの由来でも入る）
    @State private var dragging: String?
    @State private var appliedTargeted = false
    @State private var poolTargeted = false

    private var selectedFields: [HierarchyField] {
        hierarchy.compactMap { HierarchyField.from(key: $0) }
    }
    private var availableFields: [HierarchyField] {
        HierarchyField.allCases.filter { !hierarchy.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            appliedBox
            candidatesBox
        }
        .padding(12)
    }

    // MARK: - 適用ボックス

    private var appliedBox: some View {
        GroupBox {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(selectedFields.enumerated()), id: \.element.id) { item in
                        appliedChip(item.element, position: item.offset + 1)
                    }
                    if selectedFields.isEmpty {
                        Text("ここにフィールドをドロップ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(appliedTargeted ? Color.accentColor.opacity(0.12) : .clear))
            // 空きスペースへのドロップ = 末尾へ
            .onDrop(of: [.text], isTargeted: $appliedTargeted) { _ in
                appendDragging()
            }
        } label: {
            Label(String(localized: "適用する階層"), systemImage: "folder.badge.gearshape")
                .font(.subheadline)
        }
    }

    private func appliedChip(_ field: HierarchyField, position: Int) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(position)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.secondary)
            Image(systemName: field.systemImage)
            Text(field.displayName)
                .font(.callout)
            Button {
                remove(field.key)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4)))
        .opacity(dragging == field.key ? 0.35 : 1)
        .onDrag {
            dragging = field.key
            return NSItemProvider(object: field.key as NSString)
        }
        .onDrop(of: [.text], delegate: ChipReorderDelegate(
            targetKey: field.key, hierarchy: $hierarchy, dragging: $dragging))
    }

    // MARK: - 候補ボックス

    private var candidatesBox: some View {
        GroupBox {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(availableFields) { field in
                        candidateChip(field)
                    }
                    if availableFields.isEmpty {
                        Text("すべて使用中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(poolTargeted ? Color.accentColor.opacity(0.12) : .clear))
            // 適用中チップをここへドロップ = 除外
            .onDrop(of: [.text], isTargeted: $poolTargeted) { _ in
                removeDragging()
            }
        } label: {
            Label(String(localized: "候補フィールド"), systemImage: "square.grid.2x2")
                .font(.subheadline)
        }
    }

    private func candidateChip(_ field: HierarchyField) -> some View {
        HStack(spacing: 4) {
            Image(systemName: field.systemImage)
                .foregroundStyle(.tint)
            Text(field.displayName)
                .font(.callout)
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    insert(field.key, before: nil)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .opacity(dragging == field.key ? 0.35 : 1)
        .onDrag {
            dragging = field.key
            return NSItemProvider(object: field.key as NSString)
        }
    }

    // MARK: - 編集ロジック

    /// key を before の直前へ挿入。before が nil なら末尾。既存なら並べ替え。
    private func insert(_ key: String, before targetKey: String?) {
        guard HierarchyField.from(key: key) != nil else { return }
        var arr = hierarchy
        arr.removeAll { $0 == key }
        if let t = targetKey, let i = arr.firstIndex(of: t) {
            arr.insert(key, at: i)
        } else {
            arr.append(key)
        }
        hierarchy = arr
    }

    private func remove(_ key: String) {
        // 空階層も許可する（出力先直下にそのまま振り分ける）
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            hierarchy = hierarchy.filter { $0 != key }
        }
    }

    private func appendDragging() -> Bool {
        guard let key = dragging, HierarchyField.from(key: key) != nil else { return false }
        dragging = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            insert(key, before: nil)
        }
        return true
    }

    private func removeDragging() -> Bool {
        guard let key = dragging, hierarchy.contains(key) else { dragging = nil; return false }
        dragging = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            hierarchy.removeAll { $0 == key }
        }
        return true
    }
}

// MARK: - ChipReorderDelegate
// ドラッグ中のチップが各チップに重なった瞬間にライブ並べ替えし、
// 「入りそうな位置」をリアルタイムで空ける（make-way）アニメーションを実現する。

private struct ChipReorderDelegate: DropDelegate {
    let targetKey: String
    @Binding var hierarchy: [String]
    @Binding var dragging: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != targetKey,
              let to = hierarchy.firstIndex(of: targetKey) else { return }

        if let from = hierarchy.firstIndex(of: dragging) {
            // 適用内のチップ: ホバー先へ即移動（場所を空ける）
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                hierarchy.move(fromOffsets: IndexSet(integer: from),
                               toOffset: to > from ? to + 1 : to)
            }
        } else if HierarchyField.from(key: dragging) != nil {
            // 候補からのチップ: ホバー位置にライブ挿入（同じ make-way アニメーション）。
            // ドラッグ画像はスナップショットなので元チップが消えてもドラッグは継続する。
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                hierarchy.insert(dragging, at: to)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        // ホバーせずチップ上に直接ドロップされた候補のフォールバック挿入
        if let key = dragging,
           HierarchyField.from(key: key) != nil,
           !hierarchy.contains(key),
           let to = hierarchy.firstIndex(of: targetKey) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                hierarchy.insert(key, at: to)
            }
        }
        return true
    }
}
