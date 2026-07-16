"""Offline render: mix -> video file. Runs the whole pipeline on a VIRTUAL
clock - audio analyzed block-by-block, diffusion stepped at a fixed virtual
rate (renders can afford more fps than live), Layer C composited into an
offscreen FBO and piped to ffmpeg with the original audio muxed in."""

import math
import random
import shutil
import subprocess
import time
from math import gcd
from pathlib import Path

import glfw
import moderngl
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from . import mappings
from .audio_engine import AudioAnalyzer
from .state import Consumer

SHADER_DIR = Path(__file__).parent / "shaders"


class OfflineRenderer:
    def __init__(self, cfg, bus, controls, slot, engine, mix_path, out_path,
                 seek=0.0, duration=None, fps=30, size=1024, diff_fps=6.0):
        self.cfg = cfg
        self.disp = cfg["display"]
        self.bus = bus
        self.controls = controls
        self.slot = slot
        self.engine = engine
        self.mix_path = str(mix_path)
        self.out_path = str(out_path)
        self.seek = float(seek)
        self.duration = duration
        self.fps = int(fps)
        self.size = int(size)
        self.diff_fps = float(diff_fps)
        # optional center-crop of the square frame (reels: 1920 -> 1080x1920)
        out = (cfg.get("render", {}) or {}).get("out_size")
        if out:
            self.out_w = min(int(out[0]), self.size) // 2 * 2
            self.out_h = min(int(out[1]), self.size) // 2 * 2
        else:
            self.out_w = self.out_h = self.size
        self.crop_x = (self.size - self.out_w) // 2
        self.crop_y = (self.size - self.out_h) // 2

    # ---------------------------------------------------------------- audio

    def _load_audio(self):
        target_sr = int(self.cfg["audio"]["samplerate"])
        data, sr = sf.read(self.mix_path, dtype="float32", always_2d=True)
        if sr != target_sr:
            g = gcd(sr, target_sr)
            data = resample_poly(data, target_sr // g, sr // g, axis=0).astype(np.float32)
        mono = data.mean(axis=1)
        start = int(self.seek * target_sr)
        if start >= len(mono):
            raise SystemExit(f"[render] seek {self.seek:.0f}s is past end of file")
        end = len(mono)
        if self.duration is not None:
            end = min(end, start + int(float(self.duration) * target_sr))
        return mono[start:end], target_sr

    # ------------------------------------------------------------------- GL

    def _setup_gl(self):
        if not glfw.init():
            raise RuntimeError("glfw init failed")
        glfw.window_hint(glfw.VISIBLE, False)
        glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 3)
        glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 3)
        glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        glfw.window_hint(glfw.OPENGL_FORWARD_COMPAT, True)
        self.win = glfw.create_window(64, 64, "render", None, None)
        glfw.make_context_current(self.win)
        self.ctx = moderngl.create_context()

        vert = (SHADER_DIR / "composite.vert").read_text()
        frag = (SHADER_DIR / "composite.frag").read_text()
        self.prog = self.ctx.program(vertex_shader=vert, fragment_shader=frag)
        tri = np.array([-1, -1, 3, -1, -1, 3], dtype="f4")
        vbo = self.ctx.buffer(tri.tobytes())
        self.vao = self.ctx.vertex_array(self.prog, [(vbo, "2f", "in_pos")])

        res = self.engine.res
        mk = lambda size, comps: self._mk_tex(size, comps)
        self.tex_prev = mk((res, res), 3)
        self.tex_cur = mk((res, res), 3)
        black = np.zeros((res, res, 3), np.uint8)
        self.tex_prev.write(black.tobytes())
        self.tex_cur.write(black.tobytes())
        wh = (self.size, self.size)
        self.tex_src = mk(wh, 3)
        self.tex_dst = mk(wh, 3)
        self.fbo_src = self.ctx.framebuffer([self.tex_src])
        self.fbo_dst = self.ctx.framebuffer([self.tex_dst])
        self.fbo_src.clear()
        self.fbo_dst.clear()
        for name, val in (("u_prev_frame", 0), ("u_cur_frame", 1), ("u_feedback", 2)):
            self._set_uniform(name, val)

    def _mk_tex(self, size, comps):
        t = self.ctx.texture(size, comps)
        t.filter = (moderngl.LINEAR, moderngl.LINEAR)
        t.repeat_x = t.repeat_y = False
        return t

    def _set_uniform(self, name, value):
        try:
            self.prog[name].value = value
        except KeyError:
            pass

    # ------------------------------------------------------------------ run

    def run(self):
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise SystemExit("[render] ffmpeg not found - brew install ffmpeg")
        mono, sr = self._load_audio()
        dur = len(mono) / sr
        block = int(self.cfg["audio"]["blocksize"])
        analyzer = AudioAnalyzer(self.cfg, self.bus, self.controls)
        eng_consumer = Consumer(self.bus)   # one-shot onsets for the diffusion loop
        fx_consumer = Consumer(self.bus)    # separate one-shots for the FX layer
        self.engine.reset_run_state()
        self._setup_gl()

        long_side = max(self.out_w, self.out_h)
        bitrate = "5M" if long_side <= 512 else "8M" if long_side <= 768 else "12M"
        n_video = int(dur * self.fps)
        cmd = [ffmpeg, "-y", "-loglevel", "error",
               "-f", "rawvideo", "-pix_fmt", "rgb24",
               "-s", f"{self.out_w}x{self.out_h}", "-r", str(self.fps), "-i", "pipe:0",
               "-ss", f"{self.seek:.3f}", "-t", f"{dur:.3f}", "-i", self.mix_path,
               "-map", "0:v", "-map", "1:a?",
               "-c:v", "h264_videotoolbox", "-b:v", bitrate, "-pix_fmt", "yuv420p",
               "-c:a", "aac", "-b:a", "192k", "-shortest", self.out_path]
        enc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        shape = (f"{self.size}px" if self.out_w == self.size and self.out_h == self.size
                 else f"{self.out_w}x{self.out_h} (crop of {self.size}px)")
        print(f"[render] {dur:.0f}s of {Path(self.mix_path).name} -> {self.out_path} "
              f"({shape} {self.fps}fps, diffusion {self.diff_fps:g}fps)", flush=True)

        # FX-layer state (mirrors Compositor._frame on the virtual clock)
        rng = random.Random(7)
        big_env = drop_env = hue = 0.0
        drop_tau = 0.25
        strobe_until = -1.0
        frame_counter = -1
        last_diff_vt = 0.0
        diff_period = 1.0 / self.diff_fps
        frame_period = 1.0 / self.fps
        next_diff = 0.0
        next_frame = 0.0
        frames_done = 0
        wall0 = time.monotonic()
        last_report = wall0

        # scheduled forced drops (track-absolute seconds): offline we know the
        # whole mix, so exact cue beats the kick-drought heuristic (which sparse
        # breakdown kicks defeat). Cues before the seek point are out of range,
        # not "already due" - keep them from firing at t=0.
        pending_drops = sorted(float(t) - self.seek
                               for t in self.cfg.get("render", {}).get("drop_times", [])
                               if float(t) >= self.seek)
        if pending_drops:  # cues own the drops: mute the heuristic detector
            analyzer.tn_drop_min = 99.0

        n_blocks = (len(mono) + block - 1) // block
        try:
            for i in range(n_blocks):
                vt = (i + 1) * block / sr
                while pending_drops and vt >= pending_drops[0]:
                    pending_drops.pop(0)
                    self.controls.drop_request += 1
                analyzer.process_block(mono[i * block:(i + 1) * block])

                if vt >= next_diff:
                    next_diff += diff_period
                    self.engine.step(eng_consumer.read(), vt)
                    last_diff_vt = vt

                while vt >= next_frame and frames_done < n_video:
                    dt = frame_period
                    t = next_frame
                    next_frame += frame_period
                    s = fx_consumer.read()

                    frame, counter, _ = self.slot.get()
                    if frame is not None and counter != frame_counter:
                        frame_counter = counter
                        self.tex_prev, self.tex_cur = self.tex_cur, self.tex_prev
                        self.tex_cur.write(frame[::-1].tobytes())
                    blend = min(1.0, max(0.0, (t - last_diff_vt) / diff_period + 1e-6))

                    if s.big_onset:
                        big_env = 1.0
                    else:
                        big_env *= math.exp(-dt / 0.15)
                    if s.drop:
                        drop_env = 1.0
                        drop_tau = 0.25 + 0.5 * s.drop_power
                        if rng.random() < self.disp.get("drop_strobe_chance", 0.5):
                            strobe_until = t + (self.disp.get("drop_strobe_seconds", 2.0)
                                                * (0.5 + s.drop_power))
                    else:
                        drop_env *= math.exp(-dt / drop_tau)
                    p = mappings.shader_params(s, self.disp, big_env)
                    hue = (hue + p["hue_rate"] * dt) % (2 * math.pi)
                    strobe = 0.0
                    if self.disp["enable_strobe"]:
                        if s.big_onset:
                            strobe = self.disp["strobe_intensity"]
                        burst = drop_env if drop_env > 0.05 else 0.0
                        if t < strobe_until:
                            burst = max(burst, 0.8)
                        if burst > 0.0 and int(t * self.disp.get("drop_strobe_hz", 9)) % 2 == 0:
                            strobe = max(strobe, self.disp.get("drop_strobe", 0.45) * burst)

                    for k, v in {
                        "u_resolution": (float(self.size), float(self.size)),
                        "u_time": t,
                        "u_blend": blend,
                        "u_pulse": s.kick,
                        "u_pulse_amount": self.disp["pulse_amount"],
                        "u_chroma_px": p["chroma"],
                        "u_trail_amount": p["trail_amount"],
                        "u_trail_decay": self.disp["trail_decay"],
                        "u_trail_zoom": self.disp["trail_zoom"],
                        "u_strobe": strobe,
                        "u_hue": hue,
                        "u_grain": p["grain"],
                        "u_vignette": self.disp["vignette"],
                        "u_beat_phase": s.beat_phase,
                        "u_beat_breathe": self.disp["beat_breathe"],
                    }.items():
                        self._set_uniform(k, v)

                    self.fbo_dst.use()
                    self.ctx.viewport = (0, 0, self.size, self.size)
                    self.tex_prev.use(0)
                    self.tex_cur.use(1)
                    self.tex_src.use(2)
                    self.vao.render(moderngl.TRIANGLES)

                    raw = self.fbo_dst.read(components=3)
                    img = np.frombuffer(raw, np.uint8).reshape(self.size, self.size, 3)
                    img = img[::-1][self.crop_y:self.crop_y + self.out_h,
                                    self.crop_x:self.crop_x + self.out_w]
                    enc.stdin.write(img.tobytes())
                    frames_done += 1

                    self.fbo_src, self.fbo_dst = self.fbo_dst, self.fbo_src
                    self.tex_src, self.tex_dst = self.tex_dst, self.tex_src

                now = time.monotonic()
                if now - last_report >= 2.0:
                    last_report = now
                    speed = vt / max(now - wall0, 1e-6)
                    eta = (dur - vt) / max(speed, 1e-6)
                    print(f"[render] {100.0 * vt / dur:.1f}% t={vt:.0f}s/{dur:.0f}s "
                          f"speed={speed:.2f}x eta={eta:.0f}s", flush=True)
        finally:
            enc.stdin.close()
            code = enc.wait()
            glfw.terminate()
        if code != 0:
            raise SystemExit(f"[render] ffmpeg failed with code {code}")
        wall = time.monotonic() - wall0
        print(f"[render] 100.0% t={dur:.0f}s/{dur:.0f}s speed={dur / wall:.2f}x eta=0s",
              flush=True)
        print(f"[render] done {self.out_path} ({frames_done} frames, "
              f"{wall / 60.0:.1f} min, {dur / wall:.2f}x realtime)", flush=True)
