#!/usr/bin/ python3
import os, sys, shutil, glob, argparse
import tomli
from libxmp import XMPFiles, consts
path = os.getcwd()
file_list = os.listdir(path)

"""
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
設定値
"""


jpg_dir_name = "jpg"
raw_dir_name = "raw"

target_jpg_extensions = ["JPG", "JPEG", "jpg", "jpeg"]
target_raw_extensions = ["ARW", "RAF", "CR3", "CR2", "NEF"]

meta_target = ["Rating", "Label"]
"""
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
"""


parser = argparse.ArgumentParser(description='Photographer Tool')
parser.add_argument('-d', '--delete', action="store_true")
parser.add_argument('-s', '--sync', action="store_true")
args = parser.parse_args()

def main():
    iCon = dir_structure()
    iCon.imagev()

    if args.delete:
        iCon.jremove()

    # jpg -> raw に XMP メタデータをコピー
    if args.sync:
        iCon.jremove()
        iCon.syncmeta()


def dir_structure():
    path = os.getcwd()
    # カレントディレクトリに"jpg_dir_name", raw_dir_nameが存在するか？
    file_list = os.listdir(path)
    current_dirs = [_file for _file in os.listdir(path) if os.path.isdir(os.path.join(path, _file)) ]
    if all(element in current_dirs for element in [jpg_dir_name, raw_dir_name] ):
        iCon = imageContainer(jpg_dir_name, raw_dir_name)
    else:
        # ディレクトリ作成
        for _dir in [jpg_dir_name, raw_dir_name]:
            os.makedirs(_dir)
        iCon = imageContainer(jpg_dir_name, raw_dir_name)
        for _file in os.listdir(os.getcwd()):
            if any(os.path.splitext(_file)[1].replace(".", "") == _ex for _ex in target_jpg_extensions):
                shutil.move(os.path.join(os.getcwd(), _file), iCon.jpg_dir_path)
            if any(os.path.splitext(_file)[1].replace(".", "") == _ex for _ex in target_raw_extensions):
                shutil.move(os.path.join(os.getcwd(), _file), iCon.raw_dir_path)
    return iCon


class imageContainer:
    def __init__(self, jpg, raw):
        self.jpg_dir_path = os.path.abspath(os.path.join(os.getcwd(), jpg))
        self.raw_dir_path = os.path.abspath(os.path.join(os.getcwd(), raw))

    """
    jpg, raw の仕分け
    """
    def imagev(self):
        for _file in os.listdir(os.getcwd()):
            if any(os.path.splitext(_file)[1].replace(".", "") == _ex for _ex in target_jpg_extensions):
                shutil.move(os.path.join(os.getcwd(), _file), self.jpg_dir_path)
            if any(os.path.splitext(_file)[1].replace(".", "") == _ex for _ex in target_raw_extensions):
                shutil.move(os.path.join(os.getcwd(), _file), self.raw_dir_path)
    """
    jpg_dir_path に存在しない同名ファイルを raw_dir_path から削除する
    """
    def jremove(self):
        j_files = [file for file in os.listdir(self.jpg_dir_path) if file != ".DS_Store"]
        j_sl = { i.split(".")[0] for i in j_files}

        r_files = [file for file in os.listdir(self.raw_dir_path) if file != ".DS_Store"]
        r_sl = { i.split(".")[0] for i in r_files}
        diff = r_sl - j_sl
        for d in diff:
            for ex in target_raw_extensions:
                target_file_path = os.path.join(self.raw_dir_path, d + "." + ex)
                if os.path.isfile(target_file_path):
                    os.remove(target_file_path)
                    print("Rmove {}".format(target_file_path))


    def syncmeta(self):
        self._CheckXMP()
        jpgs=[]
        for ex in target_jpg_extensions:
            jpgs += glob.glob(self.jpg_dir_path+"/*.{}".format(ex))
        xmps = glob.glob(self.raw_dir_path+"/*.xmp")
        if len(jpgs) != len(xmps):
            print("jpgs と xmps の数が一致しません。ファイルの状態を確認してください。")
            sys.exit()
        jpgs.sort()
        xmps.sort()
        for j, x in zip(jpgs, xmps):
            for t in meta_target:
                if self.__pregetMeta(j, t):
                    self._writeMetaData(x, t, self._getMeta(j, t))
                print(j, "- {} sync -> ".format(t),x)

    # raw ディレクトリに xmp ファイルがあるか確認-> 存在しない場合は、bridge で MakeMeta ワークフローを実行する。
    def _CheckXMP(self):
        if glob.glob(self.raw_dir_path+"/*.xmp"):
            return True
        else:
            print("Do workflow on Adobe Bridge")
            sys.exit()

    def _writeMetaData(self, target, ns, item):
        isFirst = True
        # 既に ns が 書き込まれてる場合、そうでない場合で場合分け
        with open(target, "r") as file:
            tmp = file.readlines()
            if any("xmp:{}".format(ns) in line for line in tmp):
                isFirst = False

        if isFirst:
            target_string = "xmp:CreatorTool"
        else:
            target_string = "xmp:{}".format(ns)

        line_number = 0
        with open(target, "r") as file:
            xmp = file.readlines()
            for line in xmp:
                line_number += 1
                if target_string in line:
                    break
        if isFirst:
            xmp.insert(line_number, '   xmp:{}="{}"\n'.format(ns, item))
        else:
            xmp[line_number-1] = '   xmp:{}="{}"\n'.format(ns, item)

        with open(target, "w", encoding='utf-8') as file:
            file.writelines(xmp)

    # 指定した jpg ファイルから Meta(Rating or Label)を取得する。
    def _getMeta(self, target, meta="Rating"):
        xmpfile = XMPFiles(file_path=target, open_forupdate=False)
        xmp = xmpfile.get_xmp()
        value = xmp.get_property(consts.XMP_NS_XMP, meta)
        xmpfile.close_file()
        return value

    def __pregetMeta(self, target, meta="Rating"):
        xmpfile = XMPFiles(file_path=target, open_forupdate=False)
        xmp = xmpfile.get_xmp()
        try:
            value = xmp.get_property(consts.XMP_NS_XMP, meta)
        except:
            safe = False
        else:
            safe = True
        return safe



if __name__ == "__main__":
    main()