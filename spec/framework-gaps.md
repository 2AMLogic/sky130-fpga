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

## G2 — Tile physical design on sky130 (placement + routing)

**Gap**: FABulous describes fabric structure; it does not place or route
standard cells / custom layout on sky130. Turning the tile's RTL (4× LUT4 +
4× output FF + switch matrix per `spec/tile-spec.md`) into a manufacturable
sky130 layout is entirely this repo's work, via klayout-tools (`klt par`
and friends per `CLAUDE.md`).

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
