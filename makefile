# Makefile
APP_NAME   = imanage
VERSION    = $(shell grep "^__version__ =" src/$(APP_NAME)/_version.py 2>/dev/null | sed "s/__version__ = version = '\\(.*\\)'/\\1/")
DIST_DIR   = dist
BIN_DIR    = ~/.local/bin
CONFIG_DIR = ~/.config/$(APP_NAME)
CONFIG_SRC = src/$(APP_NAME)/config.toml
CONFIG_DST = $(CONFIG_DIR)/config.toml
VENV       = .venv
PYTHON     = $(VENV)/bin/python3
PIP        = $(VENV)/bin/pip

# --- タスク定義 -------------------------

.PHONY: all build install clean setup deps release

# ビルド一括処理
all: clean build install

# システム依存関係 (macOS / Homebrew)
deps:
	@command -v brew >/dev/null 2>&1 || { echo "Error: Homebrew が見つかりません。https://brew.sh からインストールしてください。"; exit 1; }
	brew install exempi

# venv セットアップ
setup: deps
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -e .

# ビルド (PyInstaller)
build: setup
	@echo "=== Building $(APP_NAME) ==="
	$(VENV)/bin/pyinstaller --onedir src/imanage/__main__.py --name $(APP_NAME)-$(VERSION) \
		--specpath build \
		--hidden-import=PIL \
		--hidden-import=PIL.Image \
		--hidden-import=PIL.JpegImagePlugin \
		--hidden-import=libxmp \
		--hidden-import=libxmp.utils \
		--hidden-import=tomllib \
		--hidden-import=tomli \
		--hidden-import=tqdm \
		--hidden-import=tqdm.auto \
		--hidden-import=imanage.log \
		--add-data "$(abspath src/imanage/config.toml):imanage" \
		--paths src
	codesign --force --deep --sign - $(DIST_DIR)/$(APP_NAME)-$(VERSION)/$(APP_NAME)-$(VERSION)
	@echo "Build finished: $(DIST_DIR)/$(APP_NAME)-$(VERSION)/$(APP_NAME)-$(VERSION)"

# インストール (binへコピー + 設定ファイル配置)
install:
	@echo "=== Installing $(APP_NAME) ==="
	ln -sf $(abspath $(DIST_DIR)/$(APP_NAME)-$(VERSION)/$(APP_NAME)-$(VERSION)) $(BIN_DIR)/$(APP_NAME)
	@echo "Installed successfully: $(BIN_DIR)/$(APP_NAME)"
	@mkdir -p $(CONFIG_DIR)
	@if [ ! -f $(CONFIG_DST) ]; then \
		cp $(CONFIG_SRC) $(CONFIG_DST); \
		echo "Config installed: $(CONFIG_DST)"; \
	else \
		echo "Config already exists (skipped): $(CONFIG_DST)"; \
	fi
	@echo "Pre-warming dyld closure cache (初回起動を高速化)..."
	@$(BIN_DIR)/$(APP_NAME) -h > /dev/null 2>&1 || true
	@echo "Done."

# クリーンアップ
clean:
	@echo "=== Cleaning build files ==="
	rm -rf build $(DIST_DIR) *.spec

# --- テスト -------------------------

TEST_DIR = $(abspath test)
TEST_ZIP = $(abspath test.zip)

.PHONY: test-reset test-run test

# test.zip からテストデータを再展開
test-reset:
	@echo "=== Resetting test data ==="
	rm -rf $(TEST_DIR) __MACOSX
	unzip -q $(TEST_ZIP)
	rm -rf __MACOSX
	@echo "Done"

# test/ で imanage を実行し、XMP 生成を確認
test-run:
	@echo "=== Running imanage ==="
	(cd $(TEST_DIR) && PYTHONPATH=$(abspath src) $(abspath $(PYTHON)) -m imanage)
	@echo ""
	@echo "=== Generated XMP files ==="
	@find $(TEST_DIR) -name "*.xmp" | sort

# リセット → 実行を一括
test: test-reset test-run

# バージョンを指定してリリースビルドを作成する
# 使い方: make release VERSION_TAG=v1.0.1
release:
	@if [ -z "$(VERSION_TAG)" ]; then echo "Usage: make release VERSION_TAG=v1.0.1"; exit 1; fi
	git tag $(VERSION_TAG)
	$(VENV)/bin/pip install -e . -q
	$(MAKE) all
