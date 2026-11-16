"""Scores ASR engines against the human-corrected windows in Fixtures/asr_gold/.

Usage: python3 -I Bench/score_asr.py [--engines a,b,...] [--json out.json]

Windows: Bench/asr_eval_windows.json (from Bench/sample_windows.py). Gold: Fixtures/asr_gold/<lecture>_<int start>.txt,
the corrected transcript of exactly [start, end). Terms (optional): Fixtures/asr_gold/terms.txt, one per line.
Hypotheses: Bench/data/asr_eval/hyp/<engine>/<lecture>.jsonl, lines with start, end, text; app transcripts also carry
id / isFinal (non-final lines dropped, last line per id wins). Speed (optional): <lecture>.meta.json with seconds and
audio_seconds. Words of a segment get times spread evenly over it, and only words inside the window are scored.
Prints WER (pooled: total errors / total reference words), term recall, hallucination flags and speed per engine.
"""
import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WINDOWS = ROOT / "Bench" / "asr_eval_windows.json"
GOLD = ROOT / "Fixtures" / "asr_gold"
DATA = ROOT / "Bench" / "data" / "asr_eval"
FILLERS = {"um", "uh", "er", "erm", "ah", "hmm", "mm", "mhm"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen " \
       "seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        rest = n % 100
        return ONES[n // 100] + " hundred" + ("" if rest == 0 else " " + number_words(rest))
    rest = n % 1000
    return number_words(n // 1000) + " thousand" + ("" if rest == 0 else " " + number_words(rest))


def normalise(text):
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("‘", "'").replace("’", "'").replace("“", '"').replace("”", '"')
    text = text.lower().replace("%", " percent ")
    text = re.sub(r"[-‐-―/]", " ", text)
    text = re.sub(r"\d+", lambda m: f" {number_words(int(m.group()))} " if len(m.group()) <= 6 else m.group(), text)
    text = re.sub(r"(?<![a-z0-9])'|'(?![a-z0-9])", " ", text)
    text = re.sub(r"[^a-z0-9' ]", " ", text)
    return [w for w in text.split() if w not in FILLERS]


def edit_counts(ref, hyp):
    """(substitutions, deletions, insertions) of the minimum edit path, ties broken S > D > I."""
    prev = [(j, 0, 0, j) for j in range(len(hyp) + 1)]  # (cost, S, D, I)
    for i in range(1, len(ref) + 1):
        cur = [(i, 0, i, 0)]
        for j in range(1, len(hyp) + 1):
            if ref[i - 1] == hyp[j - 1]:
                cur.append(prev[j - 1])
                continue
            s, d, ins = prev[j - 1], prev[j], cur[j - 1]
            cur.append(min((s[0] + 1, s[1] + 1, s[2], s[3]), (d[0] + 1, d[1], d[2] + 1, d[3]),
                           (ins[0] + 1, ins[1], ins[2], ins[3] + 1), key=lambda t: t[0]))
        prev = cur
    return prev[-1][1:]


def load_segments(path):
    by_id, order, plain = {}, [], []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("isFinal") is False:
            continue
        if "id" in row:
            if row["id"] not in by_id:
                order.append(row["id"])
            by_id[row["id"]] = row
        else:
            plain.append(row)
    rows = plain + [by_id[i] for i in order]
    return sorted(rows, key=lambda r: (float(r["start"]), float(r["end"])))


def words_in(segments, start, end):
    out = []
    for seg in segments:
        words = str(seg.get("text", "")).split()
        a, b = float(seg["start"]), float(seg["end"])
        for i, word in enumerate(words):
            at = a + (i + 0.5) / len(words) * (b - a)
            if start <= at < end:
                out.append(word)
    return normalise(" ".join(out))


def count_term(words, term):
    n, i = 0, 0
    while i + len(term) <= len(words):
        if words[i:i + len(term)] == term:
            n += 1
            i += len(term)
        else:
            i += 1
    return n


def repetition_loops(words, times=5):
    found = []
    for n in range(1, 5):
        i = 0
        while i + n <= len(words):
            gram, reps = words[i:i + n], 1
            while words[i + reps * n:i + (reps + 1) * n] == gram:
                reps += 1
            if reps >= times:
                found.append((" ".join(gram), reps))
                i += reps * n
            else:
                i += 1
    return found


def load_terms():
    path = GOLD / "terms.txt"
    if not path.exists():
        return []
    terms = [normalise(line) for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")]
    return [t for t in terms if t]


def score(engines):
    windows = json.loads(WINDOWS.read_text())["windows"]
    durations_path = DATA / "audio_durations.json"
    durations = json.loads(durations_path.read_text()) if durations_path.exists() else {}
    terms = load_terms()
    gold, no_gold = [], []
    for w in windows:
        path = GOLD / f"{w['lecture']}_{int(w['start'])}.txt"
        if path.exists():
            gold.append((w, normalise(path.read_text())))
        else:
            no_gold.append(path.name)
    result = {"no_gold": no_gold, "engines": {}}
    for engine in engines:
        stats = {"lectures": {}, "terms": [0, 0], "flags": [], "speed": {}}
        segments = {}
        for w, ref in gold:
            lecture = w["lecture"]
            if lecture not in segments:
                path = DATA / "hyp" / engine / f"{lecture}.jsonl"
                segments[lecture] = load_segments(path) if path.exists() else None
            if segments[lecture] is None:
                continue
            hyp = words_in(segments[lecture], w["start"], w["end"])
            s, d, i = edit_counts(ref, hyp)
            row = stats["lectures"].setdefault(lecture, {"S": 0, "D": 0, "I": 0, "N": 0})
            row["S"] += s; row["D"] += d; row["I"] += i; row["N"] += len(ref)
            for term in terms:
                g = count_term(ref, term)
                stats["terms"][0] += min(g, count_term(hyp, term))
                stats["terms"][1] += g
        for path in sorted((DATA / "hyp" / engine).glob("*.jsonl")):
            segs = load_segments(path)
            for gram, reps in repetition_loops(normalise(" ".join(str(s.get("text", "")) for s in segs))):
                stats["flags"].append(f"{path.stem}: '{gram}' x{reps}")
            limit = durations.get(path.stem)
            late = [s for s in segs if limit is not None and float(s["end"]) > limit + 1]
            if late:
                stats["flags"].append(f"{path.stem}: {len(late)} segments past end of audio")
            meta = path.with_suffix(".meta.json")
            if meta.exists():
                m = json.loads(meta.read_text())
                stats["speed"][path.stem] = round(m["audio_seconds"] / m["seconds"], 1) if m.get("seconds") else None
        total = {k: sum(r[k] for r in stats["lectures"].values()) for k in "SDIN"}
        stats["overall"] = total
        result["engines"][engine] = stats
    return result


def wer(row):
    return (row["S"] + row["D"] + row["I"]) / row["N"] if row["N"] else None


def fmt(x):
    return "-" if x is None else f"{100 * x:5.1f}%"


def report(result):
    engines = sorted(result["engines"])
    lectures = sorted({l for e in engines for l in result["engines"][e]["lectures"]})
    width = max([len(e) for e in engines] + [6])
    print("WER".ljust(width), *[l[:12].rjust(12) for l in lectures], "overall".rjust(10), "S/D/I/N".rjust(18))
    for e in engines:
        st = result["engines"][e]
        o = st["overall"]
        cells = [fmt(wer(st["lectures"][l]) if l in st["lectures"] else None).rjust(12) for l in lectures]
        print(e.ljust(width), *cells, fmt(wer(o)).rjust(10), f"{o['S']}/{o['D']}/{o['I']}/{o['N']}".rjust(18))
    print()
    for e in engines:
        st = result["engines"][e]
        hit, total = st["terms"]
        recall = f"{hit}/{total} ({100 * hit / total:.0f}%)" if total else "n/a"
        speed = ", ".join(f"{k} {v}x" for k, v in sorted(st["speed"].items()) if v) or "-"
        print(f"{e}: term recall {recall}; speed {speed}")
        for flag in st["flags"]:
            print(f"  flag {flag}")
    if result["no_gold"]:
        print(f"\nno gold for {len(result['no_gold'])} windows: {', '.join(result['no_gold'])}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engines")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--windows", type=Path, help="windows file (default Bench/asr_eval_windows.json)")
    parser.add_argument("--gold", type=Path, help="gold folder (default Fixtures/asr_gold)")
    args = parser.parse_args()
    global WINDOWS, GOLD
    WINDOWS = args.windows or WINDOWS
    GOLD = args.gold or GOLD
    hyp_root = DATA / "hyp"
    engines = args.engines.split(",") if args.engines else sorted(p.name for p in hyp_root.iterdir() if p.is_dir()) \
        if hyp_root.exists() else []
    if not engines:
        sys.exit(f"no engines under {hyp_root}")
    result = score(engines)
    for st in result["engines"].values():
        for row in list(st["lectures"].values()) + [st["overall"]]:
            row["WER"] = None if wer(row) is None else round(wer(row), 4)
    report(result)
    if args.json:
        args.json.write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
