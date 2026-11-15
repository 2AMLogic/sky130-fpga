# Work Plan

This roadmap is generated from the current GitHub label state by the Loom Guide role.

<!-- guide:plan-body:start -->
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

_None._

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

- **#162**: Bound flow/sdf-resim.sh simulator runs with SIM_TIMEOUT_SECONDS once its pinned timing record is re-characterized
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897
- **#250**: Isolate why 28 port-sourced INTERCONNECT entries are not applied in the SDF-annotated run (minimal reproducer, no place-and-route)

## Ready

Human-approved issues ready for implementation (`loom:issue`).

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#250**: Isolate why 28 port-sourced INTERCONNECT entries are not applied in the SDF-annotated run (minimal reproducer, no place-and-route)
- **#255**: Factor the three near-identical route-diagnostic blocks in flow/generated_tile_replay.sh
- **#256**: Regenerate signoff/tier-report.json with the current klt: 183 KB of it is the pre-#4286 ungated coverage echo
- **#259**: Signoff harnesses cannot measure a layout outside layout/, so every observation record re-implements their klt requests
- **#261**: Single-source the klt synthesize request and the .klt artifact resolver: three copies of each across layout.sh, sdf-resim.sh and layout_routed.sh
- **#265**: Hoist three hand-copied fragments out of the flow/*.sh drivers (7x sha256, 4x arg parse, 4x klt guard)
- **#267**: Remove duplicated stream scaffolding in flow/route_diag_negative.py: flow/_stream_gen.py already provides it
- **#268**: Deduplicate the frame-programming bitstream loader: 101 identical lines copied across four sim/tb_*.v diagnostic benches
- **#270**: Collapse the seven hand-expanded python-unittest blocks in sim/run.sh into the helper form the file already uses

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#266**: Isolate why 28 port-sourced INTERCONNECT entries are not applied in the SDF-annotated run (minimal reproducer, no place-and-route)
- **#272**: Factor the three near-identical route-diagnostic blocks in flow/generated_tile_replay.sh
- **#273**: Collapse the seven hand-expanded python-unittest blocks in sim/run.sh into the helper form the file already uses
- **#274**: Remove duplicated stream scaffolding in flow/route_diag_negative.py: flow/_stream_gen.py already provides it
- **#278**: Deduplicate the frame-programming bitstream loader: 101 identical lines copied across four sim/tb_*.v diagnostic benches
- **#279**: Hoist three hand-copied fragments out of the flow/*.sh drivers (7x sha256, 4x arg parse, 4x klt guard)

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#280**: Regenerate signoff/tier-report.json with the current klt: 183 KB of it is the pre-#4286 ungated coverage echo

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)*
- **#250**: Isolate why 28 port-sourced INTERCONNECT entries are not applied in the SDF-annotated run (minimal reproducer, no place-and-route) *(curated)*
- **#256**: Regenerate signoff/tier-report.json with the current klt: 183 KB of it is the pre-#4286 ungated coverage echo *(curated)*
- **#259**: Signoff harnesses cannot measure a layout outside layout/, so every observation record re-implements their klt requests *(curated)*
- **#262**: Pinned characterization-summary.md still names klayout-tools#2897 as the open gap; correcting it needs an item-8 signoff re-attestation *(curated)*

## Proposed (Architect / Hermit)

- **#254**: Remove the stranded def-unescape CLI mode: superseded by def-connections since klt 0.6.0, zero callers *(hermit)*
- **#260**: Deduplicate the per-suite replay helpers in flow/generated_tile_replay.sh against gate_route_diag.sh's rd_* set *(hermit)*

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 0 |
| Very important | 0 |
| Important | 3 |
| Ready (`loom:issue`) | 0 |
| In Progress (`loom:building`) | 9 |
| PRs awaiting review | 6 |
| Approved PRs awaiting merge | 1 |
| Curated | 6 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
