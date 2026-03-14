from importlib.metadata import version, PackageNotFoundError
try:
    __version__ = version("imanage")
except PackageNotFoundError:
    __version__ = "unknown"
