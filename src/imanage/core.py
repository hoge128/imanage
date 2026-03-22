#!/usr/bin/ python3
import os, sys, shutil, glob, argparse
from imanage.btime_utils import btime_safe_move
from collections import deque
from datetime import datetime

try:
    import tomllib
except ImportError:
    import tomli as tomllib

from PIL import Image
from imanage.xmp_handler import write_exif_to_xmp, sync_rating_to_raw


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


_config = load_config()
jpg_dir_name          = _config["jpg_dir_name"]
raw_dir_name          = _config["raw_dir_name"]
retouch_dir_name      = _config["retouch_dir_name"]
date_format           = _config["date_format"]
target_jpg_extensions = set(_config["target_jpg_extensions"])
target_raw_extensions = set(_config["target_raw_extensions"])
meta_target           = _config.get("meta_target", ["Rating", "Label"])


def get_exif_fields(jpg_path):
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
    for _file in os.listdir(jpg_dir_path):
        stem, dot_ext = os.path.splitext(_file)
        if dot_ext.lstrip(".") not in target_jpg_extensions:
            continue
        file_path = os.path.join(jpg_dir_path, _file)
        if not os.path.isfile(file_path):
            continue
        cache[stem] = get_exif_fields(file_path)
    return cache


parser = argparse.ArgumentParser(description='Photographer Tool')
parser.add_argument('-d', '--delete', action="store_true", help="jpg ディレクトリに存在しない raw ファイルを削除する")
parser.add_argument('-s', '--sync', action="store_true", help="jpg の XMP メタデータを同名 raw ファイルに同期する")
parser.add_argument('-l', '--link', action="store_true", help="(未使用)")
parser.add_argument('-o', '--organize', action="store_true", help="jpg/raw を作成日時ごとの日付フォルダ (YYYYMMDD/jpg, YYYYMMDD/raw) に仕分ける")
parser.add_argument('-R', '--recursive', metavar='PATH', nargs='?', const='.', help="PATH 配下の jpg/raw 構造を持つすべてのディレクトリに -s を適用する")
args = parser.parse_args()

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
        self.iCon.imagev()


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
    r_stems = {os.path.splitext(f)[0] for f in os.listdir(iCon.raw_dir_path) if f != ".DS_Store"}
    orphan_stems = r_stems - j_stems
    orphan_files = []
    for stem in sorted(orphan_stems):
        for ex in target_raw_extensions:
            candidate = os.path.join(iCon.raw_dir_path, stem + "." + ex)
            if os.path.isfile(candidate):
                orphan_files.append(stem + "." + ex)
    return orphan_files


def _print_preview(root: str, pair_dirs: list):
    print(f"\n対象ディレクトリ: {len(pair_dirs)} 件\n")
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
        print(line)
        total_jpg += jpg_count
        total_raw += raw_count
        total_orphan += len(orphan_files)
    print(f"\n  合計 孤立RAW: {total_orphan} 件  XMP 同期対象: {total_jpg} 件\n")


class RecursiveCommand(BaseCommand):
    def __init__(self, root: str):
        self.root = os.path.abspath(root)

    def setup(self):
        self.pair_dirs = find_pair_dirs(self.root)
        if not self.pair_dirs:
            print("jpg/raw 構造を持つディレクトリが見つかりませんでした")
            sys.exit(0)

    def execute(self):
        _print_preview(self.root, self.pair_dirs)
        answer = input("続行しますか？ [y/N]: ").strip().lower()
        if answer != 'y':
            print("中止しました")
            return
        for pair_dir in self.pair_dirs:
            iCon = imageContainer(pair_dir)
            iCon.imagev()
            iCon.jremove()
            iCon.syncmeta()


def resolve_command(args):
    if args.recursive is not None:
        return RecursiveCommand(args.recursive)
    if args.organize:
        return OrganizeCommand()
    if args.delete:
        return DeleteCommand()
    if args.sync:
        return SyncCommand()
    return DefaultCommand()


def main():
    cmd = resolve_command(args)
    cmd.setup()
    cmd.execute()
    cmd.teardown()


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
        print("対象ファイルが見つかりません。処理をスキップします。")
        sys.exit(0)

    current_dirs = {_file for _file in os.listdir(path) if os.path.isdir(os.path.join(path, _file))}
    if {jpg_dir_name, raw_dir_name} <= current_dirs:
        iCon = imageContainer()
    else:
        for _dir in [jpg_dir_name, raw_dir_name, retouch_dir_name]:
            os.makedirs(_dir, exist_ok=True)
        iCon = imageContainer()
        skipped = []
        for _file in os.listdir(os.getcwd()):
            ext = os.path.splitext(_file)[1].lstrip(".")
            file_path = os.path.join(os.getcwd(), _file)
            if ext in target_jpg_extensions:
                dest = iCon.retouch_dir_path if is_retouched(file_path) else iCon.jpg_dir_path
                if not btime_safe_move(file_path, dest):
                    skipped.append(file_path)
            elif ext in target_raw_extensions:
                if not btime_safe_move(file_path, iCon.raw_dir_path):
                    skipped.append(file_path)
            elif os.path.isfile(file_path) and not _file.startswith("."):
                print(f"スキップ: {_file} は処理されません（対象外の拡張子）")
        if skipped:
            print(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                print(f"  {f}")
    write_exif_to_xmp(
        [iCon.jpg_dir_path, iCon.retouch_dir_path],
        iCon.raw_dir_path,
        target_jpg_extensions,
        target_raw_extensions,
    )
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
        for _file in os.listdir(self.base_dir):
            ext = os.path.splitext(_file)[1].lstrip(".")
            file_path = os.path.join(self.base_dir, _file)
            if ext in target_jpg_extensions:
                dest = self.retouch_dir_path if is_retouched(file_path) else self.jpg_dir_path
                if not btime_safe_move(file_path, dest):
                    skipped.append(file_path)
            elif ext in target_raw_extensions:
                if not btime_safe_move(file_path, self.raw_dir_path):
                    skipped.append(file_path)
            elif os.path.isfile(file_path) and not _file.startswith("."):
                print(f"スキップ: {_file} は処理されません（対象外の拡張子）")
        write_exif_to_xmp(
            [self.jpg_dir_path, self.retouch_dir_path],
            self.raw_dir_path,
            target_jpg_extensions,
            target_raw_extensions,
        )
        if skipped:
            print(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                print(f"  {f}")

    def date_organize(self, config):
        hierarchy = config.get("organize", {}).get("hierarchy", ["date"])
        skipped = []

        exif_cache = build_exif_cache(self.jpg_dir_path)
        if os.path.isdir(self.retouch_dir_path):
            exif_cache.update(build_exif_cache(self.retouch_dir_path))

        for dir_path, dir_name in [(self.jpg_dir_path, jpg_dir_name), (self.raw_dir_path, raw_dir_name), (self.retouch_dir_path, retouch_dir_name)]:
            if not os.path.isdir(dir_path):
                continue
            for _file in os.listdir(dir_path):
                if _file == ".DS_Store":
                    continue
                file_path = os.path.join(dir_path, _file)
                if not os.path.isfile(file_path):
                    continue

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
                os.makedirs(dest_dir, exist_ok=True)
                if not btime_safe_move(file_path, os.path.join(dest_dir, _file)):
                    skipped.append(file_path)
                else:
                    print("Moved {} -> {}".format(file_path, dest_dir))

        if skipped:
            print(f"\n移動スキップ（移動先に同名ファイルが存在）: {len(skipped)} 件")
            for f in skipped:
                print(f"  {f}")

    """
    jpg_dir_path に存在しない同名ファイルを raw_dir_path から削除する
    """
    def jremove(self):
        j_sl = {os.path.splitext(f)[0] for f in os.listdir(self.jpg_dir_path) if f != ".DS_Store"}
        if os.path.isdir(self.retouch_dir_path):
            j_sl |= {os.path.splitext(f)[0] for f in os.listdir(self.retouch_dir_path) if f != ".DS_Store"}
        r_sl = {os.path.splitext(f)[0] for f in os.listdir(self.raw_dir_path) if f != ".DS_Store"}
        diff = r_sl - j_sl
        for d in diff:
            for ex in target_raw_extensions:
                target_file_path = os.path.join(self.raw_dir_path, d + "." + ex)
                if os.path.isfile(target_file_path):
                    os.remove(target_file_path)
                    print("Rmove {}".format(target_file_path))
            # RAW が削除されたらサイドカー XMP も削除する
            sidecar_path = os.path.join(self.raw_dir_path, d + ".xmp")
            if os.path.isfile(sidecar_path):
                os.remove(sidecar_path)
                print("Rmove {}".format(sidecar_path))


    def syncmeta(self):
        sync_rating_to_raw(
            [self.jpg_dir_path, self.retouch_dir_path],
            self.raw_dir_path,
            meta_target,
            target_jpg_extensions,
        )



if __name__ == "__main__":
    main()
