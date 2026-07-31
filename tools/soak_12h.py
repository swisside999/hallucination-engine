"""12-hour soak harness: finds the leak before the club does.

Launches the engine in file mode and samples the stats stream once a minute
into a CSV, plus macOS thermal throttle state. At the end (or on Ctrl-C)
prints a verdict: RSS growth per hour, fps floor, lock health, throttling.

    python tools/soak_12h.py "mix.mp3" --hours 12 --out soak.csv

Run on wall power. For a silent soak, set the Mac output device to
BlackHole 2ch (or volume to zero) - file mode plays the mix out loud.
Do not use the machine for GPU work while it runs.
"""

import argparse
import csv
import json
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

PORT = 7791  # not 7788: never collide with a cockpit-launched engine


def thermal_limit():
    """CPU speed limit percent from pmset (100 = no throttle)."""
    try:
        out = subprocess.run(["pmset", "-g", "therm"], capture_output=True,
                             text=True, timeout=10).stdout
        m = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", out)
        return int(m.group(1)) if m else 100
    except Exception:
        return -1


def read_stats(sock, buf):
    """Drain the socket, return (latest stats frame, remaining buffer)."""
    latest = None
    try:
        while True:
            sock.settimeout(0.5)
            data = sock.recv(65536)
            if not data:
                return latest, buf
            buf += data
            if len(buf) > 1 << 20:
                buf = buf[-65536:]
    except socket.timeout:
        pass
    for line in buf.split(b"\n"):
        try:
            f = json.loads(line)
            if f.get("type") == "stats":
                latest = f
        except Exception:
            continue
    return latest, b""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mix")
    ap.add_argument("--hours", type=float, default=12.0)
    ap.add_argument("--out", default="soak.csv")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    proc = subprocess.Popen(
        [sys.executable, "main.py", "--file", args.mix,
         "--control-port", str(PORT)],
        cwd=repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"engine pid {proc.pid}, warming up ...")

    sock = None
    deadline = time.time() + 300
    while sock is None and time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", PORT), timeout=2)
        except OSError:
            if proc.poll() is not None:
                sys.exit(f"engine died during warmup (exit {proc.returncode})")
            time.sleep(5)
    if sock is None:
        proc.terminate()
        sys.exit("engine never opened the control port")

    fields = ["minute", "rss_mb", "cpu_pct", "fps_diff", "fps_disp",
              "locked_pct", "resets", "frames", "thermal_limit"]
    rows = []
    buf = b""
    t0 = time.time()
    print(f"soaking {args.hours:g}h -> {args.out}")
    try:
        with open(args.out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(fields)
            while time.time() - t0 < args.hours * 3600:
                time.sleep(60)
                if proc.poll() is not None:
                    print(f"ENGINE DIED at minute {(time.time()-t0)/60:.0f} "
                          f"(exit {proc.returncode})")
                    break
                s, buf = read_stats(sock, buf)
                if s is None:
                    print(f"minute {(time.time()-t0)/60:.0f}: NO STATS (hang?)")
                    continue
                row = [round((time.time() - t0) / 60),
                       round(s.get("rss_mb", 0), 1), round(s.get("cpu_pct", 0), 1),
                       round(s.get("fps_diff", 0), 2), round(s.get("fps_disp", 0), 1),
                       round(s.get("locked_pct", 0), 3), s.get("resets", 0),
                       s.get("frames", 0), thermal_limit()]
                rows.append(row)
                w.writerow(row)
                fh.flush()
    except KeyboardInterrupt:
        print("\nstopped early")
    finally:
        proc.terminate()

    if len(rows) < 5:
        sys.exit("not enough samples for a verdict")
    mins = [r[0] for r in rows]
    rss = [r[1] for r in rows]
    n = len(rows)
    # least-squares slope, MB/hour
    mx, my = sum(mins) / n, sum(rss) / n
    slope = (sum((x - mx) * (y - my) for x, y in zip(mins, rss))
             / max(sum((x - mx) ** 2 for x in mins), 1e-9)) * 60
    fps = [r[3] for r in rows if r[3] > 0]
    therm = [r[8] for r in rows if r[8] >= 0]
    print(f"\n===== SOAK VERDICT ({rows[-1][0]} min) =====")
    print(f"RSS: {rss[0]:.0f} -> {rss[-1]:.0f} MB ({slope:+.1f} MB/h)"
          f"{'  LEAK?' if slope > 50 else '  ok'}")
    if fps:
        print(f"diffusion fps: min {min(fps):.2f} mean {sum(fps)/len(fps):.2f}"
              f"{'  DEGRADED' if min(fps) < 2.5 else '  ok'}")
    print(f"locked mean: {sum(r[5] for r in rows)/n:.1%}, resets {rows[-1][6]}")
    if therm:
        print(f"thermal speed limit: min {min(therm)}%"
              f"{'  THROTTLED' if min(therm) < 100 else '  ok'}")


if __name__ == "__main__":
    main()
