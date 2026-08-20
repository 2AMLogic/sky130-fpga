# ADR-0001: Adopt the FABulous tile/fabric description format

- **Status**: Accepted
- **Date**: 2026-08-20
- **Related**: #1 (Evaluate FABulous as the fabric framework and define the
  tile-first spec), `spec/tile-spec.md`, `spec/framework-gaps.md`

## Context

This repo delivers one LUT4-class logic tile plus a small (2×2 to 4×4)
demonstration fabric on SkyWater sky130, using an open yosys + nextpnr flow.
Before any RTL or layout work starts, we need a fabric *description* format
— the machine-readable definition of a tile's BELs, ports, and switch
matrix, and of how tiles compose into a fabric — that nextpnr's
place-and-route can consume, and that a bitstream generator can target.

Two paths were on the table:

1. **Hand-roll a fabric description** (our own tile/fabric schema, our own
   nextpnr backend or Yosys/nextpnr JSON adapter, our own bitstream format).
2. **Adopt FABulous's tile/fabric description format** — the eFPGA framework
   from the University of Manchester (Apache-2.0), which has taped out real
   sky130 fabrics (the STRIVE chips) and whose fabric description is what
   nextpnr's `generic`/FABulous-compatible flow already consumes.

## What we know about FABulous (and what we don't)

Grounded in the framework's well-documented public characteristics, per the
issue body and general FPGA/eFPGA architecture knowledge — **not** a fresh
fetch of the FABulous source (no internet access in this environment), so
treat anything below marked "unconfirmed" as needing verification against
the actual FABulous repository before implementation starts:

- **License**: Apache-2.0. Compatible with this repo's own Apache-2.0
  license (see `LICENSE`) — no license-compatibility blocker to adoption.
- **Provenance**: developed at the University of Manchester; used to tape
  out the STRIVE family of sky130 eFPGA fabrics. This is real, silicon-proven
  prior art on the *exact* PDK this repo targets, not a paper design —
  the strongest argument for adoption.
- **Toolchain fit**: FABulous's tile/fabric description is the input format
  nextpnr's `generic`/FABulous-compatible place-and-route flow consumes
  directly. Adopting it is what makes "yosys + nextpnr integration cost near
  zero" true, per this repo's own README target spec — there is no adapter
  or translation layer to write or maintain between "tile description" and
  "thing nextpnr can place-and-route."
- **Format shape (unconfirmed specifics)**: FABulous is publicly documented
  as generating a fabric from a small set of CSV-driven tile and fabric
  definition files (per-tile switch-matrix connectivity, per-tile BEL
  primitive lists, and a top-level fabric layout listing tile instances) plus
  HDL primitives for each BEL. We are **not** confident enough in the exact
  file names, column schemas, or generator CLI to encode them here — those
  specifics must be verified against the FABulous repository itself before
  the first tile/fabric description files are written (see
  `spec/framework-gaps.md`, item G1).
- **Timing model (confirmed by the issue's own framing)**: FABulous's own
  documentation marks BEL timing as placeholder-constant. Adopting the
  framework buys us the *structural* description and PnR integration; it
  explicitly does **not** buy us timing numbers. Every timing claim this repo
  makes has to come from characterized sky130 data (see
  `spec/framework-gaps.md`, item G4) — adoption does not change that, it is
  the reason the issue calls it out as a known gap rather than a surprise.
- **Physical design (confirmed by the issue's own framing)**: FABulous
  describes fabric *structure*, not sky130 GDS. Placement, routing, and
  DRC/LVS signoff for the tile's physical implementation are this repo's own
  work regardless of which fabric-description path is chosen (see
  `spec/framework-gaps.md`, items G2–G3).

## Decision

**Adopt FABulous's tile/fabric description format as the basis for this
repo's fabric definition** (to live under `design/`), rather than hand-roll
an equivalent.

Rationale:

1. **Toolchain cost**: this is the format nextpnr's FABulous-compatible flow
   already reads. A hand-rolled format would require writing and maintaining
   a nextpnr backend (or a translator into one) — a substantial, ongoing
   engineering cost with no payoff for this repo's actual scope (one tile,
   one small demo fabric). Adopting FABulous's format converts that into
   "write conformant tile/fabric description files," which is strictly
   less work and lower-risk.
2. **Prior art on the same PDK**: STRIVE is proof the format + flow combo
   works on sky130 at fabric scale, which directly de-risks the *structural*
   side of this repo's own fabric definition.
3. **No mismatch found with tile-first scope**: FABulous's tile/fabric
   description is tile-scoped by construction — a fabric is a grid of tile
   instances, each independently described — so describing exactly one
   logic tile type and a small 2×2–4×4 demonstration grid is a natural,
   minimal use of the format, not a fight against its grain. We found no
   FABulous-format requirement that forces a larger fabric, additional tile
   types, or other scope this repo intentionally declines per `CLAUDE.md`.
4. **What adoption does *not* solve**: the framework provides the fabric
   *description* and PnR integration only. It does not provide sky130
   physical design (placement/routing/DRC/LVS) or real timing data — both
   are explicit, expected gaps and are this repo's actual deliverable (see
   `spec/framework-gaps.md`).

## Alternatives considered

- **Hand-rolled fabric description**: rejected. It would require an
  independent nextpnr backend or adapter, forfeits the STRIVE sky130 prior
  art, and buys nothing this repo's tile-first scope actually needs — the
  scope is small enough that FABulous's format is not a constraint, only
  taken-for-free infrastructure.

## Consequences

- `design/` will hold FABulous-conformant tile and fabric description files
  (exact filenames/schema TBD per `spec/framework-gaps.md` item G1) plus the
  tile's RTL/HDL primitives.
- The nextpnr `generic`/FABulous-compatible flow becomes this repo's
  place-and-route path for the fabric-description → bitstream-mapping step
  (distinct from `layout/`'s klayout-tools-driven physical GDS flow for the
  tile itself — these are two different meanings of "place and route" in
  this repo: fabric-level bitstream routing vs. tile-level silicon layout).
- Every timing number in this repo must still be earned from sky130
  characterization; adopting FABulous does not relax that (see
  `spec/framework-gaps.md` item G4 and `CLAUDE.md`).
- Before writing the first real tile/fabric description file, an
  implementation issue must pin down the exact FABulous file schema/tooling
  version against the actual upstream repository (item G1) — this ADR
  records the *decision* to adopt the format, not a verified byte-for-byte
  schema.
