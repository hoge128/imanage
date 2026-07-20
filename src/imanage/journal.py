"""
journal — 操作ジャーナルと undo 実行モジュール

通常実行時: 副作用（ファイル移動・削除・サイドカー作成・ディレクトリ作成）を
インメモリで記録し、完了後にジャーナルファイルへ自動保存する。

undo 時: ジャーナルファイルを読み込み、操作を逆順に取り消す。
"""
import json
import os
import threading
import logging

from send2trash import send2trash
from imanage.i18n import _

logger = logging.getLogger("imanage.journal")

JOURNAL_PATH = os.path.expanduser("~/.local/state/imanage/last_operation.json")

_current = None


class Journal:
    def __init__(self):
        self._lock = threading.Lock()
        self.actions: list[dict] = []

    def record_move(self, src: str, dest: str) -> None:
        with self._lock:
            self.actions.append({
                "type": "move",
                "src": os.path.abspath(src),
                "dest": os.path.abspath(dest),
            })

    def record_trash(self, path: str) -> None:
        with self._lock:
            self.actions.append({"type": "trash", "path": os.path.abspath(path)})

    def record_sidecar_created(self, path: str) -> None:
        with self._lock:
            self.actions.append({"type": "sidecar_created", "path": os.path.abspath(path)})

    def record_mkdir(self, path: str) -> None:
        with self._lock:
            self.actions.append({"type": "mkdir", "path": os.path.abspath(path)})

    def save(self) -> None:
        """ジャーナルをファイルにアトミック書き込みする（サイレント）"""
        try:
            os.makedirs(os.path.dirname(JOURNAL_PATH), exist_ok=True)
            data = {"version": 1, "undone": False, "actions": self.actions}
            tmp = JOURNAL_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, JOURNAL_PATH)
        except Exception:
            pass  # ジャーナル書き込み失敗は無視（主処理に影響させない）

    def execute_undo(self) -> None:
        from imanage.btime_utils import btime_safe_move
        from imanage.progress import make_bar

        reversed_actions = list(reversed(self.actions))
        success = 0
        skipped = 0
        trashed = 0

        with make_bar(reversed_actions, desc=_("操作の取り消し")) as bar:
            for action in bar:
                t = action["type"]
                display = os.path.basename(action.get("dest", action.get("path", "")))
                bar.set_postfix_str(display, refresh=False)

                if t == "move":
                    src = action["src"]
                    dest = action["dest"]
                    if not os.path.exists(dest):
                        logger.warning(_("スキップ（ファイルが見つかりません）: {path}").format(path=dest))
                        skipped += 1
                        continue
                    if os.path.exists(src):
                        logger.warning(_("スキップ（移動先に既に存在）: {path}").format(path=src))
                        skipped += 1
                        continue
                    src_dir = os.path.dirname(src)
                    os.makedirs(src_dir, exist_ok=True)
                    if btime_safe_move(dest, src_dir):
                        logger.debug(_("戻し: {src} -> {dest}").format(src=dest, dest=src_dir))
                        success += 1
                    else:
                        logger.warning(_("スキップ（移動失敗）: {path}").format(path=dest))
                        skipped += 1

                elif t == "trash":
                    logger.info(_("ゴミ箱に移動済み: {path} — macOS のゴミ箱から手動で復元してください").format(path=action['path']))
                    trashed += 1

                elif t == "sidecar_created":
                    path = action["path"]
                    if os.path.exists(path):
                        try:
                            send2trash(path)
                            logger.debug(_("ゴミ箱へ移動: {path}").format(path=path))
                            success += 1
                        except Exception as e:
                            logger.warning(_("スキップ（ゴミ箱移動失敗）: {path}: {e}").format(path=path, e=e))
                            skipped += 1
                    else:
                        logger.warning(_("スキップ（ファイルが見つかりません）: {path}").format(path=path))
                        skipped += 1

                elif t == "mkdir":
                    path = action["path"]
                    if os.path.exists(path):
                        try:
                            send2trash(path)
                            logger.debug(_("ディレクトリをゴミ箱へ移動: {path}").format(path=path))
                        except Exception as e:
                            logger.warning(_("スキップ（ゴミ箱移動失敗）: {path}: {e}").format(path=path, e=e))

        parts = [_("{n} 件成功").format(n=success)]
        if skipped:
            parts.append(_("{n} 件スキップ").format(n=skipped))
        if trashed:
            parts.append(_("{n} 件要手動復元（ゴミ箱）").format(n=trashed))
        logger.info(_("取り消し完了（{parts}）").format(parts=_("／").join(parts)))

        # 二重 undo を防ぐためジャーナルを済みとしてマーク
        try:
            with open(JOURNAL_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            data["undone"] = True
            tmp = JOURNAL_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, JOURNAL_PATH)
        except Exception:
            pass


def init_journal() -> "Journal":
    """操作ジャーナルを初期化してシングルトンを返す"""
    global _current
    _current = Journal()
    return _current


def get_journal() -> "Journal | None":
    """現在のジャーナルを返す（未初期化なら None）"""
    return _current


def execute_undo_from_file() -> None:
    """ジャーナルファイルから直前の操作を取り消す"""
    if not os.path.isfile(JOURNAL_PATH):
        logger.info(_("取り消す操作がありません（ジャーナルが見つかりません）"))
        return

    try:
        with open(JOURNAL_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        logger.error(_("ジャーナルの読み込みに失敗しました: {e}").format(e=e))
        return

    if data.get("undone"):
        logger.info(_("直前の操作は既に取り消し済みです"))
        return

    if not data.get("actions"):
        logger.info(_("取り消す操作がありません"))
        return

    j = Journal()
    j.actions = data["actions"]
    j.execute_undo()
