#!/usr/bin/env python3
"""Unit tests for flow/corpus_run.py's outcome classification (issue #115).

Pure stdlib, no mapper needed: they pin the rule that tool/setup problems are
never reported as routability evidence and that every measured class is
distinguished.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _modload import load_module as _load  # noqa: E402

cr = _load("corpus_run", Path(__file__).with_name("corpus_run.py"))

PROGRESS = ("Info: Routing..\nInfo:    IterCnt |  w/ripup   wo/ripup |  w/r  wo/r |      arcs| batch(sec) total(sec)|\n"
            "Info:       1000 |      958         41 |  958    41 |         3|       0.02       0.02|\n")


class Classify(unittest.TestCase):
    def test_success(self):
        self.assertEqual(cr.classify(0, "Info: Routing complete.\nInfo: Program finished normally.\n")[0], "success")

    def test_success_needs_completion_marker(self):
        self.assertEqual(cr.classify(0, "Info: something\n")[0], "tool_error")

    def test_missing_binary_is_tool_error(self):
        self.assertEqual(cr.classify(None, "")[0], "tool_error")

    def test_crash_is_tool_error(self):
        for rc in (-11, 134, 139):
            self.assertEqual(cr.classify(rc, "Failed to find a route\n")[0], "tool_error")
        self.assertEqual(cr.classify(1, "terminate called after throwing an instance\n")[0], "tool_error")

    def test_route_fail(self):
        out = "ERROR: Failed to find a route for arc 0 of net x\n"
        self.assertEqual(cr.classify(125, out)[0], "route_fail")
        self.assertEqual(cr.classify(125, "ERROR: Routing design failed.\n")[0], "route_fail")

    def test_capacity_packing(self):
        self.assertEqual(cr.classify(125, "ERROR: IO port 'a' must be PAD\n")[0], "capacity_packing")

    def test_unrecognised_failure_is_tool_error(self):
        self.assertEqual(cr.classify(125, "ERROR: something new\n")[0], "tool_error")

    def test_timeout_in_router_is_nonconvergent(self):
        outcome, why, _ = cr.classify("timeout", PROGRESS)
        self.assertEqual(outcome, "route_nonconvergent")
        self.assertIn("3 arcs", why)

    def test_timeout_outside_router_or_fully_routed_is_tool_error(self):
        self.assertEqual(cr.classify("timeout", "Info: placing\n")[0], "tool_error")
        self.assertEqual(cr.classify("timeout", PROGRESS.replace("|         3|", "|         0|"))[0], "tool_error")

    def test_diag_is_normalised(self):
        d = cr.norm_diag(f"Info: x\nERROR: bad at {cr.REPO}/a\niteration #4 ERROR\n")
        self.assertEqual(d, ["ERROR: bad at <repo>/a"])


class Topology(unittest.TestCase):
    def _net(self, cells):
        return {"modules": {"top": {"ports": {}, "cells": cells}}}

    def _lut(self, ff, **conn):
        dirs = {p: ("output" if p == "O" else "input") for p in conn}
        return {"type": "lut4_ff_bel", "parameters": {"FF": ff}, "connections": {p: [b] for p, b in conn.items()},
                "port_directions": dirs}

    def test_cascade_fanout(self):
        io = lambda b: {"type": "IO_1_bidirectional_frame_config_pass", "parameters": {},
                        "connections": {"O": [b], "PAD": [99]}, "port_directions": {"O": "output", "PAD": "inout"}}
        cells = {"a": io(2), "l1": self._lut("0", I0=2, O=5), "l2": self._lut("0", I0=5, O=6),
                 "l3": self._lut("0", I0=5, I1=2, O=7), "f": self._lut("1", I0=6, O=8)}
        m = self._net(cells)
        m["modules"]["top"]["ports"] = {"a": {"direction": "input", "bits": [2]}}
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.json"
            p.write_text(json.dumps(m))
            t, _ = cr.topology(p)
        self.assertEqual(t, dict(luts=3, ffs=1, internal_nets=2, max_internal_fanout=2, max_input_fanout=2))

    def test_unknown_cell_rejected(self):
        m = self._net({"x": {"type": "$_AND_", "parameters": {}, "connections": {}, "port_directions": {}}})
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.json"
            p.write_text(json.dumps(m))
            t, why = cr.topology(p)
        self.assertIsNone(t)


class PostSynthTrial(unittest.TestCase):
    """The shared per-seed post-synthesis pipeline (corpus_run.main, pin_experiment.run_side).
    Tool steps are stubbed: only the pipeline's own sequencing and error classifications
    are under test here; the tool-facing behaviour is exercised by flow/corpus.sh."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.sd = Path(self.tmp.name)
        self.case = {"name": "c", "oracle": "o.v"}
        self._saved = (cr.nextpnr, cr.assemble, cr.simulate)

    def tearDown(self):
        cr.nextpnr, cr.assemble, cr.simulate = self._saved
        self.tmp.cleanup()

    def start(self, np_rc=0, np_out="Info: Routing complete.\nInfo: Program finished normally.\n",
              asm=None, sim=None):
        """Patch the tool steps and return a fresh Run ready for post_synth_trial."""
        (self.sd / "c_s1.post.json").write_text(json.dumps(
            {"modules": {"top": {"cells": {
                "b0": {"type": "lut4_ff_bel", "attributes": {"NEXTPNR_BEL": "X0/Y0/b0"},
                        "parameters": {"FF": "0"}},
                "b1": {"type": "lut4_ff_bel", "attributes": {"NEXTPNR_BEL": "X0/Y0/b1"},
                        "parameters": {"FF": "1"}}}}}}))
        cr.nextpnr = lambda case, seed, sd, env, model, budget: (np_rc, np_out)

        def assemble(stem, seed_dir, snap, fab_run):
            ok, why = asm if asm is not None else (True, "")
            if ok:  # the real assemble leaves the streams it verified behind
                (seed_dir / f"{stem}.fasm").write_text("fasm")
                (seed_dir / f"{stem}.bin").write_bytes(b"bin")
            return ok, why
        cr.assemble = assemble

        def simulate(tb, binf, wiring, cfgf, oracle, snap_dir):
            return sim if sim is not None else (True, "61697 checks, 0 failures; 38/38 perturbations detected")
        cr.simulate = simulate
        return cr.Run("c", 1)

    def trial(self, case=None, **kw):
        r = self.start(**kw)
        cr.post_synth_trial(r, case if case is not None else self.case, 1, self.sd,
                            "env", "model", 60, "tb", Path("snap"), "fab")
        return r

    def test_success(self):
        r = self.trial()
        self.assertEqual(r.outcome, "success")
        self.assertEqual(r.detail, "")
        self.assertEqual(r.bels, [("X0/Y0/b0", "LUT"), ("X0/Y0/b1", "FF")])
        self.assertEqual(r.sha["fasm"], cr.sha256(self.sd / "c_s1.fasm"))
        self.assertEqual(r.sha["bin"], cr.sha256(self.sd / "c_s1.bin"))
        self.assertEqual(r.sim, "61697 checks, 0 failures; 38/38 perturbations detected")

    def test_route_fail(self):
        def unreachable(*a, **k):
            raise AssertionError("assembly/simulation must not run after a route failure")
        r = self.start(np_rc=125, np_out="ERROR: Failed to find a route for arc 0 of net x\n")
        cr.assemble = cr.simulate = unreachable
        cr.post_synth_trial(r, self.case, 1, self.sd, "env", "model", 60, "tb", Path("snap"), "fab")
        self.assertEqual(r.outcome, "route_fail")
        self.assertEqual(r.bels, [])
        self.assertEqual(r.sha, {})
        self.assertEqual(r.sim, "")

    def test_pinned_placement_mismatch_is_tool_error(self):
        def unreachable(*a, **k):
            raise AssertionError("assembly must not run after a placement mismatch")
        case = dict(self.case, placement={"X0/Y0/b0": "FF"})
        r = self.start()
        cr.assemble = unreachable
        cr.post_synth_trial(r, case, 1, self.sd, "env", "model", 60, "tb", Path("snap"), "fab")
        self.assertEqual(r.outcome, "tool_error")
        self.assertIn("placement", r.detail)
        self.assertEqual(r.sha, {})

    def test_pinned_placement_match_proceeds(self):
        case = dict(self.case, placement={"X0/Y0/b0": "LUT", "X0/Y0/b1": "FF"})
        r = self.trial(case=case)
        self.assertEqual(r.outcome, "success")

    def test_assembly_failure_is_tool_error(self):
        r = self.trial(asm=(False, "bit_gen rc=1"))
        self.assertEqual(r.outcome, "tool_error")
        self.assertEqual(r.detail, "assembly: bit_gen rc=1")
        self.assertEqual(r.sha, {})
        self.assertEqual(r.sim, "")

    def test_simulation_failure_is_sim_fail(self):
        r = self.trial(sim=(False, "simulation did not PASS: x"))
        self.assertEqual(r.outcome, "sim_fail")
        self.assertEqual(r.detail, "simulation did not PASS: x")
        self.assertEqual(r.sim, "")
        self.assertEqual(r.sha["fasm"], cr.sha256(self.sd / "c_s1.fasm"))


class ShChildLifetime(unittest.TestCase):
    """Issue #204: children of sh() must not outlive a SIGKILLed parent."""

    def test_child_killed_with_parent(self):
        import os
        import signal
        import subprocess
        import time
        with tempfile.TemporaryDirectory() as d:
            pidfile = Path(d) / "child.pid"
            code = ("import importlib.util,sys\n"
                    "s=importlib.util.spec_from_file_location('cr',sys.argv[1])\n"
                    "m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                    "m.sh(['sh','-c','echo $$ > '+sys.argv[2]+'; exec sleep 300'],timeout=600)\n")
            parent = subprocess.Popen([sys.executable, "-c", code, str(Path(cr.__file__)), str(pidfile)])
            try:
                end = time.time() + 10
                while time.time() < end and not (pidfile.exists() and pidfile.read_text().strip()):
                    time.sleep(0.05)
                child = int(pidfile.read_text())
                os.kill(child, 0)  # alive
                parent.kill()
                parent.wait()
                end = time.time() + 5
                alive = True
                while time.time() < end and alive:
                    try:
                        os.kill(child, 0)
                        time.sleep(0.1)
                    except ProcessLookupError:
                        alive = False
                self.assertFalse(alive, "child outlived its SIGKILLed parent")
            finally:
                parent.kill()
                if pidfile.exists():
                    try:
                        os.kill(int(pidfile.read_text()), signal.SIGKILL)
                    except (ProcessLookupError, ValueError):
                        pass

    def test_timeout_and_missing_binary_unchanged(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "l.log"
            self.assertEqual(cr.sh(["sleep", "30"], timeout=0.5, log=log)[0], "timeout")
            self.assertTrue(log.exists())
            self.assertIsNone(cr.sh(["/nonexistent-binary-204"])[0])
            self.assertEqual(cr.sh(["true"])[0], 0)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:])
