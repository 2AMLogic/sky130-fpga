# sky130-fpga

A small open-bitstream eFPGA fabric on
[SkyWater sky130](https://github.com/google/skywater-pdk), the 130 nm open
PDK — designed by AI agents driving
[klayout-tools](https://github.com/2AMLogic/klayout-tools) and the
open-source yosys + nextpnr flow.

**Status: just opened.** Nothing is designed yet.

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
and re-verified → shuttle seat → measured silicon. **Current position:
framework evaluated, draft tile spec recorded — RTL/tile-description work
not yet started.**

## Repo layout

```
spec/          ratified spec + decision records
design/        fabric definition + RTL (FABulous-style tile/fabric description)
sim/           verification evidence — bitstream-level testbenches + results
layout/        tile physical design — GDS + DRC/LVS reports (klayout-tools driven)
measurements/  silicon characterization (empty until tape-out)
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
