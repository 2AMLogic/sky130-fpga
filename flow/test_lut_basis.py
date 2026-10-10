#!/usr/bin/env python3
"""Unit tests for flow/lut_basis.py (issue #172). stdlib only; uses the committed
snapshot sim/bitstream/fabric_spec.json, no mapping tool or simulator.

    python3 -I flow/test_lut_basis.py
"""
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


L = _load("lut_basis", REPO / "flow" / "lut_basis.py")
F = L.F


class LutBasisTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.lst = L.generate(cls.out, SNAP_PATH)
        cls.snap = F.load_snapshot(SNAP_PATH)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_case_set_covers_every_bel_and_address_once(self):
        onehot = [(b, int(a)) for _, b, k, a in (l.split() for l in self.lst) if k == "onehot"]
        self.assertEqual(sorted(onehot), [(b, a) for b in "ABCD" for a in range(16)])
        kinds = [l.split()[2] for l in self.lst]
        self.assertEqual(kinds.count("ones"), 4)
        self.assertEqual(kinds.count("zero"), 5)
        self.assertEqual(len(self.lst), 73)
        # a zero case follows the last one-hot of each BEL (clearing), blank comes first
        self.assertEqual(self.lst[0].split()[0], "blank")
        for b in "ABCD":
            ids = [l.split()[0] for l in self.lst]
            self.assertEqual(ids.index(f"{b}_zero"), ids.index(f"{b}_a15") + 1)
            self.assertLess(ids.index(f"{b}_ones"), ids.index(f"{b}_a00"))

    def test_streams_decode_and_differ_from_blank_by_init_weight(self):
        blank, _ = F.decode((self.out / "blank.bin").read_bytes(), self.snap)
        seen = set()
        for line in self.lst:
            cid, _, kind, _ = line.split()
            cfg, _ = F.decode((self.out / f"{cid}.bin").read_bytes(), self.snap)
            self.assertEqual(f"{cfg:040x}\n", (self.out / f"{cid}.cfg").read_text())
            self.assertEqual(bin(cfg ^ blank).count("1"), {"zero": 0, "ones": 16, "onehot": 1}[kind], cid)
            if kind == "onehot":
                seen.add(cfg ^ blank)
        self.assertEqual(len(seen), 64)   # 64 distinct single-bit differences

    def test_shared_wiring(self):
        w = (self.out / "basis.wiring").read_text().split("\n")
        self.assertIn("IN 0 2 0", w)
        self.assertIn("IN 3 2 3", w)
        self.assertEqual([l for l in w if l.startswith("OUT")],
                         ["OUT A 2 0", "OUT B 2 1", "OUT C 2 2", "OUT D 2 3"])
        self.assertFalse(any(l.startswith("LOOP") for l in w))

    def test_routes_are_model_pips(self):
        L.check_routes(self.snap)   # does not raise
        bad = dict(self.snap)
        bad["pips"] = [p for p in self.snap["pips"]
                       if not (p[0] == "X1Y0" and p[1] == "IOA_O" and p[3] == "S1BEG0")]
        with self.assertRaises(F.AsmError):
            L.check_routes(bad)

    def test_deterministic(self):
        with tempfile.TemporaryDirectory() as d:
            L.generate(d, SNAP_PATH)
            for line in self.lst:
                cid = line.split()[0]
                self.assertEqual((Path(d) / f"{cid}.bin").read_bytes(), (self.out / f"{cid}.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
