"""Reference ASR engines for the WER evaluation, run on a Colab GPU runtime through the Colab CLI.

Usage (from the repo root; the session keeps kernel state between exec calls):
  colab new -s asr --gpu L4
  colab upload -s asr Bench/data/asr_eval/audio/<lecture>.flac /content/asr_eval/audio/<lecture>.flac   # per file
  colab exec -s asr -f Bench/colab_asr.py            # defines functions only
  echo 'setup("whisper"); run("whisper")' | colab exec -s asr
  colab download -s asr /content/asr_eval/hyp/whisper/<lecture>.jsonl Bench/data/asr_eval/hyp/whisper_large_v3/<lecture>.jsonl
  colab stop -s asr

Engines: "whisper" (faster-whisper large-v3, not turbo, with VAD; one output row per word, exact word times),
"qwen3" (Qwen3-ASR 1.7B in bf16), "canary" (NVIDIA Canary-Qwen-2.5B). qwen3 and canary transcribe the same
pause-bounded chunks of at most 15 s from Silero VAD, so their rows are chunk-level.
Writes /content/asr_eval/hyp/<engine>/<lecture>.jsonl (start, end, text) and <lecture>.meta.json (seconds, audio_seconds).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("/content/asr_eval")
AUDIO = ROOT / "audio"
HYP = ROOT / "hyp"
RATE = 16000
MAX_CHUNK = 15.0

PACKAGES = {
    "whisper": ["faster-whisper"],
    "qwen3": ["qwen-asr", "silero-vad", "soundfile"],
    "canary": ["nemo_toolkit[asr] @ git+https://github.com/NVIDIA/NeMo.git", "silero-vad", "soundfile"],
}
_models = {}


def setup(engine):
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", *PACKAGES[engine]], check=True)


def load_audio(path):
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le", "-ac", "1", "-ar", str(RATE), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def vad_chunks(audio):
    """Speech regions from Silero VAD, merged into pause-bounded chunks of at most MAX_CHUNK seconds."""
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad
    if "vad" not in _models:
        _models["vad"] = load_silero_vad()
    spans = get_speech_timestamps(torch.from_numpy(audio), _models["vad"], sampling_rate=RATE,
                                  max_speech_duration_s=MAX_CHUNK, min_silence_duration_ms=200)
    chunks = []
    for s in spans:
        a, b = s["start"] / RATE, s["end"] / RATE
        if chunks and b - chunks[-1][0] <= MAX_CHUNK and a - chunks[-1][1] < 1.0:
            chunks[-1][1] = b
        else:
            chunks.append([a, b])
    return chunks


def run_whisper(audio):
    from faster_whisper import WhisperModel
    if "whisper" not in _models:
        _models["whisper"] = WhisperModel("large-v3", device="cuda", compute_type="float16")
    segments, _ = _models["whisper"].transcribe(audio, language="en", beam_size=5, vad_filter=True,
                                                word_timestamps=True, condition_on_previous_text=False)
    return [{"start": round(w.start, 2), "end": round(w.end, 2), "text": w.word.strip()}
            for seg in segments for w in (seg.words or [])]


def run_qwen3(audio):
    import torch
    from qwen_asr import Qwen3ASRModel
    if "qwen3" not in _models:
        _models["qwen3"] = Qwen3ASRModel.from_pretrained("Qwen/Qwen3-ASR-1.7B", dtype=torch.bfloat16,
                                                         device_map="cuda:0", max_inference_batch_size=16,
                                                         max_new_tokens=256)
    chunks = vad_chunks(audio)
    rows = []
    for i in range(0, len(chunks), 16):
        batch = chunks[i:i + 16]
        clips = [(audio[int(a * RATE):int(b * RATE)], RATE) for a, b in batch]
        results = _models["qwen3"].transcribe(audio=clips, language=["English"] * len(clips))
        rows += [{"start": round(a, 2), "end": round(b, 2), "text": r.text.strip()} for (a, b), r in zip(batch, results)]
    return rows


def run_canary(audio):
    import soundfile as sf
    from nemo.collections.speechlm2.models import SALM
    if "canary" not in _models:
        _models["canary"] = SALM.from_pretrained("nvidia/canary-qwen-2.5b").cuda().eval()
    model = _models["canary"]
    tmp = ROOT / "tmp"
    tmp.mkdir(exist_ok=True)
    rows = []
    chunks = vad_chunks(audio)
    for i in range(0, len(chunks), 16):
        batch = chunks[i:i + 16]
        paths = []
        for j, (a, b) in enumerate(batch):
            p = tmp / f"c{j}.wav"
            sf.write(p, audio[int(a * RATE):int(b * RATE)], RATE)
            paths.append(str(p))
        prompts = [[{"role": "user", "content": f"Transcribe the following: {model.audio_locator_tag}", "audio": [p]}]
                   for p in paths]
        ids = model.generate(prompts=prompts, max_new_tokens=256)
        rows += [{"start": round(a, 2), "end": round(b, 2), "text": model.tokenizer.ids_to_text(t.cpu()).strip()}
                 for (a, b), t in zip(batch, ids)]
    return rows


ENGINES = {"whisper": run_whisper, "qwen3": run_qwen3, "canary": run_canary}


def run(engine, lectures=None):
    out = HYP / engine
    out.mkdir(parents=True, exist_ok=True)
    for path in sorted(AUDIO.glob("*.flac")):
        if lectures and path.stem not in lectures:
            continue
        audio = load_audio(path)
        started = time.time()
        rows = ENGINES[engine](audio)
        took = time.time() - started
        (out / f"{path.stem}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
        (out / f"{path.stem}.meta.json").write_text(json.dumps({"seconds": round(took, 1),
                                                               "audio_seconds": round(len(audio) / RATE, 1)}))
        print(f"{engine} {path.stem}: {len(rows)} rows, {len(audio) / RATE / took:.1f}x realtime", flush=True)
