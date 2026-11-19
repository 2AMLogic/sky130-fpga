"""Regression tests for the physical LUT count used in the cost estimate."""

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

GENERATOR_PATH = Path(__file__).with_name("generate-cost-per-lut.py")
spec = importlib.util.spec_from_file_location("cost_per_lut", GENERATOR_PATH)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

SLICE_LOOP = """
    for (i = 0; i < 4; i = i + 1) begin : g_slice
        lut4_slice u_slice ();
    end
"""
OTHER_LOOP = """
    for (j = 0; j < 158; j = j + 1) begin : g_other
        wire unused;
    end
"""


class SliceCountTests(unittest.TestCase):
    def count(self, loops, extra_module=""):
        with tempfile.TemporaryDirectory() as temp:
            rtl = Path(temp) / "logic_tile_routed.v"
            rtl.write_text(
                f"module logic_tile_routed;\ngenvar i, j;\ngenerate\n{loops}\n"
                f"endgenerate\nendmodule\n{extra_module}"
            )
            with patch.object(generator, "RTL_PATH", rtl):
                return generator.collect_lut_count()

    def test_earlier_loop_does_not_supply_bound(self):
        for separator in ("", "endgenerate\ngenerate\n"):
            with self.subTest(separator=separator):
                self.assertEqual(self.count(OTHER_LOOP + separator + SLICE_LOOP), 4)

    def test_changed_slice_bound(self):
        self.assertEqual(self.count(SLICE_LOOP.replace("< 4", "< 7")), 7)

    def test_non_unit_stride(self):
        with self.assertRaisesRegex(AssertionError, "g_slice"):
            self.count(SLICE_LOOP.replace("i + 1", "i + 2"))

    def test_bound_must_be_a_positive_literal(self):
        for bound in ("0", "NUM_SLICES"):
            with (
                self.subTest(bound=bound),
                self.assertRaisesRegex(AssertionError, "g_slice"),
            ):
                self.count(SLICE_LOOP.replace("< 4", f"< {bound}"))

    def test_renamed_loop(self):
        for name in ("g_renamed", "g_slice$old"):
            with (
                self.subTest(name=name),
                self.assertRaisesRegex(AssertionError, "g_slice"),
            ):
                self.count(SLICE_LOOP.replace("g_slice", name))

    def test_loop_in_another_module(self):
        other = f"module other; genvar i; generate {SLICE_LOOP} endgenerate endmodule"
        with self.assertRaisesRegex(AssertionError, "g_slice"):
            self.count(OTHER_LOOP, extra_module=other)

    def test_instance_only_in_sibling_block(self):
        empty = SLICE_LOOP.replace("lut4_slice u_slice ();", "// lut4_slice u_old ();")
        sibling = OTHER_LOOP.replace("wire unused;", "lut4_slice u_other ();")
        with self.assertRaisesRegex(AssertionError, "lut4_slice"):
            self.count(empty + sibling)

    def test_nested_block_before_instance(self):
        nested = "if (1) begin : inner wire unused; end /* end */\n"
        self.assertEqual(
            self.count(SLICE_LOOP.replace("lut4_slice", nested + "lut4_slice")), 4
        )


if __name__ == "__main__":
    unittest.main()
