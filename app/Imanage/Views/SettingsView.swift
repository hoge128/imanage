import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(WatcherStore.self) private var watcher
    @State private var showRestartAlert = false

    var body: some View {
        @Bindable var settings = settings

        TabView {
            // MARK: 一般設定
            Form {
                Picker(String(localized: "言語"), selection: $settings.language) {
                    ForEach(SettingsStore.Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .onChange(of: settings.language) { old, new in
                    guard old != new else { return }
                    showRestartAlert = true
                }
            }
            .padding(20)
            .tabItem {
                Label(String(localized: "一般"), systemImage: "gearshape")
            }

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
        .alert(String(localized: "再起動が必要です"), isPresented: $showRestartAlert) {
            Button(String(localized: "今すぐ再起動")) { Self.relaunchApp() }
            Button(String(localized: "あとで"), role: .cancel) {}
        } message: {
            Text("言語の変更を適用するには Imanage を再起動する必要があります。自動で再起動しない場合は、手動で終了して開き直してください。")
        }
    }

    /// 自身を新しいプロセスとして開き直してから終了する。
    /// AppleLanguages の上書きは起動時にしか効かないため、言語変更には再起動が要る。
    private static func relaunchApp() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-b", bundleID]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
