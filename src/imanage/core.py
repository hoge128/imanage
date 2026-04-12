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
    def setup(self): pass
    def execute(self): pass
    def teardown(self): pass


class OrganizeCommand(BaseCommand):
    def setup(self):
        self.iCon = dir_structure()
        self.config = _config

    def execute(self):
        self.iCon.date_organize(self.config)

    def teardown(self):
        for d in [self.iCon.jpg_dir_path, self.iCon.raw_dir_path, self.iCon.retouch_dir_path]:
            try:
                os.rmdir(d)
            except OSError:
                pass


class DeleteCommand(BaseCommand):
    def setup(self):
        self.iCon = dir_structure()
        self.iCon.imagev()

    def execute(self):
        self.iCon.jremove()


class SyncCommand(BaseCommand):
    def setup(self):
        self.iCon = dir_structure()
        self.iCon.imagev()

    def execute(self):
        self.iCon.jremove()
        self.iCon.syncmeta()


class DefaultCommand(BaseCommand):
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
    def setup(self):
        cwd = os.getcwd()
        basename = os.path.basename(cwd)

        if basename in (jpg_dir_name, raw_dir_name):
            # Case 1: jpg/ または raw/ の中にいる — 親ディレクトリに対して適用
            self.mode = "single"
            parent = os.path.dirname(cwd)
            self.iCon = imageContainer(parent)
        else:
            # Case 2: 日付ディレクトリなどを含む親ディレクトリ
            self.mode = "batch"
            self.root = cwd
            self.pair_dirs = find_pair_dirs(cwd)
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

        if not pending:
            logger.info("すべてのディレクトリに既にメタデータが適用されています")
            return

        _print_meta_preview(self.root, pending, applied)
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

    def setup(self):
        self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            logger.info("jpg/raw 構造を持つディレクトリが見つかりませんでした")
            sys.exit(0)

    def execute(self):
        _print_preview(self.root, self.pair_dirs)
        answer = input("続行しますか？ [y/N]: ").strip().lower()
        if answer != 'y':
            print("中止しました")
            return
        with make_bar(self.pair_dirs, desc="ディレクトリ処理", unit="dir") as bar:
            for pair_dir in bar:
                bar.set_postfix_str(os.path.basename(pair_dir), refresh=False)
                iCon = imageContainer(pair_dir)
                iCon.imagev()
                iCon.jremove()
                iCon.syncmeta()


def resolve_command(args):
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
    parser.add_argument('-q', '--quiet', action='store_true', help="エラーのみ出力する（スクリプト用）")
    parser.add_argument('-v', '--verbose', action='store_true', help="ファイル単位の処理詳細も表示する")
    parser.add_argument('--log-file', metavar='PATH', nargs='?',
                        const=os.path.expanduser("~/.local/state/imanage/imanage.log"),
                        help="ログをファイルに出力する（PATH 省略時: ~/.local/state/imanage/imanage.log）")
    parser.add_argument('-m', '--meta', action='store_true', help="メタデータが未適用のファイルに XMP を書き込む")
    parser.add_argument('--undo', action='store_true', help="直前の操作を取り消す")
    args = parser.parse_args()

    from imanage.log import setup_logging
    from imanage.progress import set_quiet
    setup_logging(quiet=args.quiet, verbose=args.verbose, log_file=args.log_file)
    set_quiet(args.quiet)

    if args.undo:
        _journal.execute_undo_from_file()
        return

    _journal.init_journal()
    cmd = resolve_command(args)
    cmd.setup()
    cmd.execute()
    cmd.teardown()
    _journal.get_journal().save()


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

    def date_organize(self, config):
        hierarchy = config.get("organize", {}).get("hierarchy", ["date"])
        skipped = []
        j = _journal.get_journal()

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
                if stem in exif_cache:
                    fields = exif_cache[stem]
                else:
                    # RAW にキャッシュがない場合はファイルシステム日付 + Unknown で補完
                    stat = os.stat(file_path)
                    try:
                        timestamp = stat.st_birthtime
                    except AttributeError:
                        timestamp = stat.st_mtime
                    date_str = datetime.fromtimestamp(timestamp).strftime(date_format)
                    fields = {field: "Unknown" for field in ["maker", "model", "creator", "lens", "focal_length", "shutter_speed"]}
                    fields["date"] = date_str

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
