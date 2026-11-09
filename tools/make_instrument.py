#!/usr/bin/env python3
"""Turn a solo recording into a Fonn instrument (FONN-OWNSOUND-1).

Give it one or more recordings of a single instrument playing on its own --
a tune, scales, long notes, anything -- and it writes one sample per note,
named the way Fonn's player asks for them:

    <instrument>-<Note>.mp3      e.g.  violin-D5.mp3, accordion-Bb4.mp3

How it works:
  1. Tracks the pitch through the recording (YIN, every 6 ms).
  2. Cuts it into notes wherever the pitch settles on a semitone.
  3. Keeps the best example of each note: long, steady, clean start, not
     clipped.
  4. Tunes each one exactly to its note.
  5. Makes each at least 3 seconds long, so held notes don't stop short:
     a steady stretch from the middle of the note is looped with crossfades.
  6. Fills any note that was never played from its nearest neighbour,
     tuned up or down (at most a few semitones where possible).
  7. Evens out the levels and writes a report of what came from where.

Usage:
    python3 make_instrument.py violin fiddle-tune.wav more-fiddle.m4a --out out/
    python3 make_instrument.py accordion box.wav --low 48 --high 96

Needs numpy and ffmpeg. Anything ffmpeg can read will do as input.
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np

SR = 44100
HOP = 256                      # ~5.8 ms
FRAME = 2048
NAMES = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

# Sensible ranges, as MIDI notes. Fiddle: G3 to about E7. Accordion (melody
# side of a box): roughly F3 to C7.
RANGES = {"violin": (55, 100), "accordion": (53, 96), "flute": (59, 96), "whistle": (71, 100)}
# The whistle is written an octave below how it sounds, and Fonn names its
# samples by the written note: whistle-D4.mp3 sounds D5.
NAME_OFFSET = {"whistle": -12}


def note_name(m):
    return f"{NAMES[m % 12]}{m // 12 - 1}"


def load(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le",
                          "-ac", "1", "-ar", str(SR), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def yin(x, fmin, fmax, threshold=0.12):
    """Pitch (Hz, 0 for none) and aperiodicity per hop."""
    tmin, tmax = int(SR / fmax), int(SR / fmin) + 1
    n = 1 + (len(x) - FRAME - tmax) // HOP
    f0 = np.zeros(max(n, 0))
    ap = np.ones(max(n, 0))
    for i in range(max(n, 0)):
        s = i * HOP
        frame = x[s:s + FRAME + tmax]
        w = frame[:FRAME]
        # Difference function via FFT autocorrelation.
        size = 1 << int(np.ceil(np.log2(len(frame) + FRAME)))
        fx = np.fft.rfft(frame, size)
        fw = np.fft.rfft(w[::-1], size)
        corr = np.fft.irfft(fx * fw, size)[FRAME - 1:FRAME - 1 + tmax]
        energy = np.cumsum(frame ** 2)
        e0 = energy[FRAME - 1]
        et = energy[FRAME - 1 + np.arange(tmax)] - np.concatenate(([0], energy[:tmax - 1]))
        d = e0 + et - 2 * corr
        d[0] = 0
        cum = np.cumsum(d[1:]) / np.arange(1, tmax)
        dn = np.ones(tmax)
        dn[1:] = d[1:] / np.where(cum == 0, 1, cum)
        cand = np.where(dn[tmin:] < threshold)[0]
        if len(cand) == 0:
            continue
        t = cand[0] + tmin
        while t + 1 < tmax and dn[t + 1] < dn[t]:
            t += 1
        if 1 <= t < tmax - 1:                      # parabolic refinement
            a, b, c = dn[t - 1], dn[t], dn[t + 1]
            den = a - 2 * b + c
            t = t + (0.5 * (a - c) / den if den else 0)
        f0[i] = SR / t
        ap[i] = dn[int(round(t))] if int(round(t)) < tmax else 1
    return f0, ap


def segments(x, f0, ap, low, high, min_ms=110):
    """Stretches where the pitch sits on one semitone."""
    rms = np.array([np.sqrt(np.mean(x[i * HOP:i * HOP + FRAME] ** 2)) for i in range(len(f0))])
    # Relative to the loud passages, not the quiet ones: a tune played
    # straight through has no silences, so its quietest fifth is still music.
    floor = max(np.percentile(rms, 99) * 0.05 if len(rms) else 0, 1e-4)
    raw = np.where(f0 > 0, 69 + 12 * np.log2(np.maximum(f0, 1e-9) / 440), np.nan)
    # Smooth over ~50 ms so vibrato and a scratchy frame or two don't break a
    # held note into pieces; a real change of note lasts longer than that.
    midi = raw.copy()
    k = 4
    for i in range(len(raw)):
        w = raw[max(i - k, 0):i + k + 1]
        w = w[~np.isnan(w)]
        midi[i] = np.median(w) if len(w) > k else np.nan
    near = np.round(midi)
    # Any steady note counts, however far out of tune -- a held note can sit
    # nearly a quarter-tone off. Better-tuned examples are preferred in score().
    ok = (~np.isnan(midi)) & (np.abs(midi - near) <= 0.5) & (ap < 0.25) & (rms > floor) \
        & (near >= low) & (near <= high)
    # Bridge dropouts of up to 3 frames (~17 ms) inside a note.
    for i in range(1, len(ok) - 1):
        if not ok[i]:
            j = i
            while j < len(ok) and not ok[j] and j - i < 3:
                j += 1
            if j < len(ok) and ok[j] and ok[i - 1] and near[i - 1] == near[j]:
                ok[i:j] = True
                near[i:j] = near[j]
    out, i, n = [], 0, len(f0)
    min_frames = int(min_ms / 1000 * SR / HOP)
    while i < n:
        if not ok[i]:
            i += 1
            continue
        j = i
        while j + 1 < n and ok[j + 1] and near[j + 1] == near[i]:
            j += 1
        if j - i + 1 >= min_frames:
            cents = 100 * (midi[i:j + 1] - near[i])
            out.append(dict(note=int(near[i]), start=i, end=j + 1,
                            cents=float(np.median(cents)),
                            wobble=float(np.std(cents)),
                            level=float(np.median(rms[i:j + 1])),
                            onset=float(rms[max(i - 3, 0)] / max(np.median(rms[i:j + 1]), 1e-9))))
        i = j + 1
    return out


def clipped(y):
    """True when the waveform's tops are flattened -- real clipping.

    A level above 1.0 alone is not enough: a loud recording decoded from AAC
    comes back with its true peaks above full scale, smooth and undamaged.
    Clipping shows as runs of nearly equal samples along the top.
    """
    peak = np.max(np.abs(y))
    if peak < 0.95:
        return False
    top = np.abs(y) > 0.97 * peak
    flat = np.abs(np.diff(y)) < 0.002 * peak
    return np.sum(top[1:] & flat) / max(np.sum(top), 1) > 0.25


def score(seg):
    secs = (seg["end"] - seg["start"]) * HOP / SR
    # Long and steady counts for most; a start that rises from quiet (a fresh
    # note, not one slurred into) helps; heavy vibrato or a wobbly pitch hurts.
    return min(secs, 1.5) * 2 + (0.6 if seg["onset"] < 0.5 else 0) - seg["wobble"] / 25 \
        - abs(seg["cents"]) / 60


def lengthen(y, want):
    """Make y at least `want` samples long by looping its steady middle."""
    if len(y) >= want:
        return y
    a, b = int(len(y) * 0.35), int(len(y) * 0.75)
    loop = y[a:b]
    if len(loop) < 2048:
        return np.concatenate([y, np.zeros(want - len(y))])
    xf = min(1024, len(loop) // 4)
    fade_in, fade_out = np.linspace(0, 1, xf), np.linspace(1, 0, xf)
    out = y[:b].copy()
    while len(out) < want:
        seg = loop.copy()
        out[-xf:] = out[-xf:] * fade_out + seg[:xf] * fade_in
        out = np.concatenate([out, seg[xf:]])
    return out[:want]


def shift(y, semis):
    """Retune by resampling (changes length a little, which is fine)."""
    if abs(semis) < 1e-4:
        return y
    r = 2 ** (semis / 12)
    idx = np.arange(0, len(y) - 1, r)
    return np.interp(idx, np.arange(len(y)), y)


def write_mp3(y, path):
    y = np.clip(y, -1, 1).astype(np.float32)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(SR),
                    "-ac", "1", "-i", "-", "-b:a", "128k", path],
                   input=y.tobytes(), check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("instrument", help="violin or accordion (the name Fonn uses)")
    ap.add_argument("recordings", nargs="+")
    ap.add_argument("--out", default="out")
    ap.add_argument("--low", type=int, help="lowest MIDI note to write")
    ap.add_argument("--high", type=int, help="highest MIDI note to write")
    ap.add_argument("--seconds", type=float, default=3.0, help="length of each sample")
    ap.add_argument("--fill", default="21-108", help="MIDI range to fill by retuning, e.g. 21-108 (sounding pitch)")
    ap.add_argument("--name-offset", type=int, help="semitones added to the note in each file name")
    args = ap.parse_args()

    low, high = RANGES.get(args.instrument, (40, 100))
    low, high = args.low or low, args.high or high
    fill_lo, fill_hi = (int(v) for v in args.fill.split("-"))
    os.makedirs(args.out, exist_ok=True)
    offset = args.name_offset if args.name_offset is not None else NAME_OFFSET.get(args.instrument, 0)

    best = {}                                   # note -> (score, seg, audio)
    for path in args.recordings:
        x = load(path)
        f0, aper = yin(x, 440 * 2 ** ((low - 1 - 69) / 12), 440 * 2 ** ((high + 1 - 69) / 12))
        for seg in segments(x, f0, aper, low, high):
            sc = score(seg)
            a = max(seg["start"] * HOP - int(0.02 * SR), 0)
            b = seg["end"] * HOP + FRAME // 2
            clip = x[a:b]
            if clipped(clip):
                continue
            if seg["note"] not in best or sc > best[seg["note"]][0]:
                seg["file"], seg["at"] = os.path.basename(path), round(a / SR, 2)
                best[seg["note"]] = (sc, seg, clip)

    if not best:
        sys.exit("No clear notes found. Is it a solo recording of one instrument?")

    # A note heard only in passing (under ~0.35 s) makes a poor loop. If a
    # neighbour a semitone away was held, retune that instead.
    held = {n for n, (_, sg, _) in best.items() if (sg["end"] - sg["start"]) * HOP / SR >= 0.35}
    for n in list(best):
        if n not in held and (n - 1 in held or n + 1 in held):
            del best[n]

    want = int(args.seconds * SR)
    level = np.median([np.sqrt(np.mean(c ** 2)) for _, _, c in best.values()])
    made, report = {}, {}
    for note, (_, seg, clip) in best.items():
        y = shift(clip, -seg["cents"] / 100)          # exactly in tune
        y = lengthen(y, want)
        made[note] = y
        report[note_name(note)] = dict(source="recorded", file=seg["file"], at_seconds=seg["at"],
                                       length_s=round((seg["end"] - seg["start"]) * HOP / SR, 2),
                                       was_off_by_cents=round(seg["cents"], 1))
    recorded = sorted(made)
    for note in range(fill_lo, fill_hi + 1):
        if note in made:
            continue
        src = min(recorded, key=lambda r: (abs(r - note), r < note))
        made[note] = lengthen(shift(made[src], note - src), want)[:want]
        report[note_name(note)] = dict(source="retuned", from_note=note_name(src),
                                       semitones=note - src)

    fade = int(0.35 * SR)
    for note, y in made.items():
        y = y[:want].copy()
        y *= level / max(np.sqrt(np.mean(y[:int(1.0 * SR)] ** 2)), 1e-9)
        y[-fade:] *= np.linspace(1, 0, fade)
        y[:64] *= np.linspace(0, 1, 64)
        peak = np.max(np.abs(y))
        if peak > 0.89:
            y *= 0.89 / peak
        if 0 <= note + offset <= 127:
            write_mp3(y, os.path.join(args.out, f"{args.instrument}-{note_name(note + offset)}.mp3"))

    with open(os.path.join(args.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    real = [note_name(n) for n in recorded]
    print(f"{len(recorded)} notes taken from the recording: {' '.join(real)}")
    far = [k for k, v in report.items() if v["source"] == "retuned" and abs(v["semitones"]) > 3
           and low <= NAMES.index(k[:-1]) + 12 * (int(k[-1]) + 1) <= high]
    if far:
        print("Retuned a long way (worth recording these):", " ".join(far))
    print(f"Wrote {len(made)} samples to {args.out}/")


if __name__ == "__main__":
    main()
