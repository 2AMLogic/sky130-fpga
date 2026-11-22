"""Named cocotb port of sim/tb_logic_tile.v against the as-built gate-level
netlist layout/logic_tile.asbuilt.v (issue #359).

The Verilog bench sim/tb_logic_tile.v checks the tile-level wiring claims of
design/rtl/logic_tile.v in four observations, but `klt
functional-verification`'s Verilog-bench path reports one aggregate result
per run; the paired zero-delay vs SDF-annotated comparison #360 consumes
needs the four observations as four *named* verdicts, so this module ports
them one-to-one as cocotb tests:

  1. test_independent_lut_config            -- expected out = 4'b0110
  2. test_reset_with_all_enables_low        -- expected out = 4'b0000
  3. test_selective_capture                 -- expected out = 4'b0101
  4. test_reset_from_mixed_state_all_enables_high -- expected out = 4'b0000

Same stimulus, same expectations, same independence as the Verilog original:
each test initializes every input itself, and a checked output bit that
reads X or Z is a failure, not a don't-care.

Timing contract, identical in both runs of the pair (the values are inputs
to the #360 comparison, recorded in the timing-characterization record):

  CLOCK_PERIOD_NS = 20.0 -- the ratified STA row's 20 ns clk reference
                          period (ADR-0002/0003), a comfortable bound for
                          the annotated design (binding-corner SPEF WNS
                          15.2145 ns).
  SETTLE_NS       = 4.0  -- input settling interval and clock high time.
                          The combinational test samples after 8 ns.
                          Registered checks sample 20 ns after the rising
                          edge, when the full cycle has elapsed.

At the SDF typ corner, the largest single IOPATH delay is 0.477 ns
(mux4_2 A3->X, falling output). In registered mode, the rising clock
traverses the root buffer and one leaf buffer (0.089 + 0.092 ns). Adding
dfxtp_1 CLK->Q and mux2_2 A1->X gives 0.591 ns for a rising output
(0.181 + 0.293 + 0.117) and 0.693 ns for a fall (0.181 + 0.280 + 0.232).

Driven by flow/tile-functional-verification.sh through `klt
functional-verification` (klt 0.9.1) with USE_POWER_PINS and FUNCTIONAL
left undefined: the as-built netlist carries no supply pins and the cell
models keep their specify blocks, so the same models serve the zero-delay
and the SDF-annotated run. No timing claim is made by this bench alone --
see the record under measurements/timing-characterization/records/.
"""
import cocotb
from cocotb.triggers import Timer

CLOCK_PERIOD_NS = 20.0
SETTLE_NS = 4.0


def _in(dut):
    """The `in` port: `dut.in` is a Python syntax error, so go by name."""
    return getattr(dut, "in")


def _read_out(dut):
    """Return dut.out as an int, refusing X/Z on any checked bit."""
    bits = str(dut.out.value)
    bad = [i for i, ch in enumerate(reversed(bits)) if ch in "xXzZ"]
    assert not bad, f"out carries X/Z at bit(s) {bad}: {bits!r}"
    return int(bits, 2)


async def _init(dut):
    """Independent per-test initialization: every input driven by name."""
    dut.clk.value = 0
    dut.rst.value = 0
    dut.ce.value = 0b0000
    _in(dut).value = 0x0000
    dut.lut_init.value = 0
    dut.reg_sel.value = 0b0000
    await Timer(SETTLE_NS, unit="ns")


async def _capture_edge(dut):
    """Hold clk high for SETTLE_NS, then low until the caller samples at cycle end."""
    dut.clk.value = 1
    await Timer(SETTLE_NS, unit="ns")
    dut.clk.value = 0
    await Timer(CLOCK_PERIOD_NS - SETTLE_NS, unit="ns")


async def _reset_registers(dut):
    """reg_sel=1111, rst=1, ce=0000 for one edge; out must read 0000."""
    dut.reg_sel.value = 0b1111
    dut.rst.value = 1
    dut.ce.value = 0b0000
    await Timer(SETTLE_NS, unit="ns")
    await _capture_edge(dut)
    assert _read_out(dut) == 0b0000, "reset did not clear all four slice FFs"
    dut.rst.value = 0


@cocotb.test()
async def test_independent_lut_config(dut):
    """Four independent LUT configs, all combinational: slice0 always-0,
    slice1 always-1, slice2 passthrough of in[0], slice3 4-input XOR, every
    slice fed the same input pattern (index 3), so cross-slice bleed-through
    would break the hand-computed expectation 4'b0110."""
    await _init(dut)
    dut.lut_init.value = 0x6996AAAAFFFF0000
    dut.reg_sel.value = 0b0000
    dut.ce.value = 0b0000
    dut.rst.value = 0
    _in(dut).value = 0x3333  # 0011 to every slice: LUT index 3 each
    await Timer(2 * SETTLE_NS, unit="ns")
    assert _read_out(dut) == 0b0110, "independent per-slice combinational config"


@cocotb.test()
async def test_reset_with_all_enables_low(dut):
    """Shared synchronous reset with every clock enable low clears all four
    slice FFs on one edge (out = 4'b0000), including the never-clocked
    power-up X state."""
    await _init(dut)
    dut.lut_init.value = 0xFFFFFFFFFFFFFFFF
    _in(dut).value = 0x0000  # LUT output 1 at index 0 without reset
    await _reset_registers(dut)


@cocotb.test()
async def test_selective_capture(dut):
    """Per-slice clock enable is independent: after a reset, only slices 0
    and 2 (ce = 4'b0101) capture the LUT ones; 1 and 3 hold zero."""
    await _init(dut)
    dut.lut_init.value = 0xFFFFFFFFFFFFFFFF
    _in(dut).value = 0x0000
    await _reset_registers(dut)
    dut.ce.value = 0b0101
    await Timer(SETTLE_NS, unit="ns")
    await _capture_edge(dut)
    assert _read_out(dut) == 0b0101, "only enabled slices (0,2) captured"


@cocotb.test()
async def test_reset_from_mixed_state_all_enables_high(dut):
    """From the observed mixed state 4'b0101, asserting reset with every
    enable high (ce = 4'b1111) still clears all four FFs: reset beats
    capture, shared across slices."""
    await _init(dut)
    dut.lut_init.value = 0xFFFFFFFFFFFFFFFF
    _in(dut).value = 0x0000
    await _reset_registers(dut)
    dut.ce.value = 0b0101
    await Timer(SETTLE_NS, unit="ns")
    await _capture_edge(dut)
    assert _read_out(dut) == 0b0101, "could not establish the mixed state"
    dut.ce.value = 0b1111
    dut.rst.value = 1
    await Timer(SETTLE_NS, unit="ns")
    await _capture_edge(dut)
    assert _read_out(dut) == 0b0000, "shared reset cleared all slices even with ce=1111"
