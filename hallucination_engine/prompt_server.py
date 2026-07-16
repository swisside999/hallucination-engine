"""Interactive prompt preview for the app's Prompt Preview window: JSON lines
on stdin ({"prompt": ..., "seed": N}) -> one SD-Turbo txt2img frame each,
saved to a rotating pair of temp files, path answered as a JSON line on
stdout. Loads the pipeline once and stays resident - GPU-shared with the
engine, so the app must stop this before starting a set or render."""

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    import torch
    from diffusers import AutoPipelineForText2Image

    pipe = AutoPipelineForText2Image.from_pretrained(
        ROOT / "models" / "sd-turbo", torch_dtype=torch.float16, variant="fp16")
    pipe.to("mps")
    pipe.set_progress_bar_config(disable=True)
    out_dir = Path(tempfile.mkdtemp(prefix="he_prompt_preview_"))
    print(json.dumps({"ready": True}), flush=True)

    n = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        prompt = str(req.get("prompt", "")).strip()
        if not prompt:
            continue
        gen = torch.Generator("cpu").manual_seed(int(req.get("seed", 0)))
        img = pipe(prompt=prompt, negative_prompt=str(req.get("negative", "")) or None,
                   num_inference_steps=1, guidance_scale=0.0,
                   height=512, width=512, generator=gen).images[0]
        n += 1
        path = out_dir / f"frame{n % 2}.png"  # rotate: the app never reads a half-write
        img.save(path)
        print(json.dumps({"file": str(path), "n": n}), flush=True)


if __name__ == "__main__":
    main()
