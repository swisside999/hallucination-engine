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
    """Onset-locked pulse envelope for the visual inhale. The kick BAND
    envelope also rises on offbeat bass stabs (same 20-120 Hz), which lands
    the pulse between kicks on techno; kick onsets are transient-gated, so
    driving the pulse from them locks it to actual kicks. The detector still
    drops the odd kick (bass sustaining under it dilutes the flux ratio), so
    a beat-clock fill covers a missed kick - but only while kicks flow: after
    ~1.8 kickless beats the fill stops, breakdowns must not keep pulsing."""

    def __init__(self):
        self.env = 0.0
        self._since_kick = 999.0
        self._prev_phase = 0.0
        self._last_hit = 0.6

    def step(self, state, dt):
        self._since_kick += dt
        if state.kick_onset:
            self._since_kick = 0.0
            self._last_hit = 0.35 + 0.65 * state.kick_velocity
            self.env = max(self.env, self._last_hit)
        else:
            beat = 60.0 / max(state.bpm, 1.0)
            # window covers a double miss; fill matches recent kick energy -
            # a visibly softer fill reads as a skipped kick too
            if (state.beat_phase < self._prev_phase          # beat-grid boundary
                    and 0.5 * beat < self._since_kick < 3.2 * beat):
                self.env = max(self.env, 0.9 * self._last_hit)
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
