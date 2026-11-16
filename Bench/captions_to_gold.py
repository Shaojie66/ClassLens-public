"""Turns a lecture's caption file (WebVTT) into gold windows for Bench/score_asr.py, on the timeline of another recording.

Usage: python3 -I Bench/captions_to_gold.py <captions.vtt> <anchor.jsonl> [--block 300] [--out-dir Bench/data/asr_eval]

The captions belong to a different recording of the same lecture (here: the school's Re/Play captions vs the user's
own recording). <anchor.jsonl> is any engine's transcript of the recording being scored; the offset between the two
timelines is the median time difference of 5-grams that occur exactly once in each, and is checked for drift per
300 s. Captions are then shifted by that offset and cut into blocks of about --block seconds, each edge moved to the
nearest caption cue start, so cuts fall between caption lines.
Writes <out-dir>/windows.json and <out-dir>/gold/<lecture>_<int start>.txt (lecture = stem of the anchor file).
"""
import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_asr  # noqa: E402

CUE = re.compile(r"(\d+):(\d+):([\d.]+)\s+-->\s+(\d+):(\d+):([\d.]+)")


def read_vtt(path):
    rows, cur = [], None
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        m = CUE.match(line)
        if m:
            g = m.groups()
            cur = {"start": int(g[0]) * 3600 + int(g[1]) * 60 + float(g[2]),
                   "end": int(g[3]) * 3600 + int(g[4]) * 60 + float(g[5]), "text": ""}
            rows.append(cur)
        elif not line:
            cur = None
        elif cur is not None:
            cur["text"] = (cur["text"] + " " + line).strip()
    return rows


def timed_words(rows):
    out = []
    for r in rows:
        words = score_asr.normalise(r["text"])
        for i, w in enumerate(words):
            out.append((r["start"] + (i + 0.5) / len(words) * (r["end"] - r["start"]), w))
    return out


def offset(captions, anchor):
    c, h = timed_words(captions), timed_words(anchor)
    seen = defaultdict(list)
    for i in range(len(h) - 4):
        seen[tuple(w for _, w in h[i:i + 5])].append(h[i][0])
    pairs = []
    for i in range(len(c) - 4):
        hits = seen.get(tuple(w for _, w in c[i:i + 5]), [])
        if len(hits) == 1:
            pairs.append((c[i][0], hits[0] - c[i][0]))
    if len(pairs) < 50:
        sys.exit(f"only {len(pairs)} matching 5-grams: probably not the same lecture")
    shift = statistics.median(d for _, d in pairs)
    for lo in range(0, int(max(t for t, _ in pairs)) + 1, 300):
        part = [d for t, d in pairs if lo <= t < lo + 300]
        if part and abs(statistics.median(part) - shift) > 1.0:
            sys.exit(f"offset drifts at caption {lo}s: {statistics.median(part):.2f} vs {shift:.2f}")
    return shift, len(pairs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("captions", type=Path)
    parser.add_argument("anchor", type=Path)
    parser.add_argument("--block", type=float, default=300.0)
    parser.add_argument("--out-dir", type=Path, default=Path(__file__).resolve().parent / "data" / "asr_eval")
    args = parser.parse_args()

    lecture = args.anchor.stem
    captions = read_vtt(args.captions)
    shift, matched = offset(captions, score_asr.load_segments(args.anchor))
    shifted = [{**r, "start": r["start"] + shift, "end": r["end"] + shift} for r in captions]
    starts = [r["start"] for r in shifted]
    first, last = shifted[0]["start"], shifted[-1]["end"]

    edges = [first]
    while last - edges[-1] > args.block * 1.5:
        target = edges[-1] + args.block
        edges.append(min(starts, key=lambda s: abs(s - target)))
    edges.append(last)

    gold = args.out_dir / "gold"
    gold.mkdir(parents=True, exist_ok=True)
    windows = []
    for a, b in zip(edges, edges[1:]):
        text = " ".join(r["text"] for r in shifted if a <= r["start"] < b)
        start = round(a, 2)
        (gold / f"{lecture}_{int(start)}.txt").write_text(text + "\n")
        windows.append({"lecture": lecture, "start": start, "end": round(b, 2)})
    doc = {"source": f"captions {args.captions.name} shifted by {shift:.2f} s ({matched} matching 5-grams)",
           "rule": f"consecutive blocks of about {args.block:.0f} s, edges at caption cue starts", "windows": windows}
    (args.out_dir / "windows.json").write_text(json.dumps(doc, indent=1) + "\n")
    print(f"{lecture}: offset {shift:.2f} s from {matched} 5-grams, {len(windows)} windows "
          f"{first:.1f}-{last:.1f} s")


if __name__ == "__main__":
    main()
