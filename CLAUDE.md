# imanage 開発ポリシー

## ファイル削除ポリシー

**`rm` コマンドおよび `os.remove()` / `shutil.rmtree()` 等による完全削除は絶対に使用してはならない。**
**ファイル・ディレクトリの削除は必ず OS のゴミ箱へ移動する方法で行うこと。**

### 理由

写真データは不可逆的に失うと取り返しがつかない。誤操作・バグによるデータ消失を防ぐため、
削除操作は常にゴミ箱経由とし、ユーザーが復元できる余地を残す。

### 実装方法

macOS では `trash` コマンド（`brew install trash`）を使用する：

```bash
# シェルスクリプト・Bash ツール経由での削除
trash /path/to/file
```

Python コード内では `send2trash` ライブラリを使用する：

```python
from send2trash import send2trash

send2trash("/path/to/file")      # ファイル
send2trash("/path/to/directory") # ディレクトリ
```

### 禁止事項

- `rm` / `rm -rf` コマンドの使用禁止
- `os.remove()` の直接呼び出し禁止
- `os.unlink()` の直接呼び出し禁止
- `shutil.rmtree()` の直接呼び出し禁止
- `pathlib.Path.unlink()` の直接呼び出し禁止

---

## btime（ファイル作成日時）保全ポリシー

**imanage はいかなる操作においてもファイルの btime（macOS の `st_birthtime`）を変更してはならない。**

### 背景

写真管理ツールとして、btime はカメラが撮影した日時を示す重要なメタデータである。
imanage の操作（整理・移動・XMP 書き込み）によって btime が変化すると、
日付ベースの整理が誤動作し、ユーザーの写真データが破壊される。

### 実装方法

すべてのファイル操作は `src/imanage/btime_utils.py` のユーティリティを使用すること：

- **ファイル移動:** `shutil.move()` を直接使わず `btime_safe_move()` を使用する
- **インプレース書き込み（XMP等）:** `with preserve_btime(path):` でラップする
- **btime の読み書き:** `get_btime()` / `set_btime()` 経由で行う

### 禁止事項

- `shutil.move()` を `btime_utils` を経由せず直接呼ぶことは禁止
- `shutil.copy2()` でファイルをコピーした後に btime を復元しないことは禁止
- `os.utime()` で btime を変更しようとすること（効果なし、かつ意図が不明になる）

## 進捗表示・ログポリシー

**ループ処理や時間のかかる処理には必ず `tqdm` でプログレスバーを表示すること。**
**メッセージ出力はすべて `logging` モジュール経由で行うこと。**

### tqdm ルール

- ファイルのループ・並列処理（`ThreadPoolExecutor` + `as_completed()` を含む）には `tqdm` バーを付ける
- バーの生成には `src/imanage/progress.py` の `make_bar()` を使う

```python
from imanage.progress import make_bar

# 通常のループ
with make_bar(files, desc="処理内容") as bar:
    for f in bar:
        bar.set_postfix_str(f, refresh=False)
        # 処理...

# ThreadPoolExecutor + as_completed()
futures = {executor.submit(fn, p): p for p in paths}
with make_bar(as_completed(futures), total=len(futures), desc="処理内容") as bar:
    for future in bar:
        path = futures[future]
        bar.set_postfix_str(os.path.basename(path), refresh=False)
        future.result()
```

### ログレベルの使い分け

`src/imanage/log.py` の `TqdmHandler` により、すべてのログ出力は `tqdm.write()` 経由で行われ、プログレスバーを壊さない。

| ログレベル | 用途 | 例 |
|---|---|---|
| `logger.debug()` | ファイル単位の処理詳細（`-v` 時のみ表示） | "Moved X -> Y", "sync -> sidecar.xmp" |
| `logger.info()` | プレビュー・サマリー（デフォルト表示） | ディレクトリ一覧、件数表示 |
| `logger.warning()` | スキップ・警告（デフォルト表示） | 移動スキップ、サイドカー不在 |
| `logger.error()` | エラー（常に表示） | XMP 書き込みエラー |

```python
import logging
logger = logging.getLogger("imanage.<module>")

# ループ外/ループ内、どちらでも使用可（tqdm との共存は自動）
logger.debug(f"Moved {src} -> {dest}")
logger.warning(f"スキップ: {file}")
logger.error(f"XMP 書き込みエラー: {e}")
```

- `print()` をループ内で使ってはならない
- `progress_print()` はレガシーラッパーとして残っているが、新規コードでは `logger.*()` を使うこと

### 出力制御フラグ

| フラグ | コンソール出力 | tqdm バー |
|---|---|---|
| (なし) | INFO 以上 | 表示 |
| `-q / --quiet` | ERROR のみ | 非表示 |
| `-v / --verbose` | DEBUG 以上 | 表示 |
| `--log-file [PATH]` | 変化なし | — |

`--log-file` を指定するとファイルにも DEBUG レベルで出力する。PATH 省略時は `~/.local/state/imanage/imanage.log`。

## バージョン管理

バージョンは **setuptools-scm** で git タグから自動生成される。`src/imanage/_version.py` は自動生成ファイルのため手動編集不可。

### バージョンを上げる手順

```bash
# 1. タグを打つ（形式: v<major>.<minor>.<patch>）
git tag v1.0.1

# 2. _version.py を再生成
pip install -e .

# 3. リリースビルド
make all          # 手動の場合
# または
make release VERSION_TAG=v1.0.1  # Makefile ターゲット経由
```

タグを打たない限り dev バージョン（例: `1.0.1.dev6+ge048d3f51`）のバイナリが生成される。
