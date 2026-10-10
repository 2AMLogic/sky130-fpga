# ADR-0004: Rule on the five G1 tile-description discrepancies against the ratified spec

- **Status**: Proposed — pending operator ratification. This record is not
  ratified by being written. It follows the same ratification-via-PR policy
  as ADR-0002/0003 (ratified upon merge with both `RATIFY-KEY` approvals).
  **`spec/tile-spec.md` is NOT edited by this PR**; the amendment wording in
  items 2 and 3 below is a proposal only and would be applied in a separate
  change after ratification.
- **Date**: 2026-10-09
- **Decided by**: Builder (issue #77); rulings reserved to the operator
- **Related**: #77 (this issue), #73 (G1 tile description that surfaced the
  discrepancies), #74 (bitstream test that would build on these choices),
  `design/README.md` "Discrepancies and deferrals",
  `design/fabulous/fabric.csv`, `spec/tile-spec.md`,
  `spec/framework-gaps.md` item G1

## Context

The G1 work (#73) landed a FABulous 2.2.0 tile description under
`design/fabulous/` and listed, in `design/README.md` ("Discrepancies and
deferrals"), places where it departs from or goes beyond the ratified
`spec/tile-spec.md`, explicitly "for a decision record - spec NOT edited".
No such record existed. Per `CLAUDE.md`, spec changes go through `spec/`
with a decision record and agents do not relax the ratified spec to make
results pass. This record lays out each departure, the options, and a
recommendation, so downstream work is not built on unratified choices.

Scope is the tile. Nothing here grows the fabric or adds a logic tile type.

What is and is not established (from `design/README.md`): FABulous 2.2.0
accepts the description through generation (exit 0, including `gen_model_npnr`
for the committed fabric); the BEL is cycle-equivalent to
`design/rtl/lut4_slice.v` over 20000 random iverilog cycles. nextpnr itself
was **not** run, no bitstream was assembled or simulated (G5), and no timing
claim is made (`GenerateDelayInSwitchMatrix,80` is FABulous's placeholder
constant). This record makes no claim beyond that.

## Item 1: `ce`/`rst` are runtime ports, not configuration fields

**Departure.** The issue text that seeded G1 listed `lut_init`, `reg_sel`,
`ce` as configuration fields. In `design/rtl/logic_tile.v`, `ce[3:0]` and
`rst` are runtime ports; in the FABulous BEL they are the `EN`/`SR` pins
reached through jump wires. The configuration space is `lut_init[63:0]` +
`reg_sel[3:0]` = 68 BEL bits (`ConfigBits[67:0]`), plus 90 switch-matrix
select bits, 158 total (`design/README.md`).

**Spec check.** `spec/tile-spec.md` does not say `ce` is configuration: it
says each FF has an "independent clock-enable" and that the four FFs share
"one reset" whose style is "an RTL-level decision". Only the register/
combinational selection is "via bitstream configuration". So the as-built
description is consistent with the ratified spec; the discrepancy is with
the earlier issue wording, not the spec.

**Options.**
- A. Accept as is (runtime ports); document. No spec change.
- B. Make `ce` a config field. Would change the RTL's meaning (a static
  enable) and contradict the spec's per-FF dynamic clock-enable intent.
- C. Amend the spec to enumerate the config fields explicitly.

**Recommendation / disposition.** Option A. The as-built behaviour matches
the ratified spec text, so no spec amendment is needed. Proposed disposition:
**accepted as consistent with the ratified spec; no change.** Optional
clarification (operator discretion, not required): note in
`design/README.md` that the issue wording was superseded. Operator
confirmation requested at ratification.

## Item 2: four non-logic `CAP_*` terminator tiles

**Departure.** `design/fabulous/fabric.csv` places `LOGIC4` with four extra
tile definitions, `CAP_N/S/E/W` (no BELs; their switch-matrix lists are one
line each; wires only loop back), in a 3x3 cross with unused corners. Per
`design/README.md`, a bare single `LOGIC4` makes `gen_model_npnr` fail with
`Wire N1BEG0-X0Y-1>N1END0 in tile X0Y0 points to an invalid tile X0Y-1`:
edge wires must land on a tile. `spec/tile-spec.md` says "one logic tile
type" and "No I/O tile, clock tile, or second logic-tile type is defined".
The caps are not logic tiles, but they are additional tile definitions the
spec does not mention.

**Options.**
- A. Accept as harness-only boundary cells: they exist only so the generator
  accepts the fabric, carry no BELs, and are not part of the tile deliverable.
  Needs a spec sentence so "one tile type" is not read as contradicted.
- B. Amend the spec to permit non-logic boundary terminator cells in the
  demonstration fabric, explicitly not counted as tile types.
- C. Change the description: remove the caps by making `LOGIC4`'s edge
  wires self-terminating, or by using a larger all-`LOGIC4` fabric whose
  outer edges still need termination. Not established as feasible with
  FABulous 2.2.0; the generator behaviour above is the only evidence here.

**Recommendation.** Option B (which subsumes A). The caps are a generator
requirement, not a design choice, and the spec's out-of-scope intent (no I/O,
clock, BRAM/DSP tiles) is untouched if caps are defined as wire loop-backs
with no BELs and no logic. Option C is not recommended until someone shows
the generator can do without terminators. Note also that the committed 3x3
cross contains one logic tile and is below the spec's 2x2 to 4x4 logic-tile
demonstration range; it is a G1 generator harness, not the demonstration
fabric, and this record does not rule on the demonstration fabric's shape.

**Proposed `spec/tile-spec.md` wording (not applied).** Append to the
"Fabric (demonstration)" section:

> The fabric description may include non-logic boundary terminator cells
> (e.g. `CAP_N/E/S/W`) that the FABulous generator requires so edge routing
> wires land on a valid tile. A terminator cell contains no BEL, no
> configuration bits used for logic, and only loops back routing wires; it is
> not a logic tile type, and does not count toward the fabric's logic-tile
> grid size or the "single tile type" constraint. No I/O, clock, or other
> functional tile types are introduced by this allowance.

**Disposition: operator decision required** (spec amendment, option B
recommended).

## Item 3: switch matrix is a simple same-index pattern

**Departure.** The spec names "FABulous-style sparse (Wilton-class) switch
box" with 4 general-purpose tracks per edge, and says the exact population is
a generated artifact of the tile description, "not hand-specified". As built
(`design/README.md`; `design/fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list`,
217 lines): 4 single-length tracks per edge; each LUT input muxes the 4
same-index tracks of N/E/S/W; each output track muxes the 4 BEL outputs and
the other three directions' same-index tracks; `EN`/`SR` come from tracks via
jumps. Not implemented: Wilton-class population, BEL-output to BEL-input
local feedback without leaving through a track, multi-hop wires (the last is
deliberate; the spec asks for 4 tracks per edge only). Mux fan-in and area
have **not** been evaluated against the spec's routability intent; routability
under nextpnr has not been run.

**Options.**
- A. Accept as a harness-only stand-in; keep the spec's Wilton-class target
  as a pending follow-on. Leaves the description and the spec disagreeing.
- B. Amend the spec so the v1 ratified population is the same-index pattern,
  with Wilton-class and local feedback listed as deferred refinements.
- C. Change the description to a Wilton-class population (and optionally
  local feedback) before further work builds on it.

**Recommendation.** Option A until routability is evidenced, then B or C by
operator choice. The spec's wording "Wilton-class" is a stated architectural
target; narrowing it on no routability or area evidence would relax the
ratified spec to match the implementation, which `CLAUDE.md` forbids absent
a ruling. Option C is the spec-faithful path but is design work beyond this
record, and #74 should know which population it exercises. Whichever option
is chosen, nothing in this record claims the stand-in is routable by nextpnr.

**Proposed `spec/tile-spec.md` wording if option B is chosen (not applied).**
Replace the first sentence of item 1 of "Switch matrix / routing pitch
target" from "(a sparse/Wilton-class switch box, not a full crossbar)" to:

> (a sparse switch box, not a full crossbar; the v1 population is the
> same-index pattern generated from `design/fabulous/Tile/LOGIC4/`: each LUT
> input selects among the same-index track of each of N/E/S/W, and each
> output track selects among the BEL outputs and the same-index tracks of the
> other three directions. A Wilton-class population and direct BEL-output to
> BEL-input feedback are deferred refinements, to be adopted only on
> routability evidence.)

**Disposition: operator decision required** (A recommended for now; B or C
to be chosen once routability evidence exists).

*Supporting evidence (informational; added by #115, does not alter the status,
options, recommendation or disposition above).* A bounded, experimental
single-tile mapping corpus on the as-implemented harness (not the ratified
population, no inter-tile or timing content) is recorded in
`design/fabulous/corpus/README.md`, with an append-only result record in
`design/fabulous/corpus/results.txt`. Reproduce with `flow/corpus.sh`.

*Related record (informational; added by #161, does not alter the status,
options, recommendation or disposition above).* Whether a mapper-side LUT
pin-assignment step is a separate remedy from the switch-matrix population is
drafted, as Proposed, in
[ADR-0006](0006-lut-pin-assignment-policy.md). Nothing there is adopted.

## Item 4: BEL behaviour follows ratified RTL, not stock FABulous

**Departure.** The stock FABulous `LUT4c_frame_config_dffesr` has a carry
chain, a configurable reset value, and applies reset only when `EN` is
asserted. `design/fabulous/Tile/LOGIC4/lut4_ff_bel.v` follows the ratified
RTL (`design/rtl/lut4_slice.v`): no carry, reset value 0, and synchronous
active-high reset independent of the clock enable (in `lut4_slice.v`,
`if (rst) ... else if (ce)`).

**Spec check.** The spec ratifies "No dedicated carry chain in v1" and leaves
reset style to RTL; the BEL matches both. The departure is from stock
FABulous, not from the spec.

**Options.**
- A. Keep the custom BEL (recommended): it matches the spec and RTL.
- B. Adopt the stock BEL: would add a carry chain the spec excludes and
  change reset semantics versus the RTL and its tests.
- C. Amend the spec/RTL to the stock behaviour: unmotivated, and reopens
  the carry-scope decision.

**Disposition.** Option A, **accepted: no spec change needed**, since the
description conforms to the ratified spec. Consequence to note: the BEL is a
custom model, so the FABulous BEL-timing placeholder says nothing about it,
and nextpnr packing rules for stock BEL features (carry) do not apply.
Operator confirmation requested at ratification.

## Item 5: `MultiplexerStyle,generic`

**Departure.** `fabric.csv` sets `MultiplexerStyle,generic` so the description
needs no custom sky130-cell mux models. Mapping to sky130 cells is deferred
to G2 (`spec/framework-gaps.md`; `design/README.md`).

**Options.**
- A. Accept `generic` as a harness setting; revisit at G2.
- B. Switch now to a sky130-cell mux style: needs custom mux models and
  precedes the physical-design work that would justify them.
- C. Amend the spec: not needed; the spec is silent on mux implementation.

**Recommendation / disposition.** Option A: **accepted as a
harness/generation-time setting with no spec impact**; the spec does not
constrain mux style. Re-evaluate under G2 when cell mapping is done. No
area, timing or cell-mapping claim is made for the generic style.

## Summary

| # | Item | Departs from | Recommendation | Disposition |
|---|---|---|---|---|
| 1 | `ce`/`rst` runtime ports | issue wording, not spec | keep | Accepted; consistent with spec (operator to confirm) |
| 2 | `CAP_*` terminators | spec "one tile type" (by omission) | amend spec (B) | **Operator decision required** |
| 3 | same-index switch matrix | spec "Wilton-class" | keep as stand-in (A) | **Operator decision required** |
| 4 | custom BEL vs stock FABulous | stock FABulous, not spec | keep | Accepted; no spec change |
| 5 | `MultiplexerStyle,generic` | nothing in spec | keep | Accepted; revisit at G2 |

## Consequences

- If ratified as written, `spec/tile-spec.md` is amended only for item 2
  (and for item 3 only if option B is chosen), in a separate change citing
  this ADR. Until then the spec is unchanged and the ratified spec stays in
  force.
- Until items 2 and 3 are ruled, work such as the #74 bitstream test should
  treat the caps and the same-index matrix as harness-level, not ratified.
- This record does not change `design/`, the RTL, or any measurement, and
  grants no timing or nextpnr-routability claim.
