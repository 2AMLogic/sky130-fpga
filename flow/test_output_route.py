#!/usr/bin/env python3
"""Unit tests for flow/output_route.py (issue #180). stdlib only; uses the committed
snapshot sim/bitstream/fabric_spec.json, no mapping tool or simulator.

    python3 -I flow/test_output_route.py
"""
import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAP_PATH = REPO / "sim" / "bitstream" / "fabric_spec.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


O = _load("output_route", REPO / "flow" / "output_route.py")
F = O.F


class OutputRouteTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        cls.lst = O.generate(cls.out, SNAP_PATH)
        cls.snap = F.load_snapshot(SNAP_PATH)
        cls.rows = [(r[0], r[1], int(r[2]), r[3], r[4]) for r in (l.split() for l in cls.lst)]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_every_tuple_exactly_once(self):
        keys = [(e, t, tok) for _, e, t, tok, _ in self.rows]
        want = {(e, t, tok) for e in "NESW" for t in range(4) for tok in O.tokens_of("NESW".index(e) * 4 + t)}
        self.assertEqual(len(keys), 112)
        self.assertEqual(len(set(keys)), 112)
        self.assertEqual(set(keys), want)
        self.assertEqual(want, O.required_routes(self.snap))

    def test_required_set_comes_from_snapshot(self):
        snap = copy.deepcopy(self.snap)
        snap["pips"] = [p for p in snap["pips"] if not (p[1] == "LC_O" and p[3] == "W1BEG2")]
        with tempfile.TemporaryDirectory() as d, tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            json.dump(snap, f); f.flush()
            with self.assertRaises(F.AsmError):   # a route that left the model is not silently dropped
                O.generate(d, f.name)

    def test_unmodelled_source_rejected(self):
        snap = copy.deepcopy(self.snap)
        snap["pips"].append(["X1Y1", "N1END0", "X1Y1", "E1BEG1"])      # different-index track
        with self.assertRaises(F.AsmError):
            O.required_routes(snap)

    def test_streams_decode_distinct_and_consecutive_differ(self):
        prev, seen = None, set()
        for cid, *_ in self.rows:
            cfg, _ = F.decode((self.out / f"{cid}.bin").read_bytes(), self.snap)
            self.assertEqual(f"{cfg:040x}\n", (self.out / f"{cid}.cfg").read_text())
            self.assertNotEqual(cfg, prev)
            seen.add(cfg)
            prev = cfg
        self.assertEqual(len(seen), 112)

    def test_tested_sink_keeps_its_tested_source_and_all_sinks_configured(self):
        for cid, e, t, tok, bg in self.rows:
            self.assertEqual(len(bg), 16)
            self.assertEqual(bg["NESW".index(e) * 4 + t], tok)
            for n in range(16):
                self.assertIn(bg[n], O.tokens_of(n))
            text = (self.out / f"{cid}.fasm").read_text()
            self.assertEqual(O.sink_sources_of(text), dict(enumerate(bg)))

    def test_background_varies_between_cases(self):
        # every sink sees more than one source across the case list (select fields are reprogrammed)
        for n in range(16):
            self.assertGreater(len({r[4][n] for r in self.rows}), 3)

    def test_polarities_and_bel_inputs_come_from_the_tested_edge(self):
        self.assertEqual(O.init_word(0, False), "1010101010101010")
        self.assertEqual(O.init_word(1, True), "0011001100110011")
        for cid, e, *_ in self.rows:
            text = (self.out / f"{cid}.fasm").read_text()
            for k, x in enumerate("ABCD"):
                self.assertIn(f"X1Y1.{e}1END{k}.L{x}_I{k}\n", text)

    def test_position_rule_matches_assembler_encoding(self):
        """The predictor's mux position rule (incoming NESW, then BELs) == the assembler's select field."""
        base = F.assemble("X1Y1.A.INIT[15:0] = 'b0000000000000000\n", self.snap, None)["cfg"]
        for n in range(16):
            xors = []
            for pos, tok in enumerate(O.tokens_of(n)):
                text = f"X1Y1.{O.src_name(tok, n % 4)}.{O.sink_name(n)}\n"
                xors.append(F.assemble(text, self.snap, None)["cfg"] ^ base)
            low = min((x & -x).bit_length() - 1 for x in xors if x)
            for pos, x in enumerate(xors):
                self.assertEqual(x >> low, pos, (O.sink_name(n), pos))
                self.assertEqual(x & ((1 << low) - 1), 0)

    def test_predict_model(self):
        self.assertEqual(O.predict(self.rows, ("alias", "S1BEG2", "S1BEG2")), [])
        failing = O.predict(self.rows, ("swap", "N1BEG0", "3", "4"))     # BEL A <-> BEL B on N1BEG0
        self.assertIn("O_N0_A", failing)
        self.assertIn("O_N0_B", failing)
        # a swap of two positions never breaks a case whose N1BEG0 source is neither of them
        for cid, e, t, tok, bg in self.rows:
            if bg[0] not in "AB":
                self.assertNotIn(cid, failing)
        # a case whose N1BEG0 source is A or B fails, as A and B differ under the stimulus set
        for cid, e, t, tok, bg in self.rows:
            if bg[0] in "AB":
                self.assertIn(cid, failing)

    def test_determinism(self):
        with tempfile.TemporaryDirectory() as d:
            O.generate(d, SNAP_PATH)
            for cid, *_ in self.rows:
                self.assertEqual((Path(d) / f"{cid}.bin").read_bytes(), (self.out / f"{cid}.bin").read_bytes())


if __name__ == "__main__":
    unittest.main()
