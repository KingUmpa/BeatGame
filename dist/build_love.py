"""Build the .love (the game alone, runs anywhere LÖVE 11.5 is) from the project folder.

    py dist/build_love.py <project root> <out.love>

What goes in: the code and tunables (main.lua, conf.lua, juice.json, lib/, src/, the fonts),
every song (songs/*.json) with its VO lines and full track, every level (levels/*.json and its
.mid) with the samples and backing it plays. Only audio something points at is packed, so
the rest of assets/audio (unused samples, the instrumental) and source/ (Ableton sets) stay out. Tests, tools, exports and
the editors' scratch files stay out too.

Fails if a song or level points at a file that isn't there.
"""
import json
import os
import sys
import zipfile

CODE = ["main.lua", "conf.lua", "juice.json", "lib", "src", "assets/fonts"]


def main(root, out):
    files = set()

    def add(rel):
        files.add(rel.replace("\\", "/"))

    for item in CODE:
        path = os.path.join(root, item)
        if os.path.isdir(path):
            for d, _, names in os.walk(path):
                for n in names:
                    if n.endswith((".pyc", ".bak")):
                        continue
                    add(os.path.relpath(os.path.join(d, n), root))
        elif os.path.isfile(path):
            add(item)

    def load(rel):
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return json.load(f)

    songs = sorted(f for f in os.listdir(os.path.join(root, "songs")) if f.endswith(".json"))
    for f in songs:
        add("songs/" + f)
        song = load("songs/" + f)
        for e in song.get("levels", []):
            if isinstance(e, dict) and e.get("vo"):
                add(e["vo"])
        if isinstance(song.get("finale"), dict) and song["finale"].get("file"):
            add(song["finale"]["file"])

    levels = sorted(f for f in os.listdir(os.path.join(root, "levels")) if f.endswith(".json"))
    for f in levels:
        add("levels/" + f)
        lv = load("levels/" + f)
        add(lv["midi"])
        for s in lv.get("sounds", []):
            add(s["sample"])
        if isinstance(lv.get("backing"), dict):
            add(lv["backing"]["file"])

    missing = sorted(f for f in files if not os.path.isfile(os.path.join(root, f)))
    if missing:
        raise SystemExit("missing files:\n  " + "\n  ".join(missing))

    total = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in sorted(files):
            path = os.path.join(root, rel)
            total += os.path.getsize(path)
            z.write(path, rel)
    print(f"built {out}: {len(files)} files ({len(songs)} songs, {len(levels)} levels), "
          f"{total / 1e6:.1f} MB in, {os.path.getsize(out) / 1e6:.1f} MB packed")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
