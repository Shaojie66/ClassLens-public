import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import score_asr as s  # noqa: E402


class Normalise(unittest.TestCase):
    def test_numbers_hyphens_quotes_fillers(self):
        self.assertEqual(s.normalise("Um, the T-test has 25 ‘degrees’ of freedom: 1990!"),
                         "the t test has twenty five degrees of freedom one thousand nine hundred ninety".split())

    def test_apostrophe_inside_word_kept(self):
        self.assertEqual(s.normalise("We'll see 'it' -- 5%"), ["we'll", "see", "it", "five", "percent"])


class EditCounts(unittest.TestCase):
    def test_cases(self):
        self.assertEqual(s.edit_counts("a b c".split(), "a x c".split()), (1, 0, 0))
        self.assertEqual(s.edit_counts("a b c".split(), "a c".split()), (0, 1, 0))
        self.assertEqual(s.edit_counts("a b".split(), "a b c".split()), (0, 0, 1))
        self.assertEqual(s.edit_counts("a b".split(), []), (0, 2, 0))
        self.assertEqual(s.edit_counts([], ["a"]), (0, 0, 1))
        self.assertEqual(s.edit_counts("the null hypothesis".split(), "the knoll hypothesis is".split()), (1, 0, 1))


class Segments(unittest.TestCase):
    def test_app_format_dedup_and_final(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.jsonl"
            rows = [{"id": "a", "start": 0, "end": 2, "text": "old"},
                    {"id": "b", "start": 2, "end": 4, "text": "draft", "isFinal": False},
                    {"id": "a", "start": 0, "end": 2, "text": "new"},
                    {"start": 4, "end": 5, "text": "plain"}]
            p.write_text("\n".join(json.dumps(r) for r in rows))
            self.assertEqual([r["text"] for r in s.load_segments(p)], ["new", "plain"])

    def test_window_clipping_linear(self):
        segs = [{"start": 0, "end": 4, "text": "one two three four"}]  # words at 0.5 1.5 2.5 3.5
        self.assertEqual(s.words_in(segs, 1.0, 3.0), ["two", "three"])


class Terms(unittest.TestCase):
    def test_multiword(self):
        words = s.normalise("the null hypothesis and another null hypothesis null")
        self.assertEqual(s.count_term(words, ["null", "hypothesis"]), 2)


class Loops(unittest.TestCase):
    def test_detects_repeated_phrase(self):
        words = ("ok " + "let's see " * 6 + "done").split()
        self.assertIn(("let's see", 6), s.repetition_loops(words))
        self.assertEqual(s.repetition_loops("a b a b a b".split()), [])


class EndToEnd(unittest.TestCase):
    def test_pooled_wer_and_determinism(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            s.WINDOWS, s.GOLD, s.DATA = root / "w.json", root / "gold", root / "data"
            s.GOLD.mkdir(); (s.DATA / "hyp" / "eng").mkdir(parents=True)
            s.WINDOWS.write_text(json.dumps({"windows": [
                {"lecture": "l1", "start": 0, "end": 10}, {"lecture": "l2", "start": 0, "end": 10}]}))
            (s.GOLD / "l1_0.txt").write_text("a b c d")          # 4 words, 1 error
            (s.GOLD / "l2_0.txt").write_text("e f")              # 2 words, 2 errors
            (s.DATA / "hyp" / "eng" / "l1.jsonl").write_text(json.dumps({"start": 0, "end": 4, "text": "a b x d"}))
            (s.DATA / "hyp" / "eng" / "l2.jsonl").write_text(json.dumps({"start": 0, "end": 2, "text": ""}))
            r1 = s.score(["eng"])
            r2 = s.score(["eng"])
            self.assertEqual(r1, r2)
            st = r1["engines"]["eng"]
            self.assertAlmostEqual(s.wer(st["lectures"]["l1"]), 0.25)
            self.assertAlmostEqual(s.wer(st["lectures"]["l2"]), 1.0)
            self.assertAlmostEqual(s.wer(st["overall"]), 3 / 6)  # pooled, not mean of 0.25 and 1.0


if __name__ == "__main__":
    unittest.main()
