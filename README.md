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
snapshot:
[`measurements/characterization-summary.md`](measurements/characterization-summary.md);
full per-issue narrative: ["Current position" in `spec/framework-gaps.md`](spec/framework-gaps.md#current-position-moved-from-readme).

| Rung | State | Detail |
|---|---|---|
| Tile layout DRC | clean <!-- status-claim: drc=clean --> | [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) |
| Tile layout LVS | match <!-- status-claim: lvs=match --> | [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) |
| Timing characterization | setup/hold-clean at all 18 `sky130_fd_sc_hd` corners <!-- status-claim: corner-count=18 -->; binding corner `ss_n40C_1v28` <!-- status-claim: binding-corner=ss_n40C_1v28 -->; ratified ([ADR-0002](spec/decisions/0002-tile-timing-spec-ratification.md)) | [`measurements/characterization-summary.md`](measurements/characterization-summary.md) |
| Gate-level SDF re-simulation | **paired `logic_tile` suite passes -- T1 item 7 `met`.** The four checks of `sim/tb_logic_tile.v`, run as named cocotb tests on the as-built netlist of the committed geometry ([`flow/tile-functional-verification.sh`](flow/tile-functional-verification.sh)), pass identically at zero delay and with the committed SDF back-annotated: 4/4 passed, 0 failed, 0 skipped in both legs, `environment.sdf.annotated: true` (corner `typ`, entries `all`) -- record [`20261121-183351-787c7ca`](measurements/timing-characterization/records/20261121-183351-787c7ca.md), [#359](https://github.com/2AMLogic/sky130-fpga/issues/359). The annotation is **partial**: all 215 cell `IOPATH` arcs and 63 of 179 `INTERCONNECT` entries apply; the 116 zero-delay bit-selected-port `INTERCONNECT` entries are dropped and the 4 SDF `TIMINGCHECK` sections are not modelled by Icarus, so no setup/hold claim rests on this run. Coverage is the 4 BEL-level `logic_tile` checks only: the OpenROAD-regenerated `flow/sdf-resim.sh` route stays gated on layout drift ([#162](https://github.com/2AMLogic/sky130-fpga/issues/162)) and the bitstream-level post-layout criterion stays open ([#213](https://github.com/2AMLogic/sky130-fpga/issues/213)) | [`signoff/README.md`](signoff/README.md) (item 7) |
| FABulous tile description / nextpnr | accepted by the pinned generator and nextpnr (not a bitstream-correctness or timing claim) | G1 in [`spec/framework-gaps.md`](spec/framework-gaps.md) |
| [ADR-0004](spec/decisions/0004-g1-tile-description-discrepancies.md) (G1 discrepancies) | Proposed <!-- status-claim: adr-0004=Proposed --> | pending operator ratification |
| [ADR-0005](spec/decisions/0005-nextpnr-io-and-constant-handling.md) (nextpnr IO/constants) | Proposed <!-- status-claim: adr-0005=Proposed --> | pending operator ratification |
| [ADR-0006](spec/decisions/0006-lut-pin-assignment-policy.md) (LUT pin-assignment policy) | Proposed <!-- status-claim: adr-0006=Proposed --> | pending operator ratification |
| Bitstream-level verification | experimental single-tile harness only; ratified fabric not verified (G5, G6 not closed) | `sim/README.md` |
| klt T1 evidence tier | 10 <!-- status-claim: t1-met=10 --> of 11 <!-- status-claim: t1-items=11 --> items met, 1 `not_applicable` (item 6); grader verdict `tier: "T1"` | [`signoff/tier-report.json`](signoff/tier-report.json) |

## Quick start: RTL to a simulated blink (experimental single-tile harness)

One command takes the repo's tiny blinky design from Verilog to a bitstream to
a simulated blinking output with open tools only:

```bash
./flow/blinky.sh
```

[`design/fabulous/nextpnr/blinky.v`](design/fabulous/nextpnr/blinky.v) is a
one-bit divider: after a synchronous reset, its output toggles on every rising
clock edge while `en` is held high — one full blink period per two input
clocks. The script fetches the pinned tools into the gitignored `flow/build/`
(nothing is installed host-wide), regenerates the fabric model with the pinned
FABulous generator, maps the design with yosys + nextpnr-generic, assembles
the frame stream (byte-checked against FABulous's own `bit_gen genBitstream`),
loads it into the simulated tile
([`sim/tb_logic_tile_bitstream.v`](sim/tb_logic_tile_bitstream.v)) and checks
the output pad against an independent expected sequence: it exits 0 only on
the bench's `PASS: tb_logic_tile_bitstream[blinky]` line, with every flip of a
used bitstream bit required to change the simulated output — a green run means
the bitstream is what blinks.

Prerequisites: `bash`, `python3`, `uv` (for the FABulous venv), Icarus
Verilog (`iverilog` + `vvp`), and `curl`/`tar`/`sha256sum` for the first run
(~750 MB tool download). Measured wall clock on a shared 8-vCPU Linux host,
2026-11-19 (base `7fa81b8` with the flow of this section): **38 s** cold — no
`flow/build/`, tools fetched — and **17 s** with the tools already cached.
Both vary with the host and the network; CI runs the same command without
asserting a time. Tools: FABulous `fabulous-fpga` 2.2.0
<!-- status-claim: fabulous-version=2.2.0 -->, OSS CAD Suite 2026-10-08
<!-- status-claim: oss-cad-tag=2026-10-08 --> — yosys 0.69+260
<!-- status-claim: yosys-version=0.69+260 -->,
nextpnr-0.11.1-54-g861c57be
<!-- status-claim: nextpnr-version=nextpnr-0.11.1-54-g861c57be -->; the pins
live in [`flow/tool_versions.sh`](flow/tool_versions.sh).

This is evidence about the **experimental single-LOGIC4 harness**
(`sim/README.md`), not the ratified fabric: no inter-tile routing, no timing
content — the blink period is stated in clock cycles only. Evidence record:
`sim/logic_tile_bitstream_results.txt`.

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

## Size and cost

The committed experimental composed-tile layout
([`layout/experimental/`](layout/README.md#experimental-composed-tile-physical-canary-layoutexperimental-issue-102))
converts to an area-per-LUT4 figure and an illustrative cost-per-LUT4
estimate against a dated public shuttle price:
[`measurements/cost-per-lut.md`](measurements/cost-per-lut.md).
It is **generated, not hand-typed** — regenerate it with
`python3 measurements/generate-cost-per-lut.py` after the underlying
P&R report changes.

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
