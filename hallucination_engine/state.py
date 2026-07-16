"""Shared state: AudioState snapshots, thread-safe bus, controls, frame slot."""

import threading
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class AudioState:
    kick: float = 0.0
    perc: float = 0.0
    synth: float = 0.0
    air: float = 0.0
    kick_onset: bool = False
    kick_velocity: float = 0.0
    big_onset: bool = False
    rms: float = 0.0
    bpm: float = 130.0
    beat_phase: float = 0.0
    bar_phase: float = 0.0
    phrase_phase: float = 0.0
    phrase_index: int = 0
    timestamp: float = 0.0
    tension: float = 0.0      # 0-1, builds while kicks are absent (buildup/riser)
    drop: bool = False        # one analysis frame: kick returned after high tension
    drop_power: float = 0.0   # tension at the moment the last drop fired
    kick_onset_id: int = 0
    big_onset_id: int = 0
    drop_id: int = 0


class StateBus:
    """Atomic reference swap; reads/writes of a single attribute are GIL-atomic."""

    def __init__(self):
        self._state = AudioState()

    def publish(self, state: AudioState):
        self._state = state

    def read(self) -> AudioState:
        return self._state


class Consumer:
    """Per-consumer view: onset flags fire exactly once per consumer via id counters."""

    def __init__(self, bus: StateBus):
        self.bus = bus
        self._kick_id = 0
        self._big_id = 0
        self._drop_id = 0

    def read(self) -> AudioState:
        s = self.bus.read()
        kick = s.kick_onset_id != self._kick_id
        big = s.big_onset_id != self._big_id
        drop = s.drop_id != self._drop_id
        self._kick_id = s.kick_onset_id
        self._big_id = s.big_onset_id
        self._drop_id = s.drop_id
        if kick != s.kick_onset or big != s.big_onset or drop != s.drop:
            s = replace(s, kick_onset=kick, big_onset=big, drop=drop)
        return s


class Controls:
    """Hotkey/remote-driven shared controls (plain attrs, GIL-atomic)."""

    def __init__(self):
        self.denoise_offset = 0.0
        self.scene_skip = 0
        self.reset_counter = 0
        self.bpm_override = None
        # counters bumped by the control server, polled by their owners
        self.drop_request = 0        # analyzer: force THE DROP now (space bar)
        self.fullscreen_request = 0  # compositor
        self.capture_request = 0     # compositor
        self.quit_request = 0        # compositor
        self.logo_burst = 0          # diffusion: one logo flash now
        self.logo_hold = False       # diffusion: keep the logo stamped while true


class FrameSlot:
    """Latest diffusion frame + counter + measured frame period (EMA)."""

    def __init__(self):
        self._lock = threading.Lock()
        self._frame = None  # np.uint8 (H, W, 3)
        self._counter = 0
        self._period_ema = 0.25
        self._last_t = None

    def publish(self, frame, now: float):
        with self._lock:
            if self._last_t is not None:
                period = now - self._last_t
                self._period_ema = 0.9 * self._period_ema + 0.1 * period
            self._last_t = now
            self._frame = frame
            self._counter += 1

    def get(self):
        with self._lock:
            return self._frame, self._counter, self._period_ema
