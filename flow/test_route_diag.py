#!/usr/bin/env python3
"""Unit tests for flow/route_diag.py (issue #176). stdlib only; uses the committed
snapshot sim/bitstream/fabric_spec.json, no mapping tool or simulator.

    python3 -I flow/test_route_diag.py
"""
import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAP_PATH = REPO / "sim" / "bitstream" / "fabric_spec.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


R = _load("route_diag", REPO / "flow" / "route_diag.py")
F = R.F


class RouteDiagTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.lst = R.generate(cls.out, SNAP_PATH)
        cls.snap = F.load_snapshot(SNAP_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_every_route_exactly_once(self):
        keys = [(b, int(p), e) for _, b, p, e in (l.split() for l in self.lst)]
        self.assertEqual(len(keys), 64)
        self.assertEqual(sorted(keys), sorted((b, p, e) for b in "ABCD" for p in range(4) for e in "NESW"))

    def test_required_set_comes_from_snapshot(self):
        self.assertEqual(len(R.required_routes(self.snap)), 64)
        snap = copy.deepcopy(self.snap)
        snap["pips"] = [p for p in snap["pips"] if not (p[1] == "W1END3" and p[3] == "LD_I3")]
        with tempfile.TemporaryDirectory() as d, tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            import json
            json.dump(snap, f); f.flush()
            with self.assertRaises(F.AsmError):   # a route that left the model is not silently dropped
                R.generate(d, f.name)

    def test_streams_decode_distinct_and_consecutive_differ(self):
        prev, seen = None, set()
        for line in self.lst:
            cid = line.split()[0]
            cfg, _ = F.decode((self.out / f"{cid}.bin").read_bytes(), self.snap)
            self.assertEqual(f"{cfg:040x}\n", (self.out / f"{cid}.cfg").read_text())
            self.assertNotEqual(cfg, prev)
            seen.add(cfg)
            prev = cfg
        self.assertEqual(len(seen), 64)

    def test_projection_init(self):
        self.assertEqual(R.init_word(0), "1010101010101010")
        self.assertEqual(R.init_word(3), "1111111100000000")

    def test_wiring_and_determinism(self):
        w = (self.out / "route.wiring").read_text().split("\n")
        self.assertEqual([l for l in w if l.startswith("OUT")],
                         ["OUT A 2 0", "OUT B 2 1", "OUT C 2 2", "OUT D 2 3"])
        with tempfile.TemporaryDirectory() as d:
            R.generate(d, SNAP_PATH)
            for line in self.lst:
                cid = line.split()[0]
                self.assertEqual((Path(d) / f"{cid}.bin").read_bytes(), (self.out / f"{cid}.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
