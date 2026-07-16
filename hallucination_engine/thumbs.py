"""One-frame scene thumbnails for the preset editor: each prompt rendered
once by SD-Turbo txt2img (1 step, no CFG) and cached by prompt hash, so the
app can show what a scene roughly dreams like. GPU-shared with the engine -
callers must not run this during a live set or render."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def thumb_name(prompt: str) -> str:
    return hashlib.sha1(prompt.encode("utf-8")).hexdigest()[:16] + ".png"


def generate(preset_path: str, out_dir: str, size: int = 512, force: bool = False):
    data = json.loads(Path(preset_path).read_text())
    prompts = [s["prompt"] for s in data.get("scenes", []) if s.get("prompt")]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    todo = [(p, out / thumb_name(p)) for p in prompts]
    if not force:
        todo = [(p, f) for p, f in todo if not f.exists()]
    n = len(todo)
    print(f"[thumbs] {len(prompts)} scenes, {n} to render -> {out}", flush=True)
    if not n:
        print("[thumbs] done", flush=True)
        return

    import torch
    from diffusers import AutoPipelineForText2Image

    pipe = AutoPipelineForText2Image.from_pretrained(
        ROOT / "models" / "sd-turbo", torch_dtype=torch.float16, variant="fp16")
    pipe.to("mps")
    pipe.set_progress_bar_config(disable=True)

    negative = data.get("negative", "")
    for i, (prompt, path) in enumerate(todo, 1):
        img = pipe(prompt=prompt, negative_prompt=negative or None,
                   num_inference_steps=1, guidance_scale=0.0,
                   height=512, width=512).images[0]
        if size != 512:
            img = img.resize((size, size))
        img.save(path)
        print(f"[thumbs] {i}/{n} {path}", flush=True)
    print("[thumbs] done", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: python -m hallucination_engine.thumbs preset.json out_dir [--force]")
    generate(sys.argv[1], sys.argv[2], force="--force" in sys.argv)
