"""slerp, envelope followers, adaptive normalizers, misc helpers."""

import math


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


class EnvelopeFollower:
    """One-pole attack/release smoother, coefficients derived from update rate."""

    def __init__(self, attack_ms: float, release_ms: float, rate_hz: float):
        self.att = math.exp(-1.0 / (max(attack_ms, 1e-3) * 1e-3 * rate_hz))
        self.rel = math.exp(-1.0 / (max(release_ms, 1e-3) * 1e-3 * rate_hz))
        self.value = 0.0

    def process(self, x: float) -> float:
        c = self.att if x > self.value else self.rel
        self.value = x + c * (self.value - x)
        return self.value


class AdaptiveNormalizer:
    """Rolling max with slow decay -> self-calibrating 0-1 output."""

    def __init__(self, decay: float = 0.999, floor: float = 1e-6):
        self.decay = decay
        self.floor = floor
        self.peak = floor

    def process(self, x: float) -> float:
        self.peak = max(self.peak * self.decay, x, self.floor)
        return min(x / self.peak, 1.0)


def fold_bpm(bpm: float, lo: float, hi: float) -> float:
    """Double/halve into [lo, hi]; bounded iterations, clamp as last resort."""
    for _ in range(6):
        if bpm < lo:
            bpm *= 2.0
        elif bpm > hi:
            bpm /= 2.0
        else:
            return bpm
    return clamp(bpm, lo, hi)


def slerp(a, b, t: float, dot_threshold: float = 0.9995):
    """Spherical interpolation between torch tensors; lerp fallback when near-parallel."""
    import torch

    if t <= 0.0:
        return a.clone()
    if t >= 1.0:
        return b.clone()
    af = a.reshape(-1).float()
    bf = b.reshape(-1).float()
    dot = torch.clamp(torch.dot(af / af.norm(), bf / bf.norm()), -1.0, 1.0)
    if torch.abs(dot) > dot_threshold:
        return torch.lerp(a, b, t)
    theta = torch.acos(dot)
    st = torch.sin(theta)
    wa = torch.sin((1.0 - t) * theta) / st
    wb = torch.sin(t * theta) / st
    return wa * a + wb * b


def deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out
