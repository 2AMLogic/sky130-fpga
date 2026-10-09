#!/usr/bin/env python3
"""Unit tests for flow/gen_bitstream_format.py (issue #131). stdlib only.

    python3 flow/test_gen_bitstream_format.py
"""
import importlib.util
import re
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "gen_bitstream_format", REPO / "flow" / "gen_bitstream_format.py")
G = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(G)

FILES = [G.MAP, G.SPEC, G.OUT] + [f"sim/bitstream/{n}.cfg" for n in G.FIXTURES]


class T(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for f in FILES:
            (self.tmp / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / f, self.tmp / f)

    def check(self):
        return G.main(["--check", "--root", str(self.tmp)])

    def test_committed_document_is_current(self):
        self.assertEqual(G.main(["--check"]), 0)

    def test_each_config_bit_listed_exactly_once(self):
        rows = re.findall(r"^\| (\d+) \| \d+ \| \d+ \| \d+ \| (BEL|matrix)",
                          (REPO / G.OUT).read_text(), re.M)
        self.assertEqual(sorted(int(r[0]) for r in rows), list(range(158)))
        self.assertEqual(sum(r[1] == "BEL" for r in rows), 68)
        self.assertEqual(sum(r[1] == "matrix" for r in rows), 90)

    def test_header_states_experimental_and_not_ratified(self):
        head = "\n".join((REPO / G.OUT).read_text().splitlines()[:8])
        self.assertIn("experimental", head)
        self.assertIn("NOT the ratified-fabric", head)
        self.assertIn("G6", head)
        self.assertIn("**OPEN**", head)

    def test_g6_still_open(self):
        gaps = (REPO / "spec/framework-gaps.md").read_text()
        self.assertIn("(issue #74, experimental -- G6 stays OPEN)", gaps)

    def test_changed_map_entry_fails_check(self):
        p = self.tmp / G.MAP
        lines = p.read_text().splitlines()
        lines[0], lines[1] = "0 131", "1 130"   # swap two positions
        p.write_text("\n".join(lines) + "\n")
        self.assertNotEqual(self.check(), 0)

    def test_changed_spec_bit_fails_check(self):
        p = self.tmp / G.SPEC
        s = p.read_text()
        self.assertIn('"140"', s)
        p.write_text(s.replace('"140"', '"141"', 1))
        self.assertNotEqual(self.check(), 0)

    def test_stale_document_fails_and_regeneration_fixes(self):
        doc = self.tmp / G.OUT
        doc.write_text(doc.read_text().replace("| BEL A |", "| BEL Z |", 1))
        self.assertNotEqual(self.check(), 0)
        self.assertEqual(G.main(["--root", str(self.tmp)]), 0)
        self.assertEqual(self.check(), 0)

    def test_fixture_disagreeing_with_map_fails(self):
        # BEL D INIT lives in cfg[51..66]; zero INIT of the used BEL and the
        # recorded document no longer matches the fixture it was checked on.
        p = self.tmp / "sim/bitstream/top_io.cfg"
        p.write_text(f"{0:040x}\n")
        self.assertNotEqual(self.check(), 0)

    def test_fixture_bit_outside_cfg_range_fails(self):
        (self.tmp / "sim/bitstream/top_reg.cfg").write_text(f"{1 << 158:040x}\n")
        self.assertNotEqual(self.check(), 0)


if __name__ == "__main__":
    unittest.main()
