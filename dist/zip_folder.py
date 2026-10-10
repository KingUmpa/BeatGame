"""Zip a folder, the folder itself at the top of the zip, with "/" separators.

    py dist/zip_folder.py <folder> <out.zip>

(PowerShell 5's Compress-Archive writes "\\" separators, which unzip tools other than
Windows Explorer turn into odd file names.)
"""
import os
import sys
import zipfile


def main(folder, out):
    folder = os.path.abspath(folder)
    base = os.path.dirname(folder)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for d, _, names in os.walk(folder):
            for n in sorted(names):
                path = os.path.join(d, n)
                z.write(path, os.path.relpath(path, base).replace(os.sep, "/"))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
