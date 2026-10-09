"""Copy love.exe with its icon replaced by the game's (Windows only).

    py tools/win_icon.py love.exe icon.png out.exe

The icon is an exe resource: an RT_GROUP_ICON directory pointing at RT_ICON images. Every
existing icon resource is removed and the shared app icon (app_icon.py) is written in its
place, under the first group's id and language, so Explorer, the taskbar and the window
title bar (SDL takes the exe's first icon) all show it.

Run this on love.exe BEFORE the .love is appended: rewriting an exe's resources rebuilds the
file, and anything appended after the PE image (the fused game) would be cut off.
"""
import ctypes
import io
import shutil
import struct
import sys
from ctypes import wintypes

RT_ICON, RT_GROUP_ICON = 3, 14
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]   # 20 and 40 are the 125% DPI sizes

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
NAMEPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
LANGPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, wintypes.WORD, ctypes.c_void_p)
k32.LoadLibraryExW.restype = wintypes.HMODULE
k32.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
k32.FreeLibrary.argtypes = [wintypes.HMODULE]
k32.EnumResourceNamesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, NAMEPROC, ctypes.c_void_p]
k32.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p, LANGPROC, ctypes.c_void_p]
k32.BeginUpdateResourceW.restype = wintypes.HANDLE
k32.BeginUpdateResourceW.argtypes = [wintypes.LPCWSTR, wintypes.BOOL]
k32.UpdateResourceW.argtypes = [wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p, wintypes.WORD, ctypes.c_void_p, wintypes.DWORD]
k32.EndUpdateResourceW.argtypes = [wintypes.HANDLE, wintypes.BOOL]


def list_resources(exe, res_type):
    """[(name, lang)] for one resource type; name is an int id or a string."""
    h = k32.LoadLibraryExW(exe, None, 0x2 | 0x20)   # as a datafile + image resource: nothing runs
    if not h:
        raise SystemExit(f"can't open {exe}: {ctypes.WinError(ctypes.get_last_error())}")
    found = []

    def on_name(hm, t, name, _):
        key = name if name < 0x10000 else ctypes.wstring_at(name)
        k32.EnumResourceLanguagesW(hm, t, name, LANGPROC(lambda a, b, c, lang, d: found.append((key, lang)) or True), None)
        return True

    k32.EnumResourceNamesW(h, res_type, NAMEPROC(on_name), None)
    k32.FreeLibrary(h)
    return found


def dib(img):
    """An icon bitmap the way Windows lays it out: header (height doubled), BGRA rows bottom
    up, then the 1-bit AND mask (set where fully transparent) with rows padded to 4 bytes."""
    from PIL import Image
    w, h = img.size
    flipped = img.transpose(Image.FLIP_TOP_BOTTOM)
    alpha = flipped.getchannel("A").tobytes()
    row = (w + 31) // 32 * 4
    mask = bytearray(row * h)
    for y in range(h):
        for x in range(w):
            if alpha[y * w + x] == 0:
                mask[y * row + x // 8] |= 0x80 >> (x % 8)
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    return header + flipped.tobytes("raw", "BGRA") + bytes(mask)


def ico_images(png_path):
    """[(12-byte directory entry, image bytes)] of the shared app icon at every SIZES size:
    bitmaps for the small ones, PNG for 256 (the standard .ico layout since Vista)."""
    from PIL import Image
    import app_icon
    art = app_icon.render(png_path, 1024, 0)
    images = []
    for s in SIZES:
        img = art.resize((s, s), Image.LANCZOS)
        if s >= 256:
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            data = buf.getvalue()
        else:
            data = dib(img)
        entry = struct.pack("<BBBBHHI", s % 256, s % 256, 0, 0, 1, 32, len(data))   # 256 is written as 0
        images.append((entry, data))
    return images


def main(love_exe, icon_png, out_exe):
    groups = list_resources(love_exe, RT_GROUP_ICON)
    icons = list_resources(love_exe, RT_ICON)
    group_name, lang = groups[0] if groups else (1, 1033)
    images = ico_images(icon_png)
    shutil.copyfile(love_exe, out_exe)

    keep = []   # string names and data buffers must outlive the UpdateResource calls

    def res_id(name):
        if isinstance(name, int):
            return name
        keep.append(ctypes.create_unicode_buffer(name))
        return ctypes.addressof(keep[-1])

    def update(res_type, name, res_lang, data):
        if data is None:
            ptr, size = None, 0
        else:
            keep.append(ctypes.create_string_buffer(data, len(data)))
            ptr, size = ctypes.addressof(keep[-1]), len(data)
        if not k32.UpdateResourceW(h, res_type, res_id(name), res_lang, ptr, size):
            raise SystemExit(f"UpdateResource failed: {ctypes.WinError(ctypes.get_last_error())}")

    h = k32.BeginUpdateResourceW(out_exe, False)
    if not h:
        raise SystemExit(f"can't edit {out_exe}: {ctypes.WinError(ctypes.get_last_error())}")
    for name, res_lang in groups:
        update(RT_GROUP_ICON, name, res_lang, None)
    for name, res_lang in icons:
        update(RT_ICON, name, res_lang, None)
    group = struct.pack("<HHH", 0, 1, len(images))
    for i, (entry, image) in enumerate(images, start=1):
        update(RT_ICON, i, lang, image)
        group += entry + struct.pack("<H", i)
    update(RT_GROUP_ICON, group_name, lang, group)
    if not k32.EndUpdateResourceW(h, False):
        raise SystemExit(f"writing {out_exe} failed: {ctypes.WinError(ctypes.get_last_error())}")
    print(f"{out_exe}: icon from {icon_png} ({len(images)} sizes, replaced {len(icons)})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:4])
