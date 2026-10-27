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

_None._

## Ready

Human-approved issues ready for implementation (`loom:issue`).

_None._

## In Progress

Issues currently being built (`loom:building`).

- **#216**: Consolidate lvs_sanitize_verilog.py into the shared netlist sanitizer (two rename rules for one netlist)
- **#227**: Bump klayout-tools pin 0.5.0, 0.7.0, 7755612adb51 → 0.8.0

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#229**: build: pin signoff grader to klayout-tools 0.8.0 and regenerate tier report

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

_None._

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)*
- **#227**: Bump klayout-tools pin 0.5.0, 0.7.0, 7755612adb51 → 0.8.0 *(curated)*

## Proposed (Architect / Hermit)

_None._

## Epics

_None._

## Backlog Balance

| Bucket | Count |
|------|-------|
| Operator merge-risk holds | 0 |
| Very important | 0 |
| Important | 0 |
| Ready (`loom:issue`) | 0 |
| In Progress (`loom:building`) | 2 |
| PRs awaiting review | 1 |
| Approved PRs awaiting merge | 0 |
| Curated | 3 |
| Architect / Hermit proposals | 0 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
