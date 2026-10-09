#!/usr/bin/env python3
"""Tests for flow/pin_fixtures.py and the committed pin-experiment fixture set (issue #145).

Stdlib only; every mutation happens in a temporary copy, never in the committed
fixtures. Covers the replay-gate failure modes: missing/empty/malformed index,
wrong case count, missing file, sha256 drift, stray file, snapshot provenance
drift, transformed-netlist relation, plus the self-consistent LUT corruption
helper used by the simulation negative tests.
"""
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pin_fixtures", HERE / "pin_fixtures.py")
pf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pf)


class FixtureGate(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.d = self.tmp / "fx"
        shutil.copytree(pf.FIX_DIR, self.d)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fails(self, frag):
        with self.assertRaises(pf.FixtureError) as cm:
            pf.verify(self.d)
        self.assertIn(frag, str(cm.exception))

    def edit_index(self, fn):
        p = self.d / pf.INDEX
        idx = json.loads(p.read_text())
        fn(idx)
        p.write_text(json.dumps(idx))

    def test_committed_set_verifies(self):
        got = pf.verify(pf.FIX_DIR)
        self.assertEqual([s for s, _ in got], [f"fan4_distinct_s{n}" for n in (1, 2, 3)])
        self.assertTrue(all(o == "fan4" for _, o in got))

    def test_missing_index(self):
        (self.d / pf.INDEX).unlink()
        self.fails("missing or empty")

    def test_empty_index(self):
        (self.d / pf.INDEX).write_text("")
        self.fails("missing or empty")

    def test_malformed_index(self):
        (self.d / pf.INDEX).write_text("{not json")
        self.fails("not valid JSON")

    def test_no_cases(self):
        self.edit_index(lambda i: i.update(cases=[]))
        self.fails("exactly 3")

    def test_wrong_case_count(self):
        self.edit_index(lambda i: i["cases"].pop())
        self.fails("exactly 3")

    def test_missing_fixture_file(self):
        (self.d / "fan4_distinct_s2.bin").unlink()
        self.fails("missing or empty fixture file")

    def test_sha_drift(self):
        p = self.d / "fan4_distinct_s1.fasm"
        p.write_text(p.read_text() + "\n# drift\n")
        self.fails("sha256 drift")

    def test_stray_file(self):
        (self.d / "extra.bin").write_bytes(b"x")
        self.fails("stray files")

    def test_wrong_policy_or_oracle(self):
        self.edit_index(lambda i: i["cases"][0].update(policy="consistent"))
        self.fails("only fan4/distinct")

    def test_snapshot_provenance_drift(self):
        snap = self.tmp / "snap"
        shutil.copytree(pf.SNAP_DIR, snap, ignore=shutil.ignore_patterns("corpus", "pin_experiment"))
        (snap / "logic4_configmem.map").write_text("0 0\n")
        with self.assertRaises(pf.FixtureError) as cm:
            pf.verify(self.d, snap)
        self.assertIn("snapshot provenance", str(cm.exception))

    def test_netlist_relation_mapped_init(self):
        p = self.d / "fan4_distinct_s3.mapped.json"
        m = json.loads(p.read_text())
        m["cells"][0]["init"] = "".join("1" if c == "0" else "0" for c in m["cells"][0]["init"])
        p.write_text(json.dumps(m))
        idx = json.loads((self.d / pf.INDEX).read_text())
        idx["cases"][2]["files"][".mapped.json"] = pf.sha256_file(p)
        (self.d / pf.INDEX).write_text(json.dumps(idx))
        self.fails("LUT INITs differ")

    def test_corrupt_copy_is_statically_consistent_but_different(self):
        out = self.tmp / "bad"
        pf.corrupt(pf.FIX_DIR, out)
        self.assertEqual(len(pf.verify(out)), 3)          # sha/provenance gate cannot see it
        for n in (1, 2, 3):
            a = (pf.FIX_DIR / f"fan4_distinct_s{n}.cfg").read_text().strip()
            b = (out / f"fan4_distinct_s{n}.cfg").read_text().strip()
            self.assertEqual(int(a, 16) ^ int(b, 16), 0xFFFF)   # exactly BEL 0's 16 INIT bits
            self.assertNotEqual((pf.FIX_DIR / f"fan4_distinct_s{n}.bin").read_bytes(),
                                (out / f"fan4_distinct_s{n}.bin").read_bytes())


class ExportGuard(unittest.TestCase):
    """flow/pin_experiment.py export refuses (writing nothing) unless every gate held."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("pin_experiment", HERE / "pin_experiment.py")
        self.pe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.pe)
        self.tmp = Path(tempfile.mkdtemp())
        self.dest = self.tmp / "out"
        sim = "61697 checks, 0 failures; 38/38 perturbations detected"
        self.rows = [dict(side="variant-distinct", seed=n, outcome="success", sim=sim, stem=f"fan4_s{n}",
                          dir=self.tmp) for n in (1, 2, 3)]
        self.var = {"distinct": dict(equivalent=True, sha="x")}

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def export(self, rows=None, variants=None, problems=(), case="fan4"):
        ok, msg = self.pe.export_fixtures(None, {"name": case, "oracle": "fan4"}, [1, 2, 3],
                                          self.rows if rows is None else rows,
                                          self.var if variants is None else variants,
                                          list(problems), "b", {"yosys": "y", "nextpnr": "n"}, self.dest)
        self.assertFalse(ok, msg)
        self.assertFalse(self.dest.exists())
        return msg

    def test_refusals(self):
        self.assertIn("problems", self.export(problems=["x"]))
        self.assertIn("equivalent", self.export(variants={"distinct": dict(equivalent=False, sha="x")}))
        self.assertIn("not a success", self.export(rows=self.rows[:2]))
        bad = [dict(r) for r in self.rows]; bad[1]["outcome"] = "route_nonconvergent"
        self.assertIn("not a success", self.export(rows=bad))
        bad = [dict(r) for r in self.rows]; bad[0]["sim"] = "10 checks, 1 failures; 3/3 perturbations detected"
        self.assertIn("not clean", self.export(rows=bad))
        bad = [dict(r) for r in self.rows]; bad[2]["sim"] = "10 checks, 0 failures; 2/3 perturbations detected"
        self.assertIn("not clean", self.export(rows=bad))
        self.assertIn("only defined for the fan4", self.export(case="quad4"))
        self.assertIn("missing", self.export())          # all gates pass but no stream files exist


if __name__ == "__main__":
    unittest.main()
