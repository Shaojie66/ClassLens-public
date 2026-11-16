"""Transcribes audio with local MLX models.

Usage:
  python -I Bench/local_asr.py <engine> <out_dir> <clip>...          one text file per engine and clip (M1 comparison)
  python -I Bench/local_asr.py <engine> <out_dir> --jsonl <audio>...  whole recordings for Bench/score_asr.py
engine: qwen3 | qwen3_4bit | whisper | parakeet

--jsonl cuts each recording at pauses into chunks of at most 15 s (the app's sentence-length cap), transcribes
each chunk and writes <out_dir>/<stem>.jsonl (start, end, text) and <stem>.meta.json (seconds, audio_seconds).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

ENGINES = {
    "qwen3": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "qwen3_4bit": "mlx-community/Qwen3-ASR-1.7B-4bit",
    "whisper": "mlx-community/whisper-large-v3-turbo",
    "parakeet": "mlx-community/parakeet-tdt-0.6b-v3",
}
RATE = 16000
MAX_CHUNK = 15.0


def transcribe(engine, model, clip):
    if engine == "whisper":
        import mlx_whisper
        result = mlx_whisper.transcribe(clip, path_or_hf_repo=ENGINES[engine], language="en")
        return [(s["start"], s["end"], s["text"].strip()) for s in result["segments"]]
    if engine.startswith("qwen3"):
        result = model.generate(clip, language="English")
    else:
        result = model.generate(clip, chunk_duration=120.0, overlap_duration=15.0)
    segments = getattr(result, "segments", None) or getattr(result, "sentences", None)
    if segments:
        rows = []
        for s in segments:
            get = s.get if isinstance(s, dict) else lambda k, d=None: getattr(s, k, d)
            rows.append((get("start", 0.0), get("end", 0.0), str(get("text", "")).strip()))
        return rows
    return [(0.0, 0.0, result.text.strip())]


def load_pcm(path):
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def pause_chunks(audio):
    """Chunks of at most MAX_CHUNK s, cut at the quietest 20 ms frame in the last third of each chunk."""
    import numpy as np
    frame = RATE // 50
    n = len(audio) // frame
    rms = np.sqrt((audio[: n * frame].reshape(n, frame) ** 2).mean(axis=1))
    quiet = np.percentile(rms, 20) * 2
    chunks, start = [], 0
    limit = int(MAX_CHUNK * 50)
    while start < n:
        end = min(start + limit, n)
        if end < n:
            lo = start + limit * 2 // 3
            end = lo + int(np.argmin(rms[lo:end]))
        if rms[start:end].max() >= quiet:
            chunks.append((start / 50, end / 50))
        start = end
    return chunks


def whole_recording(engine, model, path, out_dir):
    import mlx.core as mx
    audio = load_pcm(path)
    started = time.time()
    rows = []
    if engine == "whisper":
        rows = [{"start": round(a, 2), "end": round(b, 2), "text": t} for a, b, t in transcribe(engine, model, audio)]
    else:
        for a, b in pause_chunks(audio):
            clip = mx.array(audio[int(a * RATE):int(b * RATE)])
            text = " ".join(t for _, _, t in transcribe(engine, model, clip)).strip()
            if text:
                rows.append({"start": round(a, 2), "end": round(b, 2), "text": text})
    took = time.time() - started
    seconds = len(audio) / RATE
    (out_dir / f"{path.stem}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    (out_dir / f"{path.stem}.meta.json").write_text(json.dumps({"seconds": round(took, 1), "audio_seconds": round(seconds, 1)}))
    print(f"{engine} {path.stem}: {len(rows)} rows, {seconds / took:.1f}x realtime", file=sys.stderr)


def main():
    engine, out_dir, rest = sys.argv[1], Path(sys.argv[2]), sys.argv[3:]
    out_dir.mkdir(parents=True, exist_ok=True)
    model = None
    if engine != "whisper":
        from mlx_audio.stt.utils import load_model
        started = time.time()
        model = load_model(ENGINES[engine])
        print(f"{engine}: loaded in {time.time() - started:.1f}s", file=sys.stderr)
    if rest and rest[0] == "--jsonl":
        for path in rest[1:]:
            whole_recording(engine, model, Path(path), out_dir)
        return
    for clip in rest:
        started = time.time()
        rows = transcribe(engine, model, clip)
        took = time.time() - started
        name = Path(clip).stem.replace("clip_", "")
        lines = [f"[{a:.1f}-{b:.1f}] {t}" for a, b, t in rows]
        (out_dir / f"{engine}_{name}.txt").write_text("\n".join(lines) + "\n")
        print(f"{engine} {name}: {took:.1f}s ({180 / took:.1f}x realtime)", file=sys.stderr)


if __name__ == "__main__":
    main()
