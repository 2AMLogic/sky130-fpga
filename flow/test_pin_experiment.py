#!/usr/bin/env python3
"""Unit tests for flow/pin_experiment.py's transform and equivalence checks (issues #137, #160). Stdlib only."""
import importlib.util
import itertools
import json
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


# ------------------------------------------------------------------ registered (issue #160)
def ffbel(d, sr, en, out):
    """Registered BEL as ff_map.v emits it: pass-through data LUT on I0, I1..I3 absent."""
    return {"type": "lut4_ff_bel", "parameters": {"INIT": "1010101010101010", "FF": "1"},
            "connections": {"EN": [en], "I0": [d], "O": [out], "SR": [sr]},
            "port_directions": {"EN": "input", "I0": "input", "O": "output", "SR": "input"}}


def reg_mod():
    """regcasc shape: q <= rst ? 0 : (en ? ((a^b^c^d) & e) : q), net ids as the mapper numbers
    them: e=11 x=12 (xor4) y=15 (e&x, e on I0, x on I1) a..d=16..19 en=20 q=21 rst=22."""
    cells = {f"i{n}": io("in", b) for n, b in zip("abcd", range(16, 20))}
    cells.update({"ie": io("in", 11), "ien": io("in", 20), "irst": io("in", 22), "oq": io("out", 21),
                  "lx": lut(lambda a, b, c, d: a ^ b ^ c ^ d, [16, 17, 18, 19], 12),
                  "ly": lut(lambda e, x: x & e, [11, 12], 15),
                  "ff": ffbel(15, 22, 20, 21)})
    return {"cells": cells, "ports": {"q": {"direction": "output", "bits": [9]}}}


def reference_next(q, a, b, c, d, e, en, rst):
    return 0 if rst else (((a ^ b ^ c ^ d) & e) if en else q)


class Registered(unittest.TestCase):
    def test_shape(self):
        s = pe.seq_shape(reg_mod())
        self.assertEqual((s["cell"], s["state"], s["sr"], s["en"]), ("ff", 21, 22, 20))

    def test_transition_table_matches_independent_reference(self):
        _, pi, po, t = pe.transition_table(reg_mod())
        self.assertEqual(len(t), 2 * 2 ** 7)
        order = [pe.port_label(l) for l in pi]     # cell-name order: ia..ie, ien, irst
        self.assertEqual(order, ["ia.O", "ib.O", "ic.O", "id.O", "ie.O", "ien.O", "irst.O"])
        for (q, vals), (nq, outs) in t.items():
            self.assertEqual(nq, reference_next(q, *vals))
            self.assertEqual(outs, (q,))
        self.assertEqual({nq for (q, _), (nq, _) in t.items() if q == 1}, {0, 1})

    def test_policies_transform_ff_data_lut_and_stay_equivalent(self):
        m = reg_mod()
        for policy in ("consistent", "distinct"):
            plan, log = pe.alignment_plan(m, policy, registered=True)
            v = pe.apply_plan(m, plan, registered=True)
            r = pe.check_registered_equivalence(m, v)
            self.assertEqual(r["status"], "EQUIVALENT", r["verdict"])
            self.assertTrue(r["structural"].startswith("UNCHANGED"))
            for pin in ("SR", "EN", "O"):
                self.assertEqual(v["cells"]["ff"]["connections"][pin], m["cells"]["ff"]["connections"][pin])
            self.assertEqual(v["cells"]["ff"]["parameters"]["FF"], "1")
            self.assertEqual(v["cells"]["oq"], m["cells"]["oq"])
        plan, _ = pe.alignment_plan(m, "distinct", registered=True)
        self.assertNotEqual(plan["ff"], [0, 1, 2, 3], "distinct must move the register's data pin here")
        self.assertNotEqual(plan["lx"], [0, 1, 2, 3])
        v = pe.apply_plan(m, plan, registered=True)
        self.assertNotIn("I0", v["cells"]["ff"]["connections"])
        self.assertEqual(sum(f"I{k}" in v["cells"]["ff"]["connections"] for k in range(4)), 1)

    def test_apply_plan_absent_pins_roundtrip(self):
        m = reg_mod()
        p = [2, 0, 3, 1]
        inv = [p.index(k) for k in range(4)]
        ident = {n: [0, 1, 2, 3] for n, _ in pe.lut_cells(m, True)}
        fwd = pe.apply_plan(m, dict(ident, ff=p), registered=True)
        back = pe.apply_plan(fwd, dict(ident, ff=inv), registered=True)
        self.assertEqual(back["cells"]["ff"]["connections"], m["cells"]["ff"]["connections"])
        self.assertEqual(back["cells"]["ff"]["parameters"], m["cells"]["ff"]["parameters"])

    def test_identity_plan_is_unchanged(self):
        m = reg_mod()
        v = pe.apply_plan(m, {n: [0, 1, 2, 3] for n, _ in pe.lut_cells(m, True)}, registered=True)
        self.assertEqual(v, m)

    # --- the three required negative-control classes: completed rejections, not errors
    def controls(self):
        return {cls: (desc, r, ok) for cls, desc, r, ok in pe.run_negative_controls(reg_mod())}

    def test_negative_control_wrong_init(self):
        desc, r, ok = self.controls()["wrong-INIT"]
        self.assertTrue(ok, r["verdict"])
        self.assertEqual(r["status"], "REJECTED")
        self.assertTrue(r["cells"].startswith("MISMATCH"))

    def test_negative_control_control_swap(self):
        desc, r, ok = self.controls()["control-swap"]
        self.assertTrue(ok, r["verdict"])
        self.assertEqual(r["status"], "REJECTED")
        self.assertTrue(r["transition"].startswith("MISMATCH at"), r["transition"])
        self.assertIn("SR net", r["structural"])

    def test_negative_control_state_interface(self):
        desc, r, ok = self.controls()["state-interface"]
        self.assertTrue(ok, r["verdict"])
        self.assertEqual(r["status"], "REJECTED")
        self.assertTrue(r["transition"].startswith("MISMATCH at"), r["transition"])

    def test_policy_plan_without_init_permutation_rejected(self):
        m = reg_mod()
        plan, _ = pe.alignment_plan(m, "distinct", registered=True)
        self.assertTrue(pe.init_changed(m, plan, True))
        r = pe.check_registered_equivalence(m, pe.apply_plan(m, plan, permute_init_too=False, registered=True))
        self.assertEqual(r["status"], "REJECTED")

    def test_symmetric_lut_permutation_does_not_count_as_changed(self):
        m = reg_mod()
        ident = {n: [0, 1, 2, 3] for n, _ in pe.lut_cells(m, True)}
        self.assertFalse(pe.init_changed(m, dict(ident, lx=[3, 0, 1, 2]), True))   # xor4 is symmetric

    def test_enable_only_mutation_rejected(self):
        # EN driven by rst's pad net and SR by en's: same nets, different roles -> rejected
        m = reg_mod()
        v = json.loads(json.dumps(m))
        v["cells"]["ff"]["connections"]["EN"] = [22]
        r = pe.check_registered_equivalence(m, v)
        self.assertEqual(r["status"], "REJECTED")
        self.assertTrue(r["transition"].startswith("MISMATCH at"))

    def test_ff_disabled_is_rejected_not_equivalent(self):
        m = reg_mod()
        v = json.loads(json.dumps(m))
        v["cells"]["ff"]["parameters"]["FF"] = "0"
        r = pe.check_registered_equivalence(m, v)
        self.assertEqual(r["status"], "REJECTED")
        self.assertIn("parameter FF", r["structural"])

    def test_inverted_data_lut_rejected(self):
        m = reg_mod()
        v = json.loads(json.dumps(m))
        v["cells"]["ff"]["parameters"]["INIT"] = "0101010101010101"
        r = pe.check_registered_equivalence(m, v)
        self.assertEqual(r["status"], "REJECTED")
        self.assertTrue(r["cells"].startswith("MISMATCH"))
        self.assertTrue(r["transition"].startswith("MISMATCH at"))

    # --- unsupported shapes fail closed with specific diagnostics
    def assertUnsupported(self, m, needle):
        with self.assertRaises(pe.Unsupported) as cm:
            pe.seq_shape(m) if needle != "cycle" else pe.transition_table(m)
        self.assertIn(needle, str(cm.exception))
        r = pe.check_registered_equivalence(m, m)
        self.assertEqual(r["status"], "UNSUPPORTED")
        self.assertIn(needle, r["verdict"])

    def test_unsupported_two_registers(self):
        m = reg_mod()
        m["cells"]["ff2"] = ffbel(12, 22, 20, 31)
        self.assertUnsupported(m, "2 state elements")

    def test_unsupported_no_register(self):
        self.assertUnsupported(fan_mod(), "no state element")

    def test_unsupported_logic_driven_control(self):
        m = reg_mod()
        m["cells"]["ff"]["connections"]["SR"] = [12]
        self.assertUnsupported(m, "SR net 12 is not a primary input")

    def test_unsupported_unconnected_enable(self):
        m = reg_mod()
        del m["cells"]["ff"]["connections"]["EN"]
        self.assertUnsupported(m, "EN unconnected or constant")

    def test_unsupported_unknown_clock_pin(self):
        m = reg_mod()
        m["cells"]["ff"]["connections"]["CLK"] = [9]
        m["cells"]["ff"]["port_directions"]["CLK"] = "input"
        self.assertUnsupported(m, "no modelled clock/control semantics")

    def test_unsupported_extra_parameter(self):
        m = reg_mod()
        m["cells"]["ff"]["parameters"]["RESET_VALUE"] = "1"
        self.assertUnsupported(m, "parameters ['RESET_VALUE']")

    def test_unsupported_combinational_cycle(self):
        m = reg_mod()
        m["cells"]["lx"]["connections"]["I3"] = [15]      # x depends on y, y on x
        self.assertUnsupported(m, "cycle")

    def test_unsupported_multiple_drivers(self):
        m = reg_mod()
        m["cells"]["ly"]["connections"]["O"] = [12]
        self.assertUnsupported(m, "several drivers")

    def test_comb_path_still_refuses_registered(self):
        with self.assertRaises(ValueError):
            pe.lut_cells(reg_mod())
        self.assertEqual(len(pe.lut_cells(reg_mod(), registered=True)), 3)


class Oracle(unittest.TestCase):
    def test_oracle_clean(self):
        self.assertTrue(pe.oracle_clean("61697 checks, 0 failures; 38/38 perturbations detected"))
        self.assertFalse(pe.oracle_clean("61697 checks, 0 failures; 37/38 perturbations detected"))
        self.assertFalse(pe.oracle_clean("61697 checks, 0 failures; 0/0 perturbations detected"))
        self.assertFalse(pe.oracle_clean("0 checks, 0 failures; 3/3 perturbations detected"))
        self.assertFalse(pe.oracle_clean(""))


if __name__ == "__main__":
    unittest.main()
