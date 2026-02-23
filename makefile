# Makefile
APP_NAME = imanage
VERSION  = 1.0.0
DIST_DIR = dist
BIN_DIR  = ~/.local/bin

# --- タスク定義 -------------------------

.PHONY: all build install clean

# ビルド一括処理
all: clean build install

# ビルド (PyInstaller)
build:
	@echo "=== Building $(APP_NAME) ==="
	pyinstaller --onefile src/imanage/core.py --name $(APP_NAME)-$(VERSION)
	@echo "Build finished: $(DIST_DIR)/$(APP_NAME)-$(VERSION)"

# インストール (binへコピー)
install:
	@echo "=== Installing $(APP_NAME) ==="
	ln -sf $(abspath $(DIST_DIR)/$(APP_NAME)-$(VERSION)) $(BIN_DIR)/$(APP_NAME)
	@echo "Installed successfully: $(BIN_DIR)/$(APP_NAME)"

# クリーンアップ
clean:
	@echo "=== Cleaning build files ==="
	rm -rf build $(DIST_DIR) *.spec
