# btime 保全テスト手順

## 概要

`imanage` 実行後にファイルの btime（macOS のファイル作成日時）が変化しないことを確認するテスト。

## 前提条件

- macOS 環境
- `imanage` がインストール済み（`pip install -e .` または `imanage` コマンドが使用可能）
- テスト用 JPG ファイル（EXIF 付き）が用意できること

## テスト 1: `imanage -o`（organize）の btime 保全確認

### 準備

```bash
mkdir -p /tmp/imanage_test
cd /tmp/imanage_test

# テスト用 JPG を配置（実際の写真ファイルをコピーして使用）
cp ~/Pictures/sample.jpg ./TEST_001.jpg
cp ~/Pictures/sample.jpg ./TEST_002.jpg

# 事前の btime を記録
stat -f "name=%N btime=%SB" TEST_001.jpg TEST_002.jpg
```

### 実行

```bash
imanage -o
```

### 確認

```bash
# 移動後のファイルを探して btime を確認
find . -name "TEST_001.jpg" -exec stat -f "name=%N btime=%SB" {} \;
find . -name "TEST_002.jpg" -exec stat -f "name=%N btime=%SB" {} \;
```

**期待値:** 事前に記録した btime と完全に一致すること。

---

## テスト 2: `imanage`（デフォルト）の btime 保全確認

### 準備

```bash
mkdir -p /tmp/imanage_test2
cd /tmp/imanage_test2

cp ~/Pictures/sample.jpg ./TEST_001.jpg
stat -f "name=%N btime=%SB" TEST_001.jpg
```

### 実行

```bash
imanage
```

### 確認

```bash
find . -name "TEST_001.jpg" -exec stat -f "name=%N btime=%SB" {} \;
```

**期待値:** jpg/ サブディレクトリに移動後も btime が変化しないこと。

---

## テスト 3: XMP 書き込みの btime 保全確認（単体）

EXIF メタデータを含む JPG に対して XMP 書き込みが走る場合の btime 確認。

```bash
mkdir -p /tmp/imanage_test3
cd /tmp/imanage_test3
mkdir jpg raw

cp ~/Pictures/sample.jpg ./jpg/TEST_001.jpg
stat -f "name=%N btime=%SB" jpg/TEST_001.jpg

# すでに jpg/raw ディレクトリがあれば imanage はファイル移動をスキップして XMP 書き込みのみ実行
imanage

stat -f "name=%N btime=%SB" jpg/TEST_001.jpg
```

**期待値:** XMP 書き込み後も btime が変化しないこと。

---

## btime の数値で比較するスクリプト

```bash
#!/bin/bash
# btime_check.sh — btime 変化を数値で検出するスクリプト

FILE=$1
if [ -z "$FILE" ]; then
  echo "Usage: $0 <file>"
  exit 1
fi

BEFORE=$(GetFileInfo -d "$FILE" 2>/dev/null || stat -f "%SB" "$FILE")
echo "Before: $BEFORE"

# ... imanage を実行 ...

AFTER=$(GetFileInfo -d "$FILE" 2>/dev/null || stat -f "%SB" "$FILE")
echo "After:  $AFTER"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "OK: btime 保全 OK"
else
  echo "NG: btime が変化しました！"
fi
```

## クリーンアップ

```bash
rm -rf /tmp/imanage_test /tmp/imanage_test2 /tmp/imanage_test3
```
