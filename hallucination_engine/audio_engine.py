"""Layer A - audio capture (live/file) + DSP feature extraction at ~86 Hz."""

import sys
import time
from collections import deque
from math import gcd

import numpy as np
import sounddevice as sd
import soundfile as sf
from scipy.signal import resample_poly

from .state import AudioState, StateBus
from .utils import AdaptiveNormalizer, EnvelopeFollower, fold_bpm


class AudioAnalyzer:
    """Per-block DSP: FFT bands, flux, adaptive normalization, envelopes,
    onset/tempo/phase tracking. Runs inside the audio callback."""

    def __init__(self, cfg, bus: StateBus, controls, samplerate=None):
        a = cfg["audio"]
        t = cfg["tempo"]
        self.sr = int(samplerate or a["samplerate"])
        self.block = int(a["blocksize"])
        self.nfft = int(a["fft_size"])
        self.bus = bus
        self.controls = controls
        self.frame_rate = self.sr / self.block

        self.window = np.hanning(self.nfft).astype(np.float32)
        freqs = np.fft.rfftfreq(self.nfft, 1.0 / self.sr)
        self.band_bins = {name: (freqs >= lo) & (freqs < hi)
                          for name, (lo, hi) in a["bands"].items()}
        self.ring = np.zeros(self.nfft, np.float32)
        self.prev_mag = np.zeros(self.nfft // 2 + 1, np.float32)

        norm = a["normalizer"]
        self.norms = {k: AdaptiveNormalizer(norm["decay"], norm["floor"])
                      for k in ("kick", "perc", "synth", "air", "rms")}
        env = a["envelopes"]
        self.envs = {k: EnvelopeFollower(env[k]["attack_ms"], env[k]["release_ms"], self.frame_rate)
                     for k in ("kick", "perc", "synth", "air")}

        o = a["onset"]
        self.kick_hist = deque(maxlen=max(8, int(o["history_seconds"] * self.frame_rate)))
        self.onset_k = o["k"]
        self.onset_min_level = float(o.get("min_level", 0.35))
        self.refractory = o["refractory_ms"] / 1000.0
        b = a["big_onset"]
        self.rms_hist = deque(maxlen=max(8, int(b["history_seconds"] * self.frame_rate)))
        self.big_k = b["k"]
        self.big_refractory = b["refractory_ms"] / 1000.0
        self.last_kick_t = -10.0
        self.last_big_t = -10.0
        self.kick_onset_id = 0
        self.big_onset_id = 0
        self.kick_velocity = 0.0

        tn = cfg.get("tension", {})
        self.tn_start = float(tn.get("drought_start", 1.2))
        self.tn_full = float(tn.get("drought_full", 7.0))
        self.tn_min_rms = float(tn.get("min_rms", 0.30))
        self.tn_drop_min = float(tn.get("drop_min_tension", 0.4))
        self.tension = 0.0
        self.drop_id = 0
        self.drop_bump = 0  # advances the scene on every drop
        self.drop_power = 0.0
        self._drop_req_seen = 0  # controls.drop_request consumer

        self.onset_times = deque(maxlen=int(t["onset_history"]))
        self.bpm_lo = float(t["min_bpm"])
        self.bpm_hi = float(t["max_bpm"])
        self.bpm = float(t["bpm_override"] or t["default_bpm"])
        self.cfg_bpm_override = t["bpm_override"]
        self.nudge = float(t["nudge"])
        self.beat_pos = 0.0
        self.phrase_beats = int(cfg["scenes"]["phrase_bars"]) * 4
        self.t = 0.0  # sample clock, seconds

    def process_block(self, mono: np.ndarray):
        n = len(mono)
        self.ring[:-n] = self.ring[n:]
        self.ring[-n:] = mono
        self.t += n / self.sr
        now = self.t

        mag = np.abs(np.fft.rfft(self.ring * self.window)).astype(np.float32)
        flux = np.maximum(mag - self.prev_mag, 0.0)
        self.prev_mag = mag

        raw = {
            "kick": float(mag[self.band_bins["kick"]].sum()),
            "perc": float(flux[self.band_bins["perc"]].sum()),
            "synth": float(mag[self.band_bins["synth"]].sum()),
            "air": float(mag[self.band_bins["air"]].sum()),
        }
        rms = float(np.sqrt(np.mean(mono.astype(np.float64) ** 2)))

        normed = {k: self.norms[k].process(v) for k, v in raw.items()}
        env = {k: self.envs[k].process(normed[k]) for k in normed}
        rms_n = self.norms["rms"].process(rms)

        # buildup tension: grows while kicks are absent but the music stays loud
        # (riser); collapses on the drop. Computed BEFORE onset detection so the
        # returning kick sees the accumulated tension.
        drought = now - self.last_kick_t
        target = 0.0
        if rms_n > self.tn_min_rms:
            target = min(max((drought - self.tn_start)
                             / max(self.tn_full - self.tn_start, 0.1), 0.0), 1.0)
        coef = 0.98 if target > self.tension else 0.90
        self.tension = target + coef * (self.tension - target)

        # kick gate: rising broadband noise (risers) puts energy in the kick band
        # and fools the adaptive threshold - a real kick is also LOUD in absolute
        # self-calibrated terms
        kick_onset = self._detect(raw["kick"], now, self.kick_hist, self.onset_k,
                                  self.refractory, "kick",
                                  gate=normed["kick"] >= self.onset_min_level)
        big_onset = self._detect(rms, now, self.rms_hist, self.big_k,
                                 self.big_refractory, "big")
        # forced drop from the control app (space bar) - full drop path, decent
        # power even with no buildup banked
        forced_drop = self.controls.drop_request != self._drop_req_seen
        if forced_drop:
            self._drop_req_seen = self.controls.drop_request
        drop = False
        if (kick_onset and self.tension > self.tn_drop_min) or forced_drop:
            drop = True
            self.drop_id += 1
            self.drop_bump += 1
            self.drop_power = max(self.tension, 0.6) if forced_drop else self.tension
            self.tension = 0.0
        self._update_tempo_phase(n / self.sr, kick_onset, now)

        bp = self.beat_pos
        self.bus.publish(AudioState(
            kick=env["kick"], perc=env["perc"], synth=env["synth"], air=env["air"],
            kick_onset=kick_onset, kick_velocity=self.kick_velocity,
            big_onset=big_onset, rms=rms_n,
            bpm=self.bpm,
            beat_phase=bp % 1.0,
            bar_phase=(bp % 4.0) / 4.0,
            phrase_phase=(bp % self.phrase_beats) / self.phrase_beats,
            phrase_index=(int(bp // self.phrase_beats)
                          + self.controls.scene_skip + self.drop_bump),
            timestamp=time.monotonic(),
            tension=self.tension, drop=drop, drop_power=self.drop_power,
            kick_onset_id=self.kick_onset_id, big_onset_id=self.big_onset_id,
            drop_id=self.drop_id,
        ))

    def _detect(self, x, now, hist, k, refractory, kind, gate=True):
        onset = False
        if gate and len(hist) >= int(0.5 * self.frame_rate):
            h = np.fromiter(hist, dtype=np.float32)
            m = float(h.mean())
            sd_ = float(h.std())
            thresh = m + k * sd_
            last = self.last_kick_t if kind == "kick" else self.last_big_t
            if x > thresh and (now - last) >= refractory:
                onset = True
                if kind == "kick":
                    self.last_kick_t = now
                    self.kick_onset_id += 1
                    self.kick_velocity = float(np.clip((x - thresh) / (3.0 * sd_ + 1e-9), 0.0, 1.0))
                else:
                    self.last_big_t = now
                    self.big_onset_id += 1
        hist.append(x)
        return onset

    def _update_tempo_phase(self, dt, kick_onset, now):
        if kick_onset:
            self.onset_times.append(now)
            if len(self.onset_times) >= 4:
                d = np.diff(np.asarray(self.onset_times))
                d = d[(d > 0.25) & (d < 2.0)]
                if len(d) >= 3:
                    # fold EACH interval into range BEFORE averaging: missed kicks
                    # give 2-beat gaps, and a median over mixed octaves lands
                    # between harmonics (fold then clamps it to min_bpm - this is
                    # how a 143 BPM mix decayed to a stuck 127)
                    bpms = np.array([fold_bpm(60.0 / x, self.bpm_lo, self.bpm_hi)
                                     for x in d])
                    med = float(np.median(bpms))
                    good = bpms[np.abs(bpms - med) <= 3.0]
                    # incoherent window (fills, syncopation) -> keep current BPM
                    if len(good) >= 0.6 * len(bpms):
                        self.bpm = 0.85 * self.bpm + 0.15 * float(np.median(good))
        override = self.controls.bpm_override or self.cfg_bpm_override
        if override:
            self.bpm = float(override)
        self.beat_pos += dt * self.bpm / 60.0
        if kick_onset:
            frac = self.beat_pos % 1.0
            if frac < 0.5:
                self.beat_pos -= frac * self.nudge
            else:
                self.beat_pos += (1.0 - frac) * self.nudge


class LiveAudioEngine:
    """Analyzes the default (or --device N) input device in realtime."""

    def __init__(self, cfg, bus, controls, device=None):
        self.cfg = cfg
        self.bus = bus
        self.controls = controls
        self.device = device if device is not None else cfg["audio"].get("device")
        self.analyzer = None
        self.stream = None

    def start(self):
        a = self.cfg["audio"]
        sr = int(a["samplerate"])
        block = int(a["blocksize"])
        try:
            self.analyzer = AudioAnalyzer(self.cfg, self.bus, self.controls, samplerate=sr)
            self.stream = sd.InputStream(device=self.device, channels=1, samplerate=sr,
                                         blocksize=block, dtype="float32", callback=self._cb)
            self.stream.start()
        except sd.PortAudioError:
            info = sd.query_devices(self.device, "input")
            sr = int(info["default_samplerate"])
            print(f"[audio] 44100 Hz unsupported on device, using {sr} Hz")
            self.analyzer = AudioAnalyzer(self.cfg, self.bus, self.controls, samplerate=sr)
            self.stream = sd.InputStream(device=self.device, channels=1, samplerate=sr,
                                         blocksize=block, dtype="float32", callback=self._cb)
            self.stream.start()
        name = sd.query_devices(self.stream.device, "input")["name"]
        print(f"[audio] live input: {name} @ {sr} Hz")

    def _cb(self, indata, frames, time_info, status):
        self.analyzer.process_block(indata[:, 0].copy())

    def stop(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()


class FileAudioEngine:
    """Plays a file to the output device while feeding the identical samples
    to analysis - zero-routing test path. Loops at EOF."""

    def __init__(self, cfg, bus, controls, path, seek=0.0):
        self.cfg = cfg
        self.bus = bus
        self.controls = controls
        self.path = path
        self.seek = seek
        self.analyzer = None
        self.stream = None
        self.data = None
        self.pos = 0
        self.sr = int(cfg["audio"]["samplerate"])

    @property
    def position(self):  # seconds into the file (wraps on loop)
        return self.pos / self.sr if self.data is not None else 0.0

    @property
    def duration(self):
        return len(self.data) / self.sr if self.data is not None else 0.0

    def start(self):
        a = self.cfg["audio"]
        target_sr = int(a["samplerate"])
        block = int(a["blocksize"])
        try:
            data, sr = sf.read(self.path, dtype="float32", always_2d=True)
        except Exception as e:
            sys.exit(f"[audio] could not read {self.path}: {e}\n"
                     f"If this is an mp3 and your libsndfile lacks mp3 support, convert first:\n"
                     f"  ffmpeg -i {self.path} mix.wav")
        if sr != target_sr:
            g = gcd(sr, target_sr)
            data = resample_poly(data, target_sr // g, sr // g, axis=0).astype(np.float32)
            print(f"[audio] resampled {sr} -> {target_sr} Hz")
        if data.shape[1] == 1:
            data = np.repeat(data, 2, axis=1)
        self.data = np.ascontiguousarray(data[:, :2])
        dur = len(self.data) / target_sr
        if self.seek:
            self.pos = int(self.seek * target_sr) % len(self.data)
            print(f"[audio] seeking to {self.seek:.0f}s")
        print(f"[audio] file: {self.path} ({dur:.0f}s @ {target_sr} Hz, looping)")
        self.analyzer = AudioAnalyzer(self.cfg, self.bus, self.controls, samplerate=target_sr)
        self.stream = sd.OutputStream(samplerate=target_sr, channels=2, blocksize=block,
                                      dtype="float32", callback=self._cb)
        self.stream.start()

    def _cb(self, outdata, frames, time_info, status):
        idx = (self.pos + np.arange(frames)) % len(self.data)
        chunk = self.data[idx]
        self.pos = (self.pos + frames) % len(self.data)
        outdata[:] = chunk
        self.analyzer.process_block(chunk.mean(axis=1))

    def stop(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()


def list_devices():
    print(sd.query_devices())
