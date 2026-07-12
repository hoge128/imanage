import SwiftUI

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
}
