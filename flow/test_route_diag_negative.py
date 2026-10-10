#!/usr/bin/env python3
"""Unit tests for flow/route_diag_negative.py (issue #189). stdlib only; uses the committed
snapshot sim/bitstream/fabric_spec.json, no simulator.

    python3 -I flow/test_route_diag_negative.py
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAP = REPO / "sim" / "bitstream" / "fabric_spec.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


N = _load("route_diag_negative", REPO / "flow" / "route_diag_negative.py")
R = _load("route_diag", REPO / "flow" / "route_diag.py")
F = N.F

CASE, OLD, NEW = "R_C_I2_E", "X1Y1.E1END2.LC_I2", "X1Y1.S1END2.LC_I2"


class RouteDiagNegativeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.src = Path(cls.tmp.name) / "src"
        R.generate(cls.src, SNAP)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def dst(self, name):
        return Path(self.tmp.name) / name

    def test_alters_only_the_named_case(self):
        dst = self.dst("ok")
        n, orig, new = N.alter(self.src, dst, CASE, OLD, NEW, SNAP)
        self.assertGreater(n, 0)
        self.assertNotEqual(orig, new)
        self.assertEqual((dst / "cases.txt").read_text(), (self.src / "cases.txt").read_text())
        for p in self.src.iterdir():
            same = (dst / p.name).read_bytes() == p.read_bytes()
            self.assertEqual(same, not p.name.startswith(CASE + "."), p.name)
        # the altered stream decodes to the recorded cfg, and equals the sibling case's route choice
        snap = F.load_snapshot(SNAP)
        cfg, _ = F.decode((dst / f"{CASE}.bin").read_bytes(), snap)
        self.assertEqual(f"{cfg:040x}\n", (dst / f"{CASE}.cfg").read_text())
        self.assertEqual(cfg, int((self.src / "R_C_I2_S.cfg").read_text(), 16))

    def test_rejects_illegal_source(self):
        # non-same-index source: not a pip of the frozen model
        with self.assertRaises(N.NegError):
            N.alter(self.src, self.dst("illegal"), CASE, OLD, "X1Y1.N1END1.LC_I2", SNAP)
        self.assertFalse(self.dst("illegal").exists())

    def test_rejects_other_sink_same_source_or_absent_line(self):
        with self.assertRaises(N.NegError):
            N.alter(self.src, self.dst("sink"), CASE, OLD, "X1Y1.S1END2.LD_I2", SNAP)
        with self.assertRaises(N.NegError):
            N.alter(self.src, self.dst("same"), CASE, OLD, OLD, SNAP)
        with self.assertRaises(N.NegError):
            N.alter(self.src, self.dst("absent"), CASE, "X1Y1.W1END2.LC_I2", NEW, SNAP)
        with self.assertRaises(N.NegError):
            N.alter(self.src, self.dst("nocase"), "R_Z_I9_Q", OLD, NEW, SNAP)

    def test_main_exit_codes(self):
        self.assertEqual(N.main([str(self.src), str(self.dst("m1")), CASE, OLD, NEW, "--snapshot", str(SNAP)]), 0)
        self.assertEqual(N.main([str(self.src), str(self.dst("m1")), CASE, OLD, NEW, "--snapshot", str(SNAP)]), 1)


if __name__ == "__main__":
    unittest.main()
