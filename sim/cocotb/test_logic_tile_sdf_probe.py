"""Settle-time probe for the paired zero-delay vs SDF-annotated logic_tile run
(issue #382).

flow/tile-functional-verification.sh runs the four named checks of
sim/cocotb/test_logic_tile.py twice against layout/logic_tile.asbuilt.v --
once at zero delay, once with the committed
measurements/timing-characterization/logic_tile_route.sdf back-annotated --
and both legs report the same 4/4 passes: nothing in that bench observes a
delay, so a toolchain change that made the annotation a silent no-op (zero
arcs applied, `environment.sdf.annotated` still true) would leave the
committed envelopes byte-identical. This module is the missing observation.

It repeats two of the bench's stimuli and watches `out` across them instead
of sampling once at the end of a long settle:

  test_probe_registered_settle      the posedge of test_selective_capture
                                    (ce = 0101 captures ones): out 0000 -> 0101
  test_probe_combinational_settle   the input change of
                                    test_independent_lut_config: out 0010 -> 0110

After each stimulus `out` is read every POLL_STEP_PS for the whole
OBSERVE_NS window, and the settle time is the first poll after the last one
that read anything other than the expected value -- so a glitch through the
expected value cannot be mistaken for settling. Each test prints one line:

    SETTLE_PROBE registered_ns=<t> poll_step_ps=<p>
    SETTLE_PROBE combinational_ns=<t> poll_step_ps=<p>

`<t>` is that poll's offset from the stimulus in ns (poll index + 1, times
the step, two decimals) -- a grid reading, not a simulator-clock one, and
quantised upwards: the annotated registered path (0.591 ns typ, see
test_logic_tile.py) reads 0.60.

The tests assert only functional correctness: `out` must read the expected
value at the end of the window, and a bit that reads X or Z at any poll is a
failure, never "not settled yet". They therefore pass on BOTH legs; the
zero-delay leg reports 0.01 ns (the first poll -- the transition is a delta
cycle) and the annotated leg something later. Which leg is which, and the
requirement that the annotated leg settle later, belong to the harness
(flow/tile_sdf_probe_gate.py): nothing here knows the leg, and no timing
claim is made -- this observes that annotation took effect, it does not
characterise timing.
"""
import cocotb
from cocotb.triggers import Timer

CLOCK_PERIOD_NS = 20.0   # identical to sim/cocotb/test_logic_tile.py
SETTLE_NS = 4.0          # identical to sim/cocotb/test_logic_tile.py
POLL_STEP_PS = 10
OBSERVE_NS = 2.0         # 200 polls; the longest typ path in the tile is 0.693 ns


def _in(dut):
    """The `in` port: `dut.in` is a Python syntax error, so go by name."""
    return getattr(dut, "in")


def _read_out(dut):
    """Return dut.out as an int, refusing X/Z on any bit."""
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


async def _reset_registers(dut):
    """reg_sel=1111, rst=1, ce=0000 for one edge; out must read 0000."""
    dut.reg_sel.value = 0b1111
    dut.rst.value = 1
    dut.ce.value = 0b0000
    await Timer(SETTLE_NS, unit="ns")
    dut.clk.value = 1
    await Timer(SETTLE_NS, unit="ns")
    dut.clk.value = 0
    await Timer(CLOCK_PERIOD_NS - SETTLE_NS, unit="ns")
    assert _read_out(dut) == 0b0000, "reset did not clear all four slice FFs"
    dut.rst.value = 0


async def _observe(dut, expected, what):
    """Poll out every POLL_STEP_PS for OBSERVE_NS; return the settle time in ns.

    Called immediately after the stimulus. The settle time is the first poll
    after the last one that read anything but `expected`; out must read
    `expected` at the end of the window.
    """
    last_off = -1
    polls = int(round(OBSERVE_NS * 1000 / POLL_STEP_PS))
    for i in range(polls):
        await Timer(POLL_STEP_PS, unit="ps")
        if _read_out(dut) != expected:
            last_off = i
    assert last_off < polls - 1, (
        f"{what}: out did not settle to {expected:04b} within {OBSERVE_NS} ns")
    return (last_off + 2) * POLL_STEP_PS / 1000.0


def _report(kind, settle_ns):
    print(f"SETTLE_PROBE {kind}_ns={settle_ns:.2f} poll_step_ps={POLL_STEP_PS}",
          flush=True)


@cocotb.test()
async def test_probe_registered_settle(dut):
    """After a reset, ce = 4'b0101 captures the LUT ones on the next posedge:
    out 0000 -> 0101. Reports when out first reads 0101 after the edge."""
    await _init(dut)
    dut.lut_init.value = 0xFFFFFFFFFFFFFFFF
    _in(dut).value = 0x0000
    await _reset_registers(dut)
    dut.ce.value = 0b0101
    await Timer(SETTLE_NS, unit="ns")
    assert _read_out(dut) == 0b0000, "registers did not hold the reset value"
    dut.clk.value = 1
    settle_ns = await _observe(dut, 0b0101, "registered")
    # Complete the bench's clock waveform: high for SETTLE_NS, then low.
    await Timer(SETTLE_NS - OBSERVE_NS, unit="ns")
    dut.clk.value = 0
    await Timer(CLOCK_PERIOD_NS - SETTLE_NS, unit="ns")
    assert _read_out(dut) == 0b0101, "only enabled slices (0,2) captured"
    _report("registered", settle_ns)


@cocotb.test()
async def test_probe_combinational_settle(dut):
    """All four slices combinational with test_independent_lut_config's LUT
    configs (slice0 always-0, slice1 always-1, slice2 passthrough of in[0],
    slice3 4-input XOR): changing in from 0x0000 to 0x3333 takes out from
    0010 to 0110 -- only slice 2's passthrough bit rises. Reports when out
    first reads 0110 after the input change."""
    await _init(dut)
    dut.lut_init.value = 0x6996AAAAFFFF0000
    dut.reg_sel.value = 0b0000
    dut.ce.value = 0b0000
    dut.rst.value = 0
    _in(dut).value = 0x0000  # LUT index 0 each: only the always-1 slice reads 1
    await Timer(2 * SETTLE_NS, unit="ns")
    assert _read_out(dut) == 0b0010, "LUT index-0 state is not 4'b0010"
    _in(dut).value = 0x3333  # 0011 to every slice: LUT index 3 each
    settle_ns = await _observe(dut, 0b0110, "combinational")
    await Timer(2 * SETTLE_NS - OBSERVE_NS, unit="ns")
    assert _read_out(dut) == 0b0110, "independent per-slice combinational config"
    _report("combinational", settle_ns)
