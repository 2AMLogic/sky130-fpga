#!/usr/bin/env python3
"""Unit tests for flow/fasm_to_bitstream.py (issue #74). stdlib only; reads the
committed fixtures in sim/bitstream/, so it needs no mapping tool.

    python3 flow/test_fasm_to_bitstream.py
"""
import json
import random
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "sim" / "bitstream"


sys.path.insert(0, str(Path(__file__).resolve().parent))
from _modload import load_module as _load  # noqa: E402


F = _load("fasm_to_bitstream", REPO / "flow" / "fasm_to_bitstream.py")
C = _load("bitstream_corrupt", REPO / "sim" / "bitstream_corrupt.py")
SNAP = F.load_snapshot(FIX / "fabric_spec.json")
SPEC = SNAP["tile_specs"]["X1Y1"]
CB_OF_POS = {p: i for i, p in enumerate(SNAP["cb_pos"])}


def mapped(d):
    return json.loads((FIX / f"{d}.mapped.json").read_text())


def fasm(d):
    return (FIX / f"{d}.fasm").read_text()


def asm_bits(text):
    return F.assemble(text, SNAP, None)


def cfg_field(cfg, lo, width):
    return (cfg >> lo) & ((1 << width) - 1)


# ---- independent reference of the documented layout (design/README.md) -------
def ref_matrix_field(sink):
    """-> (cfg lo bit, width, source list) for a switch-matrix sink."""
    def trk(i):
        return [f"{d}1END{i}" for d in "NESW"]
    if sink[1:4] == "1BE":                      # track driver  N1BEG0..
        d = "NESW".index(sink[0]); i = int(sink[-1])
        srcs = [t for t in trk(i) if not t.startswith(sink[0])] + [f"L{b}_O" for b in "ABCD"]
        return 68 + 3 * (4 * d + i), 3, srcs
    if sink[0] == "L" and "_I" in sink:         # LA_I0..
        b = "ABCD".index(sink[1]); p = int(sink[-1])
        return 68 + 48 + 2 * (4 * b + p), 2, trk(p)
    if sink == "J_SR_BEG0":
        return 68 + 80, 2, trk(0)
    if sink.startswith("J_EN_BEG"):
        n = int(sink[-1])
        return 68 + 82 + 2 * n, 2, trk(n)
    raise KeyError(sink)


class FixtureTests(unittest.TestCase):
    def test_committed_fixtures_reproduce(self):
        for d in ("top_io", "top_reg", "top_io_alias", "top_io_unused"):
            m = mapped(d)
            a = F.assemble(fasm(d), SNAP, m)
            self.assertEqual((FIX / f"{d}.bin").read_bytes(), F.pack(a["positions"], SNAP))
            self.assertEqual((FIX / f"{d}.wiring").read_text(), F.manifest_text(a, SNAP, m))
            self.assertEqual((FIX / f"{d}.cfg").read_text(), f"{a['cfg']:040x}\n")
            cfg, _ = F.decode((FIX / f"{d}.bin").read_bytes(), SNAP)
            self.assertEqual(cfg, a["cfg"])

    def test_map_file_matches_snapshot(self):
        self.assertEqual((FIX / "logic4_configmem.map").read_text(), F.map_text(SNAP))

    def test_pad_only_omissions_are_listed(self):
        for d in ("top_io", "top_reg"):
            a = F.assemble(fasm(d), SNAP, mapped(d))
            self.assertEqual(len(a["pad_lines"]), 6)
            for t, s, dd in a["pad_lines"]:
                self.assertIn(t, ("X1Y0", "X1Y2"))
                self.assertTrue(s.startswith("IO") or dd.startswith("IO"))

    def test_placement_comes_from_mapping_output(self):
        # the two fixtures place their BELs differently (A+D vs A+C)
        self.assertEqual(F.assemble(fasm("top_io"), SNAP, mapped("top_io"))["bel_used"], [0, 3])
        self.assertEqual(F.assemble(fasm("top_reg"), SNAP, mapped("top_reg"))["bel_used"], [0, 2])


class FabricTests(unittest.TestCase):
    def test_three_tiles_keep_independent_bits_in_row_major_order(self):
        # A non-square core. Repeated frame positions and BEL names refer
        # to different physical latches in each column.
        tiles = ["X1Y1", "X2Y1", "X3Y1"]
        snap = dict(SNAP, grid=[5, 3], tile_map=dict.fromkeys(reversed(tiles), "LOGIC4"),
                    tile_specs=dict.fromkeys(tiles, SPEC))
        text = "X1Y1.A.INIT[0]\nX2Y1.A.INIT[1]\nX3Y1.A.INIT[2]\n"
        asm = F.assemble(text, snap, None)
        expected = sum(1 << (i * F.CFG_BITS + i) for i in range(3))
        self.assertEqual(asm["cfg"], expected)
        self.assertEqual(F.decode(F.pack(asm["positions"], snap), snap)[0], expected)

    def test_reference_2x2_decode_and_loader_map(self):
        # The generated ConfigMem is shared by all instances of LOGIC4.
        # Decode this real bit_gen stream using just the four coordinates,
        # frame constants and single-tile map, independent of the pip model.
        tiles = ("X1Y1", "X2Y1", "X1Y2", "X2Y2")
        snap = dict(SNAP, grid=[4, 4], tile_map=dict.fromkeys(tiles, "LOGIC4"))
        fix = FIX / "fabric_2x2"
        data = (fix / "cross_tile.bin").read_bytes()
        cfg, positions = F.decode(data, snap)
        self.assertEqual(F.cfg_hex(cfg, snap) + "\n", (fix / "cross_tile.cfg").read_text())
        self.assertEqual(F.pack(dict.fromkeys(positions, 1), snap), data)
        rows = [tuple(map(int, line.split())) for line in F.map_text(snap).splitlines()]
        for i, (x, y) in enumerate(((1, 1), (2, 1), (1, 2), (2, 2))):
            self.assertEqual(rows[i * 158:(i + 1) * 158],
                             [(x, y, i * 158 + cb, pos) for cb, pos in enumerate(SNAP["cb_pos"])])
        self.assertEqual(len(rows), 4 * 158)

    def test_mapped_bel_and_wire_hop_are_tile_specific(self):
        # Two instances use BEL A with different truth tables. The source and
        # destination of the inter-tile hop must be wired on their own tiles.
        src, dst = "X1Y1", "X2Y1"
        snap = dict(SNAP, grid=[4, 3], tile_map=dict.fromkeys((src, dst), "LOGIC4"),
                    pips=[(src, "E1BEG0", dst, "E1END0")], tile_specs={src: SPEC, dst: SPEC})
        pips = [f"{src}.LA_O.E1BEG0", f"{src}.E1BEG0.E1END0", f"{dst}.E1END0.LA_I0"]
        text = "\n".join([f"{src}.A.INIT", f"{dst}.A.INIT[1]", *pips])
        cells = [dict(type="lut4_ff_bel", bel=f"{t}/A", init=init, ff="0")
                 for t, init in ((src, "01"), (dst, "10"))]
        mapped = dict(cells=cells, nets=[dict(pips=pips)], ports=[])
        asm = F.assemble(text, snap, mapped)
        self.assertIn("LINK X1Y1 E1BEG0 X2Y1 E1END0\n", F.manifest_text(asm, snap, mapped))
        with self.assertRaisesRegex(F.AsmError, "orphan wire hop"):
            F.assemble(text.replace(pips[-1], ""), snap, mapped)
        with self.assertRaisesRegex(F.AsmError, "BEL X2Y1/A"):
            F.assemble(text.replace(f"{dst}.A.INIT[1]", f"{dst}.A.INIT"), snap, mapped)


class LayoutTests(unittest.TestCase):
    def test_round_trip_every_config_bit(self):
        for cb in range(F.CFG_BITS):
            pos = SNAP["cb_pos"][cb]
            data = F.pack({pos: 1}, SNAP)
            cfg, bits = F.decode(data, SNAP)
            self.assertEqual(cfg, 1 << cb)
            self.assertEqual(bits, {pos})

    def test_round_trip_random_vectors(self):
        rnd = random.Random(74)
        for _ in range(50):
            cfg = rnd.getrandbits(F.CFG_BITS)
            pos = {SNAP["cb_pos"][cb]: 1 for cb in range(F.CFG_BITS) if cfg >> cb & 1}
            self.assertEqual(F.decode(F.pack(pos, SNAP), SNAP)[0], cfg)

    def test_configmem_positions_are_a_bijection_into_five_frames(self):
        self.assertEqual(len(set(SNAP["cb_pos"])), F.CFG_BITS)
        self.assertEqual({p // 32 for p in SNAP["cb_pos"]}, {0, 1, 2, 3, 4})

    def test_every_bel_field_lands_where_the_readme_says(self):
        for i, bel in enumerate("ABCD"):
            for j in range(16):
                key = f"{bel}.INIT[{j}]" if j else f"{bel}.INIT"
                self.assertEqual({CB_OF_POS[p] for p in SPEC[key]}, {17 * i + j}, key)
            self.assertEqual({CB_OF_POS[p] for p in SPEC[f"{bel}.FF"]}, {17 * i + 16})

    def test_bel_features_assemble_to_documented_cfg_for_every_bel(self):
        for i, bel in enumerate("ABCD"):
            pattern = 0xA5C3 ^ (0x1111 * i)
            text = f"X1Y1.{bel}.INIT[15:0] = 'b{pattern:016b}\nX1Y1.{bel}.FF\n"
            a = asm_bits(text)
            self.assertEqual(cfg_field(a["cfg"], 17 * i, 17), pattern | 1 << 16)
            self.assertEqual(a["cfg"] >> (17 * i + 17), 0)
            self.assertEqual(a["cfg"] & ((1 << 17 * i) - 1), 0)
            self.assertEqual(a["bel_used"], [i])
            self.assertEqual(F.decode(F.pack(a["positions"], SNAP), SNAP)[0], a["cfg"])

    def test_every_matrix_feature_matches_the_documented_select_encoding(self):
        n = 0
        for key, bits in SPEC.items():
            if not bits or key[0] in "ABCD" and key[1] == ".":
                continue
            src, sink = key.split(".")
            lo, width, srcs = ref_matrix_field(sink)
            a = asm_bits(f"X1Y1.{key}\n")
            self.assertEqual(a["cfg"] & ~(((1 << width) - 1) << lo), 0, key)
            self.assertEqual(cfg_field(a["cfg"], lo, width), srcs.index(src), key)
            self.assertLess(srcs.index(src), 1 << width)
            n += 1
        self.assertEqual(n, 16 * 7 + 16 * 4 + 4 + 4 * 4)   # track drivers, LUT inputs, J_SR, J_EN

    def test_default_select_is_all_zero(self):
        self.assertEqual(asm_bits("")["cfg"], 0)


# Same-driver redundancy evidence for the +mutate sweep (issue #342). The
# fixtures reproduce the measured curator cases: an alias loop (both S1BEG1
# encodings resolve to LA_O), and the negative control whose extra branch is
# unused (its W1BEG2 flips stay unexplained).
class RedundancyTests(unittest.TestCase):
    ALIAS_BRANCH = ("X1Y1.LA_O.W1BEG2\nX1Y1.W1BEG2.W1END2\nX0Y1.W1END2.E1BEG1\n"
                    "X0Y1.E1BEG1.E1END1\n")

    def test_baseline_fixtures_prove_nothing(self):
        for d in ("top_io", "top_reg"):
            self.assertEqual(F.assemble(fasm(d), SNAP, mapped(d))["red"], [])

    def test_alias_fixture_proves_exactly_the_one_flip(self):
        a = F.assemble(fasm("top_io_alias"), SNAP, mapped("top_io_alias"))
        self.assertEqual(a["red"], [(96, "S1BEG1", "E1END1", "LA_O", "X1Y1.LA_O")])
        self.assertIn("RED 96 S1BEG1 E1END1 LA_O X1Y1.LA_O\n", (FIX / "top_io_alias.wiring").read_text())

    def test_unused_branch_proves_only_the_alias_flip(self):
        a = F.assemble(fasm("top_io_unused"), SNAP, mapped("top_io_unused"))
        self.assertEqual(a["red"], [(96, "S1BEG1", "LA_O", "E1END1", "X1Y1.LA_O")])

    def fragment(self, pips):
        return F.assemble("X1Y1.A.INIT[15:0] = 'b" + "0" * 16 + "\n" + pips, SNAP, None)["red"]

    def test_flip_to_undriven_or_absent_input_is_not_proven(self):
        # S1BEG1 selects LA_O directly; every flipped encoding is undriven
        # (W1END1/E1END1) or the mux-drives-0 encoding 7
        self.assertEqual(self.fragment("X1Y1.LA_O.S1BEG1\n"), [])

    def test_flip_to_a_different_driver_is_not_proven(self):
        # the loop-back into E1END1 is driven by LB_O, not LA_O
        pips = ("X1Y1.LB_O.W1BEG2\nX1Y1.W1BEG2.W1END2\nX0Y1.W1END2.E1BEG1\n"
                "X0Y1.E1BEG1.E1END1\nX1Y1.E1END1.S1BEG1\n")
        self.assertEqual(self.fragment(pips), [])

    def test_flip_to_the_same_physical_driver_is_proven(self):
        # the measured alias case, as a minimal fragment: E1END1 and LA_O both
        # resolve to X1Y1.LA_O through the CAP loop-back
        pips = (self.ALIAS_BRANCH + "X1Y1.E1END1.S1BEG1\n")
        self.assertEqual(self.fragment(pips),
                         [(96, "S1BEG1", "E1END1", "LA_O", "X1Y1.LA_O")])

    def test_cyclic_route_is_not_proven(self):
        # S1BEG1 <- N1END1 <- CAP_S loop <- S1BEG2 <- N1END2 <- CAP_S loop <- S1BEG1:
        # both inputs resolve into a configured cycle, so no flip is provable
        pips = ("X1Y1.N1END1.S1BEG1\nX1Y1.S1BEG1.S1END1\nX1Y2.S1END1.N1BEG2\nX1Y2.N1BEG2.N1END2\n"
                "X1Y1.N1END2.S1BEG2\nX1Y1.S1BEG2.S1END2\nX1Y2.S1END2.N1BEG1\nX1Y2.N1BEG1.N1END1\n")
        self.assertEqual(self.fragment(pips), [])

    def test_flip_that_creates_a_cycle_is_not_proven(self):
        # W1BEG1 selects LA_O; its flipped input E1END1 resolves to LA_O only
        # by walking *through* the mux being flipped. With the flipped select
        # in effect the branch is the cycle W1BEG1 -> E1END2 -> W1BEG2 ->
        # E1END1 -> W1BEG1, cut off from LA_O: cfg[108] must stay SURVIVED.
        # The W1BEG2 flip (cfg[111]) keeps its genuine same-driver proof: its
        # chain E1END2 -> ... -> LA_O never crosses the mux it flips.
        pips = ("X1Y1.LA_O.W1BEG1\nX1Y1.W1BEG1.W1END1\nX0Y1.W1END1.E1BEG2\n"
                "X0Y1.E1BEG2.E1END2\nX1Y1.E1END2.W1BEG2\nX1Y1.W1BEG2.W1END2\n"
                "X0Y1.W1END2.E1BEG1\nX0Y1.E1BEG1.E1END1\n")
        self.assertEqual(self.fragment(pips),
                         [(111, "W1BEG2", "E1END2", "LA_O", "X1Y1.LA_O")])


class AssemblerRejectTests(unittest.TestCase):
    def rej(self, text, mapped_name=None, exc=F.AsmError):
        m = mapped(mapped_name) if mapped_name else None
        with self.assertRaises(exc):
            F.assemble(text, SNAP, m)

    def test_unknown_logic_feature(self):
        self.rej("X1Y1.A.BOGUS\n")
        self.rej("X1Y1.E.INIT[3]\n")
        self.rej("X1Y1.N1END0.LA_I1\n")           # wrong same-index source
        self.rej("X1Y1.LA_O.LA_I0\n")             # no local feedback in the matrix

    def test_out_of_range_selection(self):
        self.rej("X1Y1.A.INIT[16:0] = 'b11111111111111111\n")
        self.rej("X1Y1.A.INIT[16] = 1\n")
        self.rej("X1Y1.N1END4.LA_I0\n")

    def test_conflicting_assignment(self):
        self.rej("X1Y1.N1END0.LA_I0\nX1Y1.E1END0.LA_I0\n")
        self.rej("X1Y1.S1END0.LA_I0\nX1Y1.W1END0.LA_I0\n")

    def test_duplicate_feature(self):
        self.rej("X1Y1.A.FF\nX1Y1.A.FF\n")
        self.rej("X1Y1.A.INIT[3:0] = 'b0001\nX1Y1.A.INIT[1] = 1\n")

    def test_malformed_lines(self):
        for bad in ("X1Y1\n", "garbage\n", "X1Y1.A.INIT[3:0] = 'b01\n", "X1Y1.A.INIT[3:0] = 5\n",
                    "X1Y1.A.INIT[3:0]\n", "X1Y1.A.INIT[x] = 1\n", "X1Y1.A.FF # trailing comment\n",
                    "X1Y1.A.FF = 7\n", "X1Y1.A.INIT = 'b1\n"):
            self.rej(bad)

    def test_unconfigured_or_unknown_tiles(self):
        self.rej("X0Y0.N1END0.S1BEG0\n")          # NULL tile
        self.rej("X9Y9.A.FF\n")

    def test_pad_whitelist_is_exact(self):
        asm_bits("X1Y0.IOA_O.S1BEG0\n")                    # overlay pad pip: accepted, zero bits
        asm_bits("X1Y2.S1END3.IOD_I\n")
        self.rej("X1Y1.IOA_O.S1BEG0\n")                    # pad on the logic tile
        self.rej("X1Y0.IOE_O.S1BEG0\n")                    # no such pad
        self.rej("X1Y0.IOA_O.N1BEG0\n")                    # wrong side for CAP_N
        self.rej("X0Y1.IOA_O.E1BEG0\n")                    # CAP_W has no pads
        self.rej("X1Y0.IOA_O.S1BEG0[1:0] = 'b11\n")        # pad features carry no bits
        self.rej("X1Y0.IOA_O.S1BEG0\nX1Y0.IOA_O.S1BEG0\n")  # duplicate

    def test_netlist_cross_checks(self):
        good = fasm("top_reg")
        m = mapped("top_reg")
        F.assemble(good, SNAP, m)
        # a pad pip removed (the netlist routes it)
        self.rej("\n".join(l for l in good.splitlines() if "IOB_O" not in l) + "\n", "top_reg")
        # LUT contents differing from the placed cell
        self.rej(good.replace("'b1001011010010110", "'b1001011010010111"), "top_reg")
        # FF flag dropped
        self.rej("\n".join(l for l in good.splitlines() if not l.endswith(".A.FF")) + "\n", "top_reg")
        # a wire hop that no path uses
        self.rej(good + "X1Y1.E1BEG0.E1END0\n", "top_reg")
        # a pip the router never chose
        self.rej(good + "X1Y1.N1END1.LB_I1\n", "top_reg")
        # BEL present in FASM but not in the netlist
        self.rej(good + "X1Y1.B.FF\n", "top_reg")
        # port directions: swap the two designs' netlists
        self.rej(good, "top_io")

    def test_disabled_zero_bit_pips_are_rejected(self):
        # an explicit `= 0` on a zero-bit pip disables it; it must never be
        # traced as an active route (judge repro on PR #114)
        good = fasm("top_reg")
        for line in ("X1Y2.IOB_O.N1BEG3", "X1Y0.IOB_O.S1BEG1",      # pad pips
                     "X1Y2.N1BEG3.N1END3", "X2Y1.E1END3.W1BEG0",    # CAP wire pips
                     "X0Y1.W1END3.E1BEG0"):
            self.assertIn(line + "\n", good)
            bad = good.replace(line + "\n", line + " = 0\n")
            self.rej(bad, "top_reg")                    # full assembly + cross-check
            self.rej(bad)                               # bit assembly alone
        self.rej("X1Y0.IOA_O.S1BEG0 = 0\n")
        self.rej("X1Y0.S1BEG0.S1END0 = 0\n")
        # `= 1` is the explicit spelling of the bare (enabled) feature
        a = F.assemble(good.replace("X1Y2.IOB_O.N1BEG3\n", "X1Y2.IOB_O.N1BEG3 = 1\n")
                       .replace("X2Y1.E1END3.W1BEG0\n", "X2Y1.E1END3.W1BEG0 = 1\n"),
                       SNAP, mapped("top_reg"))
        self.assertEqual(a["cfg"], F.assemble(good, SNAP, mapped("top_reg"))["cfg"])

    def test_snapshot_consistency_errors(self):
        text = (FIX / "logic4_configmem.map").read_text()
        self.assertEqual(len(text.splitlines()), F.CFG_BITS)
        bad = "assign ConfigBits[0] = Emulate_Bitstream[1];\n"
        with self.assertRaises(F.AsmError):
            F.parse_configmem(bad)


class DecoderRejectTests(unittest.TestCase):
    def test_every_malformed_variant_is_rejected(self):
        good = (FIX / "top_reg.bin").read_bytes()
        F.decode(good, SNAP)
        variants = C.variants(good)
        self.assertGreaterEqual(len(variants), 12)
        for name, data in variants.items():
            with self.assertRaises(F.BitstreamError, msg=name):
                F.decode(data, SNAP)

    def test_every_truncation_length_is_rejected(self):
        good = (FIX / "top_io.bin").read_bytes()
        for n in range(0, len(good), 7):
            with self.assertRaises(F.BitstreamError, msg=n):
                F.decode(good[:n], SNAP)


class PerturbationTests(unittest.TestCase):
    def test_perturbed_stream_changes_exactly_the_flipped_bit(self):
        good = (FIX / "top_reg.bin").read_bytes()
        cfg, bits = F.decode(good, SNAP)
        pos = SNAP["cb_pos"][17 * 2 + 1]            # BEL C INIT[1]
        flipped = F.pack({p: 1 for p in bits ^ {pos}}, SNAP)
        cfg2, _ = F.decode(flipped, SNAP)
        self.assertEqual(cfg ^ cfg2, 1 << (17 * 2 + 1))


if __name__ == "__main__":
    unittest.main(verbosity=1)
