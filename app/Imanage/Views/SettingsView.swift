import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(WatcherStore.self) private var watcher

    var body: some View {
        @Bindable var settings = settings

        TabView {
            // MARK: 振り分け設定
            Form {
                Text("出力先は移動先パネル、フォルダ階層はメイン画面上部で設定できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(String(localized: "XMP サイドカーの振り分け先"), selection: $settings.xmpPairIsJpg) {
                    Text(verbatim: "raw/").tag(false)
                    Text(verbatim: "jpg/").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            .padding(20)
            .tabItem {
                Label(String(localized: "振り分け"), systemImage: "folder")
            }

            // MARK: フォルダ監視設定
            Form {
                Toggle(String(localized: "フォルダ監視を有効にする"), isOn: $settings.watcherEnabled)
                Text("監視元フォルダに追加されたファイルを自動で振り分け先へ整理します。処理中はメニューバーのアイコンが回転します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(String(localized: "監視元フォルダ（A）"), text: $settings.watcherSourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "選択…")) {
                        if let url = Self.pickFolder() { settings.watcherSourcePath = url.path }
                    }
                }
                HStack {
                    TextField(String(localized: "振り分け先フォルダ（B）"), text: $settings.watcherDestPath)
                        .textFieldStyle(.roundedBorder)
                    Button(String(localized: "選択…")) {
                        if let url = Self.pickFolder() { settings.watcherDestPath = url.path }
                    }
                }

                if watcher.isWatching {
                    Label(String(localized: "監視中"), systemImage: "eye")
                        .foregroundStyle(.green)
                }
                if let message = watcher.lastActivityMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .tabItem {
                Label(String(localized: "フォルダ監視"), systemImage: "eye")
            }
        }
        .frame(width: 480)
        .onChange(of: settings.watcherEnabled) { _, _ in watcher.restart() }
        .onChange(of: settings.watcherSourcePath) { _, _ in watcher.restart() }
        .onChange(of: settings.watcherDestPath) { _, _ in watcher.restart() }
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
