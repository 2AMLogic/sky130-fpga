# Framework gaps: what a sky130 tile implementation needs beyond FABulous

Per ADR-0001 (`spec/decisions/0001-fabric-framework-choice.md`), FABulous
supplies the fabric/tile *description* format and the nextpnr integration.
It does **not** supply sky130 physical design or real timing data. This
document lists the concrete work items that close that gap, so each can be
filed as (or folded into) a follow-on `loom:issue`. Every item below is
scoped to "what this repo must build that the framework does not provide" —
it is not a restatement of the tile spec itself (`spec/tile-spec.md`).

Each item includes a note on what its own verification/testbench evidence
should look like, per `CLAUDE.md`'s "no claim without a testbench" rule —
future implementation issues for these items must each define their own
verification plan, not inherit one from this list.

## Current position (moved from README)

This is the long-form status narrative that used to live in `README.md`; the
README now carries a short table whose machine-checkable cells are verified by
`flow/check_status_claims.py`. Facts quoted below that carry a
`status-claim` marker are checked the same way.

**Status: tile design and physical implementation landed; bitstream-level
verification of the ratified fabric not yet done (only an experimental
single-tile harness test exists).** The logic tile's RTL is implemented
and BEL-level tested, its routed layout is DRC/LVS-clean, and its timing has
been characterized across all 18 `sky130_fd_sc_hd` PVT corners with a
ratified spec row ([ADR-0002](decisions/0002-tile-timing-spec-ratification.md)).
A gate-level, SDF-annotated re-simulation of the routed tile was attempted:
the zero-delay leg passes, but the SDF-annotated leg is blocked on a real
upstream defect filed as
[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890) (closed 2026-09-16, but only as a fail-loud guard in klt v0.6.0 -- re-tried 2026-10-08 under #72, still blocked; the remaining gap is [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897)).
See [`measurements/characterization-summary.md`](../measurements/characterization-summary.md)
for the current aggregated snapshot of this evidence, and the detailed paragraph below
for the full maturity-ladder detail. This is still a tile-scoped
canary, not a fabric: bitstream-level verification of the demonstration
fabric has not been done (an experimental single-tile harness test exists,
see the detailed paragraph below).

**Current position:**
framework evaluated and tile spec ratified; tile RTL is implemented
(`design/rtl/lut4_slice.v`, `design/rtl/logic_tile.v`) and the tile layout is
DRC/LVS-clean <!-- status-claim: drc=clean --> <!-- status-claim: lvs=match --> (`layout/logic_tile.drc.json`: `status: "clean"`;
`layout/logic_tile.lvs.json`: `status: "match"`). Separately, **experimental**
(not ratified, not signoff) observations exist for the composed tile with the
stand-in same-index matrix: a routed layout in `layout/experimental/`
(issue #102), DRC `clean` / LVS `match` / ERC `clean_partial` (#108), and an
18-corner extracted-parasitics STA in
`measurements/timing-characterization-experimental/` (#113; 17 corners meet the
20 ns reference, `ss_n40C_1v28` does not, binding path undiagnosed, #117).
**Timing characterization
has landed on `main`** — evidence is recorded under
`measurements/timing-characterization/records/20260909-225431-86f71d2.md` and
corner-specific STA reports under `measurements/timing-characterization/corners/`.
[G1](#g1--pin-down-the-exact-fabulous-tilefabric-description-schema)
(FABulous tile/fabric description schema) is largely closed: FABulous 2.2.0 is
pinned and a tile description is committed under `design/fabulous/` (the
generator accepts it, and pinned `nextpnr` loads the generated model, places
and routes a trivial design, and emits FASM — issue #87, log in
`design/fabulous/nextpnr.log`; this is "the model is accepted", not a
bitstream-correctness or timing claim). Two open decision records are
Proposed <!-- status-claim: adr-0004=Proposed --> <!-- status-claim: adr-0005=Proposed -->, pending operator ratification:
[ADR-0004](decisions/0004-g1-tile-description-discrepancies.md) (G1
tile-description discrepancies) and
[ADR-0005](decisions/0005-nextpnr-io-and-constant-handling.md) (IO and
constant handling for the nextpnr flow). The
**bitstream-level-tests rung is only started, as an experiment** (issue #74):
a bitstream produced by the pinned yosys/nextpnr/FABulous flow for a
combinational and a registered example (EN/SR routed) is loaded through a
model of the FABulous frame interface into the composed single-LOGIC4 tile
RTL, and the mapped functions are checked in `./sim/run.sh`
(`tb_logic_tile_bitstream`, see `sim/README.md`). This is a **harness
observation** on the G1 harness fabric as implemented (same-index matrix,
CAP loop-backs, scratch pad overlay), not conformance to the ratified
Wilton-class routing population (ADR-0004/0005 remain Proposed), and it is not
a timing claim. [G5](#g5--bitstream-level-functional-verification-rtltile-description-correctness)
(bitstream-level functional verification of the ratified fabric, inter-tile
routing) and
[G6](#g6--bitstream-format-documentation)
(bitstream format documentation; the harness's serialized format is described
in `sim/README.md`) are **not closed**.

## G1 — Pin down the exact FABulous tile/fabric description schema

**Gap**: ADR-0001 adopts FABulous's format at the decision level but
explicitly does not encode exact file names, CSV column schemas, or
generator CLI invocations — those were not confirmed against the live
FABulous repository (no internet access during this evaluation).

**Work item**: before writing the first real tile/fabric description file
under `design/`, pull the actual FABulous repository (or pinned release) and
verify: file/directory layout for a tile definition, switch-matrix
connectivity schema, BEL/primitive HDL linkage, and the fabric-level
top-file format. Record the pinned FABulous version/commit this repo
targets.

**Verification**: a minimal single-tile fabric description that the
FABulous generator + nextpnr's FABulous-compatible flow accept without
error is the acceptance bar — "the toolchain parses our description," not
yet functional correctness.

**Status (2026-10-08)**: *largely closed, two caveats.* FABulous pinned at
2.2.0 (`flow/tool_versions.sh`, `RECORDED_FABULOUS_VERSION`); minimal tile
description under `design/fabulous/` (`fabric.csv`, `Tile/LOGIC4/`); the
generator accepts it and `gen_model_npnr` succeeds
(`design/fabulous/generator.log`, reproduce with `flow/fabulous.sh`; the
schema findings - CSV column layout, `sink,source` pair lists, BEL attributes
- are in `design/README.md`). Config-bit layout: 158 bits, of which the 68
BEL bits match `logic_tile.v`'s `lut_init[63:0]`/`reg_sel[3:0]`. Caveats:
(1) *closed 2026-10-09 (issue #87)*: `flow/nextpnr.sh` runs pinned yosys
0.69+260 + `nextpnr-generic --uarch fabulous` (nextpnr-0.11.1-54-g861c57be,
YosysHQ OSS CAD Suite 2026-10-08 unpacked under `flow/build/`, no host-wide
install; pins in `flow/tool_versions.sh`) on the generated model; nextpnr
loads it, places and routes a 4-input-function BEL plus one routed net, and
emits FASM (`design/fabulous/nextpnr.log`). Scope is "the model is accepted
and a trivial design places/routes", not bitstream correctness (G5) or
timing. Findings from the same run (resolution: ADR-0005, issue #92 --
harness-only pad model + constants folded into LUT truth tables, demonstrated
with `design/fabulous/nextpnr/top_io.v`; Proposed, pending ratification): the generated fabric has no IO BEL
(top-level ports cannot be packed: "must be PAD") and no constant driver
(tied-off pins make `$PACKER_GND` unroutable), each recorded as an
expected-FAIL probe in the same log, so the accepted design is
structural with no ports in the first design, recorded in `design/README.md`
for the G5 owner;
(2) the generator needs non-logic boundary terminator tiles and the
switch matrix is a simplified stand-in - both written up under "Discrepancies
and deferrals" in `design/README.md` for a decision record. Spec text not
modified.

## G2 — Tile physical design on sky130 (placement + routing)

**Gap**: FABulous describes fabric structure; it does not place or route
standard cells / custom layout on sky130. Turning the tile's RTL (4× LUT4 +
4× output FF + switch matrix per `spec/tile-spec.md`) into a manufacturable
sky130 layout is entirely this repo's work, via klayout-tools (`klt par`
and friends per `CLAUDE.md`).

*Status note (#90, as of that issue; superseded by the #102 and #108 notes
below):* composed-tile RTL (`design/rtl/logic_tile_routed.v`) now exists, but
the *ratified* committed layout (`layout/logic_tile.*`) is still BEL-only.

*Status note (#102):* an **experimental** `klt synthesize` + `klt
place-and-route` run of the composed tile now exists under
`layout/experimental/` (`flow/layout_routed.sh`): routing reached, 0 route
DRC violations. It measures the same-index stand-in matrix (ADR-0004
Proposed) and makes no DRC/LVS/ERC, timing or reset-compliance claim; those
and the topology decision remain open under G2/G3/G4.

*Status note (#108):* experimental DRC/LVS/ERC observations on that GDS
(`flow/routed_checks.sh`, reports beside the GDS): DRC `clean` (0 violations),
LVS `match` (power connectivity `match`), ERC `clean_partial` (0 findings, 0
antenna `violate`). These are observations of the stand-in matrix, not
signoff, and are not cited by `signoff/`. The observed track pitch and
utilization are recorded in `layout/README.md` as a G3 item (a) *input*; the
physical pitch remains undecided pending a decision record, and
`spec/tile-spec.md` is unchanged. Timing (G4) remains open.

*Status note (#113):* an **experimental** 18-corner extracted-parasitics STA of
the composed tile now exists under
`measurements/timing-characterization-experimental/` (`flow/sta-sweep.sh
--routed`): stand-in matrix, ADR-0004 Proposed, observation not spec. All 18
corners `timing_status: constrained`, SPEF fully annotated; 17 meet the 20 ns
reference and `ss_n40C_1v28` does not (WNS -4.6838 ns), recorded as found,
with boundary I/O delays of 0. The worst path's identity (datapath vs.
quasi-static `cfg` input) is not yet known, so no BEL-pin-to-output matrix
delay is claimed; `spec/tile-spec.md` timing rows are unchanged and G4 for the
composed tile stays open pending a decision record.

**Work item**: standard-cell (or custom) implementation of the tile,
placed and routed on sky130 using klayout-tools. Given `CLAUDE.md`'s framing
("a dense, regular logic tile is exactly the kind of workout `klt par`
exists to be stressed by — expect and welcome friction there"), file
klayout-tools friction as public issues against `2AMLogic/klayout-tools` as
it's hit, kept generic per the friction protocol (no design-specific detail
in that tracker).

**Verification**: a layout artifact (GDS) under `layout/`, plus a
place-and-route log/report establishing the tile met its target pitch and
area.

## G3 — DRC/LVS signoff and physical routing-pitch determination

**Gap**: neither FABulous nor the architectural tile spec fixes a physical
metal-layer routing pitch (µm) for the switch matrix — that is a sky130
design-rule-driven decision made during physical design, and DRC/LVS signoff
against the real sky130 PDK rules is entirely outside FABulous's scope.

**Work item**: (a) determine and record the actual physical routing pitch
used in the switch matrix layout, closing the deferred half of
`spec/tile-spec.md`'s "Switch matrix / routing pitch target" section; (b)
run DRC and LVS on the tile layout via klayout-tools and resolve to clean.

**Verification**: a DRC report and an LVS report (both clean) under
`layout/`, and the resolved physical pitch value recorded back into
`spec/tile-spec.md` (superseding the "deferred" note) or a spec addendum.

## G4 — Timing characterization (no inherited numbers)

**Gap**: FABulous's own documentation marks BEL timing as
placeholder-constant. This repo cannot inherit any timing number from the
framework — every delay, setup/hold, and Fmax claim has to be earned from
sky130-specific data.

**Work item**: extract real timing for the tile's BELs and switch matrix
from the sky130-implemented layout (parasitic extraction + STA against the
sky130 timing models, or equivalent characterization flow), and replace
FABulous's placeholder timing model with the characterized values before any
timing claim is published in `spec/`, `README.md`, or elsewhere.

**Verification**: a timing report under `measurements/` (per the repo
layout's existing convention — "silicon characterization," extended here to
pre-silicon extracted timing since real measurements only exist post-tapeout)
tracing each published number back to its extraction run; `sim/`-level
timing-aware simulation (if applicable) is separate from and does not
substitute for this.

**First pass landed**: see `measurements/timing-characterization/` — the
committed routed tile re-timed with extracted (SPEF) parasitics at all 18
`sky130_fd_sc_hd` liberty corners, regenerated by `./flow/sta-sweep.sh`.
Still open under this gap: ratified timing for the switch matrix and the
composed tile (RTL exists, standalone as
`design/rtl/logic_tile_switch_matrix.v` and composed with the BELs as
`design/rtl/logic_tile_routed.v`, verified by `sim/tb_logic_tile_routed.v`;
only the *experimental* layout, DRC/LVS/ERC and 18-corner STA observations in
the #102/#108/#113 notes above exist for the composed tile, none ratified, and
the binding path is undiagnosed, #117), propagated-clock and bisected-Fmax analysis, and replacing FABulous's
placeholder BEL timing model with these values.

**SDF-annotated gate-level re-simulation (T1 item 7, issue #29): partially
closed.** `klt place-and-route --post_route_sdf` writes a real, real-parasitics
SDF from the same routed geometry PR #22 already characterized (verified
byte-identical DEF); `sim/tb_logic_tile.v` re-runs unmodified, gate-level,
against the as-built netlist and PASSES zero-delay. The SDF-**annotated**
leg is blocked by a real, generically-reproducible upstream defect —
`$sdf_annotate` crashes `vvp` (`NULL handle passed to vpi_scan`) on any
escaped identifier containing `.`/`[]`, which is exactly what this design's
`generate`-block RTL produces once flattened — filed as
[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890) (closed 2026-09-16, but only as a fail-loud guard in klt v0.6.0 -- re-tried 2026-10-08 under #72, still blocked; the remaining gap is [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897))
and cited, not worked around with a fabricated substitute. `sim/
tb_lut4_slice.v` was not attempted: `lut4_slice` has no independently
placed-and-routed layout of its own (only as a sub-instance flattened
inside the routed `logic_tile`), so a literal SDF-annotated re-run of that
testbench would need a new physical-design artifact, out of scope here. See
`measurements/timing-characterization/records/20260915-133517-234b13b.md`
and `sim/README.md` for the full accounting. Still open under this item:
the SDF-annotated pass/fail result itself (blocked: klayout-tools#1890 closed as a guard only, re-tried under #72; tracked as klayout-tools#2897)
and `tb_lut4_slice.v`'s own gate-level coverage.

**Aggregated characterization report (T1 item 8, issue #33): in place.**
`measurements/characterization-summary.md` — generated by
`measurements/generate-characterization-summary.py`, not hand-typed — pulls
DRC, LVS, the 18-corner STA sweep, the ratified `spec/tile-spec.md` timing
row (ADR-0002) and the SDF-generation/gate-level re-simulation result above
into one current snapshot naming each item's status, source record/report
path, and the commit/run it was derived from. This closes T1 item 8's own
bar (one aggregated, current artifact); it aggregates evidence this item's
own "still open" list above already names as outstanding — it does not
close any of that outstanding work itself.

## G5 — Bitstream-level functional verification (RTL/tile-description correctness)

**Gap**: FABulous generates a bitstream format and a fabric description, but
functional *proof* that a real bitstream loaded onto this specific tile's
implementation does what the mapped design intends is this repo's own
verification work — per `CLAUDE.md`, "Functional claims come from
bitstream-level tests on the simulated fabric — a real bitstream, loaded
into the fabric model, exercising the mapped design."

**Work item**: build the bitstream-level testbench(es) for the tile (and
later the demonstration fabric) — a simulated fabric model driven by a real
generated bitstream, exercising representative mapped designs (at minimum:
combinational LUT function coverage, FF register behavior, inter-tile
routing across the 2×2–4×4 demo grid).

**Status note (issue #92)**: how a mapped design gets ports and constant
inputs through nextpnr is decided in
[ADR-0005](decisions/0005-nextpnr-io-and-constant-handling.md) (Proposed):
harness-only pad model plus constants folded into LUT truth tables. (The
FASM-to-bitstream step and `EN`/`SR` for registered BELs, open when this note
was written, are implemented in the experimental harness -- see the #74 note
below; they are not ratified.)

**Status note (issue #74, experimental harness coverage -- G5 stays OPEN)**:
`flow/fasm_to_bitstream.py` turns nextpnr FASM into a FABulous frame stream
(cross-checked byte-for-byte against FABulous's `bit_gen`), and
`sim/tb_logic_tile_bitstream.v` loads such streams into the composed
single-LOGIC4 tile (`design/rtl/logic_tile_routed.v`, all 158 `cfg` bits)
and checks a combinational example (exhaustive vectors) and a registered one
(capture, hold, reset independent of enable, reset-over-enable; EN/SR are
routed nets), with perturbation and malformed-stream rejection tests. This is
an observation on the G1 harness fabric exactly as implemented (same-index
matrix, CAP loop-backs, scratch pad overlay); ADR-0004/0005 are Proposed, so
it is not conformance to the ratified Wilton-class population and does not
satisfy the "inter-tile routing across the demo grid" part of the work item.
Details: `sim/README.md` ("Bitstream-driven harness test"). Zero-delay
gate-level re-runs of the same bitstreams against the synthesized composed-tile
netlist (#119, `flow/gate-sim-bitstream.sh`, evidence
`sim/logic_tile_bitstream_gate_results.txt`) are likewise experimental,
functional-only observations. Still open: the ratified fabric and inter-tile
routing.

**Verification**: this item *is* verification infrastructure — its own
acceptance bar is "tests exist under `sim/` and pass," with results recorded
as `sim/`'s append-only evidence trail.

## G6 — Bitstream format documentation

**Gap**: the target spec (README) commits to "fully documented, open
[bitstream] format." FABulous generates a bitstream mechanism but this
repo is responsible for documenting the resulting format for this specific
tile/fabric instantiation in a form readable by someone without the
FABulous source in front of them.

**Work item**: write the bitstream format documentation (bit layout,
per-tile/per-BEL configuration field meaning) once the tile description
(G1) and RTL are in place, as part of `design/` or `spec/`.

**Verification**: documentation cross-checked against a real generated
bitstream for a known test design (ties into G5's testbenches — a bitstream
that G5 already exercises is also the reference the documentation is
checked against).

**Status note (issue #74, experimental -- G6 stays OPEN)**: the serialized
frame-stream format, the frame-position -> 158-bit tile-vector mapping,
padding/default values, the pad-pip exclusions and the clock/EN/SR runtime
semantics of the *harness* are written down in `sim/README.md` and are
cross-checked by the simulation loader against the committed streams
(`sim/bitstream/*.bin`). A format document for the ratified fabric, and
per-field documentation beyond the `design/README.md` layout table, are still
to be written once ADR-0004/0005 are ruled on.

## Summary: suggested follow-on issue split

| Item | Depends on | Suggested as |
|---|---|---|
| G1 | ADR-0001 (this issue) | Its own issue — blocks all `design/` work |
| G2 | G1 + tile RTL existing | Its own issue (large; may itself decompose per `builder-complexity.md`) |
| G3 | G2 | Its own issue, or a follow-up phase of G2 |
| G4 | G2, G3 | Its own issue — explicitly separate from G2/G3 since it is characterization, not implementation |
| G5 | Tile RTL + G1 (bitstream shape) | Its own issue — can start in parallel with G2, doesn't need physical layout |
| G6 | G1, G5 | Small; can ride with G5 or be its own small issue |

Filing these as GitHub issues is left to normal repo triage (Architect/Curator/
human) rather than done automatically by this issue — this document is the
authoritative list to file from.
