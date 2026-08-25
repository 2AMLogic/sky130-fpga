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

## Out of scope here

This is BEL-level RTL plus a generic-cell derived netlist. It does **not**
implement:

- The tile's switch matrix / inter-tile routing (`spec/tile-spec.md`'s "4
  general-purpose routing tracks per tile edge" target).
- The FABulous-style tile/fabric description format itself — its exact
  schema (CSV columns, generator CLI) is unconfirmed pending
  `spec/framework-gaps.md` item G1 (pulling the pinned FABulous
  repository/release), and is a separate, larger follow-on once G1 lands.
- sky130 standard-cell mapping (liberty-mapped netlist) and downstream
  place-and-route — `design/netlist/logic_tile_netlist.v` is a generic-cell
  netlist only; standard-cell mapping is tracked separately
  (`spec/framework-gaps.md` item G2).
- Physical design, DRC/LVS, and timing characterization (`layout/`,
  `measurements/`, and `spec/framework-gaps.md` items G2–G4).
