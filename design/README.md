# design

Fabric definition + RTL.


## Current contents (BEL-level, T1 item 1)

`design/rtl/` holds plain-Verilog RTL for the tile's BEL-level logic, per
`spec/tile-spec.md`:

- `lut4_slice.v` — a single LUT4 + optional output flip-flop "slice" (the
  tile's basic logic element): a 16-bit bitstream-configured truth table
  feeding a registered/combinational output select, one FF with an
  independent clock-enable, and a synchronous, active-high reset (the
  spec leaves reset style as an RTL-level decision — this is the choice
  made here, kept to a single clock-tree topology).
- `logic_tile.v` — the tile: 4× `lut4_slice` sharing one clock and one
  reset, each with an independent clock-enable and independent bitstream
  configuration, per the spec's "All 4 FFs in a tile share one clock
  domain and one reset, each with an independent clock-enable."

Corresponding self-checking testbenches live under `sim/` (see
`sim/README.md`).

`design/netlist/` holds the **derived netlist** for the tile, per T1's
"Design sources" pass condition (see `flow/README.md`):

- `logic_tile_netlist.v` — a generic-cell (technology-independent) netlist
  synthesized from `rtl/lut4_slice.v` + `rtl/logic_tile.v` via `yosys`
  (`proc; opt; memory; opt; techmap; opt` — no sky130 standard-cell mapping).
  Regenerated and diff-checked against `design/rtl/` by `flow/synth.sh` on
  every invocation — see `flow/README.md` for the reproducibility harness.

## FABulous tile description (`design/fabulous/`, spec gap G1)

Pinned generator: **FABulous 2.2.0** (PyPI `fabulous-fpga==2.2.0`, git tag
`v2.2.0` = `432bb2873b83585d5178a8ba411f38254387ce94` of
FPGA-Research-Manchester/FABulous, Apache-2.0). The pin lives in
`flow/tool_versions.sh` (`RECORDED_FABULOUS_VERSION`); `flow/fabulous.sh`
installs it into the throwaway, untracked `flow/build/fab-venv` (never
host-wide), runs the generator on a scratch copy of `design/fabulous/`, and
diffs the normalized log against the committed `design/fabulous/generator.log`.

Description files (all committed; everything FABulous emits is regenerated
into `flow/build/fabulous-run/`, not committed):

- `fabric.csv` - 3x3 harness fabric: one `LOGIC4` tile in the centre plus four
  `CAP_*` boundary terminators (see "Discrepancies" 2).
- `Tile/LOGIC4/LOGIC4.csv` - the logic tile: 4 BELs (`LA_`..`LD_`), 4 tracks
  per edge N/E/S/W (`N1BEG/N1END` ...), jump wires for the shared reset
  (`J_SR`) and the four per-slice enables (`J_EN`).
- `Tile/LOGIC4/lut4_ff_bel.v` - the BEL: FABulous-format twin of
  `rtl/lut4_slice.v` (17 config bits: `INIT[15:0]`, `FF`), no carry.
- `Tile/LOGIC4/LOGIC4_switch_matrix.list` - the switch matrix.
- `Tile/CAP_{N,E,S,W}/` - non-logic terminators; `Fabric/models_pack.v` is the
  stock FABulous models pack (required by project validation); `FABulous.tcl`
  is the generator script; `tb_lut4_ff_bel_equiv.v` checks the BEL against
  `rtl/lut4_slice.v`.

What the generator emits (from the committed log, 2026-10-08 run): per tile
`<T>.v`, `<T>_switch_matrix.v`, `<T>_ConfigMem.v`, `<T>_ConfigMem.csv`;
fabric `Fabric/eFPGA.v`, `Fabric/eFPGA_top.v`; bitstream spec
`.FABulous/bitStreamSpec.{csv,bin}`; nextpnr model `.FABulous/{bel,bel.v2,
bel.v3,pips}.txt`, `template.pcf`, `placement_estimate.txt`; and
`eFPGA_geometry.csv`. `flow/fabulous.sh` prints the full list.

**LOGIC4 config-bit layout: 158 bits** (5 of 20 frames used, 32 bits/frame:
frame0-3 full, frame4 30 bits, frames 5-19 empty):

| ConfigBits | Meaning |
|---|---|
| `[16:0]`, `[33:17]`, `[50:34]`, `[67:51]` | BEL A, B, C, D: `[15:0]` = LUT4 truth table, `[16]` = `reg_sel` |
| `[157:68]` | switch matrix mux selects (90 bits) |

Mapping to `rtl/logic_tile.v`: `lut_init[16*i + j]` = BEL `i` `INIT[j]` =
`ConfigBits[17*i + j]`; `reg_sel[i]` = `ConfigBits[17*i + 16]`. That is
64 + 4 = 68 BEL bits, matching `lut_init[63:0]` and `reg_sel[3:0]`.
`flow/fabulous_summary.py` asserts this against the generator's own
`LOGIC4.v`, ConfigMem and bitstream-spec outputs (frame-bit positions of
BEL A: `INIT[0..15]` = 130..145, `FF` = 146).

**Verified:** FABulous 2.2.0 accepts the description end to end (parse, tile /
switch-matrix / config-mem / fabric / top-wrapper / bitstream-spec /
nextpnr-model / geometry generation, exit 0); the BEL is cycle-equivalent to
`rtl/lut4_slice.v` over 20000 random cycles (iverilog).
**Not verified:** nextpnr itself was not run (`nextpnr-generic` is not on this
host and installing it host-wide is not allowed); "accepted by nextpnr's
FABulous-compatible flow" is therefore only established at the level of the
generated nextpnr model files (`gen_model_npnr` succeeded). No bitstream was
assembled or simulated (G5), and no timing claim is made: the
`GenerateDelayInSwitchMatrix,80` value is FABulous's placeholder constant.

### Discrepancies and deferrals (for a decision record - spec NOT edited)

1. **`ce` is not a config field.** The issue text lists `lut_init`, `reg_sel`,
   `ce` as configuration fields; in `logic_tile.v` `ce[3:0]` (and `rst`) are
   runtime ports. They are BEL `EN`/`SR` pins reached via jump wires, so the
   config space is `lut_init` + `reg_sel` only.
2. **The generator cannot accept a bare single tile.** With `fabric.csv` =
   one `LOGIC4`, tile/fabric/bitstream generation succeed but `gen_model_npnr`
   fails: `Wire N1BEG0-X0Y-1>N1END0 in tile X0Y0 points to an invalid tile
   X0Y-1`. Edge wires must land on a tile, so the committed fabric adds four
   non-logic `CAP_*` terminators (wire loop-backs, no BELs, 0 config bits
   used for logic). `spec/tile-spec.md` says "one logic tile type"; the caps
   are not logic tiles but are additional tile definitions, so whether they
   are acceptable harness-only boundary cells (or the demo fabric should use
   something else) needs a decision record. No spec text was changed.
3. **Switch matrix is a stand-in for the spec's, not it.** Implemented: 4
   single-length tracks per edge; each LUT input muxes the 4 same-index
   tracks of N/E/S/W; each output track muxes the 4 BEL outputs and the 3
   other directions' same-index tracks; `EN`/`SR` come from tracks via jumps.
   Deferred: the Wilton-class population the spec names (the pattern here is
   simple same-index), BEL-output to BEL-input local feedback without leaving
   through a track, and any multi-hop / longer wires (none, deliberately: the
   spec asks for 4 tracks per edge only). Mux fan-in/area has not been
   evaluated against the spec's routability intent.
4. **BEL behaviour vs stock FABulous.** The stock `LUT4c_frame_config_dffesr`
   has a carry chain, configurable reset value, and applies reset only when
   `EN`; `lut4_ff_bel` follows the ratified RTL (no carry, reset 0, reset
   independent of `EN`).
5. **`MultiplexerStyle,generic`** is used so the description needs no custom
   (sky130-cell) mux models; mapping to sky130 cells is G2 work.
6. `rtl/logic_tile.v` / `rtl/lut4_slice.v` header comments formerly said the
   schema was "unconfirmed pending G1"; updated in #79 to point here.

## Out of scope here

This is BEL-level RTL plus a generic-cell derived netlist. It does **not**
implement:

- The tile's switch matrix / inter-tile routing (`spec/tile-spec.md`'s "4
  general-purpose routing tracks per tile edge" target).
- sky130 standard-cell mapping (liberty-mapped netlist) —
  `design/netlist/logic_tile_netlist.v` here is a generic-cell netlist only.
  A liberty-mapped netlist is now produced (as scratch, not committed under
  `design/`) by `flow/layout.sh`'s own `klt synthesize` step on the way to
  the committed GDS under `layout/` — see `flow/README.md` and
  `layout/README.md` (`spec/framework-gaps.md` item G2).
- DRC/LVS signoff and timing characterization (`measurements/`,
  `spec/framework-gaps.md` items G3–G4) — physical design/layout itself
  (item G2) now has a first pass under `layout/`, with DRC/LVS/timing
  explicitly deferred to those follow-on items.
