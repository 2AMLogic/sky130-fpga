# sky130-fpga

A small open-bitstream eFPGA fabric on
[SkyWater sky130](https://github.com/google/skywater-pdk), the 130 nm open
PDK — designed by AI agents driving
[klayout-tools](https://github.com/2AMLogic/klayout-tools) and the
open-source yosys + nextpnr flow.

**Status: tile design and physical implementation landed; bitstream-level
verification of the ratified fabric not yet done.** This is a tile-scoped
canary, not a fabric. Each row is a pointer to the committed evidence; the
machine-checkable cells carry a marker that `flow/check_status_claims.py`
verifies against its source on every PR (see `flow/README.md`). Aggregated
snapshot: [`measurements/characterization-summary.md`](measurements/characterization-summary.md);
full per-issue narrative: ["Current position" in `spec/framework-gaps.md`](spec/framework-gaps.md#current-position-moved-from-readme).

| Rung | State | Detail |
|---|---|---|
| Tile layout DRC | clean <!-- status-claim: drc=clean --> | [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) |
| Tile layout LVS | match <!-- status-claim: lvs=match --> | [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) |
| Timing characterization | setup/hold-clean at all 18 `sky130_fd_sc_hd` corners <!-- status-claim: corner-count=18 -->; binding corner `ss_n40C_1v28` <!-- status-claim: binding-corner=ss_n40C_1v28 -->; ratified ([ADR-0002](spec/decisions/0002-tile-timing-spec-ratification.md)) | [`measurements/characterization-summary.md`](measurements/characterization-summary.md) |
| Gate-level SDF re-simulation | zero-delay passes; SDF-annotated blocked upstream ([klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890) guard only, gap [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897)) | [`measurements/README.md`](measurements/README.md) |
| FABulous tile description / nextpnr | accepted by the pinned generator and nextpnr (not a bitstream-correctness or timing claim) | G1 in [`spec/framework-gaps.md`](spec/framework-gaps.md) |
| [ADR-0004](spec/decisions/0004-g1-tile-description-discrepancies.md) (G1 discrepancies) | Proposed <!-- status-claim: adr-0004=Proposed --> | pending operator ratification |
| [ADR-0005](spec/decisions/0005-nextpnr-io-and-constant-handling.md) (nextpnr IO/constants) | Proposed <!-- status-claim: adr-0005=Proposed --> | pending operator ratification |
| Bitstream-level verification | experimental single-tile harness only; ratified fabric not verified (G5, G6 not closed) | `sim/README.md` |
| klt T1 evidence tier | 9 <!-- status-claim: t1-met=9 --> of 11 <!-- status-claim: t1-items=11 --> items met | [`signoff/tier-report.json`](signoff/tier-report.json) |

**Built agent-native.** Every specification, decision record, testbench, and
line of documentation here is produced by AI agents working from a ratified
spec and an append-only evidence trail — not human-authored work that agents
merely assisted with. Verification is the product: every claim traces to a
recorded result. Where the agents hit friction with the open-source tooling —
most often [klayout-tools](https://github.com/2AMLogic/klayout-tools) — that
friction is filed as a public issue against the tool itself, so the fix
benefits everyone using sky130, not just this repo.

## Why this block — and why tile-scoped

The sibling canaries are analog blocks; this one is digital, and it is the
densest, most regular kind of digital there is. An FPGA logic tile is
hundreds of near-identical cells on a rigid pitch with a routing fabric
threaded through them — exactly the workload that stresses place-and-route
and layout tooling in ways an op-amp never will.

The scope is deliberately **one LUT4-class logic tile plus a small
demonstration fabric (2×2 to 4×4 tiles)** — not a production-size FPGA. A
tile that is verified, DRC/LVS-clean, and timing-characterized is a complete,
honest deliverable; a big fabric assembled from an unverified tile is
neither. Proposals to grow the fabric before the tile is verified are
declined by policy (see `CLAUDE.md`).

## Standing on public prior art

The fabric side of this problem is largely solved in the open:

- **[FABulous](https://github.com/FPGA-Research-Manchester/FABulous)**
  (Apache-2.0, University of Manchester) is an eFPGA framework with taped-out
  sky130 fabrics to its name — the STRIVE chips. Its tile/fabric description
  format defines the fabric's structure and generates the bitstream layout.
- **[nextpnr](https://github.com/YosysHQ/nextpnr)** consumes that description
  through its `generic`/FABulous-compatible flow, so yosys + nextpnr can map
  real designs onto the fabric from day one.

Starting from FABulous keeps nextpnr integration cost near zero. What the
framework does *not* provide — and what this repo is for — is the tile's
**physical design** on sky130 and its **timing characterization**: FABulous's
own docs mark BEL timing as placeholder-constant, so every timing number here
has to be earned from characterized data.

## Target specification (draft ratified in `spec/`, see #1)

Framework choice and a draft tile spec are recorded in `spec/` — see
[`spec/decisions/0001-fabric-framework-choice.md`](spec/decisions/0001-fabric-framework-choice.md)
and [`spec/tile-spec.md`](spec/tile-spec.md) for the full rationale.

| Parameter | Target |
|---|---|
| Logic tile | LUT4-class: 4× LUT4, 1 output FF per LUT, no dedicated carry chain in v1 |
| Routing | FABulous-style per-tile switch matrix; 4 general-purpose tracks/edge (architectural target — physical metal pitch deferred to physical design) |
| Demonstration fabric | 2×2 to 4×4 tiles, single tile type, bitstream-programmable |
| Bitstream | fully documented, open format |
| Timing | claims only from characterized sky130 data — no inherited numbers |

Framework-gap work items (physical design, DRC/LVS, timing characterization,
bitstream-level verification) that a sky130 tile implementation needs beyond
what FABulous provides are tracked in
[`spec/framework-gaps.md`](spec/framework-gaps.md).

Maturity ladder: framework evaluated → tile spec ratified → tile RTL +
fabric description passing bitstream-level tests → tile layout
DRC/LVS-clean → tile timing characterized → demonstration fabric assembled
and re-verified → shuttle seat → measured silicon.
**Current position:** see the Status table above; the detailed narrative
(experimental observations, issue references) lives in
[`spec/framework-gaps.md`](spec/framework-gaps.md#current-position-moved-from-readme).

## Repo layout

```
spec/          ratified spec + decision records
design/        fabric definition + RTL (FABulous-style tile/fabric description)
flow/          yosys + nextpnr synthesis / place-and-route tooling
sim/           verification evidence — bitstream-level testbenches + results
layout/        tile physical design — GDS + routed DEF + DRC/LVS reports (klayout-tools driven)
measurements/  characterization evidence — multi-corner extracted-parasitics timing
               (pre-silicon); silicon characterization empty until tape-out
signoff/       klt signoff block manifest + graded T1 tier report — the block's
               machine-graded gap-to-T1 state (see signoff/README.md)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
