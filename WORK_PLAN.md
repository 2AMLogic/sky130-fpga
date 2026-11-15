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

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#286**: verify-pins.sh never re-checks items 9/10's per-member hashes: a LICENSE or README drift passes clean

## In Progress

Issues currently being built (`loom:building`).

- **#259**: Signoff harnesses cannot measure a layout outside layout/, so every observation record re-implements their klt requests
- **#262**: Pinned characterization-summary.md still names klayout-tools#2897 as the open gap; correcting it needs an item-8 signoff re-attestation
- **#265**: Hoist three hand-copied fragments out of the flow/*.sh drivers (7x sha256, 4x arg parse, 4x klt guard)
- **#267**: Remove duplicated stream scaffolding in flow/route_diag_negative.py: flow/_stream_gen.py already provides it
- **#268**: Deduplicate the frame-programming bitstream loader: 101 identical lines copied across four sim/tb_*.v diagnostic benches
- **#269**: CI does not run sim/sdf_port_interconnect/run.sh: pinned-PDK gate vs gate-sim.yml's byte-identical revision
- **#270**: Collapse the seven hand-expanded python-unittest blocks in sim/run.sh into the helper form the file already uses

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#278**: sim: deduplicate the frame-programming bitstream loader into one shared include
- **#279**: refactor(flow): single-source sha256 hash, --update parse and klt guard into report_check.sh

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#273**: refactor(sim): route every python-unittest suite in run.sh through one helper
- **#274**: refactor: take route_diag_negative stream scaffolding from _stream_gen
- **#287**: docs(signoff): re-attest item 8 with klayout-tools#2897 stated as closed

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)*
- **#259**: Signoff harnesses cannot measure a layout outside layout/, so every observation record re-implements their klt requests *(curated)*
- **#262**: Pinned characterization-summary.md still names klayout-tools#2897 as the open gap; correcting it needs an item-8 signoff re-attestation *(curated)*
- **#269**: CI does not run sim/sdf_port_interconnect/run.sh: pinned-PDK gate vs gate-sim.yml's byte-identical revision *(curated)*
- **#286**: verify-pins.sh never re-checks items 9/10's per-member hashes: a LICENSE or README drift passes clean *(curated)*

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
| Important | 2 |
| Ready (`loom:issue`) | 1 |
| In Progress (`loom:building`) | 7 |
| PRs awaiting review | 2 |
| Approved PRs awaiting merge | 3 |
| Curated | 6 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
