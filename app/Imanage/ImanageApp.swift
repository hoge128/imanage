import SwiftUI

@main
struct ImanageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var organizeStore = OrganizeStore()
    @State private var settingsStore = SettingsStore()
    @State private var watcherStore = WatcherStore()

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
                    watcherStore.startIfEnabled()
                }
        }
        .commands {
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var watcherStore: WatcherStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 監視常駐中はウィンドウを閉じても終了しない
        watcherStore?.isEnabled != true
    }
}
