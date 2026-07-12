import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(OrganizeStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(WatcherStore.self) private var watcher

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            // 上部: 振り分け階層エディタ（適用 / 候補）。出力先の切替は移動先パネルへ集約。
            HierarchyBarView(settings: settings)
            Divider()

            if let plan = store.plan {
                BeforeAfterView(plan: plan, didExecute: store.didExecute)
            } else {
                DropZoneView()
            }
            ActionBarView()
        }
        .frame(minWidth: 720, minHeight: 520)
        .dropDestination(for: URL.self) { urls, _ in
            store.handleDrop(urls)
            return true
        }
        .overlay {
            if store.isScanning {
                ProgressView(String(localized: "EXIF を解析中…"))
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        // 階層・出力先が変わったらプレビューを再計算（EXIF は再読込しない）
        .onChange(of: settings.hierarchy) { _, _ in store.recomputePlan() }
        .onChange(of: settings.destinationMode) { _, _ in store.recomputePlan() }
        .onChange(of: settings.fixedDestinationPath) { _, _ in store.recomputePlan() }
    }
}
