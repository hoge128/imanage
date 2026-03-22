import os
import glob
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from PIL import Image
from libxmp import XMPFiles, XMPMeta, consts
from imanage.btime_utils import preserve_btime

XMP_NS_EXIF_AUX = "http://ns.adobe.com/exif/1.0/aux/"

_EXIF_TAGS = {
    "maker":         271,
    "model":         272,
    "creator":       315,
    "lens":          42036,
    "focal_length":  37386,
    "shutter_speed": 33434,
}


def read_exif(file_path):
    try:
        img = Image.open(file_path)
        exif_data = img._getexif() or {}
    except Exception:
        return {}

    result = {}
    for field, tag_id in _EXIF_TAGS.items():
        val = exif_data.get(tag_id)
        if val is not None:
            result[field] = val
    return result


def apply_exif_to_xmp(xmp, exif, file_path):
    def _set_str(ns, prop, value):
        if not xmp.does_property_exist(ns, prop):
            xmp.set_property(ns, prop, str(value))

    if "maker" in exif:
        _set_str(consts.XMP_NS_TIFF, "Make", exif["maker"])
    if "model" in exif:
        _set_str(consts.XMP_NS_TIFF, "Model", exif["model"])
    if "lens" in exif:
        _set_str(XMP_NS_EXIF_AUX, "Lens", exif["lens"])

    if "focal_length" in exif:
        val = exif["focal_length"]
        try:
            rational_str = f"{val.numerator}/{val.denominator}"
        except AttributeError:
            rational_str = str(val)
        if not xmp.does_property_exist(consts.XMP_NS_EXIF, "FocalLength"):
            xmp.set_property(consts.XMP_NS_EXIF, "FocalLength", rational_str)

    if "shutter_speed" in exif:
        val = exif["shutter_speed"]
        try:
            rational_str = f"{val.numerator}/{val.denominator}"
        except AttributeError:
            rational_str = str(val)
        if not xmp.does_property_exist(consts.XMP_NS_EXIF, "ExposureTime"):
            xmp.set_property(consts.XMP_NS_EXIF, "ExposureTime", rational_str)

    if "creator" in exif:
        if not xmp.does_property_exist(consts.XMP_NS_DC, "creator"):
            xmp.append_array_item(consts.XMP_NS_DC, "creator", str(exif["creator"]), {"prop_array_is_ordered": True, "prop_value_is_array": True})

    stat = os.stat(file_path)
    try:
        timestamp = stat.st_birthtime
    except AttributeError:
        timestamp = stat.st_mtime
    date_str = datetime.fromtimestamp(timestamp).strftime("%Y-%m-%dT%H:%M:%S")
    if not xmp.does_property_exist(consts.XMP_NS_XMP, "CreateDate"):
        xmp.set_property(consts.XMP_NS_XMP, "CreateDate", date_str)


def _sync_one_jpg(jpg_path, meta_target, sidecar_index):
    stem = os.path.splitext(os.path.basename(jpg_path))[0]
    sidecar_path = sidecar_index.get(stem)

    if sidecar_path is None:
        print(f"サイドカーが存在しません。スキップ: {stem}.xmp")
        return

    jpg_xmpfile = XMPFiles(file_path=jpg_path, open_forupdate=False)
    jpg_xmp = jpg_xmpfile.get_xmp()
    jpg_xmpfile.close_file()

    if jpg_xmp is None:
        return

    sidecar_xmp = XMPMeta()
    with open(sidecar_path, "r", encoding="utf-8") as f:
        try:
            sidecar_xmp.parse_from_str(f.read())
        except Exception:
            sidecar_xmp = XMPMeta()

    changed = False
    for prop in meta_target:
        try:
            value = jpg_xmp.get_property(consts.XMP_NS_XMP, prop)
            sidecar_xmp.set_property(consts.XMP_NS_XMP, prop, value)
            changed = True
            print(f"{jpg_path} - {prop} sync -> {sidecar_path}")
        except Exception:
            pass

    if changed:
        with open(sidecar_path, "w", encoding="utf-8") as f:
            f.write(sidecar_xmp.serialize_to_str())


def sync_rating_to_raw(jpg_dirs, raw_dir, meta_target, target_jpg_extensions):
    if not os.path.isdir(raw_dir):
        return

    sidecar_index = {
        os.path.splitext(name)[0]: os.path.join(raw_dir, name)
        for name in os.listdir(raw_dir)
        if name.endswith(".xmp")
    }

    jpg_paths = []
    for jpg_dir in jpg_dirs:
        if not os.path.isdir(jpg_dir):
            continue
        for ext in target_jpg_extensions:
            jpg_paths.extend(glob.glob(os.path.join(jpg_dir, f"*.{ext}")))

    with ThreadPoolExecutor() as executor:
        futures = {
            executor.submit(_sync_one_jpg, jpg_path, meta_target, sidecar_index): jpg_path
            for jpg_path in jpg_paths
        }
        for future in as_completed(futures):
            jpg_path = futures[future]
            try:
                future.result()
            except Exception as e:
                print(f"Rating/Label 同期エラー ({jpg_path}): {e}")


def write_exif_to_xmp(jpg_dirs, raw_dir, target_jpg_extensions, target_raw_extensions):
    # JPG / retouch ファイルへの書き込み
    for jpg_dir in jpg_dirs:
        if not os.path.isdir(jpg_dir):
            continue
        for ext in target_jpg_extensions:
            for jpg_path in glob.glob(os.path.join(jpg_dir, f"*.{ext}")):
                try:
                    with preserve_btime(jpg_path):
                        xmpfile = XMPFiles(file_path=jpg_path, open_forupdate=True)
                        xmp = xmpfile.get_xmp()
                        if xmp is None:
                            xmp = XMPMeta()
                        exif = read_exif(jpg_path)
                        apply_exif_to_xmp(xmp, exif, jpg_path)
                        xmpfile.put_xmp(xmp)
                        xmpfile.close_file()
                except Exception as e:
                    print(f"XMP 書き込みエラー ({jpg_path}): {e}")

    # RAW ファイル → サイドカー .xmp への書き込み
    if not os.path.isdir(raw_dir):
        return
    processed = set()
    for ext in target_raw_extensions:
        for raw_path in glob.glob(os.path.join(raw_dir, f"*.{ext}")):
            sidecar_path = os.path.splitext(raw_path)[0] + ".xmp"
            if sidecar_path in processed:
                continue
            processed.add(sidecar_path)
            try:
                if os.path.isfile(sidecar_path):
                    with open(sidecar_path, "r", encoding="utf-8") as f:
                        xmp = XMPMeta()
                        try:
                            xmp.parse_from_str(f.read())
                        except Exception:
                            xmp = XMPMeta()
                else:
                    xmp = XMPMeta()
                exif = read_exif(raw_path)
                apply_exif_to_xmp(xmp, exif, raw_path)
                xmp_str = xmp.serialize_to_str()
                with open(sidecar_path, "w", encoding="utf-8") as f:
                    f.write(xmp_str)
            except Exception as e:
                print(f"XMP サイドカー書き込みエラー ({raw_path}): {e}")
