#!/usr/bin/env python3
"""Tests for flow/audit_evidence.py check 3 (report PDK pins), issue #149.

Temporary trees only; stdlib only.
"""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("audit_evidence", Path(__file__).with_name("audit_evidence.py"))
ae = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ae)

PDK = "abc123"


def run(files):
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        for rel, doc in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(json.dumps(doc))
        a = ae.Audit(root, PDK)
        a.audit_report_pdk_pins()
        return a.failures


def prov(version):
    return {"provenance": {"pdk": {"name": "sky130", "version": version}}}


NULL = {"provenance": {"pdk": None}}


class ReportPins(unittest.TestCase):
    def test_top_level_match_passes(self):
        self.assertEqual(run({"layout/a.json": prov(PDK)}), [])

    def test_top_level_wrong_fails(self):
        f = run({"layout/a.json": prov("bad")})
        self.assertEqual(len(f), 1)
        self.assertIn("layout/a.json", f[0])

    def test_top_level_null_fails(self):
        self.assertEqual(len(run({"layout/a.json": NULL})), 1)

    def test_nested_match_passes(self):
        self.assertEqual(run({"layout/experimental/x.drc.json": prov(PDK)}), [])

    def test_nested_wrong_fails_with_path(self):
        f = run({"layout/experimental/x.drc.json": prov("bad")})
        self.assertEqual(len(f), 1)
        self.assertIn("layout/experimental/x.drc.json", f[0])

    def test_nested_null_fails_unless_listed(self):
        f = run({"layout/experimental/other.erc.json": NULL})
        self.assertEqual(len(f), 1)
        self.assertIn("layout/experimental/other.erc.json", f[0])
        self.assertEqual(run({"layout/experimental/logic_tile_routed.erc.json": NULL}), [])

    def test_deeper_nesting_reached(self):
        self.assertEqual(len(run({"layout/experimental/run-records/y.json": prov("bad")})), 1)


if __name__ == "__main__":
    unittest.main()
