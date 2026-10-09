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
**nextpnr (issue #87):** `flow/nextpnr.sh` (pinned yosys + nextpnr-generic
`--uarch fabulous`, OSS CAD Suite 2026-10-08 under `flow/build/`, not
host-wide) loads the generated model, places two LOGIC4 BELs (one carrying
the 4-input parity function, INIT `16'h6996`) and routes the net between them
through the generated switch matrix, emitting FASM; log in `nextpnr.log`.
Two findings from that run, both properties of the G1 harness fabric: it has
**no IO BEL** (the same function on top-level ports fails packing: "must be
PAD", probe recorded in `nextpnr.log`) and **no constant driver** (a
tied-off LUT input makes `$PACKER_GND` unroutable: "Failed to find a route
... `$PACKER_GND`", probe `nextpnr/top_const.v` recorded in `nextpnr.log`),
so the original
accepted design (`nextpnr/top.v`) is structural, port-less and leaves unused
inputs floating. [ADR-0005](../spec/decisions/0005-nextpnr-io-and-constant-handling.md)
(Proposed, issue #92) chooses the handling: constants fold into the LUT truth
table (replicated INIT, unused pins and SR/EN left unconnected; no
`$PACKER_GND/VCC` sink, checked by `flow/nextpnr.sh`) and IO is a
harness-only pad model (`flow/nextpnr_io_overlay.py`, a scratch copy of the
nextpnr model; no tile type, BEL or config bit added). `nextpnr/top_io.v`
(six ports, a 4-input parity LUT and a constant-folded AND3) packs, places and
routes under that scheme (`nextpnr.log`). FASM pad pips have no config bits.
Issue #74 adds a registered example (`nextpnr/top_reg.v`, with `ff_map.v`;
EN/SR routed) and an **experimental** FASM-to-bitstream assembler plus a
bitstream-driven simulation of the composed tile (`flow/fasm_to_bitstream.py`,
`flow/bitstream.sh`, `sim/tb_logic_tile_bitstream.v`, `sim/README.md`): a
harness observation on this fabric as implemented, not G5/G6 completion. No
timing claim is made: the
`GenerateDelayInSwitchMatrix,80` value is FABulous's placeholder constant.

### Discrepancies and deferrals (for a decision record - spec NOT edited)

Decision record: [ADR-0004](../spec/decisions/0004-g1-tile-description-discrepancies.md)
(Proposed, pending operator ratification) covers items 1-5 below.

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
   evaluated against the spec's routability intent. (Fan-in and generic-cell
   area are now reported in "Switch-matrix RTL (#78)" below; routability
   against the spec's intent is still a judgement left to the reader.)
4. **BEL behaviour vs stock FABulous.** The stock `LUT4c_frame_config_dffesr`
   has a carry chain, configurable reset value, and applies reset only when
   `EN`; `lut4_ff_bel` follows the ratified RTL (no carry, reset 0, reset
   independent of `EN`).
5. **`MultiplexerStyle,generic`** is used so the description needs no custom
   (sky130-cell) mux models; mapping to sky130 cells is G2 work.
6. `rtl/logic_tile.v` / `rtl/lut4_slice.v` header comments formerly said the
   schema was "unconfirmed pending G1"; updated in #79 to point here.

## Switch-matrix RTL (#78)

`rtl/logic_tile_switch_matrix.v` is **generated** (not hand-written) from
`fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list` by `gen/gen_switch_matrix.py`.
Regenerate from the repo root (also rewrites the testbench include):

    python3 design/gen/gen_switch_matrix.py \
        design/fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list \
        design/rtl/logic_tile_switch_matrix.v \
        sim/switch_matrix_tb_gen.vh

It is a purely combinational module with a flat 90-bit `cfg` (per-sink select
fields, layout documented in the generated comments; a select value >= fan-in
drives 0). Jump wires `J_EN_BEGn`/`J_SR_BEG0` loop to their `_END` inside the
module. It is verified by `sim/tb_switch_matrix.v` (469 checks). It is not
instantiated by `logic_tile.v` (which stays BEL-only and byte-unchanged so the
committed layout, timing records and signoff hashes remain valid); composition
is done by the separate module below.

**Config-bit / select order (#96, verified against FABulous 2.2.0).** FABulous
does not use `.list` file order: it orders mux sinks by the switch-matrix
module's output-port declaration order and each sink's sources by its
input-port declaration order. The generator applies the same canonical order
(`sink_rank`/`src_rank` in `gen/gen_switch_matrix.py`), so
`cfg[k]` == tile `ConfigBits[68 + k]` == the FABulous switch matrix's local
`ConfigBits[k]`:

| `cfg` bits | Field |
|---|---|
| `[3k +: 3]`, k = 0..15 | `N1BEG0..3`, `E1BEG0..3`, `S1BEG0..3`, `W1BEG0..3` (k = 4*dir + idx, dir N,E,S,W) |
| `[48 + 2*(4*bel+p) +: 2]` | `L{A..D}_I{0..3}` (bel A..D, pin p) |
| `[80 +: 2]`, `[82 + 2i +: 2]` | `J_SR_BEG0`, `J_EN_BEG0..3` |
| none | `L?_EN`, `L?_SR` (fan-in 1) |

Select value = index in the sink's source list ordered N1END0..3, E1END0..3,
S1END0..3, W1END0..3, LA_O..LD_O (own-edge track omitted for track drivers:
e.g. `N1BEG0`: 0..2 = E,S,W `END0`, 3..6 = `LA_O..LD_O`; `W1BEG0`: 0..2 = N,E,S
`END0`). A select of 7 on a fan-in-7 mux is defined as 0 in the repo RTL; the
FABulous module indexes out of range and yields X (the testbench checks
repo==0 and FABulous==X). Before #96 the generator used `.list` file order,
which differed from FABulous in both field order and source order (the
differential testbench failed massively); the generator was corrected, not
the FABulous output. Evidence: `design/fabulous/tb_switch_matrix_equiv.v`,
run by `flow/fabulous.sh` (FABulous side generated into gitignored
`flow/build/`), record in `sim/switch_matrix_fabulous_equiv.txt`.

Mux fan-in (45 sinks, 90 config bits): 8 sinks fan-in 1 (BEL EN/SR, no config),
21 sinks fan-in 4 (16 LUT inputs, 4 `J_EN_BEG`, `J_SR_BEG0`; 2 bits each),
16 sinks fan-in 7 (the N/E/S/W track drivers; 3 bits each, codes 7 unused).

Generic-cell area (method: yosys 0.67, `synth -flatten` then
`abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX`, `stat` cell count; technology
independent, not sky130 cells and not um^2): 223 cells = 143 `$_MUX_`,
48 `$_NAND_`, 16 `$_NOT_`, 16 `$_OR_`. For reference a naive N:1 mux tree needs
N-1 2:1 muxes (21*3 + 16*6 = 159); yosys/abc folds the decode logic and shares
some of it. No timing is claimed or implied by these numbers.

## Out of scope here

This is BEL-level RTL plus a generic-cell derived netlist. It does **not**
implement:

- Physical layout, routing pitch, and inter-tile / demo-fabric assembly of
  the switch matrix (`spec/tile-spec.md`'s "4 general-purpose routing tracks
  per tile edge" target). Switch-matrix *RTL* now exists -- see below.
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

## Composed tile RTL (#90)

`rtl/logic_tile_routed.v` instantiates the 4 `lut4_slice` BELs and
`logic_tile_switch_matrix` behind one flat **158-bit `cfg`** port
(`cfg[17*i +: 16]` = BEL `i` truth table, `cfg[17*i+16]` = BEL `i` `reg_sel`,
`cfg[157:68]` = matrix selects, per the layout table above), plus `clk`,
4 edges x 4 track inputs (`{n,e,s,w}_in`) and 4 x 4 track outputs
(`{n,e,s,w}_out`). `ce`/`rst` are not ports: they are BEL `EN`/`SR` pins
reached through the matrix from tracks, as in the FABulous description.
`sim/tb_logic_tile_routed.v` (1046 checks, in `./sim/run.sh`) covers
track->LUT-input routing for every BEL/pin/edge, the track->LUT->FF->track
path with EN/SR from tracks, and every output-track mux code. The BELs are
made distinguishable (each BEL reads a different edge, each edge carries a
distinct value, and the output-mux sweep runs under two BEL-output patterns),
so cross-BEL index swaps in the composition are caught.

**RTL only: no layout, no DRC/LVS, no timing** for the composed tile. The
signed-off, timing-characterized module remains BEL-only `logic_tile`.
Follow-ons (separate issues, not part of #90): `klt par` of the composed
tile; an STA sweep of it plus a decision record extending the ratified timing
row; and #74 (bitstream load path), which can target this module's `cfg`.
See `spec/framework-gaps.md` G2/G4.
