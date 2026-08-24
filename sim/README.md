# sim

Verification evidence — bitstream-level testbenches + results.

## Current coverage (BEL-level, T1 item 1)

The first design sources landed here are BEL-level RTL testbenches for the
tile's LUT4 + output-FF slice (`design/rtl/lut4_slice.v`,
`design/rtl/logic_tile.v`), per `spec/tile-spec.md`'s "LUT count per tile"
and "FF arrangement" sections. This is BEL-level verification only — no
switch matrix, no FABulous-style tile/fabric description, no bitstream-level
fabric test yet (that is `spec/framework-gaps.md` item G5, a separate,
larger follow-on).

| Testbench | Exercises | RTL under test |
|---|---|---|
| `tb_lut4_slice.v` | LUT4 truth-table programmability (all-0/all-1/mixed configs swept across all 16 input combinations), registered vs. combinational output select, per-slice clock-enable gating, synchronous reset (including reset asserted while clock-enable is active), and that combinational passthrough never latches regardless of clock activity | `design/rtl/lut4_slice.v` |
| `tb_logic_tile.v` | Tile-level composition of 4 slices: independent per-slice LUT config and registered/combinational select held simultaneously, independent per-slice clock-enable (gating one slice's FF does not affect the others), and that the single shared reset clears all 4 slices' FFs at once | `design/rtl/logic_tile.v` (instantiates 4× `lut4_slice`) |

Every testbench is self-checking: each check increments a counter and any
mismatch is printed with a `FAIL[n]` line; the run concludes with a single
`PASS: <name> -- N checks, 0 failures` (or `FAIL: <name> -- N checks, M
failures`) summary line — there is no eyeballed-waveform pass criterion.

## Running

```
./sim/run.sh
```

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`) on
`PATH`. The script recompiles every testbench against the current
`design/rtl/` sources and re-derives its own pass/fail result on every
invocation — there is no committed one-off simulation artifact to go stale;
this is the "presence AND reproducibility" evidence the T1 design-evidence
tier (`docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`) requires.
Build outputs land in `sim/build/` (gitignored).

Exit status is `0` iff every testbench reports `PASS` with zero failures.

Toolchain choice: Icarus Verilog was chosen over Verilator for these
testbenches because they are pure behavioral/event-driven checks (delays,
`@(posedge clk)`, self-checking `initial` blocks) with no need for a C++
test harness. `verilator --lint-only` is also clean against the RTL (no
warnings) and is a reasonable choice for future, larger fabric-level
testbenches that want a compiled/cycle-accurate model.

## Out of scope here

Bitstream-level fabric verification (a simulated fabric model driven by a
real generated bitstream, per `CLAUDE.md`'s "no claim without a testbench"
rule and `spec/framework-gaps.md` item G5) and inter-tile routing tests are
follow-on work, tracked separately — not part of this BEL-level increment.
