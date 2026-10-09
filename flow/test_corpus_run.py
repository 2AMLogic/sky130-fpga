#!/usr/bin/env python3
"""Unit tests for flow/corpus_run.py's outcome classification (issue #115).

Pure stdlib, no mapper needed: they pin the rule that tool/setup problems are
never reported as routability evidence and that every measured class is
distinguished.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("corpus_run", Path(__file__).with_name("corpus_run.py"))
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

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


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]] + sys.argv[1:])
