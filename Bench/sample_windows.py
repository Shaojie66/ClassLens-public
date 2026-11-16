"""Picks the one-minute windows of lecture audio that get a human-corrected (gold) transcript.

Usage: python3 -I Bench/sample_windows.py <audio_dir> [--total 20] [--seed 20261116] [--out Bench/asr_eval_windows.json]

<audio_dir> holds <lecture>.flac (16 kHz mono). Writes each file's duration to <audio_dir>/../audio_durations.json.
Windows are spread over lectures in proportion to their length (at least one each), drawn at random with a
fixed seed, skip the start and end of each file, have both edges moved onto a nearby pause, and are rejected
when mostly silent (breaks) or overlapping another window. Same inputs and seed give the same file.
"""
import argparse
import array
import json
import math
import random
import subprocess
import sys
from pathlib import Path

RATE = 16000
FRAME = 320  # 20 ms
WINDOW = 60.0
SNAP_SEARCH = 5.0
MIN_PAUSE = 0.3
RULE = ("60 s windows, count per lecture proportional to duration (largest remainder, min 1); "
        "uniform random start with fixed seed, skipping the first 300 s and last 180 s (10% each end if short); "
        "edges snapped to the nearest >=0.3 s pause within +-5 s (20 ms RMS below 2x the 20th percentile); "
        "rejected if <50% of frames are above that threshold or if overlapping another window")


def frame_rms(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                         capture_output=True, check=True).stdout
    samples = array.array("h")
    samples.frombytes(raw[: len(raw) // 2 * 2])
    if sys.byteorder == "big":
        samples.byteswap()
    rms = []
    for i in range(0, len(samples) - FRAME + 1, FRAME):
        chunk = samples[i:i + FRAME]
        rms.append(math.sqrt(sum(s * s for s in chunk) / FRAME))
    return rms, len(samples) / RATE


def threshold(rms):
    ordered = sorted(rms)
    return max(ordered[int(len(ordered) * 0.2)] * 2, 1.0) if ordered else 1.0


def pauses(rms, thr):
    """Midpoints (seconds) of quiet runs at least MIN_PAUSE long."""
    out, run = [], 0
    need = int(MIN_PAUSE / 0.02)
    for i, value in enumerate(rms + [math.inf]):
        if value < thr:
            run += 1
            continue
        if run >= need:
            out.append((i - run / 2) * 0.02)
        run = 0
    return out


def snap(at, quiet):
    near = [p for p in quiet if abs(p - at) <= SNAP_SEARCH]
    return min(near, key=lambda p: (abs(p - at), p)) if near else at


def voiced_fraction(rms, thr, start, end):
    frames = rms[int(start / 0.02):int(end / 0.02)]
    return sum(1 for v in frames if v >= thr) / len(frames) if frames else 0.0


def allocate(durations, total):
    lectures = sorted(durations)
    whole = sum(durations.values())
    exact = {k: total * durations[k] / whole for k in lectures}
    counts = {k: max(1, int(exact[k])) for k in lectures}
    left = total - sum(counts.values())
    for k in sorted(lectures, key=lambda k: (-(exact[k] - int(exact[k])), k)):
        if left <= 0:
            break
        counts[k] += 1
        left -= 1
    return counts


def pick(lecture, rms, duration, count, rng):
    thr = threshold(rms)
    quiet = pauses(rms, thr)
    if duration > 900:
        lo, hi = 300.0, duration - 180.0 - WINDOW
    else:
        lo, hi = duration * 0.1, duration * 0.9 - WINDOW
    chosen = []
    for _ in range(1000):
        if len(chosen) == count or hi <= lo:
            break
        nominal = rng.uniform(lo, hi)
        start, end = snap(nominal, quiet), snap(nominal + WINDOW, quiet)
        if end - start < WINDOW / 2:
            continue
        if voiced_fraction(rms, thr, start, end) < 0.5:
            continue
        if any(start < c["end"] and c["start"] < end for c in chosen):
            continue
        chosen.append({"lecture": lecture, "start": round(start, 2), "end": round(end, 2)})
    if len(chosen) < count:
        print(f"{lecture}: only {len(chosen)} of {count} windows found", file=sys.stderr)
    return chosen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_dir", type=Path)
    parser.add_argument("--total", type=int, default=20)
    parser.add_argument("--seed", type=int, default=20261116)
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "asr_eval_windows.json")
    args = parser.parse_args()

    files = sorted(args.audio_dir.glob("*.flac"))
    if not files:
        sys.exit(f"no .flac files in {args.audio_dir}")
    analysed = {f.stem: frame_rms(f) for f in files}
    durations = {k: round(v[1], 2) for k, v in analysed.items()}
    (args.audio_dir.parent / "audio_durations.json").write_text(json.dumps(durations, indent=1, sort_keys=True) + "\n")

    rng = random.Random(args.seed)
    windows = []
    for lecture, count in sorted(allocate(durations, args.total).items()):
        rms, duration = analysed[lecture]
        windows += pick(lecture, rms, duration, count, rng)
    windows.sort(key=lambda w: (w["lecture"], w["start"]))
    doc = {"seed": args.seed, "total": args.total, "rule": RULE, "windows": windows}
    args.out.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(windows)} windows -> {args.out}")


if __name__ == "__main__":
    main()
