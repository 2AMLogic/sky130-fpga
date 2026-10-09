#!/usr/bin/env python3
"""Unit tests for flow/check_status_claims.py (issue #125). stdlib only.

    python3 flow/test_check_status_claims.py
"""
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "check_status_claims", REPO / "flow" / "check_status_claims.py")
C = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(C)

FILES = [
    "README.md", "spec/framework-gaps.md", C.SUMMARY,
    "spec/decisions/0004-g1-tile-description-discrepancies.md",
    "spec/decisions/0005-nextpnr-io-and-constant-handling.md",
    "layout/logic_tile.drc.json", "layout/logic_tile.lvs.json",
    "signoff/tier-report.json",
]


class T(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for f in FILES:
            (self.tmp / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / f, self.tmp / f)

    def edit(self, rel, old, new):
        p = self.tmp / rel
        s = p.read_text()
        self.assertIn(old, s)
        p.write_text(s.replace(old, new, 1))

    def test_committed_tree_passes(self):
        self.assertEqual(C.check(REPO), [])

    def test_wrong_adr_status_fails(self):
        self.edit("README.md", "adr-0004=Proposed", "adr-0004=Accepted")
        errs = C.check(self.tmp)
        self.assertTrue(any("adr-0004" in e and "Proposed" in e for e in errs), errs)

    def test_wrong_corner_count_fails(self):
        self.edit("README.md", "corner-count=18", "corner-count=17")
        self.assertTrue(any("corner-count" in e for e in C.check(self.tmp)))

    def test_source_change_fails(self):
        p = self.tmp / "layout/logic_tile.drc.json"
        d = json.loads(p.read_text())
        d["status"] = "violations"
        p.write_text(json.dumps(d))
        self.assertTrue(any("drc" in e for e in C.check(self.tmp)))

    def test_tier_count_drift_fails(self):
        p = self.tmp / "signoff/tier-report.json"
        d = json.loads(p.read_text())
        d["t1_met_count"] += 1
        p.write_text(json.dumps(d))
        self.assertTrue(any("t1-met" in e for e in C.check(self.tmp)))

    def test_deleted_and_unknown_markers_fail(self):
        self.edit("README.md", "<!-- status-claim: lvs=match -->", "")
        self.assertTrue(any("'lvs' is missing" in e for e in C.check(self.tmp)))
        self.edit("spec/framework-gaps.md", "# Framework gaps",
                  "<!-- status-claim: bogus=1 -->\n# Framework gaps")
        self.assertTrue(any("unknown" in e for e in C.check(self.tmp)))


if __name__ == "__main__":
    unittest.main()
