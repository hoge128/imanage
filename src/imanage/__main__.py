import sys

# PyInstaller frozen 実行ファイルでは、Python 内部の multiprocessing (resource_tracker 等)
# がサブプロセスを生成するとき、frozen binary を
#   binary [-B -S -I ...] -c "from multiprocessing.resource_tracker import main;main(N)"
# という形で呼び出す。argparse がこれを imanage の引数として解析するとエラーになるため、
# -c フラグを検出したら main() を呼ばずにそのコードを直接 exec して終了する。
if getattr(sys, 'frozen', False):
    import multiprocessing
    multiprocessing.freeze_support()
    _args = sys.argv[1:]
    while _args and _args[0] != '-c' and _args[0].startswith('-'):
        _args.pop(0)
    if len(_args) >= 2 and _args[0] == '-c':
        exec(_args[1])  # noqa: S102
        raise SystemExit(0)

from imanage.core import main
main()
