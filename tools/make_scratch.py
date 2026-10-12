"""Makes assets/audio/sfx/scratch.wav: a DJ record scratch, played when a guess is wrong.

    python3 tools/make_scratch.py [source.wav] [seconds into it]

A scratch is a record dragged back and forth under the needle, so this drags a moment of a
song's own track: the playback position follows the hand (MOVES: speed in x real time, back is
negative) and the level follows how fast it is moving. Needs numpy.
"""
import os, sys, wave
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "assets/audio/songs/huntin_wabbits/full.wav")
OUT = os.path.join(ROOT, "assets/audio/sfx/scratch.wav")
RATE = 44100
# (seconds, speed at its start, speed at its end): a pull back, a push, a longer pull back
MOVES = [(0.13, -4.0, -1.2), (0.03, 0.0, 0.0), (0.10, 3.4, 1.0), (0.03, 0.0, 0.0), (0.22, -3.6, -0.3)]


def read_mono(path):
    w = wave.open(path)
    n, width, ch = w.getnframes(), w.getsampwidth(), w.getnchannels()
    raw = np.frombuffer(w.readframes(n), dtype=np.uint8).reshape(-1, width)
    pad = np.zeros((raw.shape[0], 4 - width), dtype=np.uint8)
    x = np.concatenate([pad, raw], axis=1).view("<i4").ravel() / 2147483648.0
    assert w.getframerate() == RATE, "source must be 44.1 kHz"
    return x.reshape(-1, ch).mean(axis=1)


def loudest(x, seconds=1.0):
    hop = RATE // 10
    win = int(seconds * RATE)
    e = np.array([np.mean(x[i:i + win] ** 2) for i in range(0, len(x) - win, hop)])
    return np.argmax(e) * hop / RATE + seconds / 2


def main():
    src = read_mono(sys.argv[1] if len(sys.argv) > 1 else SOURCE)
    at = float(sys.argv[2]) if len(sys.argv) > 2 else loudest(src[: 60 * RATE])
    speed = np.concatenate([np.linspace(a, b, int(s * RATE)) for s, a, b in MOVES])
    pos = at * RATE + np.cumsum(speed)
    i = np.floor(pos).astype(int)
    f = pos - i
    out = src[i] * (1 - f) + src[i + 1] * f
    # the needle is loud while the record moves and silent while the hand turns round
    level = np.minimum(1.0, np.abs(speed) / 1.0)
    k = int(0.004 * RATE)
    level = np.convolve(level, np.ones(k) / k, mode="same")
    out = out * level
    # a record dragged this fast is mostly its top end
    out = out - np.convolve(out, np.ones(40) / 40, mode="same") * 0.7
    fade = int(0.01 * RATE)
    out[-fade:] *= np.linspace(1, 0, fade)
    out = out / np.max(np.abs(out)) * 0.85
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    w = wave.open(OUT, "w")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes((out * 32767).astype("<i2").tobytes())
    w.close()
    print(f"wrote {OUT}: {len(out) / RATE:.2f} s from {at:.2f} s into {os.path.basename(sys.argv[1] if len(sys.argv) > 1 else SOURCE)}")


main()
