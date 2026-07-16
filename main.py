#!/usr/bin/env python3
"""Hallucination Engine - realtime audio-reactive AI VJ. Entry point + orchestration."""

import argparse
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent


def export_local_models(cfg):
    """One-time: copy the pipeline out of the HF cache into ./models so startup
    never touches the network again (Hub checks hang for minutes on flaky nets)."""
    dst = ROOT / "models" / "sd-turbo"
    if (dst / "model_index.json").exists():
        return
    import torch
    from diffusers import AutoencoderTiny, AutoPipelineForImage2Image

    print("[main] exporting models to ./models (one-time) ...")
    pipe = AutoPipelineForImage2Image.from_pretrained(
        cfg["diffusion"]["model"], torch_dtype=torch.float16, variant="fp16")
    pipe.save_pretrained(dst, variant="fp16")
    AutoencoderTiny.from_pretrained(
        "madebyollin/taesd", torch_dtype=torch.float16).save_pretrained(
        ROOT / "models" / "taesd")
    print("[main] export done")


def parse_args():
    ap = argparse.ArgumentParser(description="Hallucination Engine - audio-reactive AI VJ")
    ap.add_argument("--file", help="audio file to play + analyze (primary test path)")
    ap.add_argument("--seek", default="0",
                    help="start position in the file: seconds or MM:SS or HH:MM:SS")
    ap.add_argument("--device", type=int, help="live input device index")
    ap.add_argument("--list-devices", action="store_true", help="print audio devices and exit")
    ap.add_argument("--config", help="custom config yaml (merged over config.yaml)")
    ap.add_argument("--preset", help="prompt preset: name or path of a presets/*.json "
                                     "(default: scenes.preset from config)")
    ap.add_argument("--no-hud", action="store_true", help="start with HUD hidden")
    ap.add_argument("--no-panel", action="store_true",
                    help="skip the built-in control window (the mac app replaces it)")
    ap.add_argument("--control-port", type=int, default=7788,
                    help="localhost control server port for the mac app (0 = off)")
    ap.add_argument("--res", type=int, help="diffusion resolution override (512/448)")
    ap.add_argument("--exit-after", type=float,
                    help="auto-quit after N seconds, saving a capture (testing)")
    ap.add_argument("--render", metavar="OUT.mp4",
                    help="offline render mode: encode a video instead of a live window")
    ap.add_argument("--render-fps", type=int, default=30, help="video fps (render mode)")
    ap.add_argument("--render-size", type=int, default=1024,
                    help="video size in px, square (render mode)")
    ap.add_argument("--render-duration", default=None,
                    help="length to render, seconds or MM:SS (default: to end of file)")
    ap.add_argument("--render-diff-fps", type=float, default=6.0,
                    help="diffusion steps per VIRTUAL second (render quality knob)")
    ap.add_argument("--render-crop", metavar="WxH",
                    help="center-crop the square render to WxH, e.g. 1080x1920 "
                         "for a 9:16 reel from --render-size 1920")
    return ap.parse_args()


def parse_time(v):
    parts = [float(p) for p in str(v).split(":")]
    return sum(p * 60 ** i for i, p in enumerate(reversed(parts)))


def load_config(args, preset_cfg=None):
    """config.yaml < preset config < --config overlay < CLI flags."""
    from hallucination_engine.utils import deep_merge

    cfg = yaml.safe_load((ROOT / "config.yaml").read_text())
    if preset_cfg:
        cfg = deep_merge(cfg, preset_cfg)
    if args.config:
        cfg = deep_merge(cfg, yaml.safe_load(Path(args.config).read_text()))
    if args.res:
        cfg["diffusion"]["resolution"] = args.res
    if args.no_hud:
        cfg["display"]["hud"] = False
    if args.no_panel:
        cfg["display"]["control_window"] = False
    if args.device is not None:
        cfg["audio"]["device"] = args.device
    if args.render_crop:
        w, h = (int(v) for v in args.render_crop.lower().split("x"))
        cfg.setdefault("render", {})["out_size"] = [w, h]
    return cfg


def main():
    args = parse_args()
    if args.list_devices:
        from hallucination_engine.audio_engine import list_devices
        list_devices()
        return

    cfg = load_config(args)
    export_local_models(cfg)

    from hallucination_engine import prompts
    prompts.export_default_preset()
    preset = args.preset or cfg["scenes"].get("preset")
    if preset:
        pc = prompts.load_preset(preset)
        if pc:  # preset carries config overrides: rebuild cfg with them layered in
            cfg = load_config(args, preset_cfg=pc)

    from hallucination_engine.audio_engine import FileAudioEngine, LiveAudioEngine
    from hallucination_engine.compositor import Compositor
    from hallucination_engine.diffusion_engine import DiffusionEngine
    from hallucination_engine.prompts import SCENES
    from hallucination_engine.state import Controls, FrameSlot, StateBus

    bus = StateBus()
    controls = Controls()
    slot = FrameSlot()

    print("== HALLUCINATION ENGINE ==")
    engine = DiffusionEngine(cfg, bus, controls, slot, assets_dir=ROOT / "assets")
    engine.setup()  # model load + warmup BEFORE the window opens

    if args.render:
        if not args.file:
            sys.exit("--render needs --file")
        from hallucination_engine.renderer import OfflineRenderer
        dur = parse_time(args.render_duration) if args.render_duration else None
        OfflineRenderer(cfg, bus, controls, slot, engine, args.file, args.render,
                        seek=parse_time(args.seek), duration=dur,
                        fps=args.render_fps, size=args.render_size,
                        diff_fps=args.render_diff_fps).run()
        return

    if args.file:
        seek = parse_time(args.seek)
        audio = FileAudioEngine(cfg, bus, controls, args.file, seek=seek)
    else:
        audio = LiveAudioEngine(cfg, bus, controls, device=args.device)
    audio.start()
    engine.start()

    comp = Compositor(cfg, bus, controls, slot, engine, SCENES, exit_after=args.exit_after)
    if args.control_port:
        from hallucination_engine.control_server import ControlServer
        server = ControlServer(cfg, bus, controls, slot, engine, audio,
                               port=args.control_port)
        server.attach_compositor(comp)
        server.start()
    try:
        comp.run()
    except KeyboardInterrupt:
        pass
    finally:
        print("[main] shutting down ...")
        audio.stop()
        engine.stop()
        engine.join(timeout=10)
    print("[main] bye")


if __name__ == "__main__":
    sys.exit(main())
