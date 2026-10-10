"""Sign, notarize and staple the fused macOS app, from Windows, then re-zip it.

    py dist/sign_mac.py <app-led.zip> <out.zip> <signing dir> <rcodesign.exe> [--skip-notarize]

Needs Windows Developer Mode (so Python may create the bundle's symlinks on disk).

Steps:
  1. extract the fused app with real symlinks and Unix modes
  2. rcodesign sign  (Developer ID Application cert + key, hardened runtime, timestamp,
     LuaJIT entitlements)                                  -> Contents/_CodeSignature etc.
  3. rcodesign notary-submit --wait --staple               -> Apple scans it, ticket stapled
  4. zip the bundle back up, symlinks and modes intact, "made on Unix"

The signing dir holds: developer_id.cer, developer_id_key.pem, AuthKey.p8, notary.txt
(issuer=..., key=...). It is git-ignored.
"""
import os
import shutil
import stat
import subprocess
import sys
import time
import zipfile

ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- LuaJIT writes machine code at runtime; without these the hardened runtime kills it -->
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
"""


def extract_with_symlinks(zip_path, dest):
    """Returns {relative path: unix mode} because NTFS cannot store the execute bit; the
    re-zip step reads modes from this map, not from the filesystem."""
    # Regular files and directories first; symlinks after, so each link's target exists and
    # we can tell Windows whether it is a directory link (Windows has two kinds and a file
    # link to a directory does not resolve as a directory).
    links = []
    modes = {}
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            mode = info.external_attr >> 16
            rel = info.filename.rstrip("/")
            if mode:
                modes[rel] = mode & 0o777
            target = os.path.join(dest, info.filename)
            if info.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if stat.S_ISLNK(mode):
                links.append((target, z.read(info).decode("utf-8")))
            else:
                with open(target, "wb") as f:
                    f.write(z.read(info))
    # create links whose targets already resolve; repeat for chains (Current -> A first)
    pending = links
    while pending:
        remaining = []
        for target, link_to in pending:
            resolved = os.path.normpath(os.path.join(os.path.dirname(target), link_to))
            if os.path.exists(resolved):
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(link_to.replace("/", os.sep), target, target_is_directory=os.path.isdir(resolved))
            else:
                remaining.append((target, link_to))
        if len(remaining) == len(pending):
            for target, link_to in remaining:   # dangling in the source too; keep as file links
                os.symlink(link_to.replace("/", os.sep), target)
            break
        pending = remaining
    return modes


def zip_with_symlinks(src_dir, out_zip, extra_files, modes):
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zout:
        for root, dirs, files in os.walk(src_dir):
            dirs.sort(); files.sort()
            for name in dirs + files:
                full = os.path.join(root, name)
                rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
                st = os.lstat(full)
                zi = zipfile.ZipInfo(rel + ("/" if os.path.isdir(full) and not os.path.islink(full) else ""),
                                     date_time=time.localtime(st.st_mtime)[:6])
                zi.create_system = 3
                if os.path.islink(full):
                    zi.external_attr = (stat.S_IFLNK | 0o755) << 16
                    zi.compress_type = zipfile.ZIP_STORED
                    zout.writestr(zi, os.readlink(full).replace(os.sep, "/"))
                elif os.path.isdir(full):
                    zi.external_attr = (stat.S_IFDIR | 0o755) << 16
                    zi.compress_type = zipfile.ZIP_STORED
                    zout.writestr(zi, b"")
                else:
                    # original mode from the source zip; files the signer added (CodeResources,
                    # CodeSignature, stapled ticket) are plain data
                    perm = modes.get(rel, 0o644)
                    if rel.endswith("/MacOS/" + os.path.basename(rel)) or "/MacOS/" in rel:
                        perm = 0o755
                    zi.external_attr = (stat.S_IFREG | perm) << 16
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    with open(full, "rb") as f:
                        zout.writestr(zi, f.read())
        for arcname, path, perm in extra_files:
            zi = zipfile.ZipInfo(arcname, date_time=time.localtime()[:6])
            zi.create_system = 3
            zi.external_attr = (stat.S_IFREG | perm) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as f:
                zout.writestr(zi, f.read())


# Some frameworks LÖVE bundles (freetype) have no CFBundleIdentifier in their Info.plist.
# Apple's codesign infers one; rcodesign refuses to sign. Give each one a stable id.
def fix_framework_identifiers(app):
    import plistlib
    fw_root = os.path.join(app, "Contents", "Frameworks")
    if not os.path.isdir(fw_root):
        return
    for root, dirs, files in os.walk(fw_root):
        if "Info.plist" in files and os.path.basename(root) == "Resources":
            path = os.path.join(root, "Info.plist")
            try:
                with open(path, "rb") as f:
                    pl = plistlib.load(f)
            except Exception:
                continue
            if not pl.get("CFBundleIdentifier"):
                # .../Frameworks/<name>.framework/Versions/A/Resources/Info.plist
                fw = root
                while fw and not fw.endswith(".framework"):
                    fw = os.path.dirname(fw)
                name = os.path.basename(fw).replace(".framework", "") or pl.get("CFBundleName", "framework")
                pl["CFBundleIdentifier"] = "org.love2d." + "".join(c if c.isalnum() else "-" for c in name)
                with open(path, "wb") as f:
                    plistlib.dump(pl, f)
                print(f"added CFBundleIdentifier {pl['CFBundleIdentifier']} to {os.path.relpath(path, app)}")


def run(cmd, cwd=None):
    print("$", " ".join(f'"{c}"' if " " in c else c for c in cmd), flush=True)
    r = subprocess.run(cmd, text=True, capture_output=True, cwd=cwd)
    if r.stdout.strip():
        print(r.stdout.rstrip())
    if r.returncode != 0:
        print(r.stderr.rstrip())
        raise SystemExit(f"command failed ({r.returncode})")
    return r.stdout


def main(argv):
    app_zip, out_zip, sign_dir, rcodesign = argv[:4]
    skip_notarize = "--skip-notarize" in argv
    extras = []
    for a in argv[4:]:
        if a.startswith("--extra="):
            arc, path = a[len("--extra="):].split("=", 1)
            extras.append((arc, path, 0o755 if arc.endswith((".command", ".sh")) else 0o644))

    cert = os.path.join(sign_dir, "developer_id.cer")
    key = os.path.join(sign_dir, "developer_id_key.pem")
    for p in (cert, key):
        if not os.path.exists(p):
            raise SystemExit("missing " + p)

    work = os.path.join(os.path.dirname(out_zip), "_sign")
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work)
    modes = extract_with_symlinks(app_zip, work)
    apps = [d for d in os.listdir(work) if d.endswith(".app")]
    if len(apps) != 1:
        raise SystemExit("expected one .app in " + app_zip)
    app = os.path.join(work, apps[0])

    fix_framework_identifiers(app)

    ent = os.path.join(work, "entitlements.plist")
    with open(ent, "w", encoding="utf-8") as f:
        f.write(ENTITLEMENTS)

    # rcodesign reads "<scope>:<value>" on scoped options, so a Windows drive letter in the
    # entitlements path ("U:\...") is taken as a scope and the entitlements silently apply to
    # nothing. Run from the work dir and pass a relative path.
    run([rcodesign, "sign",
         "--pem-file", os.path.abspath(key), "--certificate-der-file", os.path.abspath(cert),
         "--for-notarization",
         "--entitlements-xml-file", "entitlements.plist",
         apps[0]], cwd=work)

    # prove the entitlements landed on the main executable before spending a notarization
    info = run([rcodesign, "print-signature-info", os.path.join(app, "Contents", "MacOS", "love")])
    if "allow-jit" not in info:
        raise SystemExit("entitlements missing from the main executable; refusing to notarize")
    print("entitlements verified on main executable")

    if not skip_notarize:
        notary = {}
        with open(os.path.join(sign_dir, "notary.txt"), encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    notary[k.strip()] = v.strip()
        api_key_json = os.path.join(work, "api-key.json")
        try:
            run([rcodesign, "encode-app-store-connect-api-key", "-o", api_key_json,
                 notary["issuer"], notary["key"], os.path.join(sign_dir, "AuthKey.p8")])
            run([rcodesign, "notary-submit", "--api-key-file", api_key_json,
                 "--wait", "--max-wait-seconds", "1800", "--staple", app])
        finally:
            # the encoded API key never stays on disk, even when Apple refuses the submission
            if os.path.exists(api_key_json):
                os.remove(api_key_json)

    os.remove(ent)
    zip_with_symlinks(work, out_zip, extras, modes)
    shutil.rmtree(work)
    print("signed" + ("" if skip_notarize else ", notarized and stapled") + f" -> {out_zip}")


if __name__ == "__main__":
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    main(sys.argv[1:])
