import SwiftUI
import UniformTypeIdentifiers

// MARK: - HierarchyBarView
// メインプレビュー画面の上部に置く振り分け階層エディタ。
// 左「適用」ボックス: 実際に使う階層（順序あり）。ドラッグで並べ替え/除外。
// 右「候補」ボックス: 未使用フィールド。ドラッグまたは + で追加。
//
// ドラッグ中は DropDelegate で「入りそうな位置」をライブで空ける（make-way）アニメーション。

struct HierarchyBarView: View {
    @Bindable var settings: SettingsStore

    /// ドラッグ中のフィールドキー（適用/候補どちらの由来でも入る）
    @State private var dragging: String?
    @State private var appliedTargeted = false
    @State private var poolTargeted = false

    /// dwell（一定時間ホバー）を経て表示が確定したヘルプ対象のフィールドキー
    @State private var shownHelpKey: String?

    // プリセットメニューの状態
    @State private var showPresetMenu = false
    @State private var editingPresetID: UUID?
    @State private var editingName = ""
    @State private var isSaving = false
    @State private var savingName = ""

    private var selectedFields: [HierarchyField] {
        settings.hierarchy.compactMap { HierarchyField.from(key: $0) }
    }
    private var availableFields: [HierarchyField] {
        HierarchyField.allCases.filter { !settings.hierarchy.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            appliedBox
            candidatesBox
        }
        .padding(12)
        // 説明カード: 描画専用オーバーレイ（ヒットテスト無効）としてバーの上に重ねる。
        // .popover と違いウィンドウ/フォーカスに一切関与しないため、ドラッグを妨げない。
        .overlayPreferenceValue(HelpAnchorKey.self) { anchors in
            helpOverlay(anchors)
        }
    }

    // MARK: - ヘルプオーバーレイ

    @ViewBuilder
    private func helpOverlay(_ anchors: [HelpAnchor]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // dwell 管理: ホバー対象が変わるたびに task(id:) が再スタートし、
                // 450ms 留まったときだけ表示を確定する。外れたら即クリア。
                Color.clear
                    .task(id: anchors.first?.key) {
                        guard let key = anchors.first?.key else {
                            shownHelpKey = nil
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(450))
                        if !Task.isCancelled { shownHelpKey = key }
                    }

                if let a = anchors.first,
                   settings.chipHelpEnabled, dragging == nil,
                   shownHelpKey == a.key,
                   let field = HierarchyField.from(key: a.key) {
                    let rect = proxy[a.anchor]
                    let cardWidth: CGFloat = 240
                    let x = min(max(rect.midX - cardWidth / 2, 8),
                                max(8, proxy.size.width - cardWidth - 8))
                    FieldHelpCard(field: field)
                        .offset(x: x, y: rect.maxY + 8)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: shownHelpKey)
        }
        .allowsHitTesting(false)
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
            HStack(spacing: 8) {
                Label(String(localized: "適用する階層"), systemImage: "folder.badge.gearshape")
                    .font(.subheadline)
                presetTrigger
                Spacer()
            }
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
        // ヘルプはホバー位置の報告のみ（プレゼンテーションなし）。カードは
        // バーのルートに描画専用オーバーレイとして出すため、ドラッグに干渉しない。
        .modifier(HelpAnchorModifier(fieldKey: field.key))
        .onDrag {
            dragging = field.key
            return NSItemProvider(object: field.key as NSString)
        }
        .onDrop(of: [.text], delegate: ChipReorderDelegate(
            targetKey: field.key, hierarchy: $settings.hierarchy, dragging: $dragging))
    }

    // MARK: - プリセットメニュー

    private var presetTrigger: some View {
        Button {
            showPresetMenu.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "star")
                Text("プリセット")
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .popover(isPresented: $showPresetMenu, arrowEdge: .bottom) {
            presetMenu
        }
    }

    private var presetMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuHeader(String(localized: "プリセットを適用"))

            ForEach(settings.allPresets) { preset in
                presetRow(preset)
            }

            Divider().padding(.vertical, 4)

            if isSaving {
                HStack(spacing: 6) {
                    TextField("プリセット名", text: $savingName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitSave() }
                    Button(String(localized: "保存")) { commitSave() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(String(localized: "取消")) { isSaving = false }
                        .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            } else {
                Button {
                    savingName = settings.suggestedPresetName()
                    isSaving = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").frame(width: 16)
                        Text("現在の並びをプリセットに保存…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(settings.hierarchy.isEmpty)
            }
        }
        .padding(6)
        .frame(width: 340)
    }

    private func presetRow(_ preset: HierarchyPreset) -> some View {
        let isDef = settings.isDefaultPreset(preset.id)
        let isBuiltin = settings.isBuiltinPreset(preset.id)
        let seq = preset.fields
            .compactMap { HierarchyField.from(key: $0)?.displayName }
            .joined(separator: " › ")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if editingPresetID == preset.id {
                    TextField("名前", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit {
                            settings.renamePreset(preset.id, to: editingName)
                            editingPresetID = nil
                        }
                } else {
                    HStack(spacing: 6) {
                        Text(preset.name).fontWeight(.medium)
                        if isBuiltin {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if isDef {
                            Text("既定").font(.caption2.bold()).foregroundStyle(Color.accentColor)
                        }
                    }
                    // 組み込み「規定」は改名不可
                    .onTapGesture(count: 2) {
                        guard !isBuiltin else { return }
                        editingName = preset.name
                        editingPresetID = preset.id
                    }
                }
                Text(seq.isEmpty ? String(localized: "（階層なし）") : seq)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button {
                settings.toggleDefaultPreset(preset.id)
            } label: {
                Image(systemName: isDef ? "pin.fill" : "pin")
                    .foregroundStyle(isDef ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isDef ? String(localized: "既定を解除") : String(localized: "既定のプリセットにする"))

            // 組み込み「規定」は削除不可（ボタン自体を出さない）
            if !isBuiltin {
                Button {
                    settings.removePreset(preset.id)
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "プリセットを削除"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingPresetID != preset.id else { return }
            settings.applyPreset(preset)
            showPresetMenu = false
        }
    }

    private func menuHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func commitSave() {
        settings.savePreset(name: savingName, fields: settings.hierarchy)
        isSaving = false
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
            HStack(spacing: 8) {
                Label(String(localized: "候補フィールド"), systemImage: "square.grid.2x2")
                    .font(.subheadline)
                Toggle(String(localized: "ヘルプ"), isOn: $settings.chipHelpEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                Spacer()
            }
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
        // ヘルプはホバー位置の報告のみ（appliedChip と同じ非干渉方式）
        .modifier(HelpAnchorModifier(fieldKey: field.key))
        .onDrag {
            dragging = field.key
            return NSItemProvider(object: field.key as NSString)
        }
    }

    // MARK: - 編集ロジック

    /// key を before の直前へ挿入。before が nil なら末尾。既存なら並べ替え。
    private func insert(_ key: String, before targetKey: String?) {
        guard HierarchyField.from(key: key) != nil else { return }
        var arr = settings.hierarchy
        arr.removeAll { $0 == key }
        if let t = targetKey, let i = arr.firstIndex(of: t) {
            arr.insert(key, at: i)
        } else {
            arr.append(key)
        }
        settings.hierarchy = arr
    }

    private func remove(_ key: String) {
        // 空階層も許可する（出力先直下にそのまま振り分ける）
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            settings.hierarchy = settings.hierarchy.filter { $0 != key }
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
        guard let key = dragging, settings.hierarchy.contains(key) else { dragging = nil; return false }
        dragging = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            settings.hierarchy.removeAll { $0 == key }
        }
        return true
    }
}

// MARK: - HelpAnchor / HelpAnchorModifier
// チップの「ホバー中の位置」を PreferenceKey でバーのルートへ報告する。
// プレゼンテーション（popover 等）を一切使わないため、ドラッグに干渉しない。

private struct HelpAnchor: Equatable {
    let key: String
    let anchor: Anchor<CGRect>
    static func == (l: Self, r: Self) -> Bool { l.key == r.key }
}

private struct HelpAnchorKey: PreferenceKey {
    static let defaultValue: [HelpAnchor] = []
    static func reduce(value: inout [HelpAnchor], nextValue: () -> [HelpAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct HelpAnchorModifier: ViewModifier {
    let fieldKey: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .anchorPreference(key: HelpAnchorKey.self, value: .bounds) {
                hovering ? [HelpAnchor(key: fieldKey, anchor: $0)] : []
            }
    }
}

private struct FieldHelpCard: View {
    let field: HierarchyField

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(field.displayName, systemImage: field.systemImage)
                .font(.headline)
            Text(field.helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                helpRow(label: field.sourceInfo.label, value: field.sourceInfo.value)
                helpRow(label: field.exampleIsValueSet
                            ? String(localized: "値の候補") : String(localized: "フォルダ例"),
                        value: field.example)
            }
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        // オーバーレイ表示のため背景は自前で持つ（Liquid Glass）
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func helpRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
        }
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
