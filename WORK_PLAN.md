# Work Plan

Backlog snapshot from current GitHub label state, maintained by the Guide role.
Direction lives in the hand-written roadmap: [`ROADMAP.md`](ROADMAP.md).

The body below is a snapshot of GitHub label state as of the last merged docs-maintenance PR — it may lag live labels until the next one merges. The `_Generated:` stamp at the top of the generated region dates the snapshot; `git log -1 -- WORK_PLAN.md` finds the merge that wrote it.

<!-- Maintained automatically by the Guide triage agent. Manual edits are fine but may be overwritten. -->

<!-- guide:plan-body:start -->
_Generated: 2026-11-28T10:30:00Z (snapshot; compare against live labels)_
## Operator Attention: Merge-Risk-Hold Pileup

Judge-approved PRs under a hold (`loom:blocked` or `loom:operator`) — a human merge decision, or the prerequisite shown, is missing.

- **#397**: chore: resync installed Loom surfaces *(held: champion merge-risk hold)*

## Very Important

`loom:very-important` (one counts per workspace); every stage takes these first.

_None._

## Important

`loom:important`; taken before unlabelled work.

- **#162**: Bound flow/sdf-resim.sh simulator runs with SIM_TIMEOUT_SECONDS once its pinned timing record is re-characterized *(held)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(held)*

## Ready

Human-approved issues (`loom:issue`) ready for implementation — excluding held (`loom:blocked`/`loom:operator`/`loom:frozen`), `loom:building`, and issues with an open linked PR (native admission `OPEN_PR`; listed under Issues with Open PRs).

- **#399**: Simplify flow/generated_tile_replay.sh after #260: retire the 12 callback adapters, fold route-suite setup, and share rtl_compile/gen_compile

## Issues with Open PRs (Not Dispatchable)

`loom:issue` issues an open linked PR already holds — native admission would refuse them (`OPEN_PR`); listed with the PR and its stage, not counted above.

_None._

## In Progress

Issues currently being built (`loom:building`).

_None._

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

_None._

## Approved (Awaiting Merge)

PRs that passed review (`loom:pr`); unmarked PRs are queued for Champion auto-merge, PRs marked `*(held …)*` are not (the hold decides).

- **#397**: chore: resync installed Loom surfaces *(held: champion merge-risk hold)*

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)* *(held)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)* *(held)*

## Proposed (Architect / Hermit)

- **#254**: Remove the stranded def-unescape CLI mode: superseded by def-connections since klt 0.6.0, zero callers *(hermit)* *(held)*
- **#393**: Remove flow/sdf_sanitize_names.py: unwired workaround superseded by klt v0.8.0 *(hermit)* *(held)*

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 1 |
| Very important | 0 |
| Important | 2 |
| Ready (`loom:issue`, net of holds/building/open-linked-PRs) | 1 |
| In Progress (`loom:building`) | 0 |
| Held, no other bucket | 2 |
| PRs awaiting review | 0 |
| Approved PRs awaiting merge | 1 |
| Curated | 2 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
