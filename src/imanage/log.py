import logging
import os
import sys
from tqdm import tqdm


class TqdmHandler(logging.StreamHandler):
    """logging.Handler that writes through tqdm.write() to avoid corrupting progress bars."""

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record)
            tqdm.write(msg, file=self.stream)
        except Exception:
            self.handleError(record)


def setup_logging(
    *,
    quiet: bool = False,
    verbose: bool = False,
    log_file: str | None = None,
) -> logging.Logger:
    """Configure the 'imanage' logger.

    quiet   → console shows ERROR and above only (also suppresses tqdm bars via set_quiet).
    verbose → console shows DEBUG and above (per-file detail).
    default → console shows INFO and above (previews, warnings, errors).
    log_file → full DEBUG log written to file with timestamps.
    """
    logger = logging.getLogger("imanage")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()

    console = TqdmHandler(stream=sys.stderr)
    if quiet:
        console.setLevel(logging.ERROR)
    elif verbose:
        console.setLevel(logging.DEBUG)
    else:
        console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(console)

    if log_file is not None:
        log_dir = os.path.dirname(os.path.abspath(log_file))
        os.makedirs(log_dir, exist_ok=True)
        fh = logging.FileHandler(log_file, encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(message)s"))
        logger.addHandler(fh)

    return logger
