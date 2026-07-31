"""Layer C - moderngl/glfw compositor at 60 fps: crossfade, beat FX, HUD, keys."""

import math
import random
import time
from pathlib import Path

import glfw
import moderngl
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from . import mappings
from .state import Consumer
from .utils import clamp, fold_bpm

SHADER_DIR = Path(__file__).parent / "shaders"
HUD_W, HUD_H = 560, 236

COPY_FRAG = """#version 330 core
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 f_color;
void main() { f_color = vec4(texture(u_tex, v_uv).rgb, 1.0); }
"""

HUD_VERT = """#version 330 core
in vec2 in_pos;
uniform vec4 u_rect;
out vec2 v_uv;
void main() {
    v_uv = vec2(in_pos.x, 1.0 - in_pos.y);
    gl_Position = vec4(u_rect.xy + in_pos * u_rect.zw, 0.0, 1.0);
}
"""

HUD_FRAG = """#version 330 core
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 f_color;
void main() { f_color = texture(u_tex, v_uv); }
"""


class Compositor:
    def __init__(self, cfg, bus, controls, slot, engine, scenes, exit_after=None):
        self.cfg = cfg
        self.disp = cfg["display"]
        self.tempo_cfg = cfg["tempo"]
        self.bus = bus
        self.controls = controls
        self.slot = slot
        self.engine = engine
        self.scenes = scenes
        self.exit_after = exit_after
        self.consumer = Consumer(bus)
        self.hud_on = bool(self.disp.get("hud", True))
        self.fullscreen = False
        self.taps = []
        self.blend = 1.0
        self.frame_counter = -1
        self.big_env = 0.0
        self.drop_env = 0.0
        self.kick_pulse = mappings.KickPulse()
        self.synth_env = 0.0
        self.synth_fx = 0   # effect drawn per synth entrance: hue jolt/chroma/trail flush
        self.hue = 0.0
        self.disp_fps = 60.0
        self._want_save = False
        self._hud_next = 0.0
        self._strobe_until = 0.0
        self._rng = random.Random()
        self.panel = None
        self._fs_seen = 0
        self._cap_seen = 0

    # ------------------------------------------------------------------ run

    def run(self):
        if not glfw.init():
            raise RuntimeError("glfw init failed")
        glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 3)
        glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 3)
        glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
        glfw.window_hint(glfw.OPENGL_FORWARD_COMPAT, True)
        w, h = int(self.disp["width"]), int(self.disp["height"])
        self.win = glfw.create_window(w, h, "HALLUCINATION ENGINE", None, None)
        if not self.win:
            glfw.terminate()
            raise RuntimeError("window creation failed")
        glfw.make_context_current(self.win)
        glfw.swap_interval(1)
        glfw.set_key_callback(self.win, self._on_key)
        self.ctx = moderngl.create_context()

        vert = (SHADER_DIR / "composite.vert").read_text()
        frag = (SHADER_DIR / "composite.frag").read_text()
        self.prog = self.ctx.program(vertex_shader=vert, fragment_shader=frag)
        self.copy_prog = self.ctx.program(vertex_shader=vert, fragment_shader=COPY_FRAG)
        self.hud_prog = self.ctx.program(vertex_shader=HUD_VERT, fragment_shader=HUD_FRAG)

        tri = np.array([-1, -1, 3, -1, -1, 3], dtype="f4")
        vbo = self.ctx.buffer(tri.tobytes())
        self.vao_main = self.ctx.vertex_array(self.prog, [(vbo, "2f", "in_pos")])
        self.vao_copy = self.ctx.vertex_array(self.copy_prog, [(vbo, "2f", "in_pos")])
        quad = np.array([0, 0, 1, 0, 0, 1, 1, 1], dtype="f4")
        qbo = self.ctx.buffer(quad.tobytes())
        self.vao_hud = self.ctx.vertex_array(self.hud_prog, [(qbo, "2f", "in_pos")])

        res = self.engine.res
        self.tex_prev = self._mk_tex((res, res), 3)
        self.tex_cur = self._mk_tex((res, res), 3)
        black = np.zeros((res, res, 3), np.uint8)
        self.tex_prev.write(black.tobytes())
        self.tex_cur.write(black.tobytes())
        self.hud_tex = self._mk_tex((HUD_W, HUD_H), 4)
        self.hud_tex.write(bytes(HUD_W * HUD_H * 4))

        self.fb_size = glfw.get_framebuffer_size(self.win)
        self.tex_src = self.tex_dst = self.fbo_src = self.fbo_dst = None
        self._make_feedback()

        self._set_uniform(self.prog, "u_prev_frame", 0)
        self._set_uniform(self.prog, "u_cur_frame", 1)
        self._set_uniform(self.prog, "u_feedback", 2)
        self._set_uniform(self.copy_prog, "u_tex", 0)
        self._set_uniform(self.hud_prog, "u_tex", 0)

        self._font = self._load_font()

        if self.disp.get("control_window", True):
            try:
                self.panel = ControlPanel(self)
            except Exception as e:
                print(f"[panel] control window disabled: {e}")
                self.panel = None
            glfw.make_context_current(self.win)

        t0 = time.monotonic()
        prev_t = t0
        try:
            while not glfw.window_should_close(self.win):
                now = time.monotonic()
                dt = max(now - prev_t, 1e-4)
                prev_t = now
                t = now - t0
                closing = self.exit_after is not None and t > self.exit_after
                if closing:
                    self._want_save = True
                self._frame(t, dt)
                if closing:
                    glfw.set_window_should_close(self.win, True)
        finally:
            glfw.terminate()

    # ---------------------------------------------------------------- frame

    def _frame(self, t, dt):
        fb = glfw.get_framebuffer_size(self.win)
        if fb != self.fb_size and fb[0] > 0 and fb[1] > 0:
            self.fb_size = fb
            self._make_feedback()

        s = self.consumer.read()

        # remote (control app) requests - same effects as the hotkeys
        c = self.controls
        if c.fullscreen_request != self._fs_seen:
            self._fs_seen = c.fullscreen_request
            self._toggle_fullscreen()
        if c.capture_request != self._cap_seen:
            self._cap_seen = c.capture_request
            self._want_save = True
        if c.quit_request:
            glfw.set_window_should_close(self.win, True)

        frame, counter, period = self.slot.get()
        if frame is not None and counter != self.frame_counter:
            self.frame_counter = counter
            self.tex_prev, self.tex_cur = self.tex_cur, self.tex_prev
            self.tex_cur.write(np.ascontiguousarray(frame[::-1]).tobytes())
            self.blend = 0.0
        self.blend = min(1.0, self.blend + dt / max(period, 1.0 / 30.0))

        if s.big_onset:
            self.big_env = 1.0
        else:
            self.big_env *= math.exp(-dt / 0.15)
        # synth entrance: draw a random effect so the reaction never repeats -
        # 0 = hue jolt (instant), 1 = chroma bloom, 2 = trail flush (crisp cut)
        if s.synth_onset:
            self.synth_env = 1.0
            self.synth_fx = self._rng.randrange(3)
            if self.synth_fx == 0:
                self.hue = (self.hue + self._rng.uniform(1.0, 2.6)) % (2 * math.pi)
        else:
            self.synth_env *= math.exp(-dt / 0.4)
        if s.drop:
            self.drop_env = 1.0
            self._drop_tau = 0.25 + 0.5 * s.drop_power  # bigger buildup, longer burst
            # sometimes the drop earns a full strobe volley, not just the burst
            if self._rng.random() < self.disp.get("drop_strobe_chance", 0.5):
                self._strobe_until = t + (self.disp.get("drop_strobe_seconds", 2.0)
                                          * (0.5 + s.drop_power))
        else:
            self.drop_env *= math.exp(-dt / getattr(self, "_drop_tau", 0.25))
        p = mappings.shader_params(s, self.disp, self.big_env)
        fx = self.disp.get("synth_fx", 1.0) * self.synth_env
        if fx > 0.01:
            if self.synth_fx == 1:
                p["chroma"] += 5.0 * fx          # chroma bloom on the entrance
            elif self.synth_fx == 2:
                p["trail_amount"] *= 1.0 - 0.8 * fx  # cut trails: sudden clarity
        self.hue = (self.hue + p["hue_rate"] * dt) % (2 * math.pi)
        strobe = 0.0
        if self.disp["enable_strobe"]:
            if s.big_onset:
                strobe = self.disp["strobe_intensity"]
            burst = self.drop_env if self.drop_env > 0.05 else 0.0
            if t < self._strobe_until:
                burst = max(burst, 0.8)
            if burst > 0.0:  # drop: pulsing strobe burst / extended volley
                hz = self.disp.get("drop_strobe_hz", 9)
                if int(t * hz) % 2 == 0:
                    strobe = max(strobe,
                                 self.disp.get("drop_strobe", 0.45) * burst)

        for k, v in {
            "u_resolution": (float(self.fb_size[0]), float(self.fb_size[1])),
            "u_time": t,
            "u_blend": self.blend,
            "u_pulse": self.kick_pulse.step(s, dt),
            "u_pulse_amount": self.disp["pulse_amount"],
            "u_chroma_px": p["chroma"],
            "u_trail_amount": p["trail_amount"],
            "u_trail_decay": self.disp["trail_decay"],
            "u_trail_zoom": self.disp["trail_zoom"],
            "u_strobe": strobe,
            "u_hue": self.hue,
            "u_grain": p["grain"],
            "u_vignette": self.disp["vignette"],
            "u_beat_phase": s.beat_phase,
            "u_beat_breathe": self.disp["beat_breathe"],
        }.items():
            self._set_uniform(self.prog, k, v)

        # main pass into feedback destination
        self.fbo_dst.use()
        self.ctx.viewport = (0, 0, *self.fb_size)
        self.tex_prev.use(0)
        self.tex_cur.use(1)
        self.tex_src.use(2)
        self.vao_main.render(moderngl.TRIANGLES)

        if self._want_save:
            self._want_save = False
            self._save_capture()

        # copy composite to screen
        self.ctx.screen.use()
        self.ctx.viewport = (0, 0, *self.fb_size)
        self.tex_dst.use(0)
        self.vao_copy.render(moderngl.TRIANGLES)

        self.disp_fps = 0.95 * self.disp_fps + 0.05 / dt
        if self.hud_on:
            if t >= self._hud_next:
                self._hud_next = t + 0.25
                self._update_hud(s, period)
            self._draw_hud()

        self.fbo_src, self.fbo_dst = self.fbo_dst, self.fbo_src
        self.tex_src, self.tex_dst = self.tex_dst, self.tex_src

        glfw.swap_buffers(self.win)
        if self.panel:
            if not self.panel.render(s, period, t):
                self.panel = None  # user closed the control window; visuals go on
            glfw.make_context_current(self.win)
        glfw.poll_events()

    # ------------------------------------------------------------------ HUD

    def _info_lines(self, s, period):
        diff_fps = 1.0 / period if period > 0 else 0.0
        bank = getattr(self.engine, "bank", None)
        if bank:
            scene_i = bank.scene_index(s.phrase_index)
            scene_name = bank.scene_label(s.phrase_index)
        else:
            scene_i = s.phrase_index % len(self.scenes)
            scene_name = self.scenes[scene_i]
        return [
            f"HALLUCINATION ENGINE   BPM {s.bpm:6.1f}   beat {s.beat_phase:4.2f}  bar {s.bar_phase:4.2f}",
            f"diffusion {diff_fps:4.1f} fps    display {self.disp_fps:5.1f} fps",
            f"scene {scene_i + 1}/{len(self.scenes)}: {scene_name[:50]}",
            f"strength {self.engine.current_strength:4.2f}  "
            f"(offset {self.controls.denoise_offset:+.2f})   phrase {s.phrase_phase:4.2f}",
        ]

    def _update_hud(self, s, period):
        img = Image.new("RGBA", (HUD_W, HUD_H), (0, 0, 0, 150))
        d = ImageDraw.Draw(img)
        f = self._font
        lines = self._info_lines(s, period)
        y = 8
        for ln in lines:
            d.text((12, y), ln, font=f, fill=(230, 230, 230, 255))
            y += 24
        for label, val in (("KICK", s.kick), ("PERC", s.perc),
                           ("SYNTH", s.synth), ("AIR", s.air),
                           ("TENSN", s.tension)):
            d.text((12, y), label, font=f, fill=(180, 180, 180, 255))
            d.rectangle([80, y + 4, 544, y + 15], outline=(90, 90, 90, 255))
            d.rectangle([80, y + 4, 80 + int(464 * clamp(val, 0.0, 1.0)), y + 15],
                        fill=(120, 255, 160, 220))
            y += 24
        self.hud_tex.write(img.tobytes())

    def _draw_hud(self):
        self.ctx.enable(moderngl.BLEND)
        self.ctx.blend_func = (moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA)
        win_w = max(glfw.get_window_size(self.win)[0], 1)
        scale = self.fb_size[0] / win_w
        m = 16 * scale
        w_ndc = 2.0 * HUD_W * scale / self.fb_size[0]
        h_ndc = 2.0 * HUD_H * scale / self.fb_size[1]
        x0 = -1.0 + 2.0 * m / self.fb_size[0]
        y0 = 1.0 - 2.0 * m / self.fb_size[1] - h_ndc
        self._set_uniform(self.hud_prog, "u_rect", (x0, y0, w_ndc, h_ndc))
        self.hud_tex.use(0)
        self.vao_hud.render(moderngl.TRIANGLE_STRIP)
        self.ctx.disable(moderngl.BLEND)

    def _load_font(self):
        for path in ("/System/Library/Fonts/Menlo.ttc",
                     "/System/Library/Fonts/Monaco.ttf"):
            try:
                return ImageFont.truetype(path, 15)
            except Exception:
                continue
        return ImageFont.load_default()

    # ------------------------------------------------------------------- GL

    def _mk_tex(self, size, comps):
        t = self.ctx.texture(size, comps)
        t.filter = (moderngl.LINEAR, moderngl.LINEAR)
        t.repeat_x = t.repeat_y = False
        return t

    def _make_feedback(self):
        for o in (self.fbo_src, self.fbo_dst, self.tex_src, self.tex_dst):
            if o is not None:
                o.release()
        self.tex_src = self._mk_tex(self.fb_size, 3)
        self.tex_dst = self._mk_tex(self.fb_size, 3)
        self.fbo_src = self.ctx.framebuffer([self.tex_src])
        self.fbo_dst = self.ctx.framebuffer([self.tex_dst])
        self.fbo_src.clear()
        self.fbo_dst.clear()

    @staticmethod
    def _set_uniform(prog, name, value):
        try:
            prog[name].value = value
        except KeyError:
            pass

    def _save_capture(self):
        data = self.fbo_dst.read(components=3)
        img = Image.frombytes("RGB", self.fb_size, data).transpose(Image.FLIP_TOP_BOTTOM)
        Path("captures").mkdir(exist_ok=True)
        p = f"captures/dream_{time.strftime('%Y%m%d_%H%M%S')}.png"
        img.save(p)
        print(f"[capture] saved {p}")

    # ------------------------------------------------------------- keyboard

    def _on_key(self, win, key, scancode, action, mods):
        if action != glfw.PRESS:
            return
        c = self.controls
        if key == glfw.KEY_ESCAPE:
            glfw.set_window_should_close(self.win, True)  # ESC quits from either window
        elif key == glfw.KEY_SPACE:
            c.scene_skip += 1
            print("[keys] next scene")
        elif key == glfw.KEY_T:
            self._tap()
        elif key == glfw.KEY_LEFT:
            c.denoise_offset = clamp(c.denoise_offset - 0.05, -0.3, 0.3)
            print(f"[keys] denoise offset {c.denoise_offset:+.2f}")
        elif key == glfw.KEY_RIGHT:
            c.denoise_offset = clamp(c.denoise_offset + 0.05, -0.3, 0.3)
            print(f"[keys] denoise offset {c.denoise_offset:+.2f}")
        elif key == glfw.KEY_R:
            c.reset_counter += 1
        elif key == glfw.KEY_F:
            self._toggle_fullscreen()
        elif key == glfw.KEY_H:
            self.hud_on = not self.hud_on
        elif key == glfw.KEY_S:
            self._want_save = True

    def _tap(self):
        now = time.monotonic()
        if self.taps and now - self.taps[-1] > 2.5:
            self.taps = []
        self.taps.append(now)
        if len(self.taps) >= 2:
            d = np.diff(np.asarray(self.taps[-8:]))
            bpm = fold_bpm(60.0 / float(np.median(d)),
                           self.tempo_cfg["min_bpm"], self.tempo_cfg["max_bpm"])
            self.controls.bpm_override = bpm
            print(f"[tap] BPM {bpm:.1f}")

    def _toggle_fullscreen(self):
        if self.fullscreen:
            glfw.set_window_monitor(self.win, None, *self._win_pos, *self._win_size, 0)
        else:
            self._win_pos = glfw.get_window_pos(self.win)
            self._win_size = glfw.get_window_size(self.win)
            mon = glfw.get_primary_monitor()
            mode = glfw.get_video_mode(mon)
            glfw.set_window_monitor(self.win, mon, 0, 0,
                                    mode.size.width, mode.size.height, mode.refresh_rate)
        self.fullscreen = not self.fullscreen
        glfw.swap_interval(1)


# ------------------------------------------------------------- control panel

PANEL_W, PANEL_H = 560, 416
_TRACK_X0, _TRACK_X1 = 96, 460
_SLIDER_Y0, _SLIDER_DY = 244, 30


class ControlPanel:
    """Second window: live info readout + click-drag knobs.
    The visual window stays clean; closing this window keeps the show running."""

    def __init__(self, comp):
        self.comp = comp
        c, disp, dcfg = comp.controls, comp.disp, comp.cfg["diffusion"]
        self.sliders = [
            ("STRGTH", -0.30, 0.30, lambda: c.denoise_offset,
             lambda v: setattr(c, "denoise_offset", v)),
            ("TRAIL", 0.0, 0.60, lambda: disp["trail_base"],
             lambda v: disp.__setitem__("trail_base", v)),
            ("STROBE", 0.0, 0.80, lambda: disp["strobe_intensity"],
             lambda v: disp.__setitem__("strobe_intensity", v)),
            ("ZOOM", 0.0, 0.015, lambda: dcfg["zoom_base"],
             lambda v: dcfg.__setitem__("zoom_base", v)),
            ("NOISE", 0.0, 0.08, lambda: dcfg["noise_idle"],
             lambda v: dcfg.__setitem__("noise_idle", v)),
        ]
        glfw.window_hint(glfw.RESIZABLE, False)
        self.win = glfw.create_window(PANEL_W, PANEL_H, "HALLUCINATION ENGINE controls", None, None)
        glfw.window_hint(glfw.RESIZABLE, True)
        if not self.win:
            raise RuntimeError("window creation failed")
        mx, my = glfw.get_window_pos(comp.win)
        mw = glfw.get_window_size(comp.win)[0]
        glfw.set_window_pos(self.win, mx + mw + 16, my)
        glfw.make_context_current(self.win)
        glfw.swap_interval(0)  # main window paces the loop; no second vsync wait
        self.ctx = moderngl.create_context()
        self.prog = self.ctx.program(vertex_shader=HUD_VERT, fragment_shader=HUD_FRAG)
        quad = np.array([0, 0, 1, 0, 0, 1, 1, 1], dtype="f4")
        self.vao = self.ctx.vertex_array(
            self.prog, [(self.ctx.buffer(quad.tobytes()), "2f", "in_pos")])
        self.tex = self.ctx.texture((PANEL_W, PANEL_H), 4)
        self.tex.filter = (moderngl.LINEAR, moderngl.LINEAR)
        self.prog["u_tex"].value = 0
        self.prog["u_rect"].value = (-1.0, -1.0, 2.0, 2.0)
        self.active = None
        self.dirty = True
        self._next = 0.0
        glfw.set_key_callback(self.win, comp._on_key)  # hotkeys work in both windows
        glfw.set_mouse_button_callback(self.win, self._on_mouse)
        glfw.set_cursor_pos_callback(self.win, self._on_move)

    # --------------------------------------------------------------- mouse

    def _logical(self, x, y):
        ww, wh = glfw.get_window_size(self.win)
        return x * PANEL_W / max(ww, 1), y * PANEL_H / max(wh, 1)

    def _on_mouse(self, win, button, action, mods):
        if button != glfw.MOUSE_BUTTON_LEFT:
            return
        if action == glfw.RELEASE:
            self.active = None
            return
        x, y = self._logical(*glfw.get_cursor_pos(self.win))
        for i in range(len(self.sliders)):
            ry = _SLIDER_Y0 + _SLIDER_DY * i
            if ry - 4 <= y <= ry + 20:
                self.active = i
                self._drag(x)
                break

    def _on_move(self, win, x, y):
        if self.active is not None:
            self._drag(self._logical(x, y)[0])

    def _drag(self, x):
        _, lo, hi, _, set_ = self.sliders[self.active]
        f = clamp((x - _TRACK_X0) / (_TRACK_X1 - _TRACK_X0), 0.0, 1.0)
        set_(lo + f * (hi - lo))
        self.dirty = True

    # ---------------------------------------------------------------- draw

    def _redraw(self, s, period):
        img = Image.new("RGBA", (PANEL_W, PANEL_H), (14, 14, 18, 255))
        d = ImageDraw.Draw(img)
        f = self.comp._font
        y = 8
        for ln in self.comp._info_lines(s, period):
            d.text((12, y), ln, font=f, fill=(230, 230, 230, 255))
            y += 24
        for label, val in (("KICK", s.kick), ("PERC", s.perc), ("SYNTH", s.synth),
                           ("AIR", s.air), ("TENSN", s.tension)):
            d.text((12, y), label, font=f, fill=(180, 180, 180, 255))
            d.rectangle([_TRACK_X0, y + 4, _TRACK_X1, y + 15], outline=(90, 90, 90, 255))
            d.rectangle([_TRACK_X0, y + 4,
                         _TRACK_X0 + int((_TRACK_X1 - _TRACK_X0) * clamp(val, 0.0, 1.0)),
                         y + 15], fill=(120, 255, 160, 220))
            y += 24
        y = _SLIDER_Y0
        for label, lo, hi, get, _set in self.sliders:
            val = float(get())
            frac = clamp((val - lo) / (hi - lo), 0.0, 1.0)
            d.text((12, y), label, font=f, fill=(255, 220, 140, 255))
            d.rectangle([_TRACK_X0, y + 6, _TRACK_X1, y + 13], outline=(110, 110, 110, 255))
            hx = _TRACK_X0 + int((_TRACK_X1 - _TRACK_X0) * frac)
            d.rectangle([_TRACK_X0, y + 6, hx, y + 13], fill=(255, 190, 90, 200))
            d.rectangle([hx - 3, y + 1, hx + 3, y + 18], fill=(255, 235, 200, 255))
            d.text((_TRACK_X1 + 10, y), f"{val:.3f}", font=f, fill=(230, 230, 230, 255))
            y += _SLIDER_DY
        d.text((12, PANEL_H - 26),
               "SPACE scene  T tap  R reset  F fullscr  H hud  S save  ESC quit",
               font=f, fill=(140, 140, 150, 255))
        self.tex.write(img.tobytes())

    def render(self, s, period, t):
        if glfw.window_should_close(self.win):
            glfw.destroy_window(self.win)
            self.win = None
            return False
        glfw.make_context_current(self.win)
        if self.dirty or t >= self._next:
            self._next = t + 0.25
            self.dirty = False
            self._redraw(s, period)
        self.ctx.screen.use()
        self.ctx.viewport = (0, 0, *glfw.get_framebuffer_size(self.win))
        self.tex.use(0)
        self.vao.render(moderngl.TRIANGLE_STRIP)
        glfw.swap_buffers(self.win)
        return True
