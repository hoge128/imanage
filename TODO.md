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

### 1. App Sandbox が未設定

Mac App Store 配布には App Sandbox が必須だが、`.entitlements` ファイルが存在せず
`app/project.yml` にも署名・サンドボックスの設定がない。

必要な entitlement（最低限）:

```
com.apple.security.app-sandbox
com.apple.security.files.user-selected.read-write
```

`app/project.yml` の `targets.Imanage.settings.base` に `CODE_SIGN_ENTITLEMENTS` を
追加し、entitlements ファイルを作る。**`Info.plist` や `project.pbxproj` は
XcodeGen の生成物なので直接編集しないこと。**

### 2. security-scoped bookmark が未実装

サンドボックス下では、保存したパス文字列だけでは次回起動時にアクセス権がない。
現状これらは生パスで保存している:

- `SettingsStore.fixedDestinationPath`
- `SettingsStore.favoriteDestinations`
- `SettingsStore.defaultDestinationPath`

`NSOpenPanel` で選んだ URL から security-scoped bookmark を作って保存し、
使用時に `startAccessingSecurityScopedResource()` で解決する方式へ移す必要がある。
サンドボックス化と同時に対応しないと、出力先の保存機能が壊れる。

### 3. プライバシーマニフェスト（`PrivacyInfo.xcprivacy`）が無い

Apple が "required reason API" に指定しているファイルタイムスタンプ API を使っている:

| 箇所 | API |
|---|---|
| `app/Imanage/Core/BTimeUtils.swift:17` | `stat()` → `st_birthtime` |
| `app/Imanage/Core/ExifReader.swift:209` | `attributesOfItem` / `.creationDate` |

`NSPrivacyAccessedAPICategoryFileTimestamp` として理由コードを宣言した
`PrivacyInfo.xcprivacy` を追加し、リソースとしてバンドルに含める。
未宣言だとアップロード時に警告、または審査で弾かれる。

なお imanage はデータを一切収集しないので、`NSPrivacyCollectedDataTypes` は空でよい。

---

## 🟡 公開まわり

### 4. Google Search Console（登録・sitemap 送信は完了 / 2026-07-20）

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

### 5. フォルダ監視が無効化されたまま

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

### 6. LP の機能スクリーンショットが読めない

`site/index.md` の機能 3 枚はアプリ全体のスクショで、約 280px 幅で表示されるため
中身が判読できず、3 枚ともほぼ同じ絵に見える。クリックで拡大はできる。

該当箇所を切り出した画像（階層チップの並び替え部分だけ、取り消しボタン周辺だけ等）
への差し替えを推奨。差し替え手順は `site/public/shots/` と
`site/.vitepress/theme/components/Shot.vue` を参照。

---

## ⚪ 軽微

### 7. CLI の i18n の取りこぼし

- argparse 自身のボイラープレート（`usage:` / `options:` /
  `show this help message and exit`）はプロセスロケール依存で、
  `IMANAGE_LANG` では切り替わらない
- `core.py` の argparse `description` の msgid が `"Photographer Tool"` と
  英語のため、日本語環境でも英語で表示される。他の msgid は日本語原文なので不統一

### 8. `knowledge/` が未追跡

`knowledge/libxmp-exif-reconciliation.md` が git 管理外のまま。
コミットするか、意図的に手元だけに置くのかを決める。

### 9. npm の脆弱性報告（対応不要と判断）

`site` で `npm audit` が 3 件（moderate 2 / high 1）報告するが、いずれも
`esbuild` の開発サーバーに関するもので `vitepress dev` の実行中のみ影響する。
ビルド成果物は静的ファイルのみで影響を受けない。上流に修正版が無いため現状対応不可。

VitePress を上げる際に再確認すること。
