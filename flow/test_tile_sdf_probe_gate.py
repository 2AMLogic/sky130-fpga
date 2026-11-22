#!/usr/bin/env python3
"""Unit tests for flow/tile_sdf_probe_gate.py (issue #382): the fail-loud
parsing of the SETTLE_PROBE lines and the annotated-later-than-zero-delay
delta gate. stdlib only; the logs are synthetic, shaped like the real
`test_icarus.log` klt writes (cocotb logger lines, the regression table,
Icarus `SDF WARNING:` lines) around the probe's own column-0 lines.

    python3 -I flow/test_tile_sdf_probe_gate.py
"""
import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _modload import load_module as _load  # noqa: E402

G = _load("tile_sdf_probe_gate", Path(__file__).resolve().parent / "tile_sdf_probe_gate.py")

NOISE_BEFORE = (
    "     0.00ns INFO     cocotb.initialize                  Running on Icarus "
    "Verilog version 13.0 (stable)\n"
    "     0.00ns INFO     cocotb.regression                  Running tests\n"
    "     0.00ns INFO     cocotb.regression                  "
    "running test_logic_tile_sdf_probe.test_probe_registered_settle (1/2)\n"
)
NOISE_AFTER = (
    "    52.00ns INFO     cocotb.regression                  "
    "test_logic_tile_sdf_probe.test_probe_registered_settle passed\n"
    "                                                        "
    "** TESTS=2 PASS=2 FAIL=0 SKIP=0                                              "
    "168.00           0.01      19697.53  **\n"
    "SDF WARNING: /repo/flow/build/tile-functional-verification/run-probe-sdf/"
    "klt_sdf_safe.sdf:340: TIMINGCHECK not supported.\n"
)
# The committed probe's own lines, as measured on 2026-11-22 (klt 0.9.1,
# Icarus 13.0, cocotb 2.1.0): record 20261121-183351-787c7ca's scratch probe
# read the same 0.60 / 0.53 against 0.01 ns.
ZERO = (NOISE_BEFORE
        + "SETTLE_PROBE registered_ns=0.01 poll_step_ps=10\n"
        + "SETTLE_PROBE combinational_ns=0.01 poll_step_ps=10\n"
        + NOISE_AFTER)
SDF = (NOISE_BEFORE
       + "SETTLE_PROBE registered_ns=0.60 poll_step_ps=10\n"
       + "SETTLE_PROBE combinational_ns=0.53 poll_step_ps=10\n"
       + NOISE_AFTER)


def log(registered=None, combinational=None, extra=""):
    text = NOISE_BEFORE
    if registered is not None:
        text += f"SETTLE_PROBE registered_ns={registered} poll_step_ps=10\n"
    if combinational is not None:
        text += f"SETTLE_PROBE combinational_ns={combinational} poll_step_ps=10\n"
    return text + extra + NOISE_AFTER


class ParseProbe(unittest.TestCase):
    def parsed(self, text):
        return G.parse_probe(text, "test_icarus.log")

    def refused(self, text, needle):
        with self.assertRaises(G.ProbeError) as ctx:
            self.parsed(text)
        self.assertIn(needle, str(ctx.exception))

    def test_both_legs_parse_to_exact_decimals(self):
        for text, expected in ((ZERO, ("0.01", "0.01")), (SDF, ("0.60", "0.53"))):
            probe = self.parsed(text)
            self.assertEqual(probe["registered_ns"], Decimal(expected[0]))
            self.assertEqual(probe["combinational_ns"], Decimal(expected[1]))
            self.assertEqual(probe["poll_step_ps"], 10)
        self.assertEqual(type(self.parsed(SDF)["registered_ns"]), Decimal)

    def test_missing_combinational_is_refused(self):
        self.refused(log(combinational="0.53"), "registered")

    def test_missing_registered_is_refused(self):
        self.refused(log(registered="0.60"), "combinational")

    def test_log_without_any_probe_line_is_refused(self):
        self.refused(NOISE_BEFORE + NOISE_AFTER, "registered")
        self.refused("", "registered")

    def test_prefixed_probe_line_does_not_count(self):
        # Only the probe's own column-0 line is evidence; a logger-prefixed or
        # traceback-quoted copy of it must not be picked up as a measurement.
        for prefixed in (
            "    0.60ns INFO     cocotb.regression                  "
            "SETTLE_PROBE registered_ns=0.60 poll_step_ps=10\n",
            "    print(f\"SETTLE_PROBE registered_ns={settle_ns:.2f} "
            "poll_step_ps={POLL_STEP_PS}\",\n",
        ):
            self.refused(
                log(combinational="0.53", extra=prefixed), "registered")

    def test_malformed_numbers_are_refused(self):
        for bad in ("abc", "", "-0.60", "nan", "inf", "0.60ns", "1e-1", "0,60",
                    ".6", "1.", "+0.6", "0.6.0"):
            with self.subTest(bad=bad):
                self.refused(log(bad, "0.53"), "registered_ns")

    def test_duplicate_kind_is_refused(self):
        self.refused(log("0.60", "0.53",
                         "SETTLE_PROBE registered_ns=0.59 poll_step_ps=10\n"),
                     "registered_ns")

    def test_unknown_token_is_refused(self):
        self.refused(log("0.60", "0.53", "SETTLE_PROBE other_ns=0.10\n"),
                     "other_ns")
        self.refused(log("0.60", "0.53", "SETTLE_PROBE registered_ns=0.60 x\n"),
                     "x")

    def test_bad_poll_step_is_refused(self):
        for bad in ("0", "-10", "1.5", "ten"):
            with self.subTest(bad=bad):
                text = (NOISE_BEFORE
                        + f"SETTLE_PROBE registered_ns=0.60 poll_step_ps={bad}\n"
                        + "SETTLE_PROBE combinational_ns=0.53 poll_step_ps=10\n"
                        + NOISE_AFTER)
                self.refused(text, "poll_step_ps")
        self.refused(
            NOISE_BEFORE
            + "SETTLE_PROBE registered_ns=0.60 poll_step_ps=10\n"
            + "SETTLE_PROBE combinational_ns=0.53 poll_step_ps=20\n"
            + NOISE_AFTER, "poll_step_ps")

    def test_poll_step_is_optional(self):
        probe = self.parsed(NOISE_BEFORE
                            + "SETTLE_PROBE registered_ns=0.60\n"
                            + "SETTLE_PROBE combinational_ns=0.53\n"
                            + NOISE_AFTER)
        self.assertIsNone(probe["poll_step_ps"])
        self.assertEqual(probe["combinational_ns"], Decimal("0.53"))

    def test_error_names_the_source(self):
        with self.assertRaises(G.ProbeError) as ctx:
            G.parse_probe("", "run-probe-sdf/test_icarus.log")
        self.assertIn("run-probe-sdf/test_icarus.log", str(ctx.exception))


class Gate(unittest.TestCase):
    def probe(self, registered, combinational):
        return {"registered_ns": Decimal(registered),
                "combinational_ns": Decimal(combinational), "poll_step_ps": 10}

    def test_committed_pair_passes_with_the_deltas_measured(self):
        v = G.gate(self.probe("0.01", "0.01"), self.probe("0.60", "0.53"), "0.1")
        self.assertTrue(v["passed"])
        self.assertEqual(v["paths"]["registered"]["delta_ns"], Decimal("0.59"))
        self.assertEqual(v["paths"]["combinational"]["delta_ns"], Decimal("0.52"))
        self.assertEqual(v["paths"]["registered"]["zero_delay_ns"], Decimal("0.01"))
        self.assertEqual(v["paths"]["combinational"]["sdf_annotated_ns"],
                         Decimal("0.53"))
        self.assertEqual(v["min_delta_ns"], Decimal("0.1"))

    def test_no_op_annotation_is_refused(self):
        # The failure this gate exists for: identical readings on both legs.
        v = G.gate(self.probe("0.01", "0.01"), self.probe("0.01", "0.01"), "0.1")
        self.assertFalse(v["passed"])
        self.assertEqual(sorted(v["refused"]), ["combinational", "registered"])

    def test_annotated_leg_settling_earlier_is_refused(self):
        v = G.gate(self.probe("0.01", "0.01"), self.probe("0.60", "0.00"), "0.1")
        self.assertFalse(v["passed"])
        self.assertEqual(v["refused"], ["combinational"])
        self.assertEqual(v["paths"]["combinational"]["delta_ns"], Decimal("-0.01"))

    def test_one_path_below_the_margin_refuses_naming_it(self):
        v = G.gate(self.probe("0.01", "0.01"), self.probe("0.60", "0.05"), "0.1")
        self.assertFalse(v["passed"])
        self.assertEqual(v["refused"], ["combinational"])
        self.assertEqual(v["paths"]["registered"]["delta_ns"], Decimal("0.59"))

    def test_delta_exactly_at_the_margin_passes_exactly(self):
        # 0.12 - 0.02 is 0.10 in decimal; in binary floating point it is
        # 0.09999999999999998, which a float comparison would refuse.
        v = G.gate(self.probe("0.02", "0.01"), self.probe("0.12", "0.11"), "0.1")
        self.assertTrue(v["passed"])

    def test_non_positive_margin_is_a_usage_error(self):
        for margin in ("0", "-0.1"):
            with self.subTest(margin=margin), self.assertRaises(ValueError):
                G.gate(self.probe("0.01", "0.01"), self.probe("0.60", "0.53"),
                       margin)


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.zero = self.tmp / "zero.log"
        self.sdf = self.tmp / "sdf.log"

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                rc = G.main(["tile_sdf_probe_gate.py", "--zero-log", str(self.zero),
                             "--sdf-log", str(self.sdf), *argv])
            except SystemExit as exc:  # argparse's usage errors
                rc = exc.code
        return rc, out.getvalue(), err.getvalue()

    def test_pass_exits_0_and_prints_both_readings(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(SDF)
        rc, out, err = self.run_main()
        self.assertEqual((rc, err), (0, ""))
        for needle in ("registered", "0.01", "0.60", "0.59", "combinational",
                       "0.53", "0.52", "0.1"):
            self.assertIn(needle, out)
        self.assertIn("passed", out)

    def test_json_output(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(SDF)
        rc, out, _ = self.run_main("--format", "json")
        self.assertEqual(rc, 0)
        doc = json.loads(out)
        self.assertEqual(doc["passed"], True)
        self.assertEqual(doc["min_delta_ns"], 0.1)
        self.assertEqual(doc["paths"]["registered"],
                         {"zero_delay_ns": 0.01, "sdf_annotated_ns": 0.6,
                          "delta_ns": 0.59})

    def test_no_op_annotation_exits_1_and_says_why(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(ZERO)
        rc, out, err = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("registered", err)
        self.assertIn("0.01", err)
        self.assertIn("0.1", err)
        self.assertNotIn("passed", out)

    def test_missing_probe_number_exits_1(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(NOISE_BEFORE + NOISE_AFTER)
        rc, _, err = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("registered", err)
        self.assertIn(str(self.sdf), err)

    def test_unreadable_log_exits_1(self):
        self.zero.write_text(ZERO)
        rc, _, err = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn(str(self.sdf), err)

    def test_custom_margin(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(SDF)
        rc, _, err = self.run_main("--min-delta-ns", "0.55")
        self.assertEqual(rc, 1)
        self.assertEqual(json.loads(self.run_main("--min-delta-ns", "0.5",
                                                  "--format", "json")[1])["passed"],
                         True)

    def test_bad_margin_is_a_usage_error(self):
        self.zero.write_text(ZERO)
        self.sdf.write_text(SDF)
        self.assertEqual(self.run_main("--min-delta-ns", "0")[0], 2)
        self.assertEqual(self.run_main("--min-delta-ns", "abc")[0], 2)


if __name__ == "__main__":
    unittest.main()
