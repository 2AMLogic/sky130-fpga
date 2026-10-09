# ADR-0005: IO and constant-driver handling for the single-tile nextpnr bitstream flow

- **Status**: Proposed -- pending operator ratification. Same
  ratification-via-PR policy as ADR-0002/0003/0004. **`spec/tile-spec.md` is
  NOT edited**; nothing here adds a tile type, BEL or fabric growth to the
  ratified spec.
- **Date**: 2026-10-09
- **Decided by**: Builder (issue #92); rulings reserved to the operator
- **Related**: #92 (this issue), #87 (origin of the findings), #74 (consumer:
  step 2 "real bitstream via yosys + nextpnr" depends on this record),
  [ADR-0004](0004-g1-tile-description-discrepancies.md) (CAP_* terminators),
  `design/README.md` (nextpnr section), `flow/nextpnr.sh`,
  `design/fabulous/nextpnr.log`, `spec/framework-gaps.md` G1/G5

## Context

`flow/nextpnr.sh` (pinned yosys 0.69+260, nextpnr-0.11.1-54-g861c57be
`--uarch fabulous`) found two limits of the generated LOGIC4 model:

1. **No IO BEL**: a design with top-level ports fails packing ("Top-level
   port 'y' connected to illegal port ... (must be PAD)"); with iopad
   insertion on it fails placement ("no BELs remaining to implement cell type
   $__FABULOUS_OBUF").
2. **No constant driver**: a tied-off LUT input becomes a `$PACKER_GND` sink
   the router cannot reach ("Failed to find a route ... $PACKER_GND").

#74 needs a mapped design with ports and unused/constant LUT inputs. Scope:
the single tile. No fabric growth, no 2x2..4x4 grid.

## Findings (all reproduced by `flow/nextpnr.sh`)

- The `fabulous` uarch recognises an IO BEL purely by BEL *type name*
  (`IO_1_bidirectional_frame_config_pass`, pins `I,T,O,Q`) in the model files
  `bel.v3.txt`/`pips.txt`; synth_fabulous's `$__FABULOUS_IBUF/OBUF` pad cells
  must be mapped onto it with `-extra-map`. So IO can be supplied to nextpnr
  **without any change to the FABulous tile description**, by adding a pad
  BEL plus pad<->track pips to a scratch copy of the generated model.
- `--pcf` (`-o pcf=`, `set_io <port> <X>Y<y>/<bel>`) pins ports to pads.
- nextpnr always creates `$PACKER_GND`/`$PACKER_VCC` nets and `_CONST*_DRV`
  cells; the failure arises only when a cell pin *sinks* them. Leaving a pin
  unconnected costs nothing. Two sources of ties were found and removed:
  `cells_map.v` zero-extending narrow `$lut`s and tying `SR`/`EN` to 1'b0,
  and a pad `T` tie.
- Pad pins reach the LOGIC4 inputs only via same-index tracks (a LUT input
  `Ik` reads track `k`), so each pad needs access to all four tracks of its
  boundary tile, otherwise success depends on pin order chosen by abc.

## Decision

### Constants: fold into the LUT truth table; no constant driver in the fabric

- Constants are removed by yosys logic optimisation (`synth_fabulous`/abc)
  before nextpnr.
- A LUT narrower than 4 inputs is mapped by `design/fabulous/nextpnr/cells_map.v`
  with its truth table **replicated** over the unused upper inputs
  (`INIT[i] = LUT[i mod 2^WIDTH]`) and those pins, and `SR`/`EN` of
  combinational BELs, **left unconnected**. Whatever the config-selected
  switch-matrix mux feeds an unused pin then cannot change the output.
- `flow/nextpnr.sh` asserts, from nextpnr's post-route JSON, that no cell pin
  uses `$PACKER_GND`/`$PACKER_VCC` for the accepted design. The tied-off
  `top_const.v` stays as the recorded expected-FAIL probe of the raw
  behaviour: hand-written structural instances must not tie pins; express
  constants as logic.
- Demonstrated: `top_io.v` has `w = (a & b & c) | (d & 1'b0)`; yosys folds it
  to an AND3, mapped with INIT `16'h8080`, 4th input unconnected.

### IO: harness-only pad model, not a tile type or BEL in the spec

- `flow/nextpnr_io_overlay.py` copies the generated model into the run's
  scratch dir and adds four pad BELs each on the CAP_N and CAP_S boundary
  tiles (the ADR-0004 terminators), each pad connected to all four tracks of
  that tile. `io_prims.v`/`io_map.v` map the pad cells onto it; `top_io.pcf`
  pins ports. The pads have **no configuration bits**: the bitstream spec,
  `LOGIC4.v`, the switch matrix and `fabric.csv` are untouched.
- The pad model stands for the outside world (a testbench drives/samples the
  pad nets). It is a harness artefact, like the CAP_* cells ADR-0004 asks
  the operator to bless; it must not appear in `rtl/` or the tile spec.
- Demonstrated: `top_io.v` (4 input ports, 2 output ports, a 4-input parity
  LUT `16'h6996` and the AND3) packs, places and routes
  (`design/fabulous/nextpnr.log`), emitting FASM with 6 pad BELs, 2 LOGIC4
  BELs and the routed tracks.

## Rejected alternatives

1. **Add an IO tile type / IO BEL to the FABulous description.** A spec
   change (new tile type, new config space), outside the issue's scope and
   the "one logic tile type" line in `spec/tile-spec.md`; irreversible by
   comparison. Not needed since nextpnr accepts a model-side pad.
2. **Add a tie/constant tile or BEL (const driver).** Same objection, plus
   it spends tracks and area on something truth-table folding gives for
   free.
3. **Tie unused inputs to a constant in the netlist and rely on a router
   constant.** This is the failing probe.
4. **Drive unused inputs from a pad or spare LUT held at 0.** Burns fabric
   resources and still needs a known value; replicated INIT is
   value-independent.
5. **Hand-edit FASM/bitstream to remove ties.** Violates "toolchain
   generated, not hand-edited" (#74 acceptance).
6. **Per-port fixed pad (no cap crossbar).** Success then depends on abc's
   pin ordering; observed failing ("Failed to find a route").

No infeasibility was found, so no spec-change escalation is requested for the
mechanism itself.

## Consequences and open items (for #74 / G5)

- The overlay adds pips (`IOx_O -> S1BEGi` / `N1ENDi -> IOx_I`) that are not
  in `bitStreamSpec`. FASM lines whose pip is a pad pip carry no bit and must
  be dropped (or checked as pad-side connectivity) by the FASM-to-bitstream
  step; only LOGIC4 pips and `INIT` lines map to config bits. This step does
  not exist yet; #74 must build it.
- `SR`/`EN` are unconnected for FF=0 BELs. A registered (`FF=1`) BEL, e.g.
  #74's counter bit, needs `EN` (and `SR`) driven by a real net (a pad or LUT
  through the `J_*` jumps) or an explicit statement that an unconnected pin is
  a don't-care in simulation. Not decided here; the flow has no constant to
  offer.
- The FASM carries no timing and the pad model no electrical claim.
- This record does not ratify ADR-0004's CAP_* terminators; the pad model
  sits on them as a convenience and moves if the operator picks a different
  boundary scheme.
- If the operator rejects a harness-only pad model, the fallback is a spec
  change request for an IO tile type, through a new decision record.
