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

## Gate-level / SDF-annotated coverage (T1 item 7, issue #29)

`./flow/sdf-resim.sh` re-runs `tb_logic_tile.v` **unmodified**, gate-level,
against the as-built `sky130_fd_sc_hd` netlist from a fresh `klt
place-and-route` run whose regenerated DEF is verified byte-identical to
the committed, PR #22-characterized `layout/logic_tile.def` — so this is
the same characterized geometry, not a different one. Two legs:

| Leg | Result |
|---|---|
| Zero-delay gate-level | **PASS** — `tb_logic_tile -- 4 checks, 0 failures`, against real `sky130_fd_sc_hd` standard cells. Functional-only; no timing claim. |
| SDF-annotated (real post-route SDF, `klt place-and-route --post_route_sdf`) | **Blocked.** `$sdf_annotate` crashes `vvp` (`NULL handle passed to vpi_scan`) on this design's `generate`-block-flattened escaped identifiers — a generic, non-design-specific Icarus/`klt` defect, bisected to a minimal 15-line reproduction and filed as [klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890). Not worked around with a fabricated SDF or a fake result. |

Full method, provenance and the crash bisection:
[`measurements/timing-characterization/records/20260915-133517-234b13b.md`](../measurements/timing-characterization/records/20260915-133517-234b13b.md).
The committed SDF itself:
[`measurements/timing-characterization/logic_tile_route.sdf`](../measurements/timing-characterization/logic_tile_route.sdf).

**`tb_lut4_slice.v` is not covered here.** `lut4_slice` has no
independently placed-and-routed layout of its own — only as a
`g_slice[N].u_slice` sub-instance flattened inside the routed `logic_tile`
— so its SDF/IOPATH delays are relative to the whole tile instance, not to
a standalone `lut4_slice` root. A literal gate-level (let alone
SDF-annotated) re-run of `tb_lut4_slice.v` against *characterized* geometry
would need a new, independently placed-and-routed sub-block layout — a new
physical-design artifact, out of scope for issue #29. See
`spec/framework-gaps.md` G4.

Requires Icarus Verilog **13.0+** (`-ginterconnect`, `options.sdf`'s own
documented minimum) — a separate, newer toolchain requirement than the
plain `./sim/run.sh` RTL-level regression above, which has no such need.
Regenerating the gate-level netlist and SDF also requires `klt`, `openroad`,
`yosys` and a resolvable sky130A PDK (same requirements as
`flow/layout.sh`).

## Out of scope here

Bitstream-level fabric verification (a simulated fabric model driven by a
real generated bitstream, per `CLAUDE.md`'s "no claim without a testbench"
rule and `spec/framework-gaps.md` item G5) and inter-tile routing tests are
follow-on work, tracked separately — not part of this BEL-level increment.
