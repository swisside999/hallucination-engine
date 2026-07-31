"""JSON-lines TCP control server on localhost - the wire the native macOS
control app talks over.

Server -> client:  {"type":"hello", scenes, weights, file, duration}
                   {"type":"stats", ...} at ~5 Hz
Client -> server:  one JSON object per line, {"cmd": ...} - see _handle.
"""

import json
import os
import resource
import socket
import threading
import time

from . import prompts

STATS_HZ = 5.0


class ControlServer(threading.Thread):
    def __init__(self, cfg, bus, controls, slot, engine, audio, port=7788):
        super().__init__(daemon=True, name="control")
        self.cfg = cfg
        self.bus = bus
        self.controls = controls
        self.slot = slot
        self.engine = engine
        self.audio = audio
        self.port = int(port)
        self.compositor = None  # attached late (created after this thread starts)
        self._clients = []
        self._clients_lock = threading.Lock()
        self._t0 = time.monotonic()
        self._cpu_prev = (time.monotonic(), sum(os.times()[:2]))
        self._cpu_pct = 0.0

    def attach_compositor(self, comp):
        self.compositor = comp

    # ------------------------------------------------------------------ run

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind(("127.0.0.1", self.port))
        except OSError as e:
            print(f"[control] port {self.port} unavailable ({e}); control app disabled")
            return
        srv.listen(4)
        print(f"[control] listening on 127.0.0.1:{self.port}")
        threading.Thread(target=self._stats_loop, daemon=True, name="control-stats").start()
        while True:
            sock, _ = srv.accept()
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self._send(sock, self._hello())
            with self._clients_lock:
                self._clients.append(sock)
            threading.Thread(target=self._reader, args=(sock,), daemon=True).start()

    def _hello(self):
        return {
            "type": "hello",
            "preset": prompts.CURRENT_PRESET,
            "scenes": list(prompts.SCENES),
            "weights": [float(w) for w in prompts.SCENE_WEIGHTS],
            "file": getattr(self.audio, "path", None),
            "duration": float(getattr(self.audio, "duration", 0.0)),
        }

    # ---------------------------------------------------------------- stats

    def _stats_loop(self):
        while True:
            time.sleep(1.0 / STATS_HZ)
            msg = self._stats()
            with self._clients_lock:
                clients = list(self._clients)
            for sock in clients:
                if not self._send(sock, msg):
                    with self._clients_lock:
                        if sock in self._clients:
                            self._clients.remove(sock)

    def _stats(self):
        s = self.bus.read()
        _, _, period = self.slot.get()
        eng = self.engine
        bank = getattr(eng, "bank", None)
        now = time.monotonic()

        # process CPU% (user+sys over wall clock) and RSS
        wall, cpu = now - self._cpu_prev[0], sum(os.times()[:2]) - self._cpu_prev[1]
        if wall >= 2.0:
            self._cpu_pct = 100.0 * cpu / wall
            self._cpu_prev = (now, sum(os.times()[:2]))
        rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6  # mac: bytes

        return {
            "type": "stats",
            "bpm": s.bpm,
            "beat_phase": s.beat_phase,
            "phrase_phase": s.phrase_phase,
            "phrase_index": s.phrase_index,
            "scene": bank.scene_label(s.phrase_index) if bank else "",
            "scene_id": bank.scene_index(s.phrase_index) if bank else 0,
            "scene_next": bank.scene_label(s.phrase_index + 1) if bank else "",
            "strength": float(eng.current_strength),
            "offset": float(self.controls.denoise_offset),
            "tension": s.tension,
            "kick": s.kick, "perc": s.perc, "synth": s.synth, "air": s.air,
            "rms": s.rms,
            "clip": s.clip,
            "fps_diff": float(getattr(eng, "diff_fps", 0.0) or (1.0 / period if period > 0 else 0.0)),
            "fps_disp": float(getattr(self.compositor, "disp_fps", 0.0)) if self.compositor else 0.0,
            "pos": float(getattr(self.audio, "position", 0.0)),
            "dur": float(getattr(self.audio, "duration", 0.0)),
            "stripe": float(eng.stripe),
            "grid": float(eng.grid),
            "locked_pct": float(eng.locked_pct),
            "drops": s.drop_id,
            "resets": int(eng.resets_total),
            "frames": int(eng.frames_total),
            "cpu_pct": self._cpu_pct,
            "rss_mb": rss_mb,
            "uptime": now - self._t0,
            "logo": float(getattr(eng, "logo_on", 0.0)),
            "logo_opacity": float(self.cfg.get("logo", {}).get("opacity", 0.8)),
            "trail": float(self.cfg["display"]["trail_base"]),
            "strobe": float(self.cfg["display"]["strobe_intensity"]),
            "zoom": float(self.cfg["diffusion"]["zoom_base"]),
            "noise": float(self.cfg["diffusion"]["noise_idle"]),
            "out_black": float(self.cfg["display"].get("out_black", 0.0)),
            "out_contrast": float(self.cfg["display"].get("out_contrast", 1.0)),
            "out_sat": float(self.cfg["display"].get("out_sat", 1.0)),
        }

    # ------------------------------------------------------------- commands

    def _reader(self, sock):
        buf = b""
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        try:
                            self._dispatch(json.loads(line))
                        except Exception as e:
                            print(f"[control] bad command: {e}")
        finally:
            with self._clients_lock:
                if sock in self._clients:
                    self._clients.remove(sock)
            sock.close()

    # NOTE: never name a method `_handle` on a threading.Thread subclass -
    # py3.13 Thread.__init__ sets a `_handle` instance attribute that shadows it
    def _dispatch(self, msg):
        cmd = msg.get("cmd")
        c = self.controls
        if cmd == "set":            # {"cmd":"set","path":"display.trail_base","value":0.3}
            node = self.cfg
            parts = str(msg["path"]).split(".")
            for p in parts[:-1]:
                node = node[p]
            old = node[parts[-1]]
            node[parts[-1]] = type(old)(msg["value"]) if old is not None else msg["value"]
        elif cmd == "offset":
            c.denoise_offset = max(-0.3, min(0.3, float(msg["value"])))
        elif cmd == "drop":
            c.drop_request += 1
        elif cmd == "skip":
            c.scene_skip += 1
        elif cmd == "reset":
            c.reset_counter += 1
        elif cmd == "capture":
            c.capture_request += 1
        elif cmd == "fullscreen":
            c.fullscreen_request += 1
        elif cmd == "quit":
            c.quit_request += 1
        elif cmd == "bpm":          # value: float or null to clear the override
            v = msg.get("value")
            c.bpm_override = float(v) if v else None
        elif cmd == "weights":      # full array, applied live
            vals = [max(0.0, float(x)) for x in msg["values"]]
            prompts.SCENE_WEIGHTS[:] = vals
        elif cmd == "logo_burst":   # one logo flash now
            c.logo_burst += 1
        elif cmd == "logo_hold":    # {"cmd":"logo_hold","value":true} - show while true
            c.logo_hold = bool(msg.get("value"))
        elif cmd == "preset":       # live prompt-preset switch, crossfaded
            name = str(msg.get("name") or "General Rave")

            def _switch():
                if self.engine.apply_preset(name):
                    # clients cache the scene bank from hello - resend it
                    hello = self._hello()
                    with self._clients_lock:
                        clients = list(self._clients)
                    for sock in clients:
                        self._send(sock, hello)

            # encode off this reader thread so a slow encode never blocks
            # the client's command stream
            threading.Thread(target=_switch, daemon=True,
                             name="preset-switch").start()
        elif cmd == "scene_select":  # pin scene i as next phrase and jump to it
            bank = getattr(self.engine, "bank", None)
            if bank:
                bank.pin_next(self.bus.read().phrase_index, int(msg["index"]))
                c.scene_skip += 1
        else:
            print(f"[control] unknown cmd {cmd!r}")

    @staticmethod
    def _send(sock, obj):
        try:
            sock.sendall(json.dumps(obj).encode() + b"\n")
            return True
        except OSError:
            return False
