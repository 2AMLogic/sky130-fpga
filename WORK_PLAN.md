# Work Plan

This roadmap is generated from the current GitHub label state by the Loom Guide role.

<!-- guide:plan-body:start -->
_Generated: 2026-11-19T09:30:00Z (snapshot; compare against live labels)_
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — only a human merge decision is missing.

_None._

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

- **#162**: Bound flow/sdf-resim.sh simulator runs with SIM_TIMEOUT_SECONDS once its pinned timing record is re-characterized *(held)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(held)*

## Ready

Human-approved issues ready for implementation (`loom:issue`).

- **#338**: Share the bitstream frame parser with the corpus testbench
- **#342**: Verify when a surviving routing-select flip in +mutate is structurally redundant

## In Progress

Issues currently being built (`loom:building`).

- **#341**: design/README.md: record the #324 blinky nextpnr fixture alongside top.v / top_io.v / top_reg.v

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#343**: docs: link the blinky divider demo from the nextpnr examples

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

_None._

## Proposed

Issues carrying `loom:curated`.

- **#341**: design/README.md: record the #324 blinky nextpnr fixture alongside top.v / top_io.v / top_reg.v *(curated)*
- **#342**: Verify when a surviving routing-select flip in +mutate is structurally redundant *(curated)*
- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)* *(held)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)* *(held)*

## Proposed (Architect / Hermit)

- **#254**: Remove the stranded def-unescape CLI mode: superseded by def-connections since klt 0.6.0, zero callers *(hermit)* *(held)*
- **#260**: Deduplicate the per-suite replay helpers in flow/generated_tile_replay.sh against gate_route_diag.sh's rd_* set *(hermit)* *(held)*

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 0 |
| Very important | 0 |
| Important | 2 |
| Ready (`loom:issue`) | 2 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 1 |
| Approved PRs awaiting merge | 0 |
| Curated | 4 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
