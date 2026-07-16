"""Layer B - SD-Turbo img2img feedback loop, running as fast as MPS allows."""

import math
import threading
import time
import traceback
from pathlib import Path

import numpy as np
from PIL import Image

from . import mappings, prompts
from .prompts import PromptBank
from .state import Consumer

LUMA_W = np.array([0.2126, 0.7152, 0.0722], np.float32)


class DiffusionEngine(threading.Thread):
    def __init__(self, cfg, bus, controls, slot, assets_dir="assets"):
        super().__init__(daemon=True, name="diffusion")
        self.cfg = cfg
        self.dcfg = cfg["diffusion"]
        self.scfg = cfg["scenes"]
        self.bus = bus
        self.controls = controls
        self.slot = slot
        self.assets_dir = Path(assets_dir)
        self.stop_event = threading.Event()
        self.res = (int(self.dcfg["resolution"]) // 8) * 8
        self.steps_cfg = int(self.dcfg["steps"])
        self.current_strength = float(self.dcfg["strength_base"])
        self._seen_reset = 0
        self._rng = np.random.default_rng()
        # live preset switch: old bank kept for the crossfade window
        self._old_bank = None
        self._fade_t0 = None
        self._preset_lock = threading.Lock()
        # live stats for the control server
        self.frames_total = 0
        self.resets_total = 0
        self.stripe = 0.0
        self.grid = 0.0
        self.diff_fps = 0.0
        self._lock_hist = []  # (t, locked) over the last ~5 min
        # DJ logo stamp
        self.logo_on = 0.0
        self._logo_path = None
        self._logo_alpha = None   # (1,1,res,res) fp32 on device
        self._logo_rgb = None     # (1,3,res,res)
        self._seen_logo_burst = 0

    # ---------------------------------------------------------------- setup

    def setup(self):
        """Load pipeline, encode prompts, warm up. Call on main thread before start()."""
        import torch
        from diffusers import AutoPipelineForImage2Image

        self.torch = torch
        if torch.backends.mps.is_available():
            self.device, self.dtype = "mps", torch.float16
        else:
            print("=" * 68)
            print("WARNING: MPS unavailable - falling back to CPU. This will be SLOW.")
            print("=" * 68)
            self.device, self.dtype = "cpu", torch.float32

        # prefer the local export: immune to Hub outages/network switches, which
        # otherwise hang from_pretrained's metadata check for minutes
        local = self.assets_dir.parent / "models" / "sd-turbo"
        model = str(local) if (local / "model_index.json").exists() else self.dcfg["model"]
        print(f"[diffusion] loading {model} ({self.device}, {self.dtype}) ...")
        try:
            pipe = AutoPipelineForImage2Image.from_pretrained(
                model, torch_dtype=self.dtype, variant="fp16")
        except Exception:
            pipe = AutoPipelineForImage2Image.from_pretrained(model, torch_dtype=self.dtype)
        pipe.set_progress_bar_config(disable=True)
        pipe = pipe.to(self.device)
        if self.dcfg.get("attention_slicing", False):
            pipe.enable_attention_slicing()
        if hasattr(pipe, "safety_checker"):
            pipe.safety_checker = None
        if self.dcfg.get("taesd", True):
            # full SD VAE costs ~500ms/frame on MPS; TAESD gets 512px above 4 fps
            from diffusers import AutoencoderTiny
            local_t = self.assets_dir.parent / "models" / "taesd"
            src = str(local_t) if (local_t / "config.json").exists() else "madebyollin/taesd"
            print("[diffusion] swapping in TAESD tiny VAE (diffusion.taesd: false for full VAE)")
            pipe.vae = AutoencoderTiny.from_pretrained(
                src, torch_dtype=self.dtype).to(self.device)
        self.pipe = pipe

        # manual single-step sampling state: the pipeline's ceil(1/strength) trick
        # quantizes effective strength to {1/2, 1/3, ...}; we add noise at an
        # arbitrary sigma and jump straight to the x0 prediction instead
        pipe.scheduler.set_timesteps(100, device=self.device)
        self.timesteps = pipe.scheduler.timesteps
        self.sigmas = pipe.scheduler.sigmas.to(self.device)
        self.vae_scale = pipe.vae.config.scaling_factor

        print("[diffusion] encoding prompt bank ...")
        # module refs, not import-time copies: a --preset load rebinds NEGATIVE
        self.bank = PromptBank(pipe, prompts.SCENES, prompts.NEGATIVE, self.device,
                               shuffle=self.scfg.get("shuffle", True),
                               hybrid_chance=self.scfg.get("hybrid_chance", 0.3))
        # launch-time snapshot of the preset-overridable sections, so a live
        # preset switch can revert one preset's overrides before applying the
        # next - overrides must never leak between presets
        import copy
        self._cfg_baseline = copy.deepcopy(
            {k: self.cfg[k] for k in ("diffusion", "display", "scenes")
             if k in self.cfg})

        # GPU-resident loop state: the frame lives on-device as (1,3,H,W) fp32 in
        # [0,1] - fp16 is only for the VAE/UNet. Transform/servo/unsharp in fp16
        # accumulate interpolation quantization into stripe banding over minutes.
        seed = self._load_seed()
        self.frame_t = torch.from_numpy(seed).permute(2, 0, 1)[None] \
            .to(self.device, torch.float32).contiguous()
        lin = torch.linspace(-1.0, 1.0, self.res, device=self.device)
        self._by, self._bx = torch.meshgrid(lin, lin, indexing="ij")
        self._luma_t = torch.tensor([0.2126, 0.7152, 0.0722], device=self.device,
                                    dtype=torch.float32).view(1, 3, 1, 1)
        k = torch.exp(-torch.arange(-4, 5, device=self.device, dtype=torch.float32) ** 2
                      / (2 * 2.0 ** 2))
        k = k / k.sum()
        self._blur_kh = k.view(1, 1, 1, 9).repeat(3, 1, 1, 1)
        self._blur_kv = k.view(1, 1, 9, 1).repeat(3, 1, 1, 1)

        # orientation-anisotropy masks (64x64 rfft2 half-plane, 8 angle bins):
        # stripe-locked frames concentrate spectral energy in one orientation
        n = 64
        fy = np.fft.fftfreq(n)[:, None]
        fx = np.fft.rfftfreq(n)[None, :]
        ang = np.mod(np.arctan2(fy, fx), np.pi)
        rad = np.sqrt(fx ** 2 + fy ** 2)
        bins = (ang / np.pi * 8).astype(int) % 8
        self._ang_masks = [(bins == k) & (rad > 0.03) for k in range(8)]

        print("[diffusion] warming up (2 iterations) ...")
        emb = self.bank.get(0, 0.0, 0.0, self.scfg["blend_start"], self.scfg["shimmer"])
        for g in (0.0, 3.0):  # warm both unet batch shapes (plain + CFG)
            t0 = time.monotonic()
            self._generate(self.frame_t, emb, 0.5, g)
            print(f"[diffusion]   warmup iter: {time.monotonic() - t0:.2f}s")
        print("[diffusion] ready")

    def _load_seed(self):
        p = self.assets_dir / "seed.png"
        if p.exists():
            img = Image.open(p).convert("RGB")
            if img.size != (self.res, self.res):
                img = img.resize((self.res, self.res), Image.LANCZOS)
            return np.asarray(img, dtype=np.float32) / 255.0
        rng = np.random.default_rng(7)
        arr = np.clip(0.5 + rng.standard_normal((self.res, self.res, 3)).astype(np.float32) * 0.25,
                      0.0, 1.0)
        p.parent.mkdir(parents=True, exist_ok=True)
        Image.fromarray((arr * 255).astype(np.uint8)).save(p)
        print(f"[diffusion] generated seed image {p}")
        return arr

    def _maybe_load_logo(self):
        """(Re)load the logo when logo.path changes - called on the diffusion
        thread, so a swap costs at most one frame."""
        lcfg = self.cfg.get("logo", {})
        path = str(lcfg.get("path") or "")
        if path == self._logo_path:
            return
        self._logo_path = path
        self._logo_alpha = self._logo_rgb = None
        if not path:
            return
        try:
            img = Image.open(path).convert("RGBA")
        except Exception as e:
            print(f"[logo] load failed {path}: {e}")
            return
        w = max(int(self.res * float(lcfg.get("scale", 0.6))), 8)
        h = max(int(img.height * w / img.width), 8)
        if h > self.res:
            w, h = int(w * self.res / h), self.res
        arr = np.asarray(img.resize((w, h), Image.LANCZOS), np.float32) / 255.0
        rgb, a = arr[..., :3], arr[..., 3]
        if a.min() > 0.99:  # no real alpha channel: white-on-black luma mask
            a = rgb @ LUMA_W
        ca = np.zeros((self.res, self.res), np.float32)
        crgb = np.zeros((self.res, self.res, 3), np.float32)
        y0, x0 = (self.res - h) // 2, (self.res - w) // 2
        ca[y0:y0 + h, x0:x0 + w] = a
        crgb[y0:y0 + h, x0:x0 + w] = rgb
        self._logo_alpha = self.torch.from_numpy(ca)[None, None].to(self.device)
        self._logo_rgb = (self.torch.from_numpy(crgb).permute(2, 0, 1)[None]
                          .to(self.device))
        print(f"[logo] loaded {path} ({w}x{h})")

    def _logo_stamp(self, frame, s, t):
        """Seed the logo shape into the pre-diffusion frame during a burst so
        the hallucination forms around it; the legibility pass happens after
        _generate (see step) - this one only computes the envelope and nudges
        the input toward the logo."""
        lcfg = self.cfg.get("logo", {})
        self._maybe_load_logo()
        if self._logo_alpha is None:
            self.logo_on = 0.0
            return frame
        fl = max(float(lcfg.get("flash_seconds", 2.5)), 0.1)
        if self.controls.logo_burst != self._seen_logo_burst:
            self._seen_logo_burst = self.controls.logo_burst
            self._logo_until = t + fl
        if lcfg.get("enable", False):
            if s.drop and self._rng.random() < lcfg.get("drop_chance", 0.8):
                self._logo_until = t + fl * (1.0 + s.drop_power)
            elif s.big_onset and self._rng.random() < lcfg.get("big_chance", 0.1):
                self._logo_until = t + fl * 0.5
            if (self._logo_last_phrase is not None
                    and s.phrase_index != self._logo_last_phrase
                    and self._rng.random() < lcfg.get("phrase_chance", 0.1)):
                self._logo_until = t + fl
            self._logo_last_phrase = s.phrase_index
        if self.controls.logo_hold:
            a = 1.0
        elif t < self._logo_until:
            a = min((self._logo_until - t) / fl, 1.0)  # fade out over the burst
        else:
            a = 0.0
        self.logo_on = a
        if a > 0.0:
            w = self._logo_alpha * (a * float(lcfg.get("seed_opacity", 0.25)))
            frame = frame + w * (self._logo_rgb - frame)
        return frame

    # ----------------------------------------------------------- core steps

    def _transform(self, img, zoom, rot_deg, tx, ty, swirl):
        """Inverse-mapped zoom/rotate/drift(/swirl) via grid_sample, reflection-padded."""
        torch = self.torch
        F = torch.nn.functional
        n = 2.0 / (self.res - 1)  # px -> normalized units
        x = self._bx - tx * n
        y = self._by - ty * n
        if swirl != 0.0:
            a = swirl * torch.exp(-1.25 * (x * x + y * y))
            cs, sn = torch.cos(a), torch.sin(a)
            x, y = cs * x - sn * y, sn * x + cs * y
        th = math.radians(rot_deg)
        cs, sn = math.cos(th), math.sin(th)
        xs = (cs * x - sn * y) / zoom
        ys = (sn * x + cs * y) / zoom
        grid = torch.stack([xs, ys], dim=-1)[None].to(img.dtype)
        return F.grid_sample(img, grid, mode="bilinear",
                             padding_mode="reflection", align_corners=True)

    def _generate(self, frame_f, embeds, strength, guidance=0.0):
        """One img2img iteration at a CONTINUOUS strength: encode -> noise at
        sigma(strength) -> single UNet pass -> x0 prediction -> decode.

        guidance > 1 runs a batched cond+uncond pass (CFG): ~1.6x cost, so it is
        used only on scene-stamp frames (phrase flash / drop), where the prompt
        must overpower the incumbent image."""
        torch = self.torch
        with torch.inference_mode():
            x = frame_f.clamp(0.0, 1.0).to(self.dtype) * 2.0 - 1.0
            enc = self.pipe.vae.encode(x)
            lat = enc.latents if hasattr(enc, "latents") else enc.latent_dist.sample()
            lat = lat * self.vae_scale
            n = len(self.timesteps)
            idx = min(max(int(round((1.0 - float(strength)) * (n - 1))), 0), n - 1)
            idxs = [idx]
            if self.steps_cfg >= 2:  # optional refinement pass at half the sigma
                idxs.append(min(idx + (n - idx) // 2, n - 1))
            emb = embeds.to(self.device, self.dtype)
            cfg = guidance > 1.0
            if cfg:
                emb2 = torch.cat([self.bank.negative.to(self.device, self.dtype), emb])
            x0 = lat
            for k, i in enumerate(idxs):
                sigma = self.sigmas[i]
                cur = x0 + torch.randn_like(lat) * sigma
                inp = cur / ((sigma ** 2 + 1.0) ** 0.5)
                if cfg:
                    eps_u, eps_c = self.pipe.unet(
                        torch.cat([inp, inp]), self.timesteps[i],
                        encoder_hidden_states=emb2).sample.chunk(2)
                    eps = eps_u + guidance * (eps_c - eps_u)
                else:
                    eps = self.pipe.unet(inp, self.timesteps[i],
                                         encoder_hidden_states=emb).sample
                x0 = cur - sigma * eps
            dec = self.pipe.vae.decode(x0 / self.vae_scale).sample
            return ((dec.float() + 1.0) * 0.5).clamp(0.0, 1.0)

    def _servo(self, arr):
        """Luma/saturation/channel-balance servo on-device; returns corrected
        (1,3,H,W) tensor + python-float measurements (one small sync)."""
        torch = self.torch
        sv = self.dcfg["servo"]
        sub = arr[..., ::4, ::4]
        # gray-world channel balance: stops the loop locking into one hue forever
        ch = sub.mean(dim=(0, 2, 3))
        ch_gain = (((ch.mean() + 1e-3) / (ch + 1e-3))
                   ** sv.get("chroma_rate", 0.01)).clamp(0.97, 1.03)
        arr = arr * ch_gain.view(1, 3, 1, 1)
        luma = float((sub * self._luma_t).sum(dim=1).mean())
        sat = float((sub.amax(dim=1) - sub.amin(dim=1)).mean())
        rate = sv["rate"]
        gain = (sv["luma_target"] / max(luma, 1e-3)) ** rate
        sgain = min(max(((sv["sat_target"] + 1e-3) / (sat + 1e-3)) ** rate, 0.7), 1.4)
        full_luma = (arr * self._luma_t).sum(dim=1, keepdim=True) * gain
        arr = full_luma + (arr * gain - full_luma) * sgain
        return arr.clamp(0.0, 1.0), luma, sat

    def _unsharp(self, arr, amount):
        """img + amount * (img - gaussian(img)), separable 9-tap sigma-2 blur.
        The threshold matters: without it, faint emerging stripe banding gets
        amplified every iteration and the feedback loop locks onto it (PIL's
        UnsharpMask threshold=2 was silently doing this job before)."""
        F = self.torch.nn.functional
        pad = F.pad(arr, (4, 4, 4, 4), mode="reflect")
        blur = F.conv2d(F.conv2d(pad, self._blur_kh, groups=3), self._blur_kv, groups=3)
        diff = arr - blur
        mask = (diff.abs() > 2.0 / 255.0).to(arr.dtype)
        return (arr + amount * diff * mask).clamp(0.0, 1.0)

    def _anisotropy(self, arr8):
        """Orientation lock measure on the published uint8 frame.
        Returns (stripe, grid): top-1 and top-2 orientation-bin energy fractions.
        Isotropic image ~ (0.125, 0.25); stripes ~ (0.35+, ...); grids split their
        energy across two orthogonal bins, so top-2 catches what top-1 misses."""
        step = max(arr8.shape[0] // 64, 1)
        g = (arr8[::step, ::step][:64, :64].astype(np.float32) / 255.0) @ LUMA_W
        F = np.abs(np.fft.rfft2(g - g.mean()))
        e = np.sort([F[m].sum() for m in self._ang_masks])
        tot = e.sum() + 1e-9
        return float(e[-1] / tot), float((e[-1] + e[-2]) / tot)

    # ------------------------------------------------------------- run loop

    def reset_run_state(self):
        """Per-run loop state - shared by the realtime thread and offline render."""
        self._old_bank = None
        self._fade_t0 = None
        self._bad_since = None
        self._last_phrase = None
        self._rampage_until = 0.0
        self._logo_until = 0.0
        self._logo_last_phrase = None
        self._n_iter = 0
        self._last_log = time.monotonic()

    def apply_preset(self, name):
        """Live prompt-preset switch, callable from the control-server thread.
        The text encoder is idle during the run loop, so re-encoding the bank
        here is safe; the swap is one attribute write and step() crossfades
        the conditioning for a few seconds. Preset config overrides merge into
        the SHARED cfg section dicts in place (startup-only keys like
        resolution/taesd merge but stay inert until relaunch); the launch
        baseline is restored first so overrides never leak between presets."""
        import copy

        from .utils import deep_merge
        with self._preset_lock:
            pc = prompts.load_preset(name)
            if pc is None:
                return False
            for key, base in self._cfg_baseline.items():
                merged = deep_merge(base, pc.get(key) or {})
                live = self.cfg[key]
                for stale in [k for k in live if k not in merged]:
                    del live[stale]  # extras a previous preset added
                live.update(copy.deepcopy(merged))
            bank = PromptBank(self.pipe, prompts.SCENES, prompts.NEGATIVE,
                              self.device,
                              shuffle=self.scfg.get("shuffle", True),
                              hybrid_chance=self.scfg.get("hybrid_chance", 0.3))
            self._old_bank = self.bank
            self._fade_t0 = None
            self.bank = bank
            print(f"[diffusion] live preset -> {prompts.CURRENT_PRESET} "
                  f"({len(prompts.SCENES)} scenes, crossfading)")
            return True

    def step(self, s, t):
        """One feedback-loop iteration at (state s, timeline t). t is wall time
        live and VIRTUAL mix time in render mode - all windows (rampage, grace)
        are expressed in it. Publishes the frame to the slot and returns it."""
        cc = self.dcfg["collapse"]
        pf = self.dcfg.get("phrase_flash", {})
        dr = self.dcfg.get("drop", {})

        zoom, rot, tx, ty, swirl = mappings.feedback_transform(s, self.dcfg, t)
        frame = self._transform(self.frame_t, zoom, rot, tx, ty, swirl)

        forced = None
        # noise floor breaks deterministic feedback attractors (stripe/grid
        # lock-in); kick/reset variances add on top, one randn call total
        var = self.dcfg.get("noise_idle", 0.01) ** 2
        if s.kick_onset:
            var += mappings.kick_noise_amp(s, self.dcfg) ** 2

        # phrase flash: one strong CFG re-dream on every phrase boundary so
        # feedback attractors never consolidate; the compositor crossfade
        # spreads it over ~250ms (a soft multi-frame melt was tried - it
        # cannot break line/grid locks and they take over the show)
        guidance = 0.0
        if pf.get("enable", True):
            if self._last_phrase is not None and s.phrase_index != self._last_phrase:
                forced = pf.get("strength", 0.85)
                var += pf.get("noise", 0.15) ** 2
                guidance = pf.get("guidance", 3.0)
            self._last_phrase = s.phrase_index

        # the drop: kick returning after a buildup -> image explodes and
        # reforms as the (drop-advanced) next scene, then keeps
        # hallucinating rapidly for a window scaled by buildup length
        if s.drop:
            forced = dr.get("strength", 0.85)
            var += dr.get("noise", 0.30) ** 2
            guidance = dr.get("guidance", 3.5)
            self._rampage_until = t + dr.get("rampage_seconds", 4.0) \
                * max(s.drop_power, 0.3)
            print(f"[diffusion] DROP (power {s.drop_power:.2f})")
        elif t < self._rampage_until:
            var += dr.get("rampage_noise", 0.03) ** 2

        auto_reset = (self._bad_since is not None
                      and (t - self._bad_since) > cc["grace_seconds"])
        if self.controls.reset_counter != self._seen_reset or auto_reset:
            self._seen_reset = self.controls.reset_counter
            var += cc["reset_noise"] ** 2
            forced = cc["reset_strength"]
            guidance = max(guidance, 3.0)  # recover INTO the scene, not mush
            self._bad_since = None
            self.resets_total += 1
            print("[diffusion] reset flash")
        if var > 0.0:
            frame = frame + self.torch.randn_like(frame) * math.sqrt(var)
        frame = self._logo_stamp(frame, s, t)
        strength = mappings.denoise_strength(s, self.dcfg,
                                             self.controls.denoise_offset, forced)
        if forced is None and t < self._rampage_until:
            strength = max(strength, dr.get("rampage_strength", 0.62))
        self.current_strength = strength
        emb = self.bank.get(s.phrase_index, s.phrase_phase, s.synth,
                            self.scfg["blend_start"], self.scfg["shimmer"])
        if self._old_bank is not None:  # live preset switch: crossfade banks
            if self._fade_t0 is None:
                self._fade_t0 = t
            f = (t - self._fade_t0) / float(self.scfg.get("preset_fade_secs", 4.0))
            if f >= 1.0:
                self._old_bank = None
                self._fade_t0 = None
            else:
                old = self._old_bank.get(s.phrase_index, s.phrase_phase, s.synth,
                                         self.scfg["blend_start"],
                                         self.scfg["shimmer"])
                emb = prompts.slerp(old, emb, f * f * (3.0 - 2.0 * f))

        arr = self._generate(frame, emb, strength, guidance)
        if not self.torch.isfinite(arr).all():
            print("[diffusion] non-finite output, reseeding")
            arr = (0.5 + self.torch.randn_like(arr) * 0.25).clamp(0.0, 1.0)

        arr, luma, sat = self._servo(arr)
        arr = self._unsharp(arr, self.dcfg["sharpen_amount"])

        # legibility pass: overlay the logo AFTER the dream at opacity < 1 so
        # it reads crisp white while scene texture bleeds through inside; the
        # feedback loop then hallucinates around the stamped frame, and the
        # burst envelope melts it back into the dream on the way out
        if self.logo_on > 0.0 and self._logo_alpha is not None:
            w = self._logo_alpha * (self.logo_on
                                    * float(self.cfg["logo"].get("opacity", 0.80)))
            arr = arr + w * (self._logo_rgb - arr)

        out8 = (arr[0].permute(1, 2, 0) * 255.0).round().byte().cpu().numpy()
        # feed back the QUANTIZED frame: the uint8 roundtrip dithers away
        # decode micro-banding that otherwise accumulates into stripe locks
        self.frame_t = (self.torch.from_numpy(out8).to(self.device)
                        .permute(2, 0, 1)[None].float() / 255.0)
        stripe, grid = self._anisotropy(out8)
        bad = (not (cc["luma_min"] <= luma <= cc["luma_max"])
               or sat < cc["sat_min"] or sat > cc.get("sat_max", 0.85)
               or stripe > cc.get("anisotropy_max", 0.45)
               or grid > cc.get("grid_max", 0.60))
        # the stamped logo's straight strokes read as a stripe/grid lock -
        # don't let a burst trip the auto-reset
        bad = bad and self.logo_on < 0.5
        self._bad_since = (self._bad_since if self._bad_since is not None else t) \
            if bad else None
        self.slot.publish(out8, time.monotonic())

        self.stripe, self.grid = stripe, grid
        self.frames_total += 1
        self._lock_hist.append((t, bad))
        while self._lock_hist and t - self._lock_hist[0][0] > 300.0:
            self._lock_hist.pop(0)

        self._n_iter += 1
        now = time.monotonic()
        if now - self._last_log >= 5.0:
            self.diff_fps = self._n_iter / (now - self._last_log)
            print(f"[diffusion] {self.diff_fps:.1f} fps "
                  f"(strength {strength:.2f}, "
                  f"scene: {self.bank.scene_label(s.phrase_index)[:44]})")
            self._n_iter = 0
            self._last_log = now
        return out8

    def run(self):
        consumer = Consumer(self.bus)
        t0 = time.monotonic()
        self.reset_run_state()
        while not self.stop_event.is_set():
            try:
                self.step(consumer.read(), time.monotonic() - t0)
            except Exception:
                traceback.print_exc()
                time.sleep(0.5)

    @property
    def locked_pct(self):
        """Fraction of the last 5 min the lock detectors read bad (0-1)."""
        h = self._lock_hist
        return sum(1 for _, b in h if b) / len(h) if h else 0.0

    def stop(self):
        self.stop_event.set()
