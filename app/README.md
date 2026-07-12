# Imanage.app — macOS GUI 版

imanage CLI の振り分け機能を GUI 化した独立 macOS アプリ。
コアロジック（EXIF 解析・振り分け・undo・btime 保全）は Swift でフル移植されており、Python ランタイムは不要。

## 機能

- **ドラッグ&ドロップ振り分け**: JPG / RAW / XMP をドロップ → EXIF を解析し振り分け先をツリーでプレビュー → 実行
- **Undo**: ⌘Z / メニュー / ボタン。ジャーナルは CLI と同一形式・同一パス（`~/.local/state/imanage/last_operation.json`）のため `imanage --undo` と相互運用可能
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

## ポリシー（CLI と共通）

- ファイル削除は `FileManager.trashItem`（ゴミ箱）のみ。`removeItem` 禁止
- すべてのファイル移動は `BTimeUtils.safeMove` 経由で btime を保全
- 詳細はリポジトリルートの `CLAUDE.md` を参照
