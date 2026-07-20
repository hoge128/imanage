# App Store 提出情報の管理

imanage（Mac App Store）の提出に関わる情報の置き場と、その同期方法。

## どこで何を管理するか

| 情報 | 置き場 | ASC への反映 |
|---|---|---|
| アプリ名・サブタイトル・説明文・キーワード・プロモテキスト・What's New・各種 URL（日英） | `fastlane/metadata/{ja,en-US}/` | `fastlane deliver`（`scripts/do-release-mas.sh` から実行可） |
| 著作権・プライマリカテゴリ | `fastlane/metadata/copyright.txt` / `primary_category.txt` | 同上 |
| 審査連絡先・審査メモ | `fastlane/metadata/review_information/` | 同上 |
| スクリーンショット | `fastlane/screenshots/{ja,en-US}/` | 同上（`overwrite_screenshots(true)`） |
| リリースごとの記録（アーカイブ） | `docs/appstore/releases/mac/<version>.md` | 反映されない（記録のみ。実体は fastlane 側） |
| 価格・年齢制限・プライバシー表示 | このファイルの下記セクション | **ASC Web で手入力**（deliver では送れない） |

原則: **git が単一の真実**。ASC Web で直接編集した場合は、必ずこのリポジトリに反映し直すこと。

## ASC 上の固定情報（変更しない）

| 項目 | 値 |
|---|---|
| ASC アプリ ID | `6792631506`（https://appstoreconnect.apple.com/apps/6792631506） |
| アプリ名 | `imanage`（小文字。iManage 社の商標と区別しづらいと審査指摘があれば要変更） |
| バンドル ID | `com.itotsum.imanage`（explicit・作成後は変更不可） |
| SKU | `imanage-mac`（作成後は変更不可） |
| プライマリ言語 | 日本語 |
| プラットフォーム | macOS |
| Team ID | `KTQ8JQW28L` |

## ASC Web で手入力する内容（初回提出時）

deliver で送れないため、以下の内容をそのまま ASC に入力する。

### 価格および配信状況

- 価格: **0円（無料）**
- 配信地域: すべての国と地域
- App 内課金・サブスクリプション: なし

### 年齢制限指定（レーティング）

質問にはすべて **「なし」** で回答 → **4+** になる想定。
（暴力・性的内容・ギャンブル・医療情報・無制限 Web アクセス・ユーザー生成コンテンツ、いずれも該当なし）

### App のプライバシー

- データ収集: **「データを収集しない」**（imanage はネットワーク通信自体を行わない）
- プライバシーポリシー URL: `https://imanage.itotsum.com/privacy`（日本語）/ `https://imanage.itotsum.com/en/privacy`（英語）
- 根拠: `app/Imanage/Resources/PrivacyInfo.xcprivacy`（NSPrivacyCollectedDataTypes は空）

### 審査連絡先の電話番号・メールアドレス

個人情報のためリポジトリには含めない:

- **電話番号**: ファイルを置かず、ASC の「App Review に関する情報」で手入力する
- **メールアドレス**: `fastlane/metadata/review_information/email_address.txt` は
  `.gitignore` 済み（ローカルにのみ存在し、`fastlane deliver` 実行時に読まれる）

## スクリーンショット仕様（Mac）

- 必須サイズ（いずれか）: **1280×800 / 1440×900 / 2560×1600 / 2880×1800**（16:10）
- 形式: PNG または JPEG、最大 10 枚
- 配置先: `fastlane/screenshots/ja/` と `fastlane/screenshots/en-US/`
- ファイル名順に並ぶ。`01_...png` のような接頭辞で順序を管理する
- LP 用スクショ（`site/public/shots/`）は WebP なので流用時は PNG へ変換すること

## リリースの流れ

```bash
./scripts/do-release-mas.sh <version>
```

詳細はリポジトリルートの `TODO.md`「🚀 リリース手順」を参照。
リリースごとの Promotional Text / What's New は `docs/appstore/releases/mac/<version>.md`
に日英で記録し、実際に ASC へ送る文面は `fastlane/metadata/{ja,en-US}/release_notes.txt`
と `promotional_text.txt` を更新する（スクリプトが途中で促す）。
