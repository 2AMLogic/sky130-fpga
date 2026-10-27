#!/usr/bin/env python3
"""Unit tests for flow/sdf_sanitize_names.py (issue #213). stdlib only.

    python3 -I flow/test_sdf_sanitize_names.py
"""
import sys
import unittest
from pathlib import Path

FLOW = Path(__file__).resolve().parent


sys.path.insert(0, str(Path(__file__).resolve().parent))
from _modload import load_module as _load  # noqa: E402


S = _load("sdf_sanitize_names", FLOW / "sdf_sanitize_names.py")

NETLIST = (
    "module logic_tile (ce, q);\n"
    "  input [1:0] ce;\n"
    "  wire \\g_slice[0].u_slice/_08_ ;\n"
    "  wire \\g_slice[1].u_slice/_08_ ;\n"
    "  wire \\_keep_ ;\n"
    "  sky130_fd_sc_hd__and2_1 \\g_slice[0].u_slice/_17_  (.A(ce[0]),\n"
    "    .X(\\g_slice[0].u_slice/_08_ ));\n"
    "endmodule\n"
)
SDF = (
    '(DELAYFILE\n (DIVIDER .)\n (CELL (CELLTYPE "logic_tile") (INSTANCE)\n'
    "  (DELAY (ABSOLUTE\n"
    "    (INTERCONNECT ce[0] g_slice\\[0\\]\\.u_slice\\/_17_.A (0.0:0.0:0.0))\n"
    "    (INTERCONNECT g_slice\\[0\\]\\.u_slice\\/_17_.X q (0.0:0.0:0.0))\n"
    "  )))\n"
    ' (CELL (CELLTYPE "sky130_fd_sc_hd__and2_1")\n'
    "  (INSTANCE g_slice\\[0\\]\\.u_slice\\/_17_)\n"
    "  (DELAY (ABSOLUTE (IOPATH A X (0.1:0.1:0.1)))))\n)\n"
)


class SanitizeTest(unittest.TestCase):
    def test_netlist_has_no_special_chars_in_renamed_ids(self):
        out, m = S.sanitize_netlist(NETLIST)
        self.assertIn("g_slice_0__u_slice___08_", out)
        self.assertNotIn("u_slice/", out)
        self.assertIn("\\_keep_ ", out)  # no `/` or `.`: left alone
        self.assertIn("ce[0]", out)  # bus index untouched
        self.assertEqual(len(m), 3)

    def test_sdf_instance_matches_netlist(self):
        n_out, n_map = S.sanitize_netlist(NETLIST)
        s_out, s_map = S.sanitize_sdf(SDF)
        self.assertIn("(INSTANCE g_slice_0__u_slice___17_)", s_out)
        self.assertIn("g_slice_0__u_slice___17_.A", s_out)  # pin divider kept
        self.assertIn("ce[0]", s_out)
        self.assertEqual(S.check(NETLIST, n_out, SDF, s_out, n_map, s_map), [])

    def test_round_trip_is_byte_identical(self):
        n_out, n_map = S.sanitize_netlist(NETLIST)
        s_out, s_map = S.sanitize_sdf(SDF)
        self.assertEqual(S.unsanitize_netlist(n_out, n_map), NETLIST)
        self.assertEqual(S.unsanitize_sdf(s_out, s_map), SDF)

    def test_collision_between_two_rewritten_names_is_refused(self):
        bad = "wire \\a.b/c ;\nwire \\a_b/c ;\n"  # both -> a_b__c
        with self.assertRaises(ValueError):
            S.sanitize_netlist(bad)

    def test_collision_with_existing_plain_name_is_refused(self):
        bad = "wire \\a.b ;\nwire a_b ;\n"
        with self.assertRaises(ValueError):
            S.sanitize_netlist(bad)
        with self.assertRaises(ValueError):
            S.sanitize_sdf("(INSTANCE a\\.b)\n(INSTANCE a_b)\n")

    def test_check_detects_a_non_inverse_rewrite(self):
        n_out, n_map = S.sanitize_netlist(NETLIST)
        s_out, s_map = S.sanitize_sdf(SDF)
        tampered = n_out.replace("endmodule", "endmodule // x")
        probs = S.check(NETLIST, tampered, SDF, s_out, n_map, s_map)
        self.assertTrue(any("netlist" in p for p in probs))

    def test_check_detects_sdf_instance_missing_from_netlist(self):
        n_out, n_map = S.sanitize_netlist(NETLIST)
        sdf2 = SDF.replace("_17_)", "_99_)")
        s_out, s_map = S.sanitize_sdf(sdf2)
        probs = S.check(NETLIST, n_out, sdf2, s_out, n_map, s_map)
        self.assertTrue(any("absent" in p for p in probs))


if __name__ == "__main__":
    unittest.main()
