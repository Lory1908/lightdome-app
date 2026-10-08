"""Offline-only LightDome recipe validator and LDY1 compiler (stdlib)."""

import argparse
import json
import math
import struct
from pathlib import Path

FIELDS = {"preset", "duration", "minimum", "maximum", "duty", "easing",
          "randomness", "loop", "autorun"}
PRESETS = {"breath", "pulse", "sunrise", "random"}
EASINGS = {"smooth", "sine", "linear", "sharp"}
SAMPLE_RATE = 250
MAX_SOURCE_BYTES = 8192
MAX_METADATA_BYTES = 2048


def validate(obj):
    if not isinstance(obj, dict):
        raise ValueError("La ricetta deve essere un oggetto JSON")
    if set(obj) != FIELDS:
        raise ValueError(f"Campi mancanti o aggiuntivi: {sorted(set(obj) ^ FIELDS)}")
    if type(obj["preset"]) is not str or obj["preset"] not in PRESETS:
        raise ValueError("preset non valido")
    if type(obj["easing"]) is not str or obj["easing"] not in EASINGS:
        raise ValueError("easing non valido")
    for field in ("loop", "autorun"):
        if type(obj[field]) is not bool:
            raise ValueError(f"{field} deve essere booleano")
    limits = {"duration": (1, 20), "minimum": (0, 90), "maximum": (10, 100),
              "duty": (5, 95), "randomness": (0, 100)}
    for field, (lo, hi) in limits.items():
        number = obj[field]
        if type(number) not in (int, float) or not math.isfinite(number) or not lo <= number <= hi:
            raise ValueError(f"{field} fuori intervallo {lo}..{hi}")
    if obj["minimum"] > obj["maximum"]:
        raise ValueError("minimum deve essere minore o uguale a maximum")
    metadata = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(metadata) > MAX_METADATA_BYTES:
        raise ValueError("Metadati troppo grandi")
    return obj


def load_recipe(path):
    raw = Path(path).read_bytes()
    if len(raw) > MAX_SOURCE_BYTES:
        raise ValueError("File JSON troppo grande")
    return validate(json.loads(raw.decode("utf-8")))


def ease(t, shape):
    if shape == "linear":
        return t
    if shape == "sharp":
        return 2*t*t if t < .5 else 1 - (-2*t+2)**2/2
    if shape == "sine":
        return (1 - math.cos(math.pi*t)) / 2
    return t*t*(3-2*t)


def value_at(recipe, t):
    lower, upper = recipe["minimum"]/100, recipe["maximum"]/100
    shape, kind = recipe["easing"], recipe["preset"]
    if kind == "sunrise":
        level = ease(t, shape)
    elif kind == "pulse":
        duty = recipe["duty"]/100
        edge = .12
        if t >= duty:
            level = 0
        else:
            q = t/duty
            level = ease(q/edge, shape) if q < edge else (
                1-ease((q-1+edge)/edge, shape) if q > 1-edge else 1)
    elif kind == "random":
        wobble = (math.sin(t*19.7) + .45*math.sin(t*43.1) +
                  .7*math.sin(t*7.3))/2.15*.5+.5
        base = (1-math.cos(2*math.pi*t))/2
        mix = recipe["randomness"]/100
        level = base*(1-mix)+wobble*mix
    else:
        level = ease((1-math.cos(2*math.pi*t))/2, shape)
    return min(1, max(0, lower + (upper-lower)*level))


def render(recipe):
    validate(recipe)
    count = max(2, int(math.floor(SAMPLE_RATE * recipe["duration"] + .5)))
    return [min(1023, max(0, int(math.floor(value_at(recipe, i/(count-1))*1023 + .5))))
            for i in range(count)]


def compile_ldy(recipe):
    samples = render(recipe)
    metadata = json.dumps(recipe, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return (struct.pack("<4sHIH", b"LDY1", SAMPLE_RATE, len(samples), len(metadata)) +
            struct.pack("<" + "H"*len(samples), *samples) + metadata)


def preview(samples):
    heights = " .:-=+*#%@"
    points = [samples[min(len(samples)-1, i*(len(samples)-1)//49)] for i in range(50)]
    return "".join(heights[min(8, value*8//1023)] for value in points)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Valida ricette JSON e compila LDY1 senza upload")
    parser.add_argument("action", choices=["validate", "convert"])
    parser.add_argument("input", type=Path)
    parser.add_argument("output", nargs="?", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == "convert" and args.output is None:
            parser.error("convert richiede un file di output")
        if args.action == "validate" and args.output is not None:
            parser.error("validate non accetta output")
        recipe = load_recipe(args.input)
        samples = render(recipe)
        print(f"VALIDO: {recipe['preset']} - {len(samples)} campioni a {SAMPLE_RATE} Hz")
        print("Anteprima approssimativa (non fisica):")
        print(preview(samples))
        if args.action == "convert":
            if args.output.suffix.lower() != ".ldy":
                raise ValueError("L'output deve avere estensione .ldy")
            if args.output.exists():
                raise ValueError("Output già presente: non viene sovrascritto")
            args.output.write_bytes(compile_ldy(recipe))
            print(f"Creato: {args.output}. Verificare prima di qualsiasi upload.")
        return 0
    except (ValueError, OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERRORE: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
