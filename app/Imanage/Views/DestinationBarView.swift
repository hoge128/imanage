import SwiftUI
import AppKit

// MARK: - DestinationMenu
// 移動先パネルのヘッダに置く出力先コントロール。
// 「ドロップ元と同じ場所」と保存済みフォルダを同列の選択肢として 1 つのメニューで選ぶ。
// お気に入りの追加・削除・既定指定もこのメニュー内で完結する。

struct DestinationMenu: View {
    @Bindable var settings: SettingsStore
    /// 実際に解決された出力先ルート（プレビューの destRoot）
    let destRootPath: String
    /// 実行後はフォルダ変更不可（既に移動済み）
    let editable: Bool

    @State private var showMenu = false

    private var isDropped: Bool { settings.destinationMode == .droppedParent }
    private var activeFixedPath: String {
        (settings.fixedDestinationPath as NSString).expandingTildeInPath
    }
    /// 現在 fixed で選ばれているパスがお気に入り（または既定）か
    private var activeIsFavorite: Bool {
        settings.favoriteDestinations.contains(activeFixedPath)
    }

    private var triggerIcon: String {
        if isDropped { return "folder" }
        return activeIsFavorite ? "star.fill" : "folder"
    }
    private var triggerTitle: String {
        isDropped
            ? String(localized: "ドロップ元と同じ場所")
            : (settings.fixedDestinationPath as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if editable {
                Button {
                    showMenu.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: triggerIcon)
                        Text(triggerTitle).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                    menuContent
                }
            } else {
                Label(triggerTitle, systemImage: triggerIcon)
                    .font(.caption)
            }

            Text(destRootPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()
        }
    }

    // MARK: - メニュー本体

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuHeader(String(localized: "出力先を選択"))

            menuRow(icon: isDropped ? "checkmark" : "folder",
                    title: String(localized: "ドロップ元と同じ場所"),
                    active: isDropped) {
                settings.destinationMode = .droppedParent
                showMenu = false
            }

            if !settings.favoriteDestinations.isEmpty {
                Divider().padding(.vertical, 4)
                menuHeader(String(localized: "保存した出力先"))
                ForEach(settings.favoriteDestinations, id: \.self) { path in
                    favoriteRow(path)
                }
            }

            Divider().padding(.vertical, 4)

            menuRow(icon: "folder.badge.plus",
                    title: String(localized: "フォルダを選択…"),
                    active: false) {
                if let url = Self.pickFolder() {
                    settings.applyFavorite(url.path)
                    showMenu = false
                }
            }

            saveCurrentRow
        }
        .padding(6)
        .frame(width: 300)
    }

    private var saveCurrentRow: some View {
        let canSave = !isDropped
            && !settings.fixedDestinationPath.isEmpty
            && !activeIsFavorite
            && settings.favoriteDestinations.count < SettingsStore.maxFavorites
        return Button {
            settings.addFavorite(settings.fixedDestinationPath)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star").frame(width: 16)
                Text("現在の出力先を保存")
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSave ? Color.primary : Color.secondary)
        .disabled(!canSave)
    }

    private func favoriteRow(_ path: String) -> some View {
        let isActive = settings.destinationMode == .fixed && activeFixedPath == path
        let isDef = settings.isDefault(path)
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark" : "star.fill")
                .frame(width: 16)
                .foregroundStyle(isActive ? Color.accentColor : Color.yellow)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text((path as NSString).lastPathComponent)
                    if isDef {
                        Text("既定")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // 既定トグル
            Button {
                settings.toggleDefault(path)
            } label: {
                Image(systemName: isDef ? "pin.fill" : "pin")
                    .foregroundStyle(isDef ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isDef ? String(localized: "既定を解除") : String(localized: "既定の出力先にする"))

            // 削除
            Button {
                settings.removeFavorite(path)
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "お気に入りから削除"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            settings.applyFavorite(path)
            showMenu = false
        }
    }

    // MARK: - パーツ

    private func menuHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func menuRow(icon: String, title: String, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
