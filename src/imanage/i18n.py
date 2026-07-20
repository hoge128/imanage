"""i18n — gettext による日英メッセージ切替

言語判定: IMANAGE_LANG → LANG / LC_ALL / LC_MESSAGES の順。
値が 'en' で始まれば英語カタログを使用し、それ以外（ja 含む）は
NullTranslations（日本語フォールバック）を使用する。
"""
import gettext
import os
import sys


def _detect_lang() -> str:
    """環境変数から使用言語を判定して返す（'en' または 'ja'）。"""
    for var in ("IMANAGE_LANG", "LANG", "LC_ALL", "LC_MESSAGES"):
        val = os.environ.get(var, "")
        if val:
            if val.lower().startswith("en"):
                return "en"
            # ja / C / POSIX など → 日本語フォールバック
            return "ja"
    return "ja"


def _get_locale_dir() -> str:
    """locale ディレクトリの絶対パスを返す。PyInstaller frozen 環境でも動く。"""
    if getattr(sys, "frozen", False):
        # PyInstaller では sys._MEIPASS にバンドルデータが展開される
        base = sys._MEIPASS  # type: ignore[attr-defined]
    else:
        base = os.path.dirname(__file__)
    return os.path.join(base, "locale")


def _build_translation() -> gettext.NullTranslations:
    lang = _detect_lang()
    if lang == "en":
        locale_dir = _get_locale_dir()
        try:
            t = gettext.translation(
                domain="imanage",
                localedir=locale_dir,
                languages=["en"],
            )
            return t
        except FileNotFoundError:
            pass
    # 日本語 or カタログ未発見 → NullTranslations（msgid をそのまま返す）
    return gettext.NullTranslations()


_translation = _build_translation()


def _(message: str) -> str:
    """翻訳関数。英語環境なら英訳を、それ以外は日本語原文をそのまま返す。"""
    return _translation.gettext(message)
