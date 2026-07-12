import SwiftUI

/// 画面下部の操作バー: 実行 / クリア / Undo / 進捗・結果表示
struct ActionBarView: View {
    @Environment(OrganizeStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            if store.isExecuting {
                ProgressView(value: Double(store.progressDone),
                             total: Double(max(store.progressTotal, 1)))
                    .frame(maxWidth: 200)
                Text(verbatim: "\(store.progressDone) / \(store.progressTotal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let message = store.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(store.didExecute ? .green : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 標準ボタンスタイルを使う。macOS 26 ではツールバー等の適切な場所で
            // システムが自動的に新デザインを適用するため、手動の glass 化はしない。
            // 完了状態: 元に戻す（強調）+ 新規
            if store.didExecute {
                Button {
                    store.reset()
                } label: {
                    Label(String(localized: "新規"), systemImage: "plus")
                }
                .disabled(store.isExecuting)

                Button {
                    store.undo()
                } label: {
                    Label(String(localized: "元に戻す"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canUndo || store.isExecuting)
                .help(String(localized: "この振り分けを取り消します（CLI の imanage --undo と互換）"))
            } else {
                // プレビュー / 初期状態: 元に戻す（前回の操作）
                Button {
                    store.undo()
                } label: {
                    Label(String(localized: "元に戻す"), systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo || store.isExecuting)
                .help(String(localized: "直前の振り分け操作を取り消します（CLI の imanage --undo と互換）"))

                if store.plan != nil {
                    Button(String(localized: "クリア")) {
                        store.reset()
                    }
                    .disabled(store.isExecuting)

                    Button {
                        store.execute()
                    } label: {
                        Label(String(localized: "振り分けを実行"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isExecuting || store.plan?.isEmpty != false)
                }
            }
        }
        .padding(12)
        .background(.bar)
    }
}
