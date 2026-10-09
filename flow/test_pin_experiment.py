#!/usr/bin/env python3
"""Unit tests for flow/pin_experiment.py's transform and equivalence check (issue #137). Stdlib only."""
import importlib.util
import itertools
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("pin_experiment", Path(__file__).with_name("pin_experiment.py"))
pe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pe)


def lut(fn, nets, out):
    """Replicated-INIT LUT cell computing fn over `nets` (placed on I0..); extra pins unconnected."""
    n = len(nets)
    bits = [fn(*[(i >> k) & 1 for k in range(n)]) for i in range(1 << n)]
    init = [bits[i % (1 << n)] for i in range(16)]
    conn = {f"I{k}": [nets[k] if k < n else "x"] for k in range(4)}
    conn["O"] = [out]
    return {"type": "lut4_ff_bel", "parameters": {"INIT": pe.init_str(init), "FF": "0"},
            "connections": conn, "port_directions": {**{f"I{k}": "input" for k in range(4)}, "O": "output"}}


def io(kind, bit):
    pin, d = ("O", "output") if kind == "in" else ("I", "input")
    return {"type": "IO_1_bidirectional_frame_config_pass", "parameters": {},
            "connections": {pin: [bit], "PAD": ["x"]}, "port_directions": {pin: d, "PAD": "inout"}}


def fan_mod():
    # a=2 b=3 c=4 d=5 ; y=a^b w=a&c z=a|d v=a^(c&d)  (the fan4 shape, mixed pin indices)
    cells = {
        "ia": io("in", 2), "ib": io("in", 3), "ic": io("in", 4), "id": io("in", 5),
        "oy": io("out", 10), "ow": io("out", 11), "oz": io("out", 12), "ov": io("out", 13),
        "l0": lut(lambda a, b: a ^ b, [2, 3], 10),
        "l1": lut(lambda a, c: a & c, [2, 4], 11),
        "l2": lut(lambda d, a: a | d, [5, 2], 12),                 # a on I1
        "l3": lut(lambda c, a, d: a ^ (c & d), [4, 2, 5], 13),     # a on I1
    }
    return {"cells": cells, "netnames": {"a": {"bits": [2]}, "b": {"bits": [3]},
                                          "c": {"bits": [4]}, "d": {"bits": [5]}}}


class Transform(unittest.TestCase):
    def test_permute_init_roundtrip_and_function(self):
        init = [(i * 7 + (i >> 2)) & 1 for i in range(16)]
        p = [2, 0, 3, 1]
        out = pe.permute_init(init, p)
        for idx in range(16):
            old = sum(((idx >> p[k]) & 1) << k for k in range(4))
            self.assertEqual(out[idx], init[old])

    def test_plan_aligns_shared_net(self):
        m = fan_mod()
        plan, log = pe.alignment_plan(m)
        v = pe.apply_plan(m, plan)
        pins = [pe.pin_nets(c).index(2) for _, c in pe.lut_cells(v)]
        self.assertEqual(len(set(pins)), 1, "net a must sit on one pin index in all LUTs")
        self.assertFalse(any("CONFLICT" in l for l in log))
        # same net never shares a pin with another net inside a cell
        for _, c in pe.lut_cells(v):
            ns = [n for n in pe.pin_nets(c) if n is not None]
            self.assertEqual(len(ns), len(set(ns)))

    def test_distinct_policy_gives_each_net_its_own_pin(self):
        m = fan_mod()
        plan, log = pe.alignment_plan(m, "distinct")
        v = pe.apply_plan(m, plan)
        idx = {}
        for _, c in pe.lut_cells(v):
            for k, n in enumerate(pe.pin_nets(c)):
                if n is not None:
                    idx.setdefault(n, set()).add(k)
        self.assertTrue(all(len(s) == 1 for s in idx.values()))
        self.assertEqual(len({next(iter(s)) for s in idx.values()}), len(idx))
        self.assertTrue(pe.check_equivalence(m, v)[0])

    def test_deterministic(self):
        self.assertEqual(pe.alignment_plan(fan_mod()), pe.alignment_plan(fan_mod()))

    def test_equivalent_after_transform(self):
        m = fan_mod()
        plan, _ = pe.alignment_plan(m)
        ok, verdict = pe.check_equivalence(m, pe.apply_plan(m, plan))
        self.assertTrue(ok, verdict)
        self.assertNotEqual(plan["l2"], [0, 1, 2, 3])

    def test_wrong_init_permutation_fails(self):
        m = fan_mod()
        plan, _ = pe.alignment_plan(m)
        ok, verdict = pe.check_equivalence(m, pe.apply_plan(m, plan, permute_init_too=False))
        self.assertFalse(ok)

    def test_inverse_permutation_init_fails(self):
        # a 3-cycle is not an involution: INIT permuted by the inverse must be rejected
        m = fan_mod()
        p = [1, 2, 0, 3]
        inv = [p.index(k) for k in range(4)]
        self.assertNotEqual(inv, p)
        plan = {n: [0, 1, 2, 3] for n, _ in pe.lut_cells(m)}
        plan["l3"] = p
        good = pe.apply_plan(m, plan)
        self.assertTrue(pe.check_equivalence(m, good)[0])
        bad = pe.apply_plan(m, plan)
        bad["cells"]["l3"]["parameters"]["INIT"] = pe.init_str(pe.permute_init(pe.init_bits(m["cells"]["l3"]), inv))
        self.assertFalse(pe.check_equivalence(m, bad)[0])

    def test_dont_care_dependence_rejected(self):
        m = fan_mod()
        m2 = pe.apply_plan(m, {n: [0, 1, 2, 3] for n, _ in pe.lut_cells(m)})
        # l0 has I2/I3 unconnected: make INIT depend on I3
        m2["cells"]["l0"]["parameters"]["INIT"] = "0110011001100111"
        ok, verdict = pe.check_equivalence(m, m2)
        self.assertFalse(ok)
        self.assertIn("unconnected", verdict)

    def test_unalignable_conflict_is_logged_and_still_equivalent(self):
        # K5 over nets 2..6 with 3-input LUTs on every pair-triple is not 4-colourable
        cells = {f"i{k}": io("in", 2 + k) for k in range(5)}
        n = 20
        for tri in itertools.combinations(range(2, 7), 3):
            cells[f"l{n}"] = lut(lambda a, b, c: (a & b) ^ c, list(tri), n)
            n += 1
        m = {"cells": cells}
        plan, log = pe.alignment_plan(m)
        self.assertTrue(any("CONFLICT" in l for l in log))
        self.assertTrue(pe.check_equivalence(m, pe.apply_plan(m, plan))[0])

    def test_duplicate_net_on_two_pins_left_unchanged(self):
        cells = {"ia": io("in", 2), "o": io("out", 9), "l": lut(lambda a, b: a & b, [2, 2], 9)}
        plan, log = pe.alignment_plan({"cells": cells})
        self.assertEqual(plan["l"], [0, 1, 2, 3])
        self.assertTrue(any("CONFLICT" in l for l in log))

    def test_registered_lut_refused(self):
        m = fan_mod()
        m["cells"]["l0"]["parameters"]["FF"] = "1"
        with self.assertRaises(ValueError):
            pe.lut_cells(m)


if __name__ == "__main__":
    unittest.main()
