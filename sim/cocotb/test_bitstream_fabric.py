"""Bitstream-level cocotb regression of the composed LOGIC4 tile (issue #228).

Run by `klt functional-verification` (flow/functional-verification.sh); its
results.xml is the source of the T1 item-5 functional-verification envelope.

What it does: the committed FABulous-format frame streams
(sim/bitstream/top_io.bin, top_reg.bin -- the pinned yosys/nextpnr/bit_gen
flow's output) are read by the repository's strict stream decoder
(flow/fasm_to_bitstream.py decode) into the 158-bit `cfg` of
design/rtl/logic_tile_routed.v, the pad/loopback wiring comes from the
committed .wiring manifests, and the mapped design's function is checked
against oracles written here independently of the assembler. No LUT or
switch-matrix constant is hand-written. This is the cocotb counterpart of
sim/tb_logic_tile_bitstream.v for the `comb` and `reg` designs (same
oracles, same wiring semantics); it does not repeat the +mutate
perturbation sweep or the Verilog-side loader checks.

Scope: G1 harness fabric as implemented, zero-delay RTL. No timing, no
inter-tile routing (see sim/README.md).
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "flow"))
import fasm_to_bitstream as f2b  # noqa: E402

BS = REPO / "sim" / "bitstream"
SNAP = f2b.load_snapshot(BS / "fabric_spec.json")
IN_SLOT = {"a": 0, "b": 1, "c": 2, "d": 3, "en": 4, "rst": 5, "e": 6, "f": 7}
OUT_SLOT = {"y": 0, "w": 1, "q": 2, "v": 3, "z": 4}


def read_wiring(design):
    ins, outs, loops = {}, {}, []
    for line in (BS / f"{design}.wiring").read_text().split("\n"):
        t = line.split()
        if not t:
            continue
        if t[0] == "IN":
            ins[t[1]] = 4 * int(t[2]) + int(t[3])
        elif t[0] == "OUT":
            outs[t[1]] = 4 * int(t[2]) + int(t[3])
        elif t[0] == "LOOP":
            loops.append((4 * int(t[1]) + int(t[2]), 4 * int(t[3]) + int(t[4])))
    return ins, outs, loops


class Harness:
    """Pads -> input tracks, CAP loopbacks (output track -> input track)."""

    def __init__(self, dut, design, unused=0):
        self.dut = dut
        self.ins, self.outs, self.loops = read_wiring(design)
        self.tin = [(unused >> i) & 1 for i in range(16)]
        self.loop_dst = {dst: src for src, dst in self.loops}
        for dst in self.loop_dst:
            self.tin[dst] = 0
        self.unused = unused
        data = (BS / f"{design}.bin").read_bytes()
        self.cfg, _ = f2b.decode(data, SNAP)
        dut.cfg.value = self.cfg
        dut.clk.value = 0

    def _drive(self):
        v = 0
        for i, b in enumerate(self.tin):
            v |= (b & 1) << i
        self.dut.n_in.value = v & 0xF
        self.dut.e_in.value = (v >> 4) & 0xF
        self.dut.s_in.value = (v >> 8) & 0xF
        self.dut.w_in.value = (v >> 12) & 0xF

    def tout(self):
        """(value, x_mask): X/Z bits (an unclocked flop before its first
        edge) read as 0 in value and are flagged in x_mask."""
        o = x = 0
        for k, p in enumerate(("n_out", "e_out", "s_out", "w_out")):
            bits = str(getattr(self.dut, p).value)
            for i, ch in enumerate(reversed(bits)):
                if ch == "1":
                    o |= 1 << (4 * k + i)
                elif ch != "0":
                    x |= 1 << (4 * k + i)
        return o, x

    async def settle(self):
        for _ in range(16):
            self._drive()
            await Timer(1, unit="ns")
            o, _ = self.tout()
            changed = False
            for dst, src in self.loop_dst.items():
                nb = (o >> src) & 1
                if self.tin[dst] != nb:
                    self.tin[dst] = nb
                    changed = True
            if not changed:
                return
        raise AssertionError("loopback network did not settle")

    async def set_pads(self, **pads):
        for name, val in pads.items():
            self.tin[self.ins[name]] = int(val)
        await self.settle()

    def out(self, name):
        o, x = self.tout()
        bit = self.outs[name]
        assert not (x >> bit) & 1, f"output {name} is X/Z"
        return (o >> bit) & 1

    async def pulse(self):
        self.dut.clk.value = 1
        await Timer(5, unit="ns")
        await self.settle()
        self.dut.clk.value = 0
        await Timer(5, unit="ns")
        await self.settle()


@cocotb.test()
async def test_bitstream_decodes_to_recorded_cfg(dut):
    """The stream decoder reproduces the recorded 158-bit vectors."""
    for design in ("top_io", "top_reg"):
        cfg, _ = f2b.decode((BS / f"{design}.bin").read_bytes(), SNAP)
        recorded = int((BS / f"{design}.cfg").read_text().strip(), 16)
        assert cfg == recorded, f"{design}: decoded cfg != recorded cfg"


@cocotb.test()
async def test_malformed_bitstreams_rejected(dut):
    """Loader refuses truncated, bad-sync and trailing-data streams."""
    good = (BS / "top_io.bin").read_bytes()
    bad = {
        "truncated": good[:-4],
        "bad sync": b"\xff" + good[1:],
        "trailing data": good + b"\x00",
        "empty": b"",
    }
    for what, data in bad.items():
        try:
            f2b.decode(data, SNAP)
        except f2b.BitstreamError:
            continue
        raise AssertionError(f"malformed stream accepted: {what}")


@cocotb.test()
async def test_comb_design_truth_table(dut):
    """top_io.bin: y = a^b^c^d, w = a&b&c over all 16 vectors, under
    several fixed patterns on the input tracks nothing is routed to."""
    for unused in (0x0000, 0xFFFF, 0xAAAA, 0x5555):
        h = Harness(dut, "top_io", unused)
        await h.settle()
        for v in range(16):
            a, b, c, d = (v >> 0) & 1, (v >> 1) & 1, (v >> 2) & 1, (v >> 3) & 1
            await h.set_pads(a=a, b=b, c=c, d=d)
            assert h.out("y") == a ^ b ^ c ^ d, f"y wrong at v={v} unused={unused:#06x}"
            assert h.out("w") == (a & b & c), f"w wrong at v={v} unused={unused:#06x}"


@cocotb.test()
async def test_reg_design_exhaustive(dut):
    """top_reg.bin: q <= rst ? 0 : en ? a^b^c : q, from both start states
    over all 32 (rst,en,c,b,a) vectors; q holds until the clock edge."""
    h = Harness(dut, "top_reg")
    await h.settle()
    for s in (0, 1):
        for v in range(32):
            if s == 0:
                await h.set_pads(a=1, b=1, c=1, en=0, rst=1)
            else:
                await h.set_pads(a=1, b=0, c=0, en=1, rst=0)
            await h.pulse()
            assert h.out("q") == s, "could not establish start state"
            a, b, c, en, rst = (v >> 0) & 1, (v >> 1) & 1, (v >> 2) & 1, (v >> 3) & 1, (v >> 4) & 1
            await h.set_pads(a=a, b=b, c=c, en=en, rst=rst)
            assert h.out("q") == s, "q changed before the clock edge"
            await h.pulse()
            exp = 0 if rst else (a ^ b ^ c) if en else s
            assert h.out("q") == exp, f"s={s} v={v:#04x}: q={h.out('q')} expected {exp}"


@cocotb.test()
async def test_reg_design_directed_sequence(dut):
    """capture, hold, reset with en=0, capture, reset beats enable."""
    h = Harness(dut, "top_reg")
    await h.settle()
    await h.set_pads(rst=1, en=0)
    await h.pulse()
    assert h.out("q") == 0
    await h.set_pads(rst=0, en=1, a=1, b=1, c=1)
    await h.pulse()
    assert h.out("q") == 1
    await h.set_pads(en=0, a=0, b=0, c=0)
    await h.pulse()
    await h.pulse()
    assert h.out("q") == 1, "hold with en=0"
    await h.set_pads(rst=1)
    await h.pulse()
    assert h.out("q") == 0, "reset with en=0"
    await h.set_pads(rst=0, en=1, a=1)
    await h.pulse()
    assert h.out("q") == 1, "capture after reset"
    await h.set_pads(en=1, rst=1, a=1)
    await h.pulse()
    assert h.out("q") == 0, "reset beats enable and data"


@cocotb.test()
async def test_reg_design_random_sequence(dut):
    """300 seeded-random cycles against an independent reference register."""
    rng = random.Random(0x228)
    h = Harness(dut, "top_reg")
    await h.settle()
    ref = 0
    await h.set_pads(rst=1, en=0)
    await h.pulse()
    for _ in range(300):
        a, b, c, en = (rng.getrandbits(1) for _ in range(4))
        rst = 1 if rng.randrange(8) == 0 else 0
        await h.set_pads(a=a, b=b, c=c, en=en, rst=rst)
        assert h.out("q") == ref, "q before edge"
        await h.pulse()
        if rst:
            ref = 0
        elif en:
            ref = a ^ b ^ c
        assert h.out("q") == ref, "q after edge"
