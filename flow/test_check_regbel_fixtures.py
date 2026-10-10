#!/usr/bin/env python3
"""Tests for flow/check_regbel_fixtures.py (issue #156). Mutations happen in a temp copy."""
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
spec = importlib.util.spec_from_file_location("crf", HERE / "check_regbel_fixtures.py")
crf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crf)


class RegbelMetadata(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        shutil.copytree(REPO / "sim/bitstream/corpus", self.tmp / "sim/bitstream/corpus")
        shutil.copytree(REPO / "design/fabulous/corpus", self.tmp / "design/fabulous/corpus")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fx(self, name):
        return self.tmp / "sim/bitstream/corpus" / name

    def test_committed_fixtures_pass(self):
        self.assertEqual(crf.check(REPO), [])

    def test_moved_placement_is_caught(self):
        p = self.fx("regbel_c_s1.mapped.json")
        m = json.loads(p.read_text())
        m["cells"][0]["bel"] = "X1Y1/D"
        p.write_text(json.dumps(m))
        self.assertTrue(any("regbel_c_s1" in e for e in crf.check(self.tmp)))

    def test_combinational_cell_is_caught(self):
        p = self.fx("regbel_b_s1.mapped.json")
        m = json.loads(p.read_text())
        m["cells"][0]["ff"] = "0"
        p.write_text(json.dumps(m))
        self.assertTrue(any("regbel_b_s1" in e for e in crf.check(self.tmp)))

    def test_wrong_wiring_bel_is_caught(self):
        p = self.fx("regbel_d_s1.wiring")
        p.write_text(p.read_text().replace("BEL 3", "BEL 2"))
        self.assertTrue(any("regbel_d_s1" in e for e in crf.check(self.tmp)))

    def test_missing_index_entry_is_caught(self):
        p = self.fx("index.txt")
        p.write_text("".join(l for l in p.read_text().splitlines(True) if not l.startswith("regbel_a_s1")))
        self.assertTrue(any("regbel_a_s1" in e for e in crf.check(self.tmp)))

    def test_unpinned_source_is_caught(self):
        p = self.tmp / "design/fabulous/corpus/regbel_a.v"
        p.write_text(p.read_text().replace("NEXTPNR_BEL", "X_NOT_A_PIN"))
        self.assertTrue(any("regbel_a" in e for e in crf.check(self.tmp)))


if __name__ == "__main__":
    unittest.main()
