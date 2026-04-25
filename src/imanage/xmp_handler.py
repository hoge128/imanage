import logging
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from imanage.progress import make_bar
from datetime import datetime

logger = logging.getLogger("imanage.xmp_handler")
from fractions import Fraction
from imanage.btime_utils import preserve_btime
from imanage import __version__

def _libxmp():
    from libxmp import XMPFiles, XMPMeta, XMPIterator, consts
    return XMPFiles, XMPMeta, XMPIterator, consts


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
    from PIL import Image
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


_EXIF_DT_TAGS = {
    "DateTimeOriginal":  36867,
    "DateTimeDigitized": 36868,
    "OffsetTimeOriginal":  36880,
    "OffsetTimeDigitized": 36881,
}


def _read_exif_datetimes(file_path):
    """撮影日時 EXIF タグを読んで dict で返す。失敗時は空 dict。
    getexif() は JPEG・TIFF 両対応の公開 API (Pillow 6.0+)。
    _getexif() は JPEG 専用のため ARW/RAW では AttributeError になる。"""
    from PIL import Image
    try:
        exif_data = Image.open(file_path).getexif()
    except Exception:
        return {}
    if not exif_data:
        return {}
    return {name: exif_data[tag] for name, tag in _EXIF_DT_TAGS.items() if tag in exif_data}


def _exif_dt_to_xmp(dt_str, offset=None):
    """EXIF 日時文字列 "YYYY:MM:DD HH:MM:SS" を XMP ISO-8601 形式に変換する。"""
    dt = datetime.strptime(dt_str[:19], "%Y:%m:%d %H:%M:%S")
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + (offset or "")


def _restore_exif_dates_to_xmp(xmp, exif_dt):
    """_remove_unwanted_namespaces で消えた DateTimeOriginal/Digitized を XMP に再注入する。
    put_xmp() 時に exempi が XMP→EXIF 同期し、EXIF タグ 0x9003/0x9004 を復元する。"""
    if not exif_dt:
        return
    _, _, _, consts = _libxmp()
    for prop, off_prop in (("DateTimeOriginal", "OffsetTimeOriginal"),
                           ("DateTimeDigitized", "OffsetTimeDigitized")):
        raw = exif_dt.get(prop)
        if not raw:
            continue
        try:
            iso = _exif_dt_to_xmp(raw, exif_dt.get(off_prop))
        except Exception as e:
            logger.debug(f"EXIF {prop} 変換失敗 ({raw!r}): {e}")
            continue
        xmp.set_property(consts.XMP_NS_EXIF, prop, iso)


def apply_exif_to_xmp(xmp, exif, file_path):
    _, _, _, consts = _libxmp()
    if "lens" in exif:
        if not xmp.does_property_exist(consts.XMP_NS_EXIF_Aux, "Lens"):
            xmp.set_property(consts.XMP_NS_EXIF_Aux, "Lens", exif["lens"])

    if "creator" in exif:
        if not xmp.does_property_exist(consts.XMP_NS_DC, "creator"):
            xmp.append_array_item(
                consts.XMP_NS_DC, "creator", str(exif["creator"]),
                {"prop_array_is_ordered": True},
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
    _, _, XMPIterator, consts = _libxmp()
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
    _, _, _, consts = _libxmp()
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
        consts.XMP_NS_XMP_MM, "History", None,
        {"prop_array_is_ordered": True},
        prop_value_is_struct=True,
    )
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:action", "saved")
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:instanceID", instance_id)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:when", now)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:softwareAgent", agent)
    xmp.set_property(consts.XMP_NS_XMP_MM, "History[last()]/stEvt:changed", "/metadata")


def check_xmp_applied(file_path):
    """JPG/RAW に crd:AlreadyApplied が書き込まれているか確認。失敗時は False を返す。"""
    XMPFiles, _, _, consts = _libxmp()
    try:
        xf = XMPFiles(file_path=file_path, open_forupdate=False)
        xmp = xf.get_xmp()
        xf.close_file()
        return xmp is not None and xmp.does_property_exist(consts.XMP_NS_CameraRaw, "AlreadyApplied")
    except Exception:
        return False


def read_xmp_meta(file_path, meta_target):
    """JPG の XMP から meta_target で指定されたプロパティを読む。
    XMP が存在しない場合は None、存在するが値がない場合は空 dict を返す。"""
    XMPFiles, _, _, consts = _libxmp()
    try:
        xf = XMPFiles(file_path=file_path, open_forupdate=False)
        xmp = xf.get_xmp()
        xf.close_file()
        if xmp is None:
            return None
        result = {}
        for prop in meta_target:
            try:
                result[prop] = xmp.get_property(consts.XMP_NS_XMP, prop)
            except Exception:
                pass
        return result
    except Exception:
        return None


def _sync_one_jpg(jpg_path, meta_target, sidecar_index):
    XMPFiles, XMPMeta, _, consts = _libxmp()
    stem = os.path.splitext(os.path.basename(jpg_path))[0]
    sidecar_path = sidecar_index.get(stem)

    if sidecar_path is None:
        logger.warning(f"サイドカーが存在しません。スキップ: {stem}.xmp")
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
            logger.debug(f"{jpg_path} - {prop} sync -> {sidecar_path}")
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
        for filename in os.listdir(jpg_dir):
            ext = os.path.splitext(filename)[1].lstrip(".").lower()
            if ext in target_jpg_extensions:
                p = os.path.join(jpg_dir, filename)
                if os.path.isfile(p):
                    jpg_paths.append(p)

    with ThreadPoolExecutor() as executor:
        futures = {
            executor.submit(_sync_one_jpg, jpg_path, meta_target, sidecar_index): jpg_path
            for jpg_path in jpg_paths
        }
        with make_bar(as_completed(futures), total=len(futures), desc="メタデータ同期") as bar:
            for future in bar:
                jpg_path = futures[future]
                bar.set_postfix_str(os.path.basename(jpg_path), refresh=False)
                try:
                    future.result()
                except Exception as e:
                    logger.error(f"Rating/Label 同期エラー ({jpg_path}): {e}")


def is_already_applied(jpg_dirs: list, raw_dir: str, target_jpg_extensions: set) -> bool:
    XMPFiles, _, _, consts = _libxmp()
    """
    Returns True only if BOTH:
    - At least one .xmp sidecar exists in raw_dir
    - The first jpg found in jpg_dirs has crd:AlreadyApplied set (written by imanage)
    """
    raw_has_xmp = os.path.isdir(raw_dir) and any(
        f.endswith(".xmp") for f in os.listdir(raw_dir)
    )

    jpg_has_xmp = False
    for jpg_dir in jpg_dirs:
        if not os.path.isdir(jpg_dir):
            continue
        for f in sorted(os.listdir(jpg_dir)):
            ext = os.path.splitext(f)[1].lstrip(".").lower()
            if ext in target_jpg_extensions:
                jpg_path = os.path.join(jpg_dir, f)
                try:
                    xf = XMPFiles(file_path=jpg_path, open_forupdate=False)
                    xmp = xf.get_xmp()
                    xf.close_file()
                    if xmp is not None and xmp.does_property_exist(
                        consts.XMP_NS_CameraRaw, "AlreadyApplied"
                    ):
                        jpg_has_xmp = True
                except Exception:
                    pass
                break  # first jpg only
        if jpg_has_xmp:
            break

    return jpg_has_xmp and raw_has_xmp


def _process_jpg_xmp(jpg_path):
    XMPFiles, XMPMeta, _, _ = _libxmp()
    try:
        exif_dt = _read_exif_datetimes(jpg_path)
        with preserve_btime(jpg_path):
            xmpfile = XMPFiles(file_path=jpg_path, open_forupdate=True)
            xmp = xmpfile.get_xmp()
            if xmp is None:
                xmp = XMPMeta()
            _remove_unwanted_namespaces(xmp)
            exif = read_exif(jpg_path)
            apply_exif_to_xmp(xmp, exif, jpg_path)
            _apply_workflow_metadata(xmp, jpg_path)
            _restore_exif_dates_to_xmp(xmp, exif_dt)
            xmpfile.put_xmp(xmp)
            xmpfile.close_file()
    except Exception as e:
        logger.error(f"XMP 書き込みエラー ({jpg_path}): {e}")


def _process_raw_xmp(raw_path):
    from imanage import journal as _journal
    _, XMPMeta, _, _ = _libxmp()
    sidecar_path = os.path.splitext(raw_path)[0] + ".xmp"
    try:
        is_new = not os.path.isfile(sidecar_path)
        if not is_new:
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
        if is_new:
            j = _journal.get_journal()
            if j:
                j.record_sidecar_created(sidecar_path)
    except Exception as e:
        logger.error(f"XMP サイドカー書き込みエラー ({raw_path}): {e}")
    return sidecar_path


def find_jpg_raw_pairs(jpg_dir, raw_dir, target_jpg_exts, target_raw_exts):
    """jpg_dir と raw_dir でステムが一致するペアを返す [(jpg_path, raw_path), ...]。"""
    raw_by_stem = {}
    if os.path.isdir(raw_dir):
        for f in os.listdir(raw_dir):
            stem, dot_ext = os.path.splitext(f)
            if dot_ext.lstrip(".").lower() in target_raw_exts:
                raw_by_stem[stem] = os.path.join(raw_dir, f)
    pairs = []
    if os.path.isdir(jpg_dir):
        for f in sorted(os.listdir(jpg_dir)):
            stem, dot_ext = os.path.splitext(f)
            if dot_ext.lstrip(".").lower() not in target_jpg_exts:
                continue
            raw_path = raw_by_stem.get(stem)
            if raw_path:
                pairs.append((os.path.join(jpg_dir, f), raw_path))
    return pairs


def restore_datetime_from_raw(jpg_path, raw_path):
    """ペアの RAW から DateTimeOriginal/Digitized を読み、JPG EXIF に書き戻す。"""
    exif_dt = _read_exif_datetimes(raw_path)
    if not exif_dt.get("DateTimeOriginal") and not exif_dt.get("DateTimeDigitized"):
        logger.warning(f"スキップ: RAW に撮影日時なし ({os.path.basename(raw_path)})")
        return False
    XMPFiles, XMPMeta, _, _ = _libxmp()
    try:
        with preserve_btime(jpg_path):
            xmpfile = XMPFiles(file_path=jpg_path, open_forupdate=True)
            xmp = xmpfile.get_xmp()
            if xmp is None:
                xmp = XMPMeta()
            _restore_exif_dates_to_xmp(xmp, exif_dt)
            xmpfile.put_xmp(xmp)
            xmpfile.close_file()
        logger.debug(f"復元: {os.path.basename(jpg_path)} ← {exif_dt.get('DateTimeOriginal')}")
        return True
    except Exception as e:
        logger.error(f"復元エラー ({os.path.basename(jpg_path)}): {e}")
        return False


def write_exif_to_xmp(jpg_dirs, raw_dir, target_jpg_extensions, target_raw_extensions):
    # JPG / retouch ファイルへの書き込み（並列）
    jpg_paths = []
    for jpg_dir in jpg_dirs:
        if not os.path.isdir(jpg_dir):
            continue
        for filename in os.listdir(jpg_dir):
            ext = os.path.splitext(filename)[1].lstrip(".").lower()
            if ext in target_jpg_extensions:
                p = os.path.join(jpg_dir, filename)
                if os.path.isfile(p):
                    jpg_paths.append(p)

    if jpg_paths:
        with ThreadPoolExecutor() as executor:
            futures = {executor.submit(_process_jpg_xmp, p): p for p in jpg_paths}
            with make_bar(as_completed(futures), total=len(futures), desc="JPG XMP書き込み") as bar:
                for future in bar:
                    path = futures[future]
                    bar.set_postfix_str(os.path.basename(path), refresh=False)
                    try:
                        future.result()
                    except Exception:
                        pass

    # RAW ファイル → サイドカー .xmp への書き込み（並列）
    if not os.path.isdir(raw_dir):
        return
    raw_paths = []
    seen_sidecars = set()
    for filename in os.listdir(raw_dir):
        ext = os.path.splitext(filename)[1].lstrip(".").lower()
        if ext not in target_raw_extensions:
            continue
        raw_path = os.path.join(raw_dir, filename)
        if not os.path.isfile(raw_path):
            continue
        sidecar_path = os.path.splitext(raw_path)[0] + ".xmp"
        if sidecar_path in seen_sidecars:
            continue
        seen_sidecars.add(sidecar_path)
        raw_paths.append(raw_path)

    if raw_paths:
        with ThreadPoolExecutor() as executor:
            futures = {executor.submit(_process_raw_xmp, p): p for p in raw_paths}
            with make_bar(as_completed(futures), total=len(futures), desc="RAW XMPサイドカー") as bar:
                for future in bar:
                    path = futures[future]
                    bar.set_postfix_str(os.path.basename(path), refresh=False)
                    try:
                        future.result()
                    except Exception:
                        pass
