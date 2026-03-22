import os
import glob
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from fractions import Fraction
from PIL import Image
from libxmp import XMPFiles, XMPMeta, XMPIterator, consts
from imanage.btime_utils import preserve_btime
from imanage import __version__

_MIME_TYPES = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "jpe": "image/jpeg",
    "tif": "image/tiff", "tiff": "image/tiff",
    "png": "image/png",
}

_EXIF_TAGS = {
    "creator": 315,
    "lens":    42036,
}


def _to_rational_str(val):
    try:
        return f"{val.numerator}/{val.denominator}"
    except AttributeError:
        frac = Fraction(val).limit_denominator(100000)
        return f"{frac.numerator}/{frac.denominator}"


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
    if "lens" in exif:
        if not xmp.does_property_exist(consts.XMP_NS_EXIF_Aux, "Lens"):
            xmp.set_property(consts.XMP_NS_EXIF_Aux, "Lens", exif["lens"])

    if "creator" in exif:
        if not xmp.does_property_exist(consts.XMP_NS_DC, "creator"):
            xmp.append_array_item(
                consts.XMP_NS_DC, "creator", str(exif["creator"]),
                {"prop_array_is_ordered": True, "prop_value_is_array": True},
            )

    stat = os.stat(file_path)
    try:
        timestamp = stat.st_birthtime
    except AttributeError:
        timestamp = stat.st_mtime
    dt = datetime.fromtimestamp(timestamp).astimezone()
    tz_str = dt.strftime("%z")
    tz_fmt = f"{tz_str[:3]}:{tz_str[3:]}"
    date_str = dt.strftime(f"%Y-%m-%dT%H:%M:%S.{dt.microsecond // 1000:03d}") + tz_fmt
    if not xmp.does_property_exist(consts.XMP_NS_XMP, "CreateDate"):
        xmp.set_property(consts.XMP_NS_XMP, "CreateDate", date_str)


def _remove_unwanted_namespaces(xmp):
    NS_TO_REMOVE = [
        consts.XMP_NS_TIFF,
        consts.XMP_NS_EXIF,
        "http://cipa.jp/exif/1.0/",
    ]
    for ns in NS_TO_REMOVE:
        try:
            top_props = [
                path for _, path, _, _ in XMPIterator(xmp, ns)
                if path and "[" not in path and "/" not in path
            ]
            for prop in top_props:
                xmp.delete_property(ns, prop)
        except Exception:
            pass


def _now_str():
    now = datetime.now().astimezone()
    tz_str = now.strftime("%z")
    tz_fmt = f"{tz_str[:3]}:{tz_str[3:]}"
    return now.strftime(f"%Y-%m-%dT%H:%M:%S.{now.microsecond // 1000:03d}") + tz_fmt


def _apply_workflow_metadata(xmp, file_path):
    now = _now_str()
    agent = f"imanage v{__version__}"

    xmp.set_property(consts.XMP_NS_XMP, "CreatorTool", agent)
    xmp.set_property(consts.XMP_NS_XMP, "MetadataDate", now)
    xmp.set_property(consts.XMP_NS_XMP, "ModifyDate", now)

    ext = os.path.splitext(file_path)[1].lstrip(".").lower()
    mime = _MIME_TYPES.get(ext, "image/x-raw")
    if not xmp.does_property_exist(consts.XMP_NS_DC, "format"):
        xmp.set_property(consts.XMP_NS_DC, "format", mime)

    if not xmp.does_property_exist(consts.XMP_NS_CameraRaw, "AlreadyApplied"):
        xmp.set_property(consts.XMP_NS_CameraRaw, "AlreadyApplied", "True")

    if not xmp.does_property_exist(consts.XMP_NS_XMP_MM, "OriginalDocumentID"):
        try:
            doc_id = xmp.get_property(consts.XMP_NS_XMP_MM, "DocumentID")
            if doc_id:
                xmp.set_property(consts.XMP_NS_XMP_MM, "OriginalDocumentID", doc_id)
        except Exception:
            pass

    try:
        instance_id = xmp.get_property(consts.XMP_NS_XMP_MM, "InstanceID")
    except Exception:
        instance_id = ""

    xmp.append_array_item(
        consts.XMP_NS_XMP_MM, "History", "",
        {"prop_value_is_struct": True, "prop_array_is_ordered": True, "prop_value_is_array": True},
    )
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:action", "saved")
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:instanceID", instance_id)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:when", now)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:softwareAgent", agent)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:changed", "/metadata")


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
                        _remove_unwanted_namespaces(xmp)
                        exif = read_exif(jpg_path)
                        apply_exif_to_xmp(xmp, exif, jpg_path)
                        _apply_workflow_metadata(xmp, jpg_path)
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
                _remove_unwanted_namespaces(xmp)
                exif = read_exif(raw_path)
                apply_exif_to_xmp(xmp, exif, raw_path)
                _apply_workflow_metadata(xmp, raw_path)
                xmp_str = xmp.serialize_to_str()
                with open(sidecar_path, "w", encoding="utf-8") as f:
                    f.write(xmp_str)
            except Exception as e:
                print(f"XMP サイドカー書き込みエラー ({raw_path}): {e}")
