# TODO

公開・リリースに向けた残作業と既知の課題。
機能アイデアは `FUTURE.md`、開発ポリシーは `CLAUDE.md` を参照。

最終更新: 2026-07-20

---

## 決定事項（記録）

### 自動更新（Sparkle 等）

**今は実装しない。** 将来 App Store 外で配布する場合に備え、フィード URL は
`https://imanage.itotsum.com/appcast.xml` を予約しておく。

理由:

- App Store 配布のみであれば自動更新は不要。CLI は `pip install -U` で済む
- 更新フィード URL は配布バイナリに焼き込まれ、事実上変更できなくなる。
  github.io に置くとカスタムドメインを当てる標準手順が使えなくなり、
  リバースプロキシ等の回避策を強いられる（bridge-lite が実際にその状態）
- 自分が恒久的にコントロールできる `itotsum.com` 配下なら、その制約を負わない

実装する際は、上記 URL 以外を使わないこと。

### LP の公開先

`https://imanage.itotsum.com`（Cloudflare Workers 静的アセット）。
`main` へ push すると Workers Builds が自動デプロイする。
`*.workers.dev` とプレビュー URL は重複コンテンツを避けるため無効化済み
（`site/wrangler.jsonc` の `workers_dev` / `preview_urls`）。

---

## 🔴 App Store 提出のブロッカー

### 1〜3. App Sandbox / bookmark / プライバシーマニフェスト（対応済み・2026-07-20）

- `app/project.yml` の `targets.Imanage.entitlements` で
  `app-sandbox` / `files.user-selected.read-write` / `files.bookmarks.app-scope` を宣言。
  entitlements ファイルは xcodegen の生成物なので直接編集しないこと
- `app/Imanage/Core/SecurityScope.swift` を追加。ドロップ・`NSOpenPanel` で得た URL を
  app-scoped bookmark 化して UserDefaults に保存し、起動時に `restoreAll()` で
  アクセスを復元する。保存済みの出力先・監視フォルダは再起動後も使える
- `app/Imanage/Resources/PrivacyInfo.xcprivacy` を追加
  （FileTimestamp = `DDA9.1` / UserDefaults = `CA92.1`）
- `DEVELOPMENT_TEAM: KTQ8JQW28L` と `CODE_SIGN_STYLE: Automatic` を設定

サンドボックス化に伴う仕様変更:

- **CLI との undo 相互運用は失われた。** サンドボックス下では
  `homeDirectoryForCurrentUser` がアプリコンテナを返すため、ジャーナルの実体は
  `~/Library/Containers/com.itotsum.imanage/Data/.local/state/imanage/` に置かれる。
  アプリ単体の undo（起動をまたぐものも含む）は従来どおり動作する
- **ファイル単体をドロップして「ドロップ元と同じ場所」で振り分ける場合**、親フォルダへの
  書き込み権限がないため、実行時に一度だけ `NSOpenPanel` で許可を求める。
  許可したフォルダは bookmark に残るので次回以降は聞かれない。
  フォルダごとドロップした場合は配下も含めて権限が付くため、確認は出ない
- undo で元の場所へ書き戻せない場合も同様に許可を求める
  （`OrganizeStore.undo` / `Journal.undoTargetDirectories`）
- 言語変更時の再起動は `Process` が sandbox で禁止のため `NSWorkspace.openApplication` に変更
- `BTimeUtils.safeMove` の btime 復元失敗を `Logger` で記録するようにした（従来は `try?` で無言）

**sandbox 下での E2E 検証結果（2026-07-20・UI 自動操作で実測）:**

- ✅ フォルダ選択 → EXIF スキャン → プレビュー → 実行 → サブフォルダ作成・移動、すべて成功
- ✅ btime 保全（移動後・undo 後とも撮影日時のまま変化なし）
- ✅ ジャーナルがコンテナ内 `~/Library/Containers/com.itotsum.imanage/Data/.local/state/imanage/` に書かれ、⌘Z undo で全ファイル復元・作成フォルダはゴミ箱へ・undone フラグ更新
- ✅ 再起動後も bookmark でアクセス復元（restoreAll 経由）
- 🐛 検証中に `SecurityScope.grantedAncestor` の**無限ループを発見・修正**
  （`deletingLastPathComponent()` は "/" の親に "/.." を返し続けるため、
  パス比較では終端しない。"/" 到達で明示的に打ち切る）。修正前は
  ドロップ／ファイル選択した瞬間にメインスレッドが固まる致命バグだった
- ➕ ドロップゾーンに「ファイルを選択…」ボタンを追加（NSOpenPanel 経由の入力手段。
  E2E 自動化の入口にもなる）

**残る手動確認（リリース前に 1 回だけ）:**

> Finder からの**実ドラッグ&ドロップ**は合成イベントでは再現できず未検証
> （cliclick で 3 回試行、macOS 26 は synthetic drag を受理しない模様）。
> ドロップ以降のコードは検証済みのため、残る未知は SwiftUI の
> `.dropDestination(for: URL.self)` が sandbox extension 付き URL を返すか
> という OS 標準動作のみ。**手でドロップして 1 回振り分けが通れば完了。**
> 万一失敗する場合は `.onDrop(of: [.fileURL])` + `loadObject(ofClass: NSURL.self)`
> 方式へ切り替える。あわせて「ファイル単体ドロップ → 実行時の
> アクセス許可プロンプト（ensureAccess）」の文言・挙動も目視確認すること。

### 4. App Store Connect のアプリレコード（作成済み・2026-07-20）

- Developer Portal に App ID `com.itotsum.imanage`（explicit・capability なし）を登録
- ASC にアプリレコードを作成:
  - 名前: **imanage**（小文字。iManage 社との商標衝突リスクを考慮しつつ、この表記で通った。
    審査で指摘されたら名称変更を検討）
  - プラットフォーム: macOS / プライマリ言語: 日本語 / SKU: `imanage-mac`
  - ASC アプリ ID: **6792631506**（https://appstoreconnect.apple.com/apps/6792631506）

次のステップ: `scripts/do-release-mas.sh` でリリース（下記）。初回提出前に
ASC 側でスクリーンショット・説明文・カテゴリ・価格（無料）・プライバシー表示の
入力が必要（fastlane deliver でメタデータは投入可能。スクショは未準備）。

---

## 🚀 リリース手順（Mac App Store）

```bash
./scripts/do-release-mas.sh 0.2.0
```

やること: プリフライト検証 → バージョン更新 → `xcodegen generate` →
Release ビルド確認 → **（手動）Xcode で Archive → Distribute → Upload** →
`fastlane deliver`（任意）→ commit + タグ `mas/v0.2.0` + push。

メタデータ（日英）は `fastlane/metadata/` で git 管理している。
ASC への手入力事項（価格・年齢制限・プライバシー表示）とリリース記録は
`docs/appstore/README.md` を参照。
`fastlane deliver` を使う場合は App Store Connect API キーを環境変数で渡す:

```bash
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8   # リポジトリ外に置く
```

スクリーンショットは `fastlane/screenshots/{ja,en-US}/` が空のままなので、
投入するなら先に配置すること（未配置でも `deliver` は通る）。

---

## 🟡 公開まわり

### 5. Google Search Console（登録・sitemap 送信は完了 / 2026-07-20）

`itotsum.com` をドメインプロパティとして登録し、DNS の TXT レコードで所有権を確認済み。
`https://imanage.itotsum.com/sitemap.xml` を送信し、**検出ページ数 4** を確認した。

> ⚠️ 確認用の TXT レコード（`google-site-verification=...`、`itotsum.com` の `@`）は
> 削除しないこと。Google が定期的に再確認し、消えているとプロパティが失効する。
> 値を忘れても `dig +short TXT itotsum.com` でいつでも読み出せる。

残りは経過観察:

- 数日〜2 週間後、**インデックス作成 → ページ** で 4 ページが「登録済み」になっているか
  （検出 ≠ インデックス。反映には時間がかかる）
- 任意: URL 検査から `https://imanage.itotsum.com/` と `/en/` の
  インデックス登録をリクエストすると早まる
- hreflang のエラーが出ていないか（日英の相互参照は実装済みなので通常は出ない）

今後 `itotsum.com` 配下にサイトを増やしても、このドメインプロパティがカバーする。

---

## 🟢 機能の課題

### 6. フォルダ監視が無効化されたまま

`app/Imanage/Core/FeatureFlags.swift` の `folderWatcher = false` で
UI と常駐処理の入口を塞いでいる。実装自体は残っている。

再有効化の条件:

- **監視専用の階層を指定できるようにする。** 現状は
  `WatcherStore.processSourceFolder()` が `settings.config` を見ており、
  メイン画面で選択中の階層をそのまま使ってしまう。ウィンドウを閉じても常駐する
  機能なので、メイン画面で一時的に階層を変えたことを忘れると意図しない構成で
  写真が移動される。既存のプリセット機構を流用して監視専用の指定を持たせる
- **取り込み完了の判定を堅くする。** 現状は FSEvents 発火から 2 秒待つだけなので、
  大量コピーや低速な外部ストレージでは書き込み途中のファイルを掴む可能性がある

LP（`site/index.md` / `site/en/index.md`）からも記載を削除済み。
再有効化する際は LP にも戻すこと。

### 7. LP の機能スクリーンショットが読めない

`site/index.md` の機能 3 枚はアプリ全体のスクショで、約 280px 幅で表示されるため
中身が判読できず、3 枚ともほぼ同じ絵に見える。クリックで拡大はできる。

該当箇所を切り出した画像（階層チップの並び替え部分だけ、取り消しボタン周辺だけ等）
への差し替えを推奨。差し替え手順は `site/public/shots/` と
`site/.vitepress/theme/components/Shot.vue` を参照。

---

## ⚪ 軽微

### 8. CLI の i18n の取りこぼし

- argparse 自身のボイラープレート（`usage:` / `options:` /
  `show this help message and exit`）はプロセスロケール依存で、
  `IMANAGE_LANG` では切り替わらない
- `core.py` の argparse `description` の msgid が `"Photographer Tool"` と
  英語のため、日本語環境でも英語で表示される。他の msgid は日本語原文なので不統一

### 9. `knowledge/` が未追跡

`knowledge/libxmp-exif-reconciliation.md` が git 管理外のまま。
コミットするか、意図的に手元だけに置くのかを決める。

### 10. npm の脆弱性報告（対応不要と判断）

`site` で `npm audit` が 3 件（moderate 2 / high 1）報告するが、いずれも
`esbuild` の開発サーバーに関するもので `vitepress dev` の実行中のみ影響する。
ビルド成果物は静的ファイルのみで影響を受けない。上流に修正版が無いため現状対応不可。

VitePress を上げる際に再確認すること。
