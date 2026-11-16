"""Scores slide following against Fixtures/slides_follow/scem_week7_labels.json.

Usage: python3 -I Bench/score_slides.py <app binary> <slides.pdf> [dev|test|all]
The slides PDF is course material kept outside the repository; pass its path.
Scores the slide the reader shows. Tune on "dev" (anchors before 60:00); "test" (after) is held out.
Settings can be overridden with CLASSLENS_SLIDES="temperature=0.15 jump=0.0005 ...".
CLASSLENS_SLIDES_MODE=llm or hybrid asks deepseek-flash every 30 s (real API calls, key from the keychain).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Fixtures" / "slides_follow"


def shown_at(track, at):
    state = [row for row in track if row[0] <= at]
    return state[-1][1] if state else 1


def main():
    binary, slides = sys.argv[1], sys.argv[2]
    part = sys.argv[3] if len(sys.argv) > 3 else "all"
    labels = json.loads((FIXTURES / "scem_week7_labels.json").read_text())
    out = subprocess.run([binary, "--document", slides, "--eval-slides", str(FIXTURES / "scem_week7_full.jsonl")],
                         capture_output=True, text=True, timeout=600).stdout
    groups = next((l for l in out.splitlines() if l.startswith("slides ")), "")
    expected = "slides 26: " + labels["groups"]
    if groups != expected:
        print(f"WARNING: slide grouping changed\n  now:      {groups}\n  labelled: {expected}")
    track = [(float(t), int(shown), float(p)) for _, t, _, _, p, shown in (l.split() for l in out.splitlines() if l.startswith("slide "))]
    anchors = [a for a in labels["anchors"] if part == "all" or (part == "dev") == (a["at"] < 3600)]
    exact = near = 0
    for anchor in anchors:
        state = [row for row in track if row[0] <= anchor["at"]]
        slide, probability = (state[-1][1], state[-1][2]) if state else (1, 0)
        ok = slide in anchor["slides"]
        close = ok or any(abs(slide - s) <= 1 for s in anchor["slides"])
        exact += ok
        near += close
        mark = "ok  " if ok else ("±1  " if close else "MISS")
        if "-q" not in sys.argv:
            print(f"{mark} {anchor['at'] // 60:3d}:{anchor['at'] % 60:02d}  expected {anchor['slides']}  got {slide} (p={probability:.2f})  {anchor['cue'][:60]}")
    if part == "all":
        for name, keep in (("dev", lambda a: a["at"] < 3600), ("test", lambda a: a["at"] >= 3600)):
            subset = [a for a in anchors if keep(a)]
            hits = sum(shown_at(track, a["at"]) in a["slides"] for a in subset)
            close = sum(any(abs(shown_at(track, a["at"]) - s) <= 1 for s in a["slides"]) for a in subset)
            print(f"  [{name}] exact {hits}/{len(subset)}, within one slide {close}/{len(subset)}")
    total = len(anchors)
    changes = sum(1 for a, b in zip(track, track[1:]) if a[1] != b[1])
    calls = next((l for l in out.splitlines() if l.startswith("calls ")), "")
    if calls:
        print(calls)
    print(f"TOTAL [{part}] exact {exact}/{total}, within one slide {near}/{total}, slide changes {changes} (lecture has ~25 real transitions)")


if __name__ == "__main__":
    main()
