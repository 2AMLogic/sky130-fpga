# sky130-fpga — agent instructions

Open-source canary block: a small open-bitstream eFPGA fabric on SkyWater
sky130, tile-scoped, designed and verified by AI agents.

- **PDK**: SkyWater sky130 (open PDK, google/skywater-pdk). Open-source flow:
  yosys + nextpnr with a FABulous-style tile/fabric description for the
  fabric itself; klayout-tools (`klt`) for layout, DRC/LVS, and
  place-and-route work. A dense, regular logic tile is exactly the kind of
  workout `klt par` exists to be stressed by — expect and welcome friction
  there.
- **The tile is the scope, not the FPGA.** This canary delivers one
  LUT4-class logic tile plus a small demonstration fabric (2×2 to 4×4 tiles)
  — deliberately not a production-size FPGA. Decline proposals to grow the
  fabric, add tile types, or widen the routing before the tile itself is
  verified; record the proposal in an issue and move on. Fabric growth is a
  spec change, and spec changes go through a decision record.
- **Build on public prior art, don't re-derive it.** The
  [FABulous](https://github.com/FPGA-Research-Manchester/FABulous) eFPGA
  framework (Apache-2.0, University of Manchester) has taped out sky130
  fabrics (the STRIVE chips), and nextpnr's `generic`/FABulous-compatible
  flow consumes its fabric description. Starting from FABulous's tile/fabric
  description format keeps nextpnr integration cost near zero; the real work
  this repo adds is the tile's physical design and its timing
  characterization on sky130.
- **Friction protocol (the canary's job)**: every time klayout-tools is
  awkward, missing a capability, or wrong for what you need, file an issue at
  `2AMLogic/klayout-tools` describing the tool gap generically — that tracker
  is scoped to the tool, so keep design-specific detail out of it and describe
  the gap, not the design.
- **Verification is the product**: no claim without a testbench.
  Functional claims come from bitstream-level tests on the simulated fabric —
  a real bitstream, loaded into the fabric model, exercising the mapped
  design. Timing claims come only from characterized data: FABulous's own
  docs mark BEL timing as placeholder-constant, so timing characterization is
  real work here, not something inherited from the framework. `sim/` results
  are append-only evidence.
- Spec changes go through `spec/` with a decision record; agents do not relax
  the ratified spec to make results pass.

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses [Loom](https://github.com/rjwalters/loom) for AI-powered development orchestration — see the Loom repository for the full guide (roles, labels, worktrees, configuration). When installed, Loom also writes a locally-substituted copy of that guide to `.loom/CLAUDE.md`.
<!-- END LOOM ORCHESTRATION -->
