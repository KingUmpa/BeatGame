"""Fuse a .love into LÖVE's macOS app bundle, zip to zip, without ever extracting it.

    py dist/fuse_mac.py love-11.5-macos.zip game.love out.zip "App Name" com.example.app 0.4 [icon.png]

Why zip-to-zip: love.app contains symlinks and executable bits. Extracting it onto NTFS and
re-zipping loses both, and the app then refuses to launch on the Mac. Copying the entries
straight across keeps every entry's Unix mode (external_attr), including the symlinks.
Every entry is also stamped "made on Unix" (create_system = 3); without that, macOS
ignores the mode bits, the executable loses +x and the app "can't be opened".

What changes inside the bundle (per the LÖVE wiki "Game Distribution" page):
  * love.app/ -> <App Name>.app/
  * Contents/Info.plist: CFBundleName / CFBundleIdentifier / version set, and the
    .love document-type claims removed so the app doesn't register as a .love opener
  * Contents/Resources/<App Name>.love added (LÖVE runs it automatically = "fused")
  * Contents/_CodeSignature/ dropped: the bundle is modified, so LÖVE's signature would be
    invalid anyway; an unsigned bundle is what right-click -> Open handles
  * with an icon PNG: Contents/Resources/OS X AppIcon.icns is rebuilt from it (Pillow), and
    CFBundleIconName is removed, or macOS 11+ keeps showing LÖVE's icon from Assets.car
"""
import io
import plistlib
import sys
import time
import zipfile

ICON_FILE = "Contents/Resources/OS X AppIcon.icns"   # what LÖVE's CFBundleIconFile names


def make_icns(png_path):
    """The shared app icon on Apple's 1024 grid (an 824 px rounded square with a 100 px
    margin, the shape every Big Sur+ app icon has), as .icns bytes."""
    import app_icon
    out = io.BytesIO()
    app_icon.render(png_path, 1024, 100).save(out, format="ICNS")
    return out.getvalue()


def main(src_zip, love_file, out_zip, app_name, bundle_id, version, icon_png=None):
    icns = make_icns(icon_png) if icon_png else None
    app_dir = app_name + ".app/"
    with zipfile.ZipFile(src_zip) as zin, zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zout:
        prefix = None
        for info in zin.infolist():
            if info.filename.endswith("love.app/") or info.filename.startswith("love.app/"):
                prefix = info.filename[: info.filename.index("love.app/") + len("love.app/")]
                break
        if prefix is None:
            raise SystemExit("no love.app/ inside " + src_zip)

        copied = 0
        for info in zin.infolist():
            if not info.filename.startswith(prefix):
                continue
            rel = info.filename[len(prefix):]
            if rel.startswith("Contents/_CodeSignature"):
                continue
            new_name = app_dir + rel
            data = zin.read(info)
            if rel == "Contents/Info.plist":
                pl = plistlib.loads(data)
                pl["CFBundleName"] = app_name
                pl["CFBundleDisplayName"] = app_name
                pl["CFBundleIdentifier"] = bundle_id
                pl["CFBundleShortVersionString"] = version
                pl["CFBundleVersion"] = version
                pl.pop("UTExportedTypeDeclarations", None)
                pl.pop("CFBundleDocumentTypes", None)
                if icns:
                    pl.pop("CFBundleIconName", None)
                data = plistlib.dumps(pl)
            elif rel == ICON_FILE and icns:
                data = icns
            ni = zipfile.ZipInfo(new_name, date_time=info.date_time)
            ni.external_attr = info.external_attr   # keeps mode bits and S_IFLNK for symlinks
            ni.create_system = 3                    # "made on Unix": macOS honours those bits
            ni.compress_type = zipfile.ZIP_STORED if info.is_dir() else zipfile.ZIP_DEFLATED
            zout.writestr(ni, data)
            copied += 1

        ni = zipfile.ZipInfo(app_dir + "Contents/Resources/" + app_name + ".love", date_time=time.localtime()[:6])
        ni.external_attr = 0o644 << 16
        ni.create_system = 3
        ni.compress_type = zipfile.ZIP_DEFLATED
        with open(love_file, "rb") as f:
            zout.writestr(ni, f.read())
        print(f"fused {app_name}.app ({copied} bundle entries{', icon from ' + icon_png if icns else ''}) -> {out_zip}")


if __name__ == "__main__":
    if len(sys.argv) not in (7, 8):
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
