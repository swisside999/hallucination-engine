"""Audio feature -> visual parameter mappings."""

import math

from .utils import clamp


def denoise_strength(state, dcfg, offset, forced=None):
    if forced is not None:
        return forced
    s = (dcfg["strength_base"]
         + state.kick * dcfg["strength_kick"]
         + (dcfg["strength_big"] if state.big_onset else 0.0)
         - state.tension * dcfg.get("strength_tension", 0.15)  # buildup: crystallize
         + offset)
    return clamp(s, dcfg["strength_min"], dcfg["strength_max"])


def feedback_transform(state, dcfg, t):
    """Returns (zoom, rot_deg, tx, ty, swirl) for the pre-diffusion affine."""
    zoom = (1.0 + dcfg["zoom_base"] + state.perc * dcfg["zoom_perc"]
            + state.tension * dcfg.get("zoom_tension", 0.010))  # buildup: accelerate
    rot = math.sin(2 * math.pi * dcfg["rot_lfo_hz"] * t) * state.synth * dcfg["rot_max_deg"]
    d = dcfg["drift_amount"]
    tx = math.sin(2 * math.pi * 0.011 * t) * d
    ty = math.sin(2 * math.pi * 0.017 * t + 1.7) * d
    swirl = dcfg["swirl_amount"] if (state.phrase_index % 4) == 3 else 0.0
    return zoom, rot, tx, ty, swirl


def kick_noise_amp(state, dcfg):
    return dcfg["noise_base"] + state.kick_velocity * dcfg["noise_kick_scale"]


class KickPulse:
    """Grid-locked pulse envelope for the visual inhale. Driving the pulse
    straight from detections is janky twice over: the kick BAND envelope
    rises on offbeat bass stabs (same 20-120 Hz, pulses land between kicks),
    and raw onsets flam against beat-clock fills (detections land half
    before / half after the nudged grid line). So while kicks flow, the
    pulse fires on every beat-grid boundary - the same phase-locked signal
    as the HUD beat dot - at the energy of recent real kicks. Detections
    only steer energy and the flow gate, with one exception: the FIRST kick
    after a kickless stretch (set start, THE DROP) hits instantly, on the
    kick itself, because the grid may not be re-anchored yet. The flow gate
    closes after 3.2 kickless beats so breakdowns get at most a couple of
    soft ghosts, then stay still."""

    def __init__(self):
        self.env = 0.0
        self._since_kick = 999.0
        self._prev_phase = 0.0
        self._hit = 0.6           # EMA of real kick energy

    def step(self, state, dt):
        beat = 60.0 / max(state.bpm, 1.0)
        flowing = self._since_kick < 3.2 * beat
        self._since_kick += dt
        if state.kick_onset:
            self._since_kick = 0.0
            self._hit = 0.6 * self._hit + 0.4 * (0.35 + 0.65 * state.kick_velocity)
            if not flowing:                                  # drop / set start
                self.env = max(self.env, self._hit)
        if state.beat_phase < self._prev_phase and flowing:  # beat-grid boundary
            self.env = max(self.env, self._hit)
        self.env *= math.exp(-dt / 0.13)
        self._prev_phase = state.beat_phase
        return self.env


def shader_params(state, disp, big_env):
    tn = state.tension
    return {
        "chroma": (state.kick * disp["chroma_kick_px"] + big_env * disp["chroma_big_px"]
                   + tn * disp.get("chroma_tension_px", 3.0)),  # rising unease
        "trail_amount": (disp["trail_base"] + state.synth * disp["trail_synth"])
        * (1.0 - 0.4 * tn),  # image tightens as the buildup rises
        "grain": disp["grain_base"] * (1.0 + state.perc * 0.5 + tn),
        "hue_rate": math.radians(disp["hue_rate_deg"]) * state.air,
    }
