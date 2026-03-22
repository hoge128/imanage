"""
btime_utils — macOS btime (st_birthtime) 保全ユーティリティ

ポリシー: imanage はいかなる操作においてもファイルの btime を変更してはならない。
"""
import os, ctypes, ctypes.util, struct, shutil
from contextlib import contextmanager

ATTR_BIT_MAP_COUNT = 5
ATTR_CMN_CRTIME    = 0x00000200


class _attrlist(ctypes.Structure):
    _fields_ = [
        ("bitmapcount", ctypes.c_uint16), ("reserved", ctypes.c_uint16),
        ("commonattr",  ctypes.c_uint32), ("volattr",  ctypes.c_uint32),
        ("dirattr",     ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
        ("forkattr",    ctypes.c_uint32),
    ]


def get_btime(path: str) -> float | None:
    try:
        return os.stat(path).st_birthtime
    except AttributeError:
        return None


def set_btime(path: str, btime: float) -> None:
    """macOS 専用: setattrlist(2) で birthtime を設定する"""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    attrs = _attrlist()
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT
    attrs.commonattr  = ATTR_CMN_CRTIME
    sec, nsec = int(btime), int((btime - int(btime)) * 1_000_000_000)
    buf = struct.pack("qq", sec, nsec)  # timespec: tv_sec + tv_nsec (各 8 bytes)
    ret = libc.setattrlist(path.encode("utf-8"), ctypes.byref(attrs), buf, len(buf), 0)
    if ret != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno), path)


@contextmanager
def preserve_btime(path: str):
    """btime を保存してブロック終了後に復元するコンテキストマネージャ"""
    btime = get_btime(path)
    try:
        yield
    finally:
        if btime is not None:
            try:
                set_btime(path, btime)
            except Exception:
                pass  # 復元失敗は silent fail（処理継続を優先）


def btime_safe_move(src: str, dst: str) -> None:
    """btime を保持したまま shutil.move を実行する"""
    btime = get_btime(src)
    shutil.move(src, dst)
    if btime is not None:
        final = os.path.join(dst, os.path.basename(src)) if os.path.isdir(dst) else dst
        try:
            set_btime(final, btime)
        except Exception:
            pass
