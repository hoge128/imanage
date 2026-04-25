#!/usr/bin/ python3
import os, sys, shutil, glob, argparse
from imanage.btime_utils import btime_safe_move
from imanage import journal as _journal
from collections import deque
from datetime import datetime

try:
    import tomllib
except ImportError:
    import tomli as tomllib

import logging
from imanage.progress import make_bar

logger = logging.getLogger("imanage.core")


def load_config():
    default = {"organize": {"hierarchy": ["maker", "model", "date"]}}

    if getattr(sys, 'frozen', False):
        bundled = os.path.join(sys._MEIPASS, "imanage", "config.toml")
    else:
        bundled = os.path.join(os.path.dirname(__file__), "config.toml")
    global_path = os.path.expanduser("~/.config/imanage/config.toml")
    local_path = os.path.join(os.getcwd(), ".imanage.toml")

    config = default.copy()
    for cfg_path in [bundled, global_path, local_path]:
        if os.path.isfile(cfg_path):
            with open(cfg_path, "rb") as f:
                loaded = tomllib.load(f)
            for key, value in loaded.items():
                if key in config and isinstance(config[key], dict) and isinstance(value, dict):
                    config[key].update(value)
                else:
                    config[key] = value
    return config


def get_exif_fields(jpg_path):
    from PIL import Image
    TAGS = {
        "maker": 271,
        "model": 272,
        "creator": 315,
        "lens": 42036,
        "focal_length": 37386,
        "shutter_speed": 33434,
    }
    result = {}
    try:
        img = Image.open(jpg_path)
        exif_data = img._getexif() or {}
    except Exception:
        exif_data = {}

    for field, tag_id in TAGS.items():
        val = exif_data.get(tag_id)
        if val is None:
            result[field] = "Unknown"
        elif field == "focal_length":
            try:
                result[field] = "{}mm".format(int(float(val)))
            except Exception:
                result[field] = str(val)
        elif field == "shutter_speed":
            try:
                fval = float(val)
                if fval >= 1:
                    result[field] = "{}s".format(int(fval))
                else:
                    result[field] = "1/{}s".format(int(round(1 / fval)))
            except Exception:
                result[field] = str(val)
        else:
            result[field] = str(val).strip().replace("\x00", "").replace("/", "-").replace(" ", "_") or "Unknown"

    # 撮影日時: EXIF DateTimeOriginal(36867) → DateTimeDigitized(36868) → btime
    exif_date = exif_data.get(36867) or exif_data.get(36868)
    if exif_date:
        try:
            result["date"] = datetime.strptime(str(exif_date)[:19], "%Y:%m:%d %H:%M:%S").strftime(date_format)
        except Exception:
            exif_date = None
    if not exif_date:
        stat = os.stat(jpg_path)
        try:
            timestamp = stat.st_birthtime
        except AttributeError:
            timestamp = stat.st_mtime
        result["date"] = datetime.fromtimestamp(timestamp).strftime(date_format)

    return result


RETOUCH_KEYWORDS = ["Lightroom", "Photoshop", "Capture One", "DxO", "Luminar", "ON1", "Darktable", "RawTherapee", "GIMP", "Affinity"]


def is_retouched(jpg_path):
    from PIL import Image
    try:
        exif = Image.open(jpg_path)._getexif() or {}
        software = str(exif.get(305, ""))
        return any(kw.lower() in software.lower() for kw in RETOUCH_KEYWORDS)
    except Exception:
        return False


def _resolve_fields(file_path, stem, exif_cache):
    if stem in exif_cache:
        return exif_cache[stem]
    # キャッシュにない場合（JPG 対応なし RAW など）はファイル自身から直接 EXIF を読む
    return get_exif_fields(file_path)


def build_exif_cache(jpg_dir_path):
    cache = {}
    if not os.path.isdir(jpg_dir_path):
        return cache
    files = list(os.listdir(jpg_dir_path))
    with make_bar(files, desc="EXIFキャッシュ") as bar:
        for _file in bar:
            stem, dot_ext = os.path.splitext(_file)
            if dot_ext.lstrip(".") not in target_jpg_extensions:
                continue
            file_path = os.path.join(jpg_dir_path, _file)
            if not os.path.isfile(file_path):
                continue
            bar.set_postfix_str(_file, refresh=False)
            cache[stem] = get_exif_fields(file_path)
    return cache


class BaseCommand:
    yes: bool = False
    needs_global_confirm: bool = True
    def setup(self): pass
    def preview(self): pass
    def execute(self): pass
    def teardown(self): pass


class OrganizeCommand(BaseCommand):
    def preview(self):
        path = os.getcwd()
        all_exts = target_jpg_extensions | target_raw_extensions
        loose = [f for f in os.listdir(path)
                 if os.path.isfile(os.path.join(path, f)) and not f.startswith('.')
                 and os.path.splitext(f)[1].lstrip('.').lower() in all_exts]
        hierarchy = _config.get("organize", {}).get("hierarchy", ["date"])
        logger.info("[処理内容]")
        if loose:
            # JPG を先に処理することで RAW が同名 JPG の EXIF を参照できるようにソート
            loose_sorted = sorted(loose, key=lambda f: (
                0 if os.path.splitext(f)[1].lstrip('.').lower() in target_jpg_extensions else 1, f
            ))
            loose_exif = {}
            dest_groups = {}
            with make_bar(loose_sorted, desc="EXIFスキャン") as bar:
                for f in bar:
                    bar.set_postfix_str(f, refresh=False)
                    ext = os.path.splitext(f)[1].lstrip('.').lower()
                    fp = os.path.join(path, f)
                    stem = os.path.splitext(f)[0]
                    if ext in target_jpg_extensions:
                        try:
                            loose_exif[stem] = get_exif_fields(fp)
                        except Exception:
                            pass
                        dir_name = retouch_dir_name if is_retouched(fp) else jpg_dir_name
                    else:
                        dir_name = raw_dir_name
                    fields = _resolve_fields(fp, stem, loose_exif)
                    dest_key = os.path.join(*[fields.get(h, "Unknown") for h in hierarchy], dir_name)
                    dest_groups[dest_key] = dest_groups.get(dest_key, 0) + 1
            self._exif_cache = loose_exif

            logger.info(f"  ルーズファイル {len(loose)} 件を振り分け後、以下へ整理します:")
            for dest, count in sorted(dest_groups.items()):
                logger.info(f"    {dest}/  ({count} 件)")
            return

        # ルーズファイルなし → EXIF を読んで実際の移動先を表示
        jpg_dir = os.path.join(path, jpg_dir_name)
        retouch_dir = os.path.join(path, retouch_dir_name)
        exif_cache = build_exif_cache(jpg_dir)
        if os.path.isdir(retouch_dir):
            exif_cache.update(build_exif_cache(retouch_dir))
        self._exif_cache = exif_cache

        all_files = []
        for dir_path, dir_name in [
            (os.path.join(path, jpg_dir_name), jpg_dir_name),
            (os.path.join(path, raw_dir_name), raw_dir_name),
            (os.path.join(path, retouch_dir_name), retouch_dir_name),
        ]:
            if not os.path.isdir(dir_path):
                continue
            for f in os.listdir(dir_path):
                if f != ".DS_Store" and os.path.isfile(os.path.join(dir_path, f)):
                    all_files.append((dir_path, dir_name, f))

        if not all_files:
            logger.info("  整理対象のファイルがありません")
            return

        dest_groups = {}
        for dir_path, dir_name, f in all_files:
            fields = _resolve_fields(os.path.join(dir_path, f), os.path.splitext(f)[0], exif_cache)
            dest_key = os.path.join(*[fields.get(h, "Unknown") for h in hierarchy], dir_name)
            dest_groups[dest_key] = dest_groups.get(dest_key, 0) + 1

        total = sum(dest_groups.values())
        logger.info(f"  {total} 件のファイルを以下へ整理します:")
        for dest, count in sorted(dest_groups.items()):
            logger.info(f"    {dest}/  ({count} 件)")

    def setup(self):
        self.iCon = dir_structure()
        self.config = _config

    def execute(self):
        self.iCon.date_organize(self.config, exif_cache=getattr(self, '_exif_cache', None))

    def teardown(self):
        for d in [self.iCon.jpg_dir_path, self.iCon.raw_dir_path, self.iCon.retouch_dir_path]:
            try:
                os.rmdir(d)
            except OSError:
                pass


class DeleteCommand(BaseCommand):
    def preview(self):
        path = os.getcwd()
        jpg_dir = os.path.join(path, jpg_dir_name)
        raw_dir = os.path.join(path, raw_dir_name)
        logger.info("[処理内容]")
        if not (os.path.isdir(jpg_dir) and os.path.isdir(raw_dir)):
            logger.info(f"  ファイルを振り分けます")
            logger.info(f"    JPG/現像済み → {os.path.join(path, jpg_dir_name)}/")
            logger.info(f"    RAW          → {raw_dir}/")
            logger.info(f"  振り分け後、孤立 RAW をゴミ箱に移動します")
            return
        iCon = imageContainer(path)
        orphan_files = _count_orphan_raws(iCon)
        # 孤立 RAW に対応する .xmp サイドカーも削除対象になるためカウントする
        orphan_stems = {os.path.splitext(f)[0] for f in orphan_files}
        orphan_xmp = [f for f in os.listdir(raw_dir)
                      if f.endswith('.xmp') and os.path.splitext(f)[0] in orphan_stems]
        xmp_note = f" (XMP サイドカー {len(orphan_xmp)} 件を含む)" if orphan_xmp else ""
        logger.info(f"  孤立 RAW {len(orphan_files)} 件{xmp_note}をゴミ箱に移動します")
        for f in orphan_files:
            logger.info(f"    {os.path.join(raw_dir, f)}")

    def setup(self):
        self.iCon = dir_structure()
        self.iCon.imagev()

    def execute(self):
        self.iCon.jremove()


class SyncCommand(BaseCommand):
    def preview(self):
        path = os.getcwd()
        jpg_dir = os.path.join(path, jpg_dir_name)
        raw_dir = os.path.join(path, raw_dir_name)
        logger.info("[処理内容]")
        if not (os.path.isdir(jpg_dir) and os.path.isdir(raw_dir)):
            logger.info(f"  ファイルを振り分けます")
            logger.info(f"    JPG/現像済み → {jpg_dir}/")
            logger.info(f"    RAW          → {raw_dir}/")
            logger.info(f"  振り分け後、孤立 RAW 削除 + XMP 同期を行います")
            return
        iCon = imageContainer(path)
        orphan_files = _count_orphan_raws(iCon)
        orphan_stems = {os.path.splitext(f)[0] for f in orphan_files}
        orphan_xmp = [f for f in os.listdir(raw_dir)
                      if f.endswith('.xmp') and os.path.splitext(f)[0] in orphan_stems]
        xmp_note = f" (XMP サイドカー {len(orphan_xmp)} 件を含む)" if orphan_xmp else ""
        logger.info(f"  孤立 RAW {len(orphan_files)} 件{xmp_note}をゴミ箱に移動します")
        for f in orphan_files:
            logger.info(f"    {os.path.join(raw_dir, f)}")

        # JPG XMP から Rating/Label を読んで同期内容をプレビュー
        from imanage.xmp_handler import read_xmp_meta
        jpg_files = [
            os.path.join(jpg_dir, f) for f in os.listdir(jpg_dir)
            if f != ".DS_Store" and os.path.isfile(os.path.join(jpg_dir, f))
            and os.path.splitext(f)[1].lstrip('.').lower() in target_jpg_extensions
        ] if os.path.isdir(jpg_dir) else []
        with_meta = 0
        no_xmp = 0
        no_meta = 0
        with make_bar(jpg_files, desc="XMPスキャン") as bar:
            for fp in bar:
                bar.set_postfix_str(os.path.basename(fp), refresh=False)
                result = read_xmp_meta(fp, meta_target)
                if result is None:
                    no_xmp += 1
                elif any(result.values()):
                    with_meta += 1
                else:
                    no_meta += 1
        logger.info(f"  JPG {len(jpg_files)} 件の XMP を {raw_dir}/ 配下の .xmp サイドカーへ同期します")
        if with_meta:
            logger.info(f"    Rating/Label あり: {with_meta} 件")
        if no_meta:
            logger.info(f"    Rating/Label 未設定: {no_meta} 件")
        if no_xmp:
            logger.info(f"    XMP なし (未処理): {no_xmp} 件")

    def setup(self):
        self.iCon = dir_structure()
        self.iCon.imagev()

    def execute(self):
        self.iCon.jremove()
        self.iCon.syncmeta()


class DefaultCommand(BaseCommand):
    def preview(self):
        from imanage.xmp_handler import check_xmp_applied
        path = os.getcwd()
        files = [f for f in os.listdir(path)
                 if os.path.isfile(os.path.join(path, f)) and not f.startswith('.')]
        loose_jpg = [f for f in files if os.path.splitext(f)[1].lstrip('.').lower() in target_jpg_extensions]
        loose_raw = [f for f in files if os.path.splitext(f)[1].lstrip('.').lower() in target_raw_extensions]
        logger.info("[処理内容]")
        if loose_jpg:
            retouch_count = 0
            with make_bar(loose_jpg, desc="JPGスキャン") as bar:
                for f in bar:
                    bar.set_postfix_str(f, refresh=False)
                    if is_retouched(os.path.join(path, f)):
                        retouch_count += 1
            normal_count = len(loose_jpg) - retouch_count
            logger.info(f"  JPG {len(loose_jpg)} 件を振り分けます")
            if normal_count:
                logger.info(f"    通常    → {os.path.join(path, jpg_dir_name)}/  ({normal_count} 件)")
            if retouch_count:
                logger.info(f"    現像済み → {os.path.join(path, retouch_dir_name)}/  ({retouch_count} 件)")
        if loose_raw:
            logger.info(f"  RAW {len(loose_raw)} 件 → {os.path.join(path, raw_dir_name)}/")

        # XMP 処理状況を確認（ルーズ JPG + 既存 jpg/retouch ディレクトリ内）
        xmp_pending = len(loose_jpg)  # ルーズファイルは未処理確定
        xmp_done = 0
        dir_jpg_files = []
        for dn in [jpg_dir_name, retouch_dir_name]:
            dp = os.path.join(path, dn)
            if not os.path.isdir(dp):
                continue
            for f in os.listdir(dp):
                if os.path.splitext(f)[1].lstrip('.').lower() not in target_jpg_extensions:
                    continue
                fp = os.path.join(dp, f)
                if os.path.isfile(fp):
                    dir_jpg_files.append(fp)
        with make_bar(dir_jpg_files, desc="XMP確認") as bar:
            for fp in bar:
                bar.set_postfix_str(os.path.basename(fp), refresh=False)
                if check_xmp_applied(fp):
                    xmp_done += 1
                else:
                    xmp_pending += 1

        if xmp_pending:
            logger.info(f"  XMP 書き込み: {xmp_pending} 件")
        if xmp_done:
            logger.info(f"  XMP 処理済み: {xmp_done} 件 (スキップ)")

    def setup(self):
        self.iCon = dir_structure()
        # base_dir に未振り分けの画像ファイルが残っているか確認
        all_exts = target_jpg_extensions | target_raw_extensions
        loose = [
            f for f in os.listdir(self.iCon.base_dir)
            if os.path.isfile(os.path.join(self.iCon.base_dir, f))
            and not f.startswith('.')
            and os.path.splitext(f)[1].lstrip('.').lower() in all_exts
        ]
        from imanage.xmp_handler import is_already_applied
        xmp_done = is_already_applied(
            [self.iCon.jpg_dir_path, self.iCon.retouch_dir_path],
            self.iCon.raw_dir_path,
            target_jpg_extensions,
        )
        if loose or not xmp_done:
            self.iCon.imagev()
        else:
            logger.info("既に処理済みです。スキップします。")


def find_pair_dirs(root: str) -> list:
    result = []
    for dirpath, dirnames, _ in os.walk(root):
        if jpg_dir_name in dirnames and raw_dir_name in dirnames:
            result.append(dirpath)
    return sorted(result)


def _count_orphan_raws(iCon):
    j_stems = {os.path.splitext(f)[0] for f in os.listdir(iCon.jpg_dir_path) if f != ".DS_Store"}
    if os.path.isdir(iCon.retouch_dir_path):
        j_stems |= {os.path.splitext(f)[0] for f in os.listdir(iCon.retouch_dir_path) if f != ".DS_Store"}
    raw_files_by_stem = {}
    for f in os.listdir(iCon.raw_dir_path):
        if f == ".DS_Store":
            continue
        stem, dot_ext = os.path.splitext(f)
        if dot_ext.lstrip(".").lower() in target_raw_extensions:
            raw_files_by_stem.setdefault(stem, []).append(f)
    orphan_stems = set(raw_files_by_stem) - j_stems
    orphan_files = []
    for stem in sorted(orphan_stems):
        orphan_files.extend(raw_files_by_stem[stem])
    return orphan_files


def _print_preview(root: str, pair_dirs: list):
    logger.info(f"\n対象ディレクトリ: {len(pair_dirs)} 件\n")
    total_orphan = 0
    total_jpg = 0
    total_raw = 0
    for i, pair_dir in enumerate(pair_dirs, 1):
        iCon = imageContainer(pair_dir)
        jpg_count = len([f for f in os.listdir(iCon.jpg_dir_path) if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.jpg_dir_path, f))])
        raw_count = len([f for f in os.listdir(iCon.raw_dir_path) if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.raw_dir_path, f))])
        orphan_files = _count_orphan_raws(iCon)
        rel = os.path.relpath(pair_dir, root)
        line = f"  [{i}] {rel}\n      JPG: {jpg_count}  RAW: {raw_count}  孤立RAW: {len(orphan_files)}"
        if orphan_files:
            line += "  → " + " ".join(orphan_files)
        logger.info(line)
        total_jpg += jpg_count
        total_raw += raw_count
        total_orphan += len(orphan_files)
    logger.info(f"\n  合計 孤立RAW: {total_orphan} 件  XMP 同期対象: {total_jpg} 件\n")


def _print_meta_preview(root: str, pending: list, applied: list):
    total = len(pending) + len(applied)
    logger.info(f"\nメタデータ未適用: {len(pending)} 件 / 全 {total} 件\n")
    for i, pair_dir in enumerate(pending, 1):
        iCon = imageContainer(pair_dir)
        jpg_count = len([
            f for f in os.listdir(iCon.jpg_dir_path)
            if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.jpg_dir_path, f))
        ]) if os.path.isdir(iCon.jpg_dir_path) else 0
        raw_count = len([
            f for f in os.listdir(iCon.raw_dir_path)
            if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.raw_dir_path, f))
        ]) if os.path.isdir(iCon.raw_dir_path) else 0
        rel = os.path.relpath(pair_dir, root)
        logger.info(f"  [{i}] {rel}  JPG: {jpg_count}  RAW: {raw_count}")
    if applied:
        logger.info(f"\n適用済み (スキップ): {len(applied)} 件")
    logger.info("")


def _select_dirs(pending: list) -> list:
    while True:
        ans = input("適用するディレクトリ番号を入力 (例: 1 2 3 / all / q): ").strip().lower()
        if ans == 'q':
            return []
        if ans == 'all':
            return pending
        try:
            indices = [int(x) - 1 for x in ans.replace(',', ' ').split()]
            selected = [pending[i] for i in indices if 0 <= i < len(pending)]
            if selected:
                return selected
        except ValueError:
            pass
        print("入力が正しくありません。再入力してください。")


class MetaCommand(BaseCommand):
    needs_global_confirm: bool = False  # 独自のインタラクションで確認する

    def preview(self):
        cwd = os.getcwd()
        basename = os.path.basename(cwd)
        if basename in (jpg_dir_name, raw_dir_name):
            self._preview_mode = "single"
            parent = os.path.dirname(cwd)
            iCon = imageContainer(parent)
            jpg_count = sum(1 for f in os.listdir(iCon.jpg_dir_path)
                            if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.jpg_dir_path, f))) \
                if os.path.isdir(iCon.jpg_dir_path) else 0
            raw_count = sum(1 for f in os.listdir(iCon.raw_dir_path)
                            if f != ".DS_Store" and os.path.isfile(os.path.join(iCon.raw_dir_path, f))) \
                if os.path.isdir(iCon.raw_dir_path) else 0
            logger.info("[処理内容]")
            logger.info(f"  JPG {jpg_count} 件 ({iCon.jpg_dir_path}/) の XMP を")
            logger.info(f"  RAW {raw_count} 件 ({iCon.raw_dir_path}/) の .xmp サイドカーへ書き込みます")
        else:
            self._preview_mode = "batch"
            self._root = cwd
            self._pair_dirs = find_pair_dirs(cwd)
            if not self._pair_dirs:
                logger.info("[処理内容] jpg/raw 構造を持つディレクトリが見つかりませんでした")
                return
            from imanage.xmp_handler import is_already_applied
            self._pending = []
            self._applied = []
            for pair_dir in self._pair_dirs:
                iCon = imageContainer(pair_dir)
                if is_already_applied(
                    [iCon.jpg_dir_path, iCon.retouch_dir_path],
                    iCon.raw_dir_path,
                    target_jpg_extensions,
                ):
                    self._applied.append(pair_dir)
                else:
                    self._pending.append(pair_dir)
            _print_meta_preview(self._root, self._pending, self._applied)

    def setup(self):
        cwd = os.getcwd()
        basename = os.path.basename(cwd)
        if basename in (jpg_dir_name, raw_dir_name):
            self.mode = "single"
            parent = os.path.dirname(cwd)
            self.iCon = imageContainer(parent)
        else:
            self.mode = "batch"
            self.root = cwd
            # preview() でキャッシュ済みなら再計算しない
            self.pair_dirs = getattr(self, '_pair_dirs', None) or find_pair_dirs(cwd)
            if not self.pair_dirs:
                logger.info("jpg/raw 構造を持つディレクトリが見つかりませんでした")
                sys.exit(0)

    def execute(self):
        if self.mode == "single":
            self._apply_single()
        else:
            self._apply_batch()

    def _apply_single(self):
        from imanage.xmp_handler import write_exif_to_xmp
        write_exif_to_xmp(
            [self.iCon.jpg_dir_path, self.iCon.retouch_dir_path],
            self.iCon.raw_dir_path,
            target_jpg_extensions,
            target_raw_extensions,
        )

    def _apply_batch(self):
        from imanage.xmp_handler import write_exif_to_xmp, is_already_applied
        # preview() でキャッシュ済みなら再利用
        if hasattr(self, '_pending'):
            pending = self._pending
            applied = self._applied
        else:
            pending = []
            applied = []
            for pair_dir in self.pair_dirs:
                iCon = imageContainer(pair_dir)
                if is_already_applied(
                    [iCon.jpg_dir_path, iCon.retouch_dir_path],
                    iCon.raw_dir_path,
                    target_jpg_extensions,
                ):
                    applied.append(pair_dir)
                else:
                    pending.append(pair_dir)
            _print_meta_preview(self.root, pending, applied)

        if not pending:
            logger.info("すべてのディレクトリに既にメタデータが適用されています")
            return

        if self.yes:
            selected = pending
        else:
            selected = _select_dirs(pending)
        if not selected:
            print("中止しました")
            return

        with make_bar(selected, desc="メタデータ適用", unit="dir") as bar:
            for pair_dir in bar:
                bar.set_postfix_str(os.path.basename(pair_dir), refresh=False)
                iCon = imageContainer(pair_dir)
                write_exif_to_xmp(
                    [iCon.jpg_dir_path, iCon.retouch_dir_path],
                    iCon.raw_dir_path,
                    target_jpg_extensions,
                    target_raw_extensions,
                )


class RecursiveCommand(BaseCommand):
    def __init__(self, root: str):
        self.root = os.path.abspath(root)
        self.pair_dirs = None

    def preview(self):
        if self.pair_dirs is None:
            self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            logger.info("[処理内容] jpg/raw 構造を持つディレクトリが見つかりませんでした")
            return
        _print_preview(self.root, self.pair_dirs)

    def setup(self):
        if self.pair_dirs is None:
            self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            logger.info("jpg/raw 構造を持つディレクトリが見つかりませんでした")
            sys.exit(0)

    def execute(self):
        with make_bar(self.pair_dirs, desc="ディレクトリ処理", unit="dir") as bar:
            for pair_dir in bar:
                bar.set_postfix_str(os.path.basename(pair_dir), refresh=False)
                iCon = imageContainer(pair_dir)
                iCon.imagev()
                iCon.jremove()
                iCon.syncmeta()


class RestoreRawDatetimeCommand(BaseCommand):
    def __init__(self, root: str):
        self.root = os.path.abspath(root)
        self.pair_dirs = None

    def _collect_pairs(self):
        from imanage.xmp_handler import find_jpg_raw_pairs
        all_pairs = []
        for pair_dir in self.pair_dirs:
            iCon = imageContainer(pair_dir)
            all_pairs.extend(find_jpg_raw_pairs(
                iCon.jpg_dir_path, iCon.raw_dir_path,
                target_jpg_extensions, target_raw_extensions,
            ))
        return all_pairs

    def preview(self):
        if self.pair_dirs is None:
            self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            logger.info("[処理内容] jpg/raw 構造を持つディレクトリが見つかりませんでした")
            return
        from imanage.xmp_handler import find_jpg_raw_pairs
        total = 0
        logger.info(f"\n[RAW から DateTimeOriginal を復元]\n対象ディレクトリ: {len(self.pair_dirs)} 件\n")
        for i, pair_dir in enumerate(self.pair_dirs, 1):
            iCon = imageContainer(pair_dir)
            pairs = find_jpg_raw_pairs(
                iCon.jpg_dir_path, iCon.raw_dir_path,
                target_jpg_extensions, target_raw_extensions,
            )
            rel = os.path.relpath(pair_dir, self.root)
            logger.info(f"  [{i}] {rel}  JPG-RAW ペア: {len(pairs)} 件")
            total += len(pairs)
        logger.info(f"\n  合計: {total} 件の JPG を復元対象とします\n")

    def setup(self):
        if self.pair_dirs is None:
            self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            logger.info("jpg/raw 構造を持つディレクトリが見つかりませんでした")
            sys.exit(0)

    def execute(self):
        from imanage.xmp_handler import restore_datetime_from_raw
        from concurrent.futures import ThreadPoolExecutor, as_completed as _as_completed
        all_pairs = self._collect_pairs()
        if not all_pairs:
            logger.info("復元対象のペアが見つかりませんでした")
            return
        with ThreadPoolExecutor() as executor:
            futures = {executor.submit(restore_datetime_from_raw, jpg, raw): jpg
                       for jpg, raw in all_pairs}
            with make_bar(_as_completed(futures), total=len(futures), desc="DateTimeOriginal 復元") as bar:
                for future in bar:
                    jpg = futures[future]
                    bar.set_postfix_str(os.path.basename(jpg), refresh=False)
                    try:
                        future.result()
                    except Exception as e:
                        logger.error(f"復元エラー ({os.path.basename(jpg)}): {e}")


def resolve_command(args):
    if args.restore_raw_datetime is not None:
        return RestoreRawDatetimeCommand(args.restore_raw_datetime)
    if args.recursive is not None:
        return RecursiveCommand(args.recursive)
    if args.meta:
        return MetaCommand()
    if args.organize:
        return OrganizeCommand()
    if args.delete:
        return DeleteCommand()
    if args.sync:
        return SyncCommand()
    return DefaultCommand()


def main():
    global _config, jpg_dir_name, raw_dir_name, retouch_dir_name, date_format
    global target_jpg_extensions, target_raw_extensions, meta_target

    _config = load_config()
    jpg_dir_name          = _config["jpg_dir_name"]
    raw_dir_name          = _config["raw_dir_name"]
    retouch_dir_name      = _config["retouch_dir_name"]
    date_format           = _config["date_format"]
    target_jpg_extensions = set(_config["target_jpg_extensions"])
    target_raw_extensions = set(_config["target_raw_extensions"])
    meta_target           = _config.get("meta_target", ["Rating", "Label"])

    parser = argparse.ArgumentParser(description='Photographer Tool')
    parser.add_argument('-d', '--delete', action="store_true", help="jpg ディレクトリに存在しない raw ファイルを削除する")
    parser.add_argument('-s', '--sync', action="store_true", help="jpg の XMP メタデータを同名 raw ファイルに同期する")
    parser.add_argument('-l', '--link', action="store_true", help="(未使用)")
    parser.add_argument('-o', '--organize', action="store_true", help="jpg/raw を作成日時ごとの日付フォルダ (YYYYMMDD/jpg, YYYYMMDD/raw) に仕分ける")
    parser.add_argument('-R', '--recursive', metavar='PATH', nargs='?', const='.', help="PATH 配下の jpg/raw 構造を持つすべてのディレクトリに -s を適用する")
    parser.add_argument('-RRR', '--restore-raw-datetime', metavar='PATH', nargs='?', const='.', help="ペアの RAW から DateTimeOriginal/Digitized を JPG EXIF に復元する")
    parser.add_argument('-q', '--quiet', action='store_true', help="エラーのみ出力する（スクリプト用）")
    parser.add_argument('-v', '--verbose', action='store_true', help="ファイル単位の処理詳細も表示する")
    parser.add_argument('--log-file', metavar='PATH', nargs='?',
                        const=os.path.expanduser("~/.local/state/imanage/imanage.log"),
                        help="ログをファイルに出力する（PATH 省略時: ~/.local/state/imanage/imanage.log）")
    parser.add_argument('-m', '--meta', action='store_true', help="メタデータが未適用のファイルに XMP を書き込む")
    parser.add_argument('--undo', action='store_true', help="直前の操作を取り消す")
    parser.add_argument('-y', '--yes', action='store_true', help="確認プロンプトをスキップして即実行する")
    args = parser.parse_args()

    from imanage.log import setup_logging
    from imanage.progress import set_quiet
    setup_logging(quiet=args.quiet, verbose=args.verbose, log_file=args.log_file)
    set_quiet(args.quiet)

    if args.undo:
        _journal.execute_undo_from_file()
        return

    cmd = resolve_command(args)
    cmd.yes = args.yes
    cmd.preview()
    if not args.yes and cmd.needs_global_confirm:
        answer = input("\n続行しますか？ [y/N]: ").strip().lower()
        if answer != 'y':
            print("中止しました")
            return

    _journal.init_journal()
    cmd.setup()
    cmd.execute()
    cmd.teardown()
    _journal.get_journal().save()
    logger.info("\nやり直したい場合は: imanage --undo")


def _has_target_files(dir_path):
    if not os.path.isdir(dir_path):
        return False
    all_exts = target_jpg_extensions | target_raw_extensions
    return any(
        os.path.splitext(f)[1].lstrip(".").lower() in all_exts
        for f in os.listdir(dir_path)
        if os.path.isfile(os.path.join(dir_path, f))
    )


def dir_structure():
    path = os.getcwd()

    if not any(_has_target_files(d) for d in [
        path,
        os.path.join(path, jpg_dir_name),
        os.path.join(path, raw_dir_name),
        os.path.join(path, retouch_dir_name),
    ]):
        logger.info("対象ファイルが見つかりません。処理をスキップします。")
        sys.exit(0)

    current_dirs = {_file for _file in os.listdir(path) if os.path.isdir(os.path.join(path, _file))}
    if {jpg_dir_name, raw_dir_name} <= current_dirs:
        iCon = imageContainer()
    else:
        j = _journal.get_journal()
        for _dir in [jpg_dir_name, raw_dir_name, retouch_dir_name]:
            abs_dir = os.path.join(path, _dir)
            dir_is_new = not os.path.isdir(abs_dir)
            os.makedirs(_dir, exist_ok=True)
            if dir_is_new and j:
                j.record_mkdir(abs_dir)
        iCon = imageContainer()
        skipped = []
        files = list(os.listdir(os.getcwd()))
        with make_bar(files, desc="ファイル振り分け") as bar:
            for _file in bar:
                bar.set_postfix_str(_file, refresh=False)
                ext = os.path.splitext(_file)[1].lstrip(".")
                file_path = os.path.join(os.getcwd(), _file)
                if ext in target_jpg_extensions:
                    dest = iCon.retouch_dir_path if is_retouched(file_path) else iCon.jpg_dir_path
                    if btime_safe_move(file_path, dest):
                        if j:
                            j.record_move(file_path, os.path.join(dest, _file))
                    else:
                        skipped.append(file_path)
                elif ext in target_raw_extensions:
                    if btime_safe_move(file_path, iCon.raw_dir_path):
                        if j:
                            j.record_move(file_path, os.path.join(iCon.raw_dir_path, _file))
                    else:
                        skipped.append(file_path)
                elif os.path.isfile(file_path) and not _file.startswith("."):
                    logger.warning(f"スキップ: {_file} は処理されません（対象外の拡張子）")
        if skipped:
            logger.warning(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                logger.warning(f"  {f}")
    return iCon


class imageContainer:
    def __init__(self, base_dir: str = None):
        base = os.path.abspath(base_dir) if base_dir else os.getcwd()
        self.base_dir = base
        self.jpg_dir_path = os.path.join(base, jpg_dir_name)
        self.raw_dir_path = os.path.join(base, raw_dir_name)
        self.retouch_dir_path = os.path.join(base, retouch_dir_name)

    """
    jpg, raw の仕分け
    """
    def imagev(self):
        skipped = []
        j = _journal.get_journal()
        files = list(os.listdir(self.base_dir))
        with make_bar(files, desc="ファイル振り分け") as bar:
            for _file in bar:
                bar.set_postfix_str(_file, refresh=False)
                ext = os.path.splitext(_file)[1].lstrip(".")
                file_path = os.path.join(self.base_dir, _file)
                if ext in target_jpg_extensions:
                    dest = self.retouch_dir_path if is_retouched(file_path) else self.jpg_dir_path
                    if btime_safe_move(file_path, dest):
                        if j:
                            j.record_move(file_path, os.path.join(dest, _file))
                    else:
                        skipped.append(file_path)
                elif ext in target_raw_extensions:
                    if btime_safe_move(file_path, self.raw_dir_path):
                        if j:
                            j.record_move(file_path, os.path.join(self.raw_dir_path, _file))
                    else:
                        skipped.append(file_path)
                elif os.path.isfile(file_path) and not _file.startswith("."):
                    logger.warning(f"スキップ: {_file} は処理されません（対象外の拡張子）")
        from imanage.xmp_handler import write_exif_to_xmp
        write_exif_to_xmp(
            [self.jpg_dir_path, self.retouch_dir_path],
            self.raw_dir_path,
            target_jpg_extensions,
            target_raw_extensions,
        )
        if skipped:
            logger.warning(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                logger.warning(f"  {f}")

    def date_organize(self, config, exif_cache=None):
        hierarchy = config.get("organize", {}).get("hierarchy", ["date"])
        skipped = []
        j = _journal.get_journal()

        if exif_cache is None:
            exif_cache = build_exif_cache(self.jpg_dir_path)
            if os.path.isdir(self.retouch_dir_path):
                exif_cache.update(build_exif_cache(self.retouch_dir_path))

        all_files = []
        for dir_path, dir_name in [(self.jpg_dir_path, jpg_dir_name), (self.raw_dir_path, raw_dir_name), (self.retouch_dir_path, retouch_dir_name)]:
            if not os.path.isdir(dir_path):
                continue
            for _file in os.listdir(dir_path):
                if _file == ".DS_Store":
                    continue
                if os.path.isfile(os.path.join(dir_path, _file)):
                    all_files.append((dir_path, dir_name, _file))

        with make_bar(all_files, desc="ファイル移動") as bar:
            for dir_path, dir_name, _file in bar:
                bar.set_postfix_str(_file, refresh=False)
                file_path = os.path.join(dir_path, _file)

                stem = os.path.splitext(_file)[0]
                fields = _resolve_fields(file_path, stem, exif_cache)

                path_parts = [fields.get(field, "Unknown") for field in hierarchy]
                dest_dir = os.path.join(self.base_dir, *path_parts, dir_name)
                dest_is_new = not os.path.isdir(dest_dir)
                os.makedirs(dest_dir, exist_ok=True)
                if dest_is_new and j:
                    j.record_mkdir(dest_dir)
                dest_path = os.path.join(dest_dir, _file)
                if btime_safe_move(file_path, dest_path):
                    if j:
                        j.record_move(file_path, dest_path)
                    logger.debug("Moved {} -> {}".format(file_path, dest_dir))
                else:
                    skipped.append(file_path)

        if skipped:
            logger.warning(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                logger.warning(f"  {f}")

    """
    jpg_dir_path に存在しない同名ファイルを raw_dir_path から削除する
    """
    def jremove(self):
        from send2trash import send2trash as _send2trash
        j_sl = {os.path.splitext(f)[0] for f in os.listdir(self.jpg_dir_path) if f != ".DS_Store"}
        if os.path.isdir(self.retouch_dir_path):
            j_sl |= {os.path.splitext(f)[0] for f in os.listdir(self.retouch_dir_path) if f != ".DS_Store"}
        raw_files_by_stem = {}
        for f in os.listdir(self.raw_dir_path):
            if f == ".DS_Store":
                continue
            stem, dot_ext = os.path.splitext(f)
            if dot_ext.lstrip(".").lower() in target_raw_extensions or dot_ext.lower() == ".xmp":
                raw_files_by_stem.setdefault(stem, []).append(f)
        diff = set(raw_files_by_stem) - j_sl
        to_delete = [(d, f) for d in sorted(diff) for f in raw_files_by_stem[d]]
        if to_delete:
            j = _journal.get_journal()
            with make_bar(to_delete, desc="孤立RAW削除") as bar:
                for d, f in bar:
                    bar.set_postfix_str(f, refresh=False)
                    target_file_path = os.path.join(self.raw_dir_path, f)
                    _send2trash(target_file_path)
                    if j:
                        j.record_trash(target_file_path)
                    logger.debug("Trashed {}".format(target_file_path))


    def syncmeta(self):
        from imanage.xmp_handler import sync_rating_to_raw
        sync_rating_to_raw(
            [self.jpg_dir_path, self.retouch_dir_path],
            self.raw_dir_path,
            meta_target,
            target_jpg_extensions,
        )



if __name__ == "__main__":
    main()
