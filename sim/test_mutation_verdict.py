#!/usr/bin/env python3
"""Regression for the RTL mutation verdict classifier (issue #164).

Uses stub `iverilog`/`vvp` on PATH (no simulator needed). Only a completed
functional FAIL may be a kill; every infrastructure case must surface as an
error. Run: python3 -I sim/test_mutation_verdict.py
"""
import importlib.util
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

SIM = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SIM.parent / "flow"))
spec = importlib.util.spec_from_file_location("mutation", SIM / "mutation.py")
mutation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mutation)

TB = "tb_lut4_slice"
PASS = f"PASS: {TB} -- 10 checks, 0 failures"
FUNC = f"FAIL: {TB} -- 10 checks, 3 failures"
BS = "tb_logic_tile_bitstream[reg]"
BS_FUNC = f"FAIL: {BS} (10 checks, 3 failures, 1 perturbations survived)"

# (case, rc, output, tb, expected classification)
CASES = [
    ("normal PASS", 0, PASS + "\n", TB, "PASS"),
    ("functional FAIL", 0, "FAIL[3] x: expected=1 got=0 (t=5)\n" + FUNC + "\n", TB, "FUNC_FAIL"),
    ("bitstream functional FAIL", 0, BS_FUNC + "\n", BS, "FUNC_FAIL"),
    ("nonzero exit", 1, FUNC + "\n", TB, "INFRA"),
    ("crash after PASS", 139, PASS + "\n", TB, "INFRA"),
    ("empty output", 0, "", TB, "INFRA"),
    ("no verdict", 0, "some banner\n", TB, "INFRA"),
    ("loader FAIL", 0, "FAIL: tb_logic_tile_bitstream: cannot open map\n", BS, "INFRA"),
    ("bitstream loader FAIL plus summary", 0,
     f"FAIL: {BS}: loader rejected a stream that must load: x\n{BS_FUNC}\n", BS, "INFRA"),
    ("PASS plus FAIL", 0, PASS + "\nFAIL[1] x: expected=1 got=0 (t=5)\n", TB, "INFRA"),
    ("PASS plus FAIL summary", 0, PASS + "\n" + FUNC + "\n", TB, "INFRA"),
    ("duplicate PASS", 0, PASS + "\n" + PASS + "\n", TB, "INFRA"),
    ("duplicate FAIL summary", 0, FUNC + "\n" + FUNC + "\n", TB, "INFRA"),
    ("other bench's verdict", 0, "PASS: tb_logic_tile_routed (1 checks, 0 failures)\n", "tb_logic_tile", "INFRA"),
]

STUB_VVP = """#!/bin/sh
printf '%s' "$STUB_OUT"
exit "${STUB_RC:-0}"
"""
STUB_IVERILOG = "#!/bin/sh\nexit 0\n"
STUB_VVP_SLEEP = "#!/bin/sh\nsleep 30\n"
# Prints the clean PASS verdict for whichever bench is being run.
STUB_VVP_ALLPASS = """case "$*" in
*+design=comb*) echo "PASS: tb_logic_tile_bitstream[comb] (1 checks, 0 failures)";;
*+design=reg*) echo "PASS: tb_logic_tile_bitstream[reg] (1 checks, 0 failures)";;
*) echo "PASS: $(basename "$1" .out) -- 1 checks, 0 failures";;
esac
"""


def write_exe(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Classify(unittest.TestCase):
    def test_cases(self):
        for name, rc, out, tb, want in CASES:
            with self.subTest(name):
                self.assertEqual(mutation.classify(rc, out, tb), want)


class Killer(unittest.TestCase):
    """End-to-end through killer() with stub simulators."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.bin = pathlib.Path(tmp.name) / "bin"
        self.bin.mkdir()
        self.mdir = pathlib.Path(tmp.name) / "m"
        self.mdir.mkdir()
        write_exe(self.bin / "iverilog", STUB_IVERILOG)
        old = os.environ.copy()
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ["PATH"] = f"{self.bin}{os.pathsep}{os.environ['PATH']}"

    def _killer(self, rc, out):
        write_exe(self.bin / "vvp", STUB_VVP)
        os.environ["STUB_RC"], os.environ["STUB_OUT"] = str(rc), out
        return mutation.killer(self.mdir)

    def test_clean_pass_is_no_kill_no_error(self):
        write_exe(self.bin / "vvp", "#!/bin/sh\n" + STUB_VVP_ALLPASS)
        self.assertEqual(mutation.killer(self.mdir), (None, None))

    def test_functional_fail_is_a_kill(self):
        k, err = self._killer(0, "FAIL: tb_lut4_slice -- 4 checks, 1 failures\n")
        self.assertEqual((k, err), ("tb_lut4_slice", None))

    def test_infrastructure_cases_are_errors_not_kills(self):
        for name, rc, out, tb, want in CASES:
            if want != "INFRA" or tb != TB:
                continue
            with self.subTest(name):
                k, err = self._killer(rc, out)
                self.assertIsNone(k)
                self.assertTrue(err)

    def test_timeout_is_error_not_kill(self):
        os.environ["SIM_TIMEOUT_SECONDS"] = "1"
        write_exe(self.bin / "vvp", STUB_VVP_SLEEP)
        k, err = mutation.killer(self.mdir)
        self.assertIsNone(k)
        self.assertIn("TIMEOUT", err)


class MainExit(unittest.TestCase):
    def test_infra_error_after_passing_baseline_fails_invocation(self):
        """Baseline passes, then every mutant run crashes: exit 1 and no
        mutant reported KILLED."""
        with tempfile.TemporaryDirectory() as t:
            t = pathlib.Path(t)
            (t / "bin").mkdir()
            write_exe(t / "bin" / "iverilog", STUB_IVERILOG)
            # The baseline's last run is the reg bitstream design; after it,
            # all runs crash.
            write_exe(t / "bin" / "vvp", f"""#!/bin/sh
if [ -e "{t}/baseline_done" ]; then echo "PASS: x"; exit 139; fi
case "$*" in *+design=reg*) touch "{t}/baseline_done";; esac
{STUB_VVP_ALLPASS}""")
            env = dict(os.environ, PATH=f"{t / 'bin'}{os.pathsep}{os.environ['PATH']}")
            r = subprocess.run([sys.executable, "-I", str(SIM / "mutation.py")],
                               capture_output=True, text=True, env=env, timeout=300)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertNotIn("KILLED ", r.stdout)
            self.assertIn("ERROR", r.stdout)


if __name__ == "__main__":
    unittest.main()
