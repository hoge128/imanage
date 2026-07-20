import SwiftUI
import AppKit

/// アプリケーションメニューの「Imanage について」で開く情報ウィンドウ。
/// 標準の About パネルではアイコン・バージョン・著作権しか出せないため、
/// 説明文とリンクを含めた独自ウィンドウに差し替えている。
struct AboutView: View {
    private static let gitHubURL = URL(string: "https://github.com/hoge128/imanage")!
    private static let privacyURL = URL(string: "https://imanage.itotsum.com/privacy")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                appIcon

                Text(verbatim: Self.appName)
                    .font(.system(size: 26, weight: .bold))

                Text(Self.versionText)
                    .font(.title3)

                Text("撮影日時（EXIF）をもとに写真を自動でフォルダ分けします。\nRAW+JPG ペアと XMP サイドカーをまとめて移動し、\n振り分け前に結果をプレビューできます。")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                HStack(spacing: 24) {
                    Link(String(localized: "GitHub"), destination: Self.gitHubURL)
                    Link(String(localized: "プライバシーポリシー"), destination: Self.privacyURL)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)

            Divider()
                .padding(.horizontal, 32)
                .padding(.vertical, 20)

            VStack(spacing: 10) {
                Text(verbatim: Self.copyright)
                Text("このアプリは写真データを外部に送信しません。すべての処理は Mac 上で完結します。")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 128, height: 128)
        } else {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Info.plist

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "imanage"
    }

    private static var versionText: String {
        // CFBundleVersion はリリースごとに更新していないため表示しない
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return String(format: String(localized: "バージョン %1$@"), short)
    }

    private static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
