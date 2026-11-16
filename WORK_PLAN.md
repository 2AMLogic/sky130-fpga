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

- **#288**: Generated characterization-summary.md's relative links do not resolve on the forge (17 of 18 targets)

## In Progress

Issues currently being built (`loom:building`).

- **#293**: test_pdk_gate.sh is run by no CI lane, and its "half-matching" check does not half-match
- **#294**: sim/sdf_port_interconnect/ is absent from item 9's attestation inventory, which claims to cover every committed harness
- **#296**: flow/routed_checks.sh: a failed sha256_of in argument position is still silent (3 call sites)
- **#299**: signoff/README.md's item-9 row omits three inventoried members (two .vh includes + fv_request.json)

## PRs Awaiting Review

PRs waiting on Judge (`loom:review-requested`).

- **#300**: docs: name .vh bench includes and cocotb request fixture in item-9 inventory row
- **#301**: fix: hoist routed_checks.sh sha256_of calls to assignment position

## Approved (Awaiting Merge)

PRs that passed review and are queued for Champion auto-merge (`loom:pr`).

- **#297**: ci: run the hermetic PDK gate regression in flow-evidence; fix mislabelled check
- **#298**: signoff: pin the sim/sdf_port_interconnect harness into item 9's attestation

## Proposed

Issues carrying `loom:curated`.

- **#117**: G4: identify the binding path of the composed-tile STA (cfg-input vs datapath) once klt exposes path reports *(curated)*
- **#213**: T1 item 7: SDF-annotated post-route functional run, via name sanitization or klayout-tools#2897 *(curated)*
- **#288**: Generated characterization-summary.md's relative links do not resolve on the forge (17 of 18 targets) *(curated)*
- **#293**: test_pdk_gate.sh is run by no CI lane, and its "half-matching" check does not half-match *(curated)*
- **#294**: sim/sdf_port_interconnect/ is absent from item 9's attestation inventory, which claims to cover every committed harness *(curated)*
- **#296**: flow/routed_checks.sh: a failed sha256_of in argument position is still silent (3 call sites) *(curated)*
- **#299**: signoff/README.md's item-9 row omits three inventoried members (two .vh includes + fv_request.json) *(curated)*

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
| In Progress (`loom:building`) | 4 |
| PRs awaiting review | 2 |
| Approved PRs awaiting merge | 2 |
| Curated | 7 |
| Architect / Hermit proposals | 2 |
| Active epics | 0 |
<!-- guide:plan-body:end -->
