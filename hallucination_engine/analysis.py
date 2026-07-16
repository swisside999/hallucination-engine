"""Offline audio analysis: mix -> JSON. Runs only the audio layer (no GPU,
no GL, no ffmpeg) over the whole file on a virtual clock, so the app's
timeline editor can auto-fill drop markers in seconds."""

import json
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from .audio_engine import AudioAnalyzer
from .state import Consumer, Controls, StateBus


def analyze(cfg, mix_path, out_path):
    target_sr = int(cfg["audio"]["samplerate"])
    data, sr = sf.read(str(mix_path), dtype="float32", always_2d=True)
    if sr != target_sr:
        g = gcd(sr, target_sr)
        data = resample_poly(data, target_sr // g, sr // g, axis=0).astype(np.float32)
    mono = data.mean(axis=1)
    dur = len(mono) / target_sr

    bus = StateBus()
    analyzer = AudioAnalyzer(cfg, bus, Controls())
    consumer = Consumer(bus)
    block = int(cfg["audio"]["blocksize"])

    drops = []
    bpms = []
    n_blocks = (len(mono) + block - 1) // block
    for i in range(n_blocks):
        analyzer.process_block(mono[i * block:(i + 1) * block])
        s = consumer.read()
        vt = (i + 1) * block / target_sr
        if s.drop:
            drops.append(round(vt, 2))
        bpms.append(s.bpm)

    # median of the settled second half; early blocks are still converging
    bpm = float(np.median(bpms[len(bpms) // 2:])) if bpms else 0.0
    result = {"duration": round(dur, 2), "bpm": round(bpm, 1), "drops": drops}
    Path(out_path).write_text(json.dumps(result))
    print(f"[analyze] {dur:.0f}s, bpm {bpm:.1f}, {len(drops)} drops -> {out_path}",
          flush=True)
    return result
