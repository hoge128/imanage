#!/bin/zsh
set -e

APP_NAME="imanage"
VERSION="1.0.0"

# 実行形態をビルドするための仕組みです。
pyinstaller --onefile src/imanage/core.py --noconsole --name "${APP_NAME}-${VERSION}"
