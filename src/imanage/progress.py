import logging
from tqdm import tqdm as _tqdm

_quiet = False
_logger = logging.getLogger("imanage.progress")


def set_quiet(q: bool):
    global _quiet
    _quiet = q


def make_bar(iterable=None, *, total=None, desc="", unit="file"):
    return _tqdm(
        iterable, total=total, desc=desc, unit=unit,
        disable=_quiet, dynamic_ncols=True,
        bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )


def progress_print(msg: str):
    """Legacy wrapper — prefer using logger.debug/info/warning/error directly."""
    _logger.info(msg)
