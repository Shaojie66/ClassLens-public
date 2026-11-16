"""Scores question spotting against Fixtures/questions/labels.json.

Usage: python3 -I Bench/score_questions.py <app binary> [window ...]
Runs `--eval-questions` on each fixture transcript (real DeepSeek calls, key from the app's keychain),
then prints hits, misses and false positives per window and in total, and false positives per 10 minutes.
A window may name its transcript with "file" (relative to Fixtures/questions) and mark a "break" span,
inside which every detection is a false positive.
`--before <s>` / `--from <s>` keep only labels and detections before / from that time, to score the
tuning half and the held-out half of a long window separately.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Fixtures" / "questions"


def transcript(spans, window):
    return (FIXTURES / spans.get("file", f"{window}.jsonl")).resolve()


def minutes(path, lo, hi):
    times = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    start = max(lo, min(t["start"] for t in times))
    end = min(hi, max(t["end"] for t in times))
    return max(0.0, end - start) / 60


def detect(binary, path):
    out = subprocess.run([binary, "--eval-questions", str(path)], capture_output=True, text=True, timeout=3600).stdout
    found = [json.loads(line[len("question "):]) for line in out.splitlines() if line.startswith("question ")]
    status = next((line for line in out.splitlines() if line.startswith(("calls", "eval failed"))), "no status line")
    return found, status


def inside(at, span):
    return span["from"] - 2 <= at <= span["to"] + 15


def main():
    args = sys.argv[1:]
    lo, hi = 0.0, float("inf")
    for flag in ("--before", "--from"):
        if flag in args:
            value = float(args.pop(args.index(flag) + 1))
            args.remove(flag)
            lo, hi = (lo, value) if flag == "--before" else (value, hi)
    binary = args[0]
    labels = json.loads((FIXTURES / "labels.json").read_text())["windows"]
    windows = args[1:] or list(labels)
    total = {"directed": 0, "hit": 0, "fp": 0, "minutes": 0.0}
    for window in windows:
        spans = labels[window]
        path = transcript(spans, window)
        found, status = detect(binary, path)
        found = [f for f in found if lo <= float(f["at"]) < hi]
        directed = [span for span in spans["directed"] if lo <= span["from"] < hi]
        hits = [span for span in directed if any(inside(float(f["at"]), span) for f in found)]
        false_positives = [f for f in found if not any(inside(float(f["at"]), s) for s in spans["directed"] + spans["ambiguous"])]
        rest = spans.get("break")
        in_break = [f for f in found if rest and rest["from"] <= float(f["at"]) <= rest["to"]]
        length = minutes(path, lo, hi)
        rate = len(false_positives) / length * 10 if length else 0
        print(f"== {window}: {len(hits)}/{len(directed)} found, {len(false_positives)} false positive(s) in {length:.0f} min = {rate:.2f} / 10 min  [{status}]")
        for span in directed:
            print(f"   {'hit ' if span in hits else 'MISS'} {span['from']:>4}s {span['what']}")
        for f in false_positives:
            print(f"   FP   {float(f['at']):>6.1f}s {'(break) ' if f in in_break else ''}{f['english']}")
        total["directed"] += len(directed)
        total["hit"] += len(hits)
        total["fp"] += len(false_positives)
        total["minutes"] += length
    rate = total["fp"] / total["minutes"] * 10 if total["minutes"] else 0
    print(f"TOTAL recall {total['hit']}/{total['directed']}, false positives {total['fp']} in {total['minutes']:.0f} min = {rate:.2f} / 10 min")


if __name__ == "__main__":
    main()
