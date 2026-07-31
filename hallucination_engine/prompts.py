"""Prompt bank + precomputed embedding interpolation + preset files."""

import json
from pathlib import Path

from .utils import slerp

SCENES = [
    "crowd of dancers dissolving into black smoke, strobe-lit warehouse, long exposure, bodies merging into fog, monochrome with deep green accents, grainy 35mm",
    "breathing concrete walls, brutalist cathedral interior, organic veins pulsing under wet stone surface, bioluminescent cracks, fog, cinematic",
    "liquid chrome humanoid figures morphing and splitting, industrial fog, caustic reflections, dark iridescent, macro detail",
    "endless fractal tunnel of bone and machinery, ribbed corridor, breathing walls, symmetrical, volumetric haze, dark sci-fi",
    "faces emerging from television static, half-formed, dissolving, analog glitch, double exposure, haunting, monochrome",
    "dark water surface with slow ripples, moonlight caustics, koi shadows moving beneath, oil slick iridescence, drifting petals, top-down, photographic",
    "thousands of moths orbiting a floodlight in an empty parking structure, motion blur, sodium vapor glow, swarming particles",
    "melting cathedral of speakers and subwoofers, cables like roots, dust in light beams, monolithic, dark ambient",
    "cavernous abandoned warehouse, green laser fans cutting through smoke, silhouetted crowd, monolithic concrete pillars, darkness",
    "sea of raised hands in strobing darkness, hypnotic crowd swaying in unison, sweat and haze, backlit silhouettes, grainy monochrome",
    "overgrown brutalist ruins, vines strangling concrete, black moss, decaying industrial architecture, fog through broken windows, moonlight",
    "rotting forest floor breathing, bioluminescent fungi pulsing, decaying leaves swirling into fractal patterns, dark organic matter, macro",
    "infinite dark stairwell spiraling downward, flickering sodium lights, wet concrete, brutalist geometry, oppressive, cinematic haze",
    "skeletal cathedral of rusted rebar and hanging chains swinging slowly, dust motes in a void, industrial decay, chiaroscuro",
    "surrealist oil painting in the style of salvador dali, melting clocks dripping over a dark dancefloor, elongated shadows, dreamlike desert of speakers, impossible architecture",
    "surrealist oil painting, distorted faces stretching out of black liquid, floating eyes, burning giraffe silhouettes, dali dreamscape, rich oil texture",
    "dark renaissance oil painting, chiaroscuro crowd of figures reaching upward in candlelight, caravaggio lighting, swirling drapery, cracked varnish texture",
    "baroque renaissance ceiling fresco of a storm of bodies spiraling into darkness, dramatic candlelit chiaroscuro, gold leaf glints, aged canvas craquelure",
    "vintage 1930s rubber hose animation, max fleischer style, grinning cartoon characters with hollow pie-cut eyes dancing in unison, wobbling boneless limbs, heavy film scratches and dust, flickering projector light, unsettling frozen smiles, stark black and white ink",
    "old silent-era cartoon haunted forest, twisted trees with faces, bouncing skeletons with unsettling smiles, heavy film grain, sepia, dark vignette",
    "ancient egyptian tomb wall art, procession of gods with animal heads, hieroglyphs glowing faintly gold, torchlit ochre and lapis pigment, cracked plaster, flat profile figures",
    "colossal egyptian pyramids and temple ruins at night, torch-lit obelisks, avenue of sphinxes vanishing into sandstorm haze, monumental scale, moonlit, ominous",
    "writhing mass of snakes coiling in darkness, iridescent scales catching light, cobra hoods flaring, hypnotic serpent eyes, macro detail, black background",
    "giant serpent wrapped around a ruined temple column, egyptian relief carvings, candle smoke, gold and obsidian, slow menace, chiaroscuro",
    "ancient alien beings with elongated skulls descending in a beam of light over a stone temple, hieroglyph carvings of spacecraft, volumetric god rays, dark sci-fi, cinematic",
    "occult illuminati ritual, hooded figures circling a glowing all-seeing eye atop a pyramid, candlelit lodge, masonic symbols in smoke, chiaroscuro, ominous",
    "beautiful goth women dancing at an underground rave, black leather and velvet, dark eyeliner, ecstatic expressions, strobing shadows, cinematic low light, film grain",
    "field of dark hypnotic eyes floating in blackness, dilated pupils, irises like spiral galaxies, eyes slowly opening and dissolving into smoke, wet glossy reflections, macro detail, chiaroscuro",
    "surrealist oil painting of hundreds of mismatched eyes melting in and out of a dark wall, weeping black mascara, gothic ink wash, gold leaf glints, ominous, rich impasto texture",
    "packed underground club at peak time, blinding strobe light freezing dancers mid-motion, silhouettes with raised arms, thick smoke machine haze, sweat glistening, harsh white flashes against darkness, photographic motion blur",
    "surrealist oil painting in the style of salvador dali, elephants on impossibly long spindly legs marching across a burning horizon, melting mirrors, floating drawers spilling smoke, rich oil texture, dreamlike",
    "abstract surrealist dreamscape, salvador dali style, biomorphic shapes dissolving into a dark desert sky, soft melting watches draped over dead branches, swarming ants, hyperreal oil painting",
    "fleet of glowing ufo saucers hovering over a night rave in the desert, abduction beams of white light, silhouetted crowd reaching upward, swirling storm clouds and stars, cinematic, ominous",
    "cathedral built of human skulls, candlelit ossuary walls, hollow eye sockets flickering with inner fire, baroque bone architecture, dust and smoke, chiaroscuro, macabre",
    "sensual female lips parting slowly, glossy dark red lipstick, smoke curling from the mouth, teeth glinting, macro photography, dramatic low-key lighting, film grain",
    "brutalist apartment tower at night, hundreds of glowing windows each framing a silhouetted figure, voyeuristic grid of lit rooms, flickering televisions, rain streaks on concrete, cinematic",
    "macro still life of white powder lines and scattered pills on black glass, pastel capsules glowing under ultraviolet light, crystalline dust drifting, mirror reflections, dark hedonistic, shallow depth of field",
    "endless corridor of mismatched doors and doorways opening into further doorways, impossible escher architecture, light spilling through cracks, some doors ajar into darkness, surreal, cinematic haze",
    "hi-tech industrial machine hall, robotic arms and pistons moving in rhythm, glowing cables and server racks, steam vents, sodium and cyan lighting, dark sci-fi, cinematic",
    "aerial night view of a sprawling city, glowing towers and rivers of street light stretching to the horizon, fog drifting between skyscrapers, high altitude, dark cinematic",
    "night highway interchange seen from above, streams of cars and trucks leaving red and white light trails, long exposure, wet asphalt reflections, weaving overpasses, cinematic",
    "extreme macro of a dark motherboard, towering capacitors and heatsinks like a night city, pulsing traces of glowing copper circuitry, solder joints glinting, shallow depth of field, cyberpunk",
]
# NOTE: never put "cartoon"/"flat colors" here - the single global negative is
# applied on every CFG frame (drops, resets) and kills the cartoon scenes
NEGATIVE = "text, watermark, logo, frame, border, jpeg artifacts, bright daylight"

# relative pick-probability per scene, same order as SCENES (1.0 = baseline);
# bias toward figurative content - the feedback loop already over-produces
# abstract line/flow imagery on its own
SCENE_WEIGHTS = [
    1.0,  # crowd of dancers dissolving into smoke
    1.0,  # breathing concrete walls
    1.0,  # liquid chrome humanoids
    1.0,  # fractal tunnel of bone and machinery
    1.0,  # faces in television static
    1.0,  # black water mandala (line-prone)
    1.0,  # moths orbiting floodlight
    1.0,  # melting cathedral of speakers
    1.0,  # warehouse, lasers, crowd
    1.0,  # sea of raised hands
    1.0,  # overgrown brutalist ruins
    1.0,  # rotting forest floor
    1.0,  # dark stairwell (line-prone)
    1.0,  # rebar cathedral
    2.0,  # dali melting clocks dancefloor
    2.0,  # dali faces from black liquid
    1.0,  # renaissance crowd in candlelight
    1.0,  # baroque fresco storm of bodies
    1.0,  # rubber hose cartoon
    1.0,  # cartoon haunted forest
    1.0,  # egyptian tomb wall art
    1.0,  # pyramids at night
    1.0,  # writhing snakes
    1.0,  # serpent around column
    1.0,  # ancient aliens
    1.0,  # illuminati ritual
    1.0,  # goth rave women
    1.0,  # hypnotic eyes, photoreal macro
    1.0,  # hypnotic eyes, surrealist painting
    1.0,  # strobe club, dancers frozen
    2.0,  # dali elephants on spider legs
    2.0,  # dali abstract dreamscape
    1.0,  # ufos over desert rave
    1.0,  # skull cathedral ossuary
    1.0,  # sensual lips macro
    1.0,  # apartment tower windows
    1.0,  # powder and pills uv still life
    1.0,  # escher corridor of doors
    1.0,  # hi-tech machine hall
    1.0,  # aerial city at night
    1.0,  # highway light trails from above
    1.0,  # motherboard macro circuitry
]


# ------------------------------------------------------------------ presets
# A preset is one JSON file in ./presets: {"name", "negative",
# "scenes": [{"prompt", "weight"}]} - editable by hand or in the mac app's
# Prompts tab, selected per launch (--preset / scenes.preset); embeddings are
# encoded once at startup, so presets don't switch mid-set.

PRESET_DIR = Path(__file__).resolve().parent.parent / "presets"
CURRENT_PRESET = "General Rave (built-in)"


def export_default_preset():
    """One-time: write the built-in bank as presets/general_rave.json."""
    p = PRESET_DIR / "general_rave.json"
    if p.exists():
        return
    PRESET_DIR.mkdir(exist_ok=True)
    data = {"name": "General Rave", "negative": NEGATIVE,
            "scenes": [{"prompt": s, "weight": w}
                       for s, w in zip(SCENES, SCENE_WEIGHTS)]}
    p.write_text(json.dumps(data, indent=2))
    print(f"[prompts] exported built-in bank -> {p}")


def load_preset(name_or_path):
    """Load a preset by file path or by name (case-insensitive, also matches
    the file stem). Mutates the bank IN PLACE so every module-level reference
    stays valid. Returns the preset's optional "config" dict ({} if none) on
    success, None on any problem - in which case the current bank is kept;
    a broken file must never kill a set."""
    global NEGATIVE, CURRENT_PRESET
    want = str(name_or_path)
    p = Path(want)
    if not (p.suffix == ".json" and p.exists()):
        p = None
        for cand in sorted(PRESET_DIR.glob("*.json")):
            try:
                nm = json.loads(cand.read_text()).get("name", "")
            except Exception:
                continue
            if want.lower() in (str(nm).lower(), cand.stem.lower()):
                p = cand
                break
        if p is None:
            print(f"[prompts] preset {want!r} not found - keeping current bank")
            return None
    try:
        data = json.loads(p.read_text())
        scenes = [s for s in data.get("scenes", [])
                  if str(s.get("prompt", "")).strip()]
        if not scenes:
            raise ValueError("no scenes")
        SCENES[:] = [str(s["prompt"]).strip() for s in scenes]
        SCENE_WEIGHTS[:] = [max(0.0, float(s.get("weight", 1.0))) for s in scenes]
        NEGATIVE = str(data.get("negative", NEGATIVE))
        CURRENT_PRESET = str(data.get("name") or p.stem)
    except Exception as e:
        print(f"[prompts] bad preset {p}: {e} - keeping current bank")
        return None
    pc = data.get("config") or {}
    print(f"[prompts] preset '{CURRENT_PRESET}': {len(SCENES)} scenes"
          + (" + config overrides" if pc else ""))
    return pc if isinstance(pc, dict) else {}


class PromptBank:
    """Encodes all scenes once at startup; per-frame conditioning is pure tensor math."""

    def __init__(self, pipe, scenes, negative, device, shuffle=True,
                 hybrid_chance=0.0, flavor=0.15):
        import random
        import threading
        import torch

        self.scenes = scenes
        self.shuffle = shuffle
        self.hybrid_chance = hybrid_chance
        self.flavor = flavor        # max dose of a random second scene per phrase
        self._order = [0]           # walk entries: scene id, or (i, j, t) blend
        self._rng = random.Random()
        self._lock = threading.Lock()
        with torch.inference_mode():
            self.embeds = [self._encode(pipe, s, device) for s in scenes]
            self.negative = self._encode(pipe, negative, device)

    @staticmethod
    def _encode(pipe, text, device):
        emb, _ = pipe.encode_prompt(text, device, 1, False)
        return emb.float()

    def _entry(self, phrase_index: int):
        """phrase counter -> walk entry: scene id, or an (i, j, t) blend. Weighted-
        random but deterministic within a run, so the diffusion thread and the HUD
        agree. Hybrids fuse two scenes near the middle; every other phrase gets a
        small random "flavor" dose of a second scene, so the same base scene never
        renders with identical conditioning twice."""
        if not self.shuffle:
            return phrase_index % len(self.scenes)
        n = len(self.scenes)
        weights = (SCENE_WEIGHTS + [1.0] * n)[:n]  # tolerate user-edited banks
        with self._lock:
            while len(self._order) <= phrase_index + 1:
                prev = self._order[-1]
                prev_ids = (set(prev[:2]) if isinstance(prev, tuple) else {prev})
                w = [0.0 if k in prev_ids else weights[k] for k in range(n)]
                i = self._rng.choices(range(n), weights=w)[0]
                w[i] = 0.0
                if n > 1 and self._rng.random() < self.hybrid_chance:
                    j = self._rng.choices(range(n), weights=w)[0]
                    t = self._rng.uniform(0.35, 0.65)   # hybrid: two scenes fused
                    self._order.append((i, j, t))
                elif n > 1 and self.flavor > 0.0:
                    j = self._rng.choices(range(n), weights=w)[0]
                    t = self._rng.uniform(0.25, 1.0) * self.flavor  # subtle tint
                    self._order.append((i, j, t))
                else:
                    self._order.append(i)
            return self._order[phrase_index]

    def pin(self, phrase_index: int, scene_id: int):
        """Force a specific phrase to a specific scene (timeline renders).
        Unlike pin_next this does not truncate the walk, so repeated re-pins
        while the timeline holds one scene are cheap and stable."""
        self._entry(phrase_index)  # materialize the walk up to here
        with self._lock:
            self._order[phrase_index] = int(scene_id) % len(self.scenes)

    def pin_next(self, phrase_index: int, scene_id: int):
        """Make the NEXT phrase (phrase_index + 1) a specific scene - the control
        app pins it then bumps scene_skip so it becomes current immediately."""
        with self._lock:
            del self._order[phrase_index + 1:]
            self._order.append(int(scene_id) % len(self.scenes))

    def _embed_of(self, entry):
        if isinstance(entry, tuple):
            i, j, t = entry
            return slerp(self.embeds[i], self.embeds[j], t)
        return self.embeds[entry]

    def scene_index(self, phrase_index: int) -> int:
        e = self._entry(phrase_index)
        return e[0] if isinstance(e, tuple) else e

    def scene_label(self, phrase_index: int) -> str:
        e = self._entry(phrase_index)
        if isinstance(e, tuple) and e[2] >= 0.3:  # true hybrid; flavor stays quiet
            return f"{self.scenes[e[0]][:24]} x {self.scenes[e[1]][:24]}"
        if isinstance(e, tuple):
            e = e[0]
        return self.scenes[e]

    def get(self, phrase_index: int, phrase_phase: float, synth: float,
            blend_start: float = 0.75, shimmer: float = 0.15):
        import torch

        a = self._embed_of(self._entry(phrase_index))
        b = self._embed_of(self._entry(phrase_index + 1))
        if phrase_phase < blend_start:
            t = 0.0
        else:
            t = (phrase_phase - blend_start) / max(1.0 - blend_start, 1e-6)
        cond = slerp(a, b, float(min(t, 1.0)))
        sh = min(max(shimmer * synth, 0.0), 0.5)
        if sh > 0.0:
            cond = torch.lerp(cond, b, sh)
        return cond
