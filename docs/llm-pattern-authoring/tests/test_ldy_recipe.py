import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ldy_recipe import compile_ldy, load_recipe, main, render, validate

BASE = Path(__file__).resolve().parents[1] / "examples"


class RecipeTests(unittest.TestCase):
    def test_all_four_examples_compile_as_ldy1_250hz(self):
        for kind in ("breath", "pulse", "sunrise", "organic"):
            with self.subTest(kind=kind):
                recipe = load_recipe(BASE / (kind + ".json"))
                blob = compile_ldy(recipe)
                magic, rate, count, meta_len = struct.unpack("<4sHIH", blob[:12])
                self.assertEqual(magic, b"LDY1")
                self.assertEqual(rate, 250)
                self.assertEqual(count, len(render(recipe)))
                self.assertEqual(len(blob), 12 + count*2 + meta_len)
                self.assertEqual(json.loads(blob[12 + count*2:]), recipe)
                samples = struct.unpack("<" + "H"*count, blob[12:12+count*2])
                self.assertTrue(all(0 <= sample <= 1023 for sample in samples))

    def test_bad_inputs_rejected(self):
        good = load_recipe(BASE / "breath.json")
        for bad in (
            {**good, "duration": 100},
            {**good, "minimum": 90, "maximum": 10},
            {**good, "loop": 1},
            {**good, "duration": float('nan')},
            {**good, "preset": "__import__('os')"},
            {**good, "unknown": "expression"},
            {"preset": "breath"},
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    validate(bad)

    def test_cli_does_not_overwrite_or_upload(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "test.ldy"
            self.assertEqual(main(["convert", str(BASE / "pulse.json"), str(target)]), 0)
            first = target.read_bytes()
            self.assertEqual(main(["convert", str(BASE / "pulse.json"), str(target)]), 1)
            self.assertEqual(target.read_bytes(), first)
            self.assertEqual(main(["validate", str(BASE / "pulse.json")]), 0)

    def test_rejects_invalid_json(self):
        with tempfile.TemporaryDirectory() as temp:
            bad = Path(temp) / "bad.json"
            bad.write_text('{"preset": "breath", "duration": NaN}', encoding="utf-8")
            self.assertEqual(main(["validate", str(bad)]), 1)


if __name__ == "__main__":
    unittest.main()
