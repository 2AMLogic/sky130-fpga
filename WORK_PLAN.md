# Work Plan

This roadmap is generated from the current GitHub label state by the Loom Guide role.

<!-- guide:plan-body:start -->
_Generated: 2026-11-23T10:25:53Z (snapshot; compare against live labels)_
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

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#363**: Share frame-stream validation between the ConfigMem adapter and Python decoder

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#373**: refactor: extract shared frame_records() reader for adapter and decoder

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

_None._

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)* *(held)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)* *(held)*
- **#260**: Deduplicate the per-suite replay helpers in flow/generated_tile_replay.sh against gate_route_diag.sh's rd_* set *(curated)*
- **#363**: Share frame-stream validation between the ConfigMem adapter and Python decoder *(curated)*

## Proposed (Architect / Hermit)

- **#254**: Remove the stranded def-unescape CLI mode: superseded by def-connections since klt 0.6.0, zero callers *(hermit)* *(held)*
- **#260**: Deduplicate the per-suite replay helpers in flow/generated_tile_replay.sh against gate_route_diag.sh's rd_* set *(hermit)*

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 0 |
| Very important | 0 |
| Important | 2 |
| Ready (`loom:issue`) | 0 |
| In Progress (`loom:building`) | 1 |
| PRs awaiting review | 1 |
| Approved PRs awaiting merge | 0 |
| Curated | 4 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
