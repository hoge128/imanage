import SwiftUI

// MARK: - BeforeAfterView
// 状態に応じてパネル背景を 3 色で塗り分ける。
//
//   実行前:   移動元=白(active)  移動先=ややグレー(preview)
//   実行後:   移動元=グレー(done) 移動先=白(active)
//   Undo後:   移動元=白(active)  移動先=ややグレー(preview)  ← 実行前と同じ

// パネル背景の 3 段階をライト/ダークモード両対応のアダプティブカラーで定義
private func panelColor(light: Double, dark: Double) -> Color {
    Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: dark, alpha: 1)
            : NSColor(white: light, alpha: 1)
    })
}
/// 白（アクティブ・注目状態）
private let panelActive   = panelColor(light: 1.00, dark: 0.18)
/// ややグレー（プレビュー・まだ実行していない）。白に近い控えめなグレー。
private let panelPreview  = panelColor(light: 0.96, dark: 0.15)
/// グレー（無効感・実行済みで役目が終わった）
private let panelDisabled = panelColor(light: 0.86, dark: 0.10)

struct BeforeAfterView: View {
    @Environment(OrganizeStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    let plan: OrganizePlan
    let didExecute: Bool

    // 実行前後で展開ポリシーはそのまま維持する
    @State private var sourceExpansion = TreeExpansionModel(policy: .all)
    @State private var destExpansion = TreeExpansionModel(policy: .exceptLeaves)
    // 「入力を追加」ボックスへのドラッグ中ハイライト
    @State private var isAddTargeted = false

    // 移動元は複数入力をタブで切替える。選択中の入力ユニット。
    @State private var selectedUnitID: InputUnit.ID?

    // タブから対象セクションへスクロールするための要求 ID（更新でジャンプ）
    @State private var scrollTargetID: InputUnit.ID?

    // 選択中の入力ユニット（未選択・削除済みなら先頭にフォールバック）
    private var selectedUnit: InputUnit? {
        if let id = selectedUnitID,
           let unit = store.inputUnits.first(where: { $0.id == id }) {
            return unit
        }
        return store.inputUnits.first
    }

    // 実行後は移動元を無効化色、移動先をアクティブ色に切り替える
    private var sourcePanelFill: Color { didExecute ? panelDisabled : panelActive }
    private var destPanelFill: Color   { didExecute ? panelActive   : panelPreview }

    private var destForest: [FolderNode] { FolderTreeBuilder.buildDestination(plan) }
    private var sourceTotal: Int { store.inputUnits.reduce(0) { $0 + $1.targetCount } }
    /// 対象外（移動されない）の合計件数
    private var sourceSkipped: Int { store.inputUnits.reduce(0) { $0 + $1.skippedCount } }
    /// 全入力ユニットの対象外ファイル一覧
    private var allSkipped: [SkippedFile] { store.inputUnits.flatMap { $0.scan.skipped } }

    /// 対象外一覧ポップオーバーの表示状態
    @State private var showSkippedList = false
    private var destTotal: Int { plan.moves.count }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sourcePanel

            Image(systemName: "arrow.right")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 60)

            destPanel
        }
        .padding(12)
    }

    // MARK: - 適用前パネル（N 入力ユニット・実ディスク構造 → 白背景）

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            panelHeader(String(localized: "移動元"), systemImage: "tray.full",
                        count: sourceTotal, skipped: sourceSkipped)
            expandButtons(sourceExpansion)

            // 複数入力はルートディレクトリ名のタブで一覧・削除・ジャンプ。
            if store.inputUnits.count > 1 {
                sourceTabBar
            }

            // 全入力ユニットのツリーを縦に積み、スクロールで全部たどれるようにする。
            // タブのタップで該当セクションへジャンプ（scrollTargetID → scrollTo）。
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.inputUnits) { unit in
                            VStack(alignment: .leading, spacing: 6) {
                                sourcePathRow(unit)
                                    .frame(minHeight: Self.pathRowMinHeight)
                                unitTree(unit)
                            }
                            .id(unit.id)
                        }
                        addControl
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    // 実行後の移動元は「役目を終えた履歴」。彩度を落とし（アーカイブ感）+
                    // 軽くフェードして無効感を出す。背景は solid のまま。
                    .saturation(didExecute ? 0 : 1)
                    .opacity(didExecute ? 0.55 : 1)
                }
                .onChange(of: scrollTargetID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(sourcePanelFill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .animation(.easeInOut(duration: 0.25), value: didExecute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 入力が増えたら新しいタブを選択し、そのセクションへスクロール。
        .onChange(of: store.inputUnits.count) { old, new in
            if new > old, let last = store.inputUnits.last?.id {
                selectedUnitID = last
                scrollTargetID = last
            }
        }
    }

    // 移動元の入力タブ（ルートディレクトリ名）。追加フォルダが増えても
    // 横スクロールで全て辿れるよう、スクロールバーを常時表示する。
    private var sourceTabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(store.inputUnits) { unit in
                    sourceTab(unit)
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.visible)
    }

    private func sourceTab(_ unit: InputUnit) -> some View {
        let isSelected = unit.id == (selectedUnit?.id)
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.caption2)
            Text(unit.rootURL.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            if !didExecute {
                Button {
                    store.removeInput(unit.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(String(localized: "この入力を削除"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6)
                                         : Color.secondary.opacity(0.3),
                              lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedUnitID = unit.id
            scrollTargetID = unit.id
        }
        .help(unit.rootURL.path)
    }

    // 移動先パネルのパス行と縦位置を揃えるための行高（ヘッダ位置のパス表示に適用）。
    private static let pathRowMinHeight: CGFloat = 24

    // 移動元ルートパス行。単一入力時にヘッダ位置（スクロール外）へ出す。
    private func sourcePathRow(_ unit: InputUnit) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text(unit.rootURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if !didExecute {
                Button {
                    store.removeInput(unit.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "この入力を削除"))
            }
        }
    }

    // 選択中入力のツリー本体（ルートパスはヘッダ位置の sourcePathRow に集約済み）。
    private func unitTree(_ unit: InputUnit) -> some View {
        FolderNodeView(
            node: FolderTreeBuilder.buildSourceTree(scan: unit.scan, rootURL: unit.rootURL),
            depth: 0, expansion: sourceExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    // 「入力を追加」ボックス。移動元の幅いっぱいの点線枠。
    // クリックで Finder のフォルダ選択、ドロップはこのボックス範囲だけが反応する。
    @ViewBuilder
    private var addControl: some View {
        if !didExecute {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(isAddTargeted ? Color.accentColor : .secondary)
                Text("ファイル / フォルダを追加")
                    .font(.callout)
                    .foregroundStyle(isAddTargeted ? Color.accentColor : .secondary)
                Text("クリックで選択（複数可）、またはここにドロップ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isAddTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isAddTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 2, dash: [8])))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                let urls = Self.pickInputs()
                if !urls.isEmpty { store.handleDrop(urls) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.handleDrop(urls)
                return true
            } isTargeted: { isAddTargeted = $0 }
        }
    }

    /// 入力追加用の Finder 選択。ファイル・フォルダを複数選択できる。
    private static func pickInputs() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    // MARK: - 適用後パネル（プレビュー/振り分け後の構造 → グレー背景）

    private var destPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            panelHeader(
                didExecute ? String(localized: "移動先（完了）") : String(localized: "移動先"),
                systemImage: didExecute ? "checkmark.circle" : "folder.badge.gearshape",
                count: destTotal)
            expandButtons(destExpansion)

            DestinationMenu(
                settings: settings,
                destRootPath: plan.destRoot.path,
                editable: !didExecute)
                .frame(minHeight: Self.pathRowMinHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(destForest) {
                        FolderNodeView(node: $0, depth: 0, expansion: destExpansion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(destPanelFill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .animation(.easeInOut(duration: 0.25), value: didExecute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 共通パーツ

    private func panelHeader(_ title: String, systemImage: String,
                             count: Int, skipped: Int = 0) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(String(format: String(localized: "合計 %d 件"), count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if skipped > 0 {
                // クリックで対象外ファイルの一覧を表示
                Button {
                    showSkippedList = true
                } label: {
                    HStack(spacing: 3) {
                        Text(String(format: String(localized: "対象外 %d 件"), skipped))
                            .font(.caption.monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(String(localized: "振り分け対象外のファイル一覧を表示（移動されず、その場に残ります）"))
                .popover(isPresented: $showSkippedList, arrowEdge: .bottom) {
                    skippedListView
                }
            }
            Spacer()
        }
    }

    // MARK: - 対象外ファイル一覧

    private var skippedListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(String(localized: "対象外のファイル"), systemImage: "nosign")
                    .font(.headline)
                Text(String(format: String(localized: "%d 件"), allSkipped.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("これらは振り分け対象外のため移動されず、元の場所に残ります。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allSkipped, id: \.url) { item in
                        skippedRow(item)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(width: 460)
    }

    private func skippedRow(_ item: SkippedFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.callout.monospaced())
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(item.reason == .noExif
                 ? String(localized: "EXIF なし") : String(localized: "非対応の種類"))
                .font(.caption2)
                .foregroundStyle(.orange)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Finder で表示"))
        }
        .padding(.vertical, 3)
    }

    private func expandButtons(_ model: TreeExpansionModel) -> some View {
        HStack(spacing: 6) {
            Button(String(localized: "すべて閉じる")) { model.apply(.none) }
            Button(String(localized: "すべて開く（最下層以外）")) { model.apply(.exceptLeaves) }
            Button(String(localized: "すべて開く")) { model.apply(.all) }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
