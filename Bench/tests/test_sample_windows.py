import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sample_windows as sw  # noqa: E402

SCRIPT = Path(__file__).resolve().parent.parent / "sample_windows.py"


def make_audio(path, seconds, gap_every=7, gap=0.6, silent=None):
    """Tone with a short gap every `gap_every` seconds, and an optional fully silent (from, to) span."""
    expr = f"if(lt(mod(t,{gap_every}),{gap}),0,0.5*sin(2*PI*300*t))"
    if silent:
        expr = f"if(between(t,{silent[0]},{silent[1]}),0,{expr})"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"aevalsrc='{expr}':s=16000:d={seconds}",
                    "-ac", "1", str(path)], check=True)


class Sampler(unittest.TestCase):
    def test_snaps_to_gaps_skips_silence_and_is_deterministic(self):
        with tempfile.TemporaryDirectory() as d:
            audio = Path(d) / "audio"
            audio.mkdir()
            make_audio(audio / "lec.flac", 1500, silent=(400, 1100))
            outs = []
            for i in range(2):
                out = Path(d) / f"w{i}.json"
                subprocess.run([sys.executable, "-I", str(SCRIPT), str(audio), "--total", "3", "--out", str(out)],
                               check=True, capture_output=True)
                outs.append(out.read_text())
            self.assertEqual(outs[0], outs[1])
            windows = json.loads(outs[0])["windows"]
            self.assertEqual(len(windows), 3)
            durations = json.loads((Path(d) / "audio_durations.json").read_text())
            self.assertAlmostEqual(durations["lec"], 1500, delta=0.1)
            for w in windows:
                for edge in (w["start"], w["end"]):
                    self.assertLess(edge % 7, 0.6 + 0.05, f"edge {edge} not in a gap")
                # mostly silent region must not be chosen
                self.assertFalse(w["start"] < 1100 - 30 and w["end"] > 400 + 30, w)

    def test_allocation(self):
        # exact shares 14.63 / 4.88 / 0.49: floors 14 + 4 + min-1 = 19, the spare slot goes to the largest remainder (b)
        self.assertEqual(sw.allocate({"a": 3000, "b": 1000, "c": 100}, 20), {"a": 14, "b": 5, "c": 1})


if __name__ == "__main__":
    unittest.main()
