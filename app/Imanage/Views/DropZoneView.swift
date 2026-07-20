import SwiftUI
import AppKit

/// プラン未作成時に表示するドロップ受付エリア（ドロップ処理自体は ContentView の dropDestination が担う）
struct DropZoneView: View {
    @Environment(OrganizeStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("写真ファイルをここにドロップ")
                .font(.title2)
            Text("JPG / RAW / XMP を EXIF で解析し、振り分け先をプレビューします")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                let urls = Self.pickInputs()
                if !urls.isEmpty { store.handleDrop(urls) }
            } label: {
                Label(String(localized: "ファイルを選択…"), systemImage: "folder")
            }
            .padding(.top, 4)
            if let message = store.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.quaternary)
                .padding(20)
        )
    }

    /// ドロップの代替となる Finder 選択。ファイル・フォルダを複数選択できる。
    /// （サンドボックスでは NSOpenPanel = powerbox 経由の選択にもアクセス権が付く）
    private static func pickInputs() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
