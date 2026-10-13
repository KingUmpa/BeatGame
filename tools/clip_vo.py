"""Cuts one long recording of the voice lines into assets/audio/vo/<name>.wav.

    python3 tools/clip_vo.py recording.mp3 [--dry]

The recording is every line of LINES in order, with a pause between lines. A line spoken as
several sentences is that many stretches of sound (the number after its name); pauses inside
a line are shortened to PAUSE. --dry only prints what it found. Needs numpy; anything but a
.wav is converted with macOS's afconvert.
"""
import os, subprocess, sys, tempfile, wave
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets/audio/vo")
RATE = 44100
GAP = 0.25      # seconds of quiet that separate two stretches of speech
QUIET = 0.02    # of the loudest 10 ms: below this is quiet
PAUSE = 0.35    # the longest pause kept inside a line
LINES = [
    ("title", 1), ("press_start", 1), ("idle_nudge", 2), ("howto_1", 3), ("howto_strikes", 1),
    ("level_1", 1), ("level_2", 1), ("level_last", 1), ("part_bass", 1), ("part_synth", 1), ("part_vocal_chops", 1),
    ("waiting", 1), ("strike_1", 1), ("strike_2", 2), ("strike_3", 2), ("game_over", 1),
    ("reached_level_1", 1), ("reached_level_2", 1), ("reached_level_last", 2),
    ("locked_bass", 1), ("locked_synth", 1), ("locked_vocal_chops", 1), ("nice", 1), ("great", 1), ("amazing", 1),
    ("strikes_cleared", 1), ("you_built_it", 1), ("play_along", 1), ("all_clear", 2), ("flawless", 1),
    ("play_again", 1), ("paused", 1), ("resume", 1), ("next_song", 1),
]


def read(path):
    if not path.lower().endswith(".wav"):
        tmp = os.path.join(tempfile.mkdtemp(), "in.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", path, tmp], check=True)
        path = tmp
    w = wave.open(path)
    assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, "want 44.1 kHz mono 16-bit"
    return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)


def stretches(x):
    hop = RATE // 100
    rms = np.sqrt(np.mean(x[: len(x) // hop * hop].reshape(-1, hop) ** 2, axis=1))
    loud = rms > rms.max() * QUIET
    out, start, quiet = [], None, 0
    for i, on in enumerate(loud):
        if on:
            if start is None: start = i
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet >= GAP * 100:
                out.append((start * hop, (i - quiet + 1) * hop)); start = None
    if start is not None: out.append((start * hop, len(x)))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    x = read(args[0])
    found = stretches(x)
    want = sum(n for _, n in LINES)
    print(f"{len(found)} stretches of speech, the script needs {want}")
    if len(found) != want:
        for i, (a, b) in enumerate(found): print(f"  {i + 1:3d}  {a / RATE:7.2f} - {b / RATE:7.2f}  {(b - a) / RATE:5.2f} s")
        sys.exit("they don't match: fix LINES (or GAP) for this recording")
    pre, post, fin, fout = int(.03 * RATE), int(.10 * RATE), int(.005 * RATE), int(.04 * RATE)
    k = 0
    for name, n in LINES:
        parts = []
        for j in range(n):
            a, b = found[k + j]
            lo = max(0, a - pre, (found[k + j - 1][1] + a) // 2 if k + j > 0 else 0)
            hi = min(len(x), b + post, (b + found[k + j + 1][0]) // 2 if k + j + 1 < len(found) else len(x))
            c = x[lo:hi].copy()
            c[:fin] *= np.linspace(0, 1, fin); c[-fout:] *= np.linspace(1, 0, fout)
            if j > 0:
                gap = min(PAUSE, (a - found[k + j - 1][1]) / RATE)
                parts.append(np.zeros(max(0, int(gap * RATE) - pre - post)))
            parts.append(c)
        k += n
        clip = np.concatenate(parts)
        print(f"  {name:20s} {len(clip) / RATE:5.2f} s  peak {np.abs(clip).max() / 32768:.2f}")
        if not dry:
            w = wave.open(os.path.join(OUT, name + ".wav"), "w")
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
            w.writeframes(clip.astype("<i2").tobytes()); w.close()


main()
