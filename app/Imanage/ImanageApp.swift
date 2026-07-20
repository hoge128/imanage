import SwiftUI

@main
struct ImanageApp: App {
    /// 表示言語の上書きを最初の文字列参照より前に一度だけ適用する。
    /// Bundle は最初のローカライズ参照時に言語を確定させてしまうため、
    /// View の生成前（= init）に走らせる必要がある。
    private static let bootstrap: Void = {
        SettingsStore.applyLanguageOverride()
    }()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var organizeStore = OrganizeStore()
    @State private var settingsStore = SettingsStore()
    @State private var watcherStore = WatcherStore()

    init() {
        _ = Self.bootstrap
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(organizeStore)
                .environment(settingsStore)
                .environment(watcherStore)
                .onAppear {
                    organizeStore.settings = settingsStore
                    watcherStore.settings = settingsStore
                    appDelegate.watcherStore = watcherStore
                    // 保存済みの出力先・監視フォルダへのアクセスを取り戻してから
                    // 監視を開始する（サンドボックス下では権限がないと即失敗する）。
                    SecurityScope.shared.restoreAll()
                    watcherStore.startIfEnabled()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            CommandGroup(replacing: .undoRedo) {
                Button(String(localized: "元に戻す（ファイル振り分け）")) {
                    organizeStore.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!organizeStore.canUndo)
            }
        }

        Settings {
            SettingsView()
                .environment(settingsStore)
                .environment(watcherStore)
        }

        // 標準の About パネルを AboutView に差し替えるための単独ウィンドウ
        Window(String(localized: "imanage について"), id: ImanageApp.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }

    static let aboutWindowID = "about"
}

/// `CommandGroup` 内では `openWindow` を直接引けないため、View に切り出している。
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(String(localized: "imanage について")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: ImanageApp.aboutWindowID)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var watcherStore: WatcherStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 監視常駐中はウィンドウを閉じても終了しない
        watcherStore?.isEnabled != true
    }
}
