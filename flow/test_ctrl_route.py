#!/usr/bin/env python3
"""Unit tests for flow/ctrl_route.py (issue #181). stdlib only; uses the committed
snapshot sim/bitstream/fabric_spec.json, no mapping tool or simulator.

    python3 -I flow/test_ctrl_route.py
"""
import copy
import importlib.util
import json
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


C = _load("ctrl_route", REPO / "flow" / "ctrl_route.py")
F = C.F


def _gen_with(snap, out):
    with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
        json.dump(snap, f)
        f.flush()
        return C.generate(out, f.name)


class CtrlRouteTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.lst = C.generate(cls.out, SNAP_PATH)
        cls.snap = F.load_snapshot(SNAP_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_every_control_route_exactly_once(self):
        keys = [(k, b, e) for _, k, b, e, _, _ in (l.split() for l in self.lst)]
        want = [("EN", b, e) for b in "ABCD" for e in "NESW"] + [("SR", "-", e) for e in "NESW"]
        self.assertEqual(sorted(keys), sorted(want))
        self.assertEqual(len(keys), 20)

    def test_required_set_comes_from_snapshot(self):
        self.assertEqual(len(C.required_routes(self.snap)), 20)
        snap = copy.deepcopy(self.snap)
        snap["pips"] = [p for p in snap["pips"] if not (p[1] == "W1END0" and p[3] == "J_SR_BEG0")]
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(len(C.required_routes(snap)), 19)
            with self.assertRaises(F.AsmError):     # a dropped route is not silently accepted
                _gen_with(snap, d)

    def test_destination_fanout_is_checked(self):
        snap = copy.deepcopy(self.snap)
        snap["pips"] = [p for p in snap["pips"] if not (p[1] == "J_EN_END1" and p[3] == "LB_EN")]
        with self.assertRaises(F.AsmError):
            C.required_routes(snap)
        snap = copy.deepcopy(self.snap)
        snap["pips"].append(["X1Y1", "J_EN_END1", "X1Y1", "LA_EN"])   # enable 1 also reaches BEL A
        with self.assertRaises(F.AsmError):
            C.required_routes(snap)

    def test_roles_match_fasm_and_never_share_track_index0(self):
        for line in self.lst:
            cid, kind, bel, edge, redge, en = line.split()
            roles = C.pips_of_case((self.out / f"{cid}.fasm").read_text())
            self.assertEqual(roles, {"en": list(en), "sr": redge}, cid)
            self.assertNotEqual(en[0], redge, cid)
            if kind == "EN":
                self.assertEqual(en["ABCD".index(bel)], edge, cid)
            else:
                self.assertEqual(redge, edge, cid)

    def test_streams_decode_distinct_and_consecutive_differ(self):
        prev, seen = None, set()
        for line in self.lst:
            cid = line.split()[0]
            cfg, _ = F.decode((self.out / f"{cid}.bin").read_bytes(), self.snap)
            self.assertEqual(f"{cfg:040x}\n", (self.out / f"{cid}.cfg").read_text())
            self.assertNotEqual(cfg, prev)
            seen.add(cfg)
            prev = cfg
        self.assertEqual(len(seen), 20)

    def test_wiring_and_determinism(self):
        w = (self.out / "ctrl.wiring").read_text().split("\n")
        self.assertEqual([l for l in w if l.startswith("OUT")],
                         ["OUT A 2 0", "OUT B 2 1", "OUT C 2 2", "OUT D 2 3"])
        with tempfile.TemporaryDirectory() as d:
            C.generate(d, SNAP_PATH)
            for line in self.lst:
                cid = line.split()[0]
                self.assertEqual((Path(d) / f"{cid}.bin").read_bytes(), (self.out / f"{cid}.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
