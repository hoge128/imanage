#!/usr/bin/env bash
# Imanage Mac App Store リリース手順スクリプト
#
# Usage: ./scripts/do-release-mas.sh <version>
# Example: ./scripts/do-release-mas.sh 0.2.0
#
# 自動実行:
#   1. 提出要件のプリフライトチェック（entitlements / PrivacyInfo / 署名設定）
#   2. app/project.yml のバージョン更新（CFBundleShortVersionString / CFBundleVersion++）
#   3. xcodegen generate（Info.plist と entitlements の再生成）
#   4. Release 構成でのビルド確認（xcodebuild）
#   5. fastlane deliver でメタデータ/スクショを ASC へ投入（任意）
#   6. git commit + タグ作成（mas/v<version>）+ push
#
# 手動操作が必要な箇所（スクリプトが一時停止して案内します）:
#   - fastlane/metadata/{ja,en-US}/release_notes.txt の更新
#   - Xcode で Archive → Distribute App → App Store Connect → Upload（.pkg）
#
# CLI（PyInstaller）のリリースは Makefile 側（make release）で、こちらとは別系統。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
PROJECT_YML="$APP_DIR/project.yml"
XCODEPROJ="$APP_DIR/Imanage.xcodeproj"
SCHEME="Imanage"
ENTITLEMENTS="$APP_DIR/Imanage/Imanage.entitlements"
PRIVACY_MANIFEST="$APP_DIR/Imanage/Resources/PrivacyInfo.xcprivacy"

# ─── カラー出力 ───────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}✓ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
fail()  { echo -e "${RED}✗ $1${NC}"; exit 1; }
pause() {
    echo -e "\n${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}${BOLD}  手動操作が必要です${NC}"
    echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "$1"
    echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    read -rp "完了したら Enter を押してください..."
}
confirm() { # confirm "質問" → yes なら 0
    local reply
    read -rp "$(echo -e "${YELLOW}$1 [y/N]: ${NC}")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ─── 引数確認 ─────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.2.0"
    exit 1
fi
VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "バージョンは x.y.z 形式で指定してください"
fi

echo -e "\n${BOLD}Imanage (Mac App Store) v${VERSION} リリースを開始します${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── STEP 0: プリフライト ─────────────────────────────────────
step "STEP 0/6: 提出要件のプリフライトチェック"

command -v xcodegen >/dev/null || fail "xcodegen が見つかりません（brew install xcodegen）"
command -v xcodebuild >/dev/null || fail "xcodebuild が見つかりません（Xcode をインストールしてください）"

# 作業ツリーが汚れていると、後段の git add でリリースと無関係な変更を巻き込む
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$APP_DIR" "$REPO_ROOT/fastlane")" ]]; then
    warn "app/ または fastlane/ に未コミットの変更があります:"
    git -C "$REPO_ROOT" status --short -- "$APP_DIR" "$REPO_ROOT/fastlane"
    confirm "このまま続行しますか？" || exit 1
fi

# App Sandbox（App Store 必須）
[[ -f "$ENTITLEMENTS" ]] || fail "entitlements が見つかりません: ${ENTITLEMENTS#$REPO_ROOT/}
  App Store 配布には App Sandbox が必須です。project.yml の targets.Imanage.entitlements を設定してください。"
if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS" 2>/dev/null | grep -q true; then
    fail "entitlements に com.apple.security.app-sandbox: true がありません"
fi
ok "App Sandbox の entitlement を確認"

# プライバシーマニフェスト（ファイルタイムスタンプ API を使うため必須）
[[ -f "$PRIVACY_MANIFEST" ]] || fail "PrivacyInfo.xcprivacy が見つかりません: ${PRIVACY_MANIFEST#$REPO_ROOT/}
  btime 読み取り（stat / .creationDate）は required reason API のため宣言が必要です。"
ok "PrivacyInfo.xcprivacy を確認"

# 署名（Apple Distribution + 3rd Party Mac Developer Installer が要る）
grep -q "DEVELOPMENT_TEAM" "$PROJECT_YML" || fail "project.yml に DEVELOPMENT_TEAM がありません"
security find-identity -v 2>/dev/null | grep -q "Apple Distribution" \
    || fail "「Apple Distribution」証明書がキーチェーンにありません"
security find-identity -v 2>/dev/null | grep -q "3rd Party Mac Developer Installer" \
    || warn "「3rd Party Mac Developer Installer」証明書が見つかりません（.pkg の書き出しに必要）"
ok "署名証明書を確認"

# ─── STEP 1: バージョン更新 ───────────────────────────────────
step "STEP 1/6: バージョン更新 (app/project.yml)"

read -r CURRENT_VERSION CURRENT_BUILD <<<"$(python3 - "$PROJECT_YML" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
v = re.search(r'CFBundleShortVersionString:\s*"([^"]+)"', c)
b = re.search(r'CFBundleVersion:\s*"([^"]+)"', c)
print(v.group(1) if v else "", b.group(1) if b else "")
PY
)"

[[ -n "$CURRENT_VERSION" && -n "$CURRENT_BUILD" ]] \
    || fail "project.yml からバージョンを読み取れませんでした"

# ASC は同一バージョン内でも build 番号の重複を拒否するため、必ず単調増加させる
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "現在  : $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "更新後: $VERSION (build $NEW_BUILD)"
echo ""

python3 - "$PROJECT_YML" "$CURRENT_VERSION" "$VERSION" "$CURRENT_BUILD" "$NEW_BUILD" <<'PY'
import sys
path, cur_v, new_v, cur_b, new_b = sys.argv[1:6]
c = open(path).read()
c = c.replace(f'CFBundleShortVersionString: "{cur_v}"',
              f'CFBundleShortVersionString: "{new_v}"', 1)
c = c.replace(f'CFBundleVersion: "{cur_b}"',
              f'CFBundleVersion: "{new_b}"', 1)
open(path, "w").write(c)
PY
ok "project.yml を更新しました"

# ─── STEP 2: xcodegen ─────────────────────────────────────────
step "STEP 2/6: xcodegen generate"

# Xcode 起動中の再生成は Package.resolved 消失やプロジェクト不整合の原因になる
if pgrep -x Xcode >/dev/null; then
    warn "Xcode が起動中です。"
    pause "  Xcode を完全終了してから Enter を押してください。"
fi
(cd "$APP_DIR" && xcodegen generate)
ok "Info.plist / entitlements を再生成しました"

# ─── STEP 3: リリースノート ───────────────────────────────────
step "STEP 3/6: リリースノートの確認"

# リリースごとの記録（docs/appstore/releases/mac/<version>.md）
RELEASE_NOTES_DOC="$REPO_ROOT/docs/appstore/releases/mac/${VERSION}.md"
if [[ ! -f "$RELEASE_NOTES_DOC" ]]; then
    pause "  リリース記録が見つかりません。以下を作成してください:

    ${BOLD}docs/appstore/releases/mac/${VERSION}.md${NC}${YELLOW}

  Promotional Text（日英）と What's New（日英）を記載。
  参考: docs/appstore/releases/mac/ の前バージョン"
    [[ -f "$RELEASE_NOTES_DOC" ]] || fail "${RELEASE_NOTES_DOC#$REPO_ROOT/} が作成されていません"
fi
ok "リリース記録を確認: docs/appstore/releases/mac/${VERSION}.md"

pause "  App Store の「今回のバージョンの新機能」を更新してください（ASC に反映される実体はこちら）:

    ${BOLD}fastlane/metadata/ja/release_notes.txt${NC}${YELLOW}
    ${BOLD}fastlane/metadata/en-US/release_notes.txt${NC}${YELLOW}

  description / keywords / promotional_text に変更があればついでに更新。"

for f in ja en-US; do
    notes="$REPO_ROOT/fastlane/metadata/$f/release_notes.txt"
    [[ -s "$notes" ]] || fail "$notes が空です"
done
ok "リリースノートを確認しました"

# ─── STEP 4: ビルド確認 ───────────────────────────────────────
step "STEP 4/6: Release 構成でのビルド確認"

xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' clean build 2>&1 | tail -5
ok "Release ビルドが通りました"

# ─── STEP 5: Archive → App Store Connect Upload ──────────────
step "STEP 5/6: Xcode Archive → App Store Connect Upload（手動・.pkg）"

open "$XCODEPROJ"
pause "  Xcode で以下を実行（スキーム: ${BOLD}Imanage${NC}${YELLOW} / 実行先: ${BOLD}My Mac${NC}${YELLOW}）:

  ${BOLD}Product → Archive${NC}${YELLOW}
    → ${BOLD}Distribute App${NC}${YELLOW}
    → ${BOLD}App Store Connect${NC}${YELLOW} を選択（Developer ID ではない）
    → ${BOLD}Upload${NC}${YELLOW}
    → Organizer でアップロード完了を確認

  ※ App Sandbox + Apple Distribution 署名で .pkg として書き出されます。
  ※ 完了後、App Store Connect のビルド一覧に「処理中」で表示されます。"

# ─── メタデータ投入（任意） ───────────────────────────────────
if confirm "fastlane deliver でメタデータ/スクショを ASC へ投入しますか？"; then
    : "${ASC_KEY_ID:?ASC_KEY_ID が未設定です}"
    : "${ASC_ISSUER_ID:?ASC_ISSUER_ID が未設定です}"
    : "${ASC_KEY_PATH:?ASC_KEY_PATH が未設定です}"
    [[ -f "$ASC_KEY_PATH" ]] || fail "API キーが見つかりません: $ASC_KEY_PATH"
    command -v fastlane >/dev/null || fail "fastlane が見つかりません（brew install fastlane）"

    (cd "$REPO_ROOT" && fastlane deliver \
        --api_key_path <(python3 -c "
import json, os
print(json.dumps({
    'key_id': os.environ['ASC_KEY_ID'],
    'issuer_id': os.environ['ASC_ISSUER_ID'],
    'key': open(os.environ['ASC_KEY_PATH']).read(),
    'in_house': False,
}))"))
    ok "メタデータを ASC へ投入しました"
else
    warn "メタデータ投入をスキップしました（ASC の Web 画面で入力してください）"
fi

# ─── STEP 6: git commit + tag + push ─────────────────────────
step "STEP 6/6: main ブランチに記録 + タグ作成"

git -C "$REPO_ROOT" add \
    app/project.yml \
    app/Imanage/Resources/Info.plist \
    app/Imanage/Imanage.entitlements \
    "docs/appstore/releases/mac/${VERSION}.md" \
    fastlane/ 2>/dev/null || true
git -C "$REPO_ROOT" commit -m "release: mas/v${VERSION} (build ${NEW_BUILD})" || true

TAG="mas/v${VERSION}"
if git -C "$REPO_ROOT" tag "$TAG" 2>/dev/null; then
    ok "タグ ${TAG} を作成しました"
else
    warn "タグ ${TAG} は既に存在します（スキップ）"
fi
git -C "$REPO_ROOT" push origin main
git -C "$REPO_ROOT" push origin "$TAG" 2>/dev/null || warn "タグ ${TAG} は origin に既に存在します（スキップ）"
ok "main ブランチを push しました"

# ─── 完了 ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Imanage (Mac App Store) ${VERSION} リリース準備完了！${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  タグ              : ${TAG} (build ${NEW_BUILD})"
echo "  App Store Connect : https://appstoreconnect.apple.com/"
echo ""
echo "  ASC でビルド処理完了後、バージョンにビルドを紐付けて「審査に提出」してください。"
