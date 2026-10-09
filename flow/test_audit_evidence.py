#!/usr/bin/env python3
"""Unit tests for supersession-graph validation in flow/audit_evidence.py
(issue #150). stdlib only, temp trees; no committed record is touched.

    python3 flow/test_audit_evidence.py
"""
import hashlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "audit_evidence", REPO / "flow" / "audit_evidence.py")
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)

PDK = "test-pdk"
DATA = b"current contents\n"
GOOD = "sha256:" + hashlib.sha256(DATA).hexdigest()
STALE = "sha256:" + "0" * 64


class T(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "h.sh").write_text("#!/bin/sh\n")
        (self.tmp / "in.txt").write_bytes(DATA)
        (self.tmp / "measurements/m/records").mkdir(parents=True)

    def rec(self, fname, rid, supersedes=None, h=GOOD, **extra):
        meta = {"harness": "h.sh",
                "provenance": {"pdk": {"version": PDK},
                               "inputs": [{"path": "in.txt", "content_hash": h}]}}
        if rid is not None:
            meta["record_id"] = rid
        if supersedes is not None:
            meta["supersedes"] = supersedes
        meta.update(extra)
        (self.tmp / "measurements/m/records" / fname).write_text(
            f"<!-- record-meta {json.dumps(meta)} -->\n")

    def run_audit(self):
        a = A.Audit(self.tmp, PDK)
        with redirect_stdout(io.StringIO()):
            a.audit_records()
        return a

    def fails(self, a, needle):
        self.assertTrue(any(needle in f for f in a.failures), a.failures)

    def test_valid_chain_tolerates_old_mismatch(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("b.md", "B", supersedes="A")
        a = self.run_audit()
        self.assertEqual(a.failures, [])
        self.assertEqual(a.superseded_by, {"A": "B"})

    def test_valid_chain_list_form_and_three_deep(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("b.md", "B", supersedes=["A"], h=STALE)
        self.rec("c.md", "C", supersedes=["B"])
        self.assertEqual(self.run_audit().failures, [])

    def test_stale_current_successor_still_fails(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("b.md", "B", supersedes="A", h=STALE)
        a = self.run_audit()
        self.assertEqual(len(a.failures), 1)
        self.fails(a, "B: in.txt no longer hashes")

    def test_self_supersession(self):
        self.rec("a.md", "A", supersedes="A", h=STALE)
        a = self.run_audit()
        self.fails(a, "supersedes itself")
        self.fails(a, "A: in.txt no longer hashes")

    def test_two_cycle(self):
        self.rec("a.md", "A", supersedes="B", h=STALE)
        self.rec("b.md", "B", supersedes="A", h=STALE)
        a = self.run_audit()
        self.fails(a, "supersession cycle")
        self.fails(a, "A: in.txt no longer hashes")
        self.fails(a, "B: in.txt no longer hashes")
        self.assertEqual(a.superseded_by, {})

    def test_duplicate_identity(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("a2.md", "A")
        self.rec("b.md", "B", supersedes="A")
        a = self.run_audit()
        self.fails(a, "duplicate record_id 'A'")
        self.fails(a, "A: in.txt no longer hashes")

    def test_unknown_target(self):
        self.rec("a.md", "A", supersedes="ghost", h=STALE)
        a = self.run_audit()
        self.fails(a, "unknown record_id 'ghost'")
        self.fails(a, "A: in.txt no longer hashes")

    def test_missing_identity(self):
        self.rec("a.md", None, supersedes="X")
        self.fails(self.run_audit(), "missing or invalid record_id")

    def test_conflicting_successors_rejected_deterministically(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("b.md", "B", supersedes="A")
        self.rec("c.md", "C", supersedes="A")
        a = self.run_audit()
        self.fails(a, "conflicting supersession of 'A': declared by B, C")
        self.fails(a, "A: in.txt no longer hashes")

    def test_chain_into_cycle_not_exempt(self):
        self.rec("a.md", "A", h=STALE)
        self.rec("b.md", "B", supersedes=["A", "C"], h=STALE)
        self.rec("c.md", "C", supersedes="B", h=STALE)
        a = self.run_audit()
        self.assertNotIn("A", a.superseded_by)
        self.fails(a, "A: in.txt no longer hashes")

    def test_allowed_drift_preserved(self):
        self.rec("a.md", "20260909-225431-86f71d2", h=STALE)
        (self.tmp / "in.txt").write_bytes(DATA)
        orig = dict(A.ALLOWED_INPUT_DRIFT)
        A.ALLOWED_INPUT_DRIFT[("20260909-225431-86f71d2", "in.txt")] = "reviewed"
        self.addCleanup(lambda: (A.ALLOWED_INPUT_DRIFT.clear(), A.ALLOWED_INPUT_DRIFT.update(orig)))
        self.assertEqual(self.run_audit().failures, [])


if __name__ == "__main__":
    unittest.main()
