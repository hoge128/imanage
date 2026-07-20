# Imanage.app — macOS GUI 版

imanage CLI の振り分け機能を GUI 化した独立 macOS アプリ。
コアロジック（EXIF 解析・振り分け・undo・btime 保全）は Swift でフル移植されており、Python ランタイムは不要。

## 機能

- **ドラッグ&ドロップ振り分け**: JPG / RAW / XMP をドロップ → EXIF を解析し振り分け先をツリーでプレビュー → 実行
- **Undo**: ⌘Z / メニュー / ボタン。ジャーナルは CLI と同一形式（`.local/state/imanage/last_operation.json`）。ただし App Sandbox 下では実体がアプリコンテナ内に置かれるため、`imanage --undo` との相互運用はできない
- **フォルダ監視常駐**: 設定した監視フォルダ A に追加されたファイルを自動でフォルダ B へ振り分け。処理中はメニューバーアイコンが回転
- **日英対応**: システム言語に追従（Localizable.xcstrings）

CLI にある JPG↔RAW のメタデータ sync（-m/-s）・孤立 RAW 削除（-d）は GUI には意図的に実装していない（ファイル内容に触らない振り分け専用アプリ）。

## ビルド

```bash
brew install xcodegen   # 初回のみ
cd app
xcodegen generate
xcodebuild -project Imanage.xcodeproj -scheme Imanage -configuration Release build
```

開発時は `open Imanage.xcodeproj` で Xcode から ⌘R。

**注意:** `project.yml` が唯一のソース。`Imanage.xcodeproj` は生成物なので直接編集せず、変更は project.yml に対して行い `xcodegen generate` で再生成する。

## 構成

```
app/
├── project.yml             # xcodegen プロジェクト定義
└── Imanage/
    ├── ImanageApp.swift    # エントリポイント
    ├── Core/               # CLI コアロジックの Swift 移植
    │   ├── ExifReader.swift      # ImageIO による EXIF 読み取り（core.py get_exif_fields 相当）
    │   ├── PathCalculator.swift  # 振り分け先計算（_preview_single 相当）
    │   ├── FileOrganizer.swift   # 移動実行（date_organize 相当）
    │   ├── BTimeUtils.swift      # setattrlist(2) による btime 保全（btime_utils.py 相当）
    │   ├── Journal.swift         # CLI 互換ジャーナル + undo（journal.py 相当）
    │   └── ImanageConfig.swift   # config.toml 相当のデフォルト設定
    ├── Models/             # OrganizePlan / PlannedMove / ExifFields
    ├── Stores/             # @Observable 状態管理 + FSEvents フォルダ監視
    ├── Views/              # SwiftUI（ドロップゾーン / プレビューツリー / 設定）
    ├── MenuBar/            # NSStatusItem + 回転アニメーション
    └── Resources/          # Localizable.xcstrings (ja/en)
```

## App Sandbox

Mac App Store 配布のため App Sandbox を有効にしている（entitlements は `project.yml` の
`targets.Imanage.entitlements` が唯一のソース。`.entitlements` ファイルは生成物）。

サンドボックス下ではパス文字列を保存してもアクセス権が復元されないため、
`Core/SecurityScope.swift` がユーザーの選んだフォルダを app-scoped security-scoped
bookmark として保持する。

- ドロップ受付時（`OrganizeStore.handleDrop`）と `NSOpenPanel` 選択時に `remember()`
- 起動時に `SecurityScope.shared.restoreAll()` でアクセスを再取得
- 権限のない場所へ書く直前（`execute` / `undo`）に `ensureAccess()` で許可を求める

**新しくファイルパスを扱うコードを足すときは、`SecurityScope` を通すこと。**
生の `URL(fileURLWithPath:)` で組んだパスは、ユーザーが許可した祖先の配下でない限り
サンドボックスに拒否される。

## リリース

Mac App Store へのリリースはリポジトリルートの `scripts/do-release-mas.sh` を使う。
メタデータは `fastlane/metadata/`（日英）で git 管理している。詳細は `TODO.md` を参照。

## ポリシー（CLI と共通）

- ファイル削除は `FileManager.trashItem`（ゴミ箱）のみ。`removeItem` 禁止
- すべてのファイル移動は `BTimeUtils.safeMove` 経由で btime を保全
- 詳細はリポジトリルートの `CLAUDE.md` を参照
