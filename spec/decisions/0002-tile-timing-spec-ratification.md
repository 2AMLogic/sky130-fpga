# ADR-0002: Ratify the tile's timing spec row from the PR #22 18-corner STA record

- **Status**: Proposed — ratified upon this PR merging with both
  `RATIFY-KEY` approvals (two-key ratification mechanism,
  `2AMLogic/2am#372`), per the standing ratification-via-PR policy
  (`2AMLogic/2am#357`, 2026-08-19).
- **Date**: 2026-09-15
- **Decided by**: Builder (issue #28), extending `spec/tile-spec.md` and
  `spec/framework-gaps.md` item G4
- **Related**: #28 (this issue), #20 / PR #22 (the STA sweep this record
  ratifies from), `spec/decisions/0001-fabric-framework-choice.md`

## Context

`spec/tile-spec.md`'s Timing row (line 28) currently reads outright: "No
numbers in this spec" — deliberately, per that row's own rationale column:
"this repo publishes no timing claim until it is backed by characterized
sky130 data (`spec/framework-gaps.md` item G4)." Item G4 itself, before this
record, listed the tile's timing as an open gap with no ratified target to
verify against, which blocks T1 checklist item 5 ("full corner verification
vs a ratified spec") on the ratification half of that requirement, not the
verification half.

That evidentiary gap closed with PR #22 (issue #20): a full 18-corner `klt
sta` sweep of the routed tile (`layout/logic_tile.def`, `layout/
logic_tile.gds`), both LEF-only and SPEF-annotated with extracted
parasitics, recorded at `measurements/timing-characterization/records/
20260909-225431-86f71d2.md`. That record is explicit that it is evidence,
not a ratification: **"it publishes no number into `spec/tile-spec.md` ...
changing them is a ratified spec change requiring its own decision record —
this record is the evidence such a decision record would cite, not the
ruling."** This is that decision record.

Per `CLAUDE.md` ("Spec changes go through `spec/` with a decision record")
this record proposes **one** recommended option (not a menu), derived from
and citing the PR #22 record's own numbers.

## Evidence relied on (from `measurements/timing-characterization/records/20260909-225431-86f71d2.md`)

- **18 of 18 `sky130_fd_sc_hd` PVT corners** the sky130A PDK ships, each run
  three ways (LEF-only on the committed DEF, LEF-only on a name-rewritten
  control DEF, SPEF-annotated on the name-rewritten DEF); the
  timing-neutrality control passed at all 18 corners (identical
  `worst_slack_ns` / `total_negative_slack_ns` / `fmax_mhz` /
  `setup_violation_count` / `hold_violation_count` / `clock_skew_ns` /
  `estimated_power_mw` between the committed and rewritten DEFs), so the
  SPEF-annotated numbers below are an analysis of the committed geometry.
- **Setup: 0 violations and 0 total negative slack at every one of the 18
  corners**, in both the LEF-only and SPEF-annotated runs, against a 20 ns
  SDC reference period on `clk` (a non-propagated, ideal clock; see
  caveats below). The binding setup corner is **`ss_n40C_1v28`**
  (slow-slow process, −40 °C, 1.28 V): SPEF-annotated WNS **15.1760 ns**
  (LEF-only 15.4650 ns) — i.e. **4.824 ns** of worst-case data-path delay
  plus library setup time at that corner. Every `_ccsnoise` corner
  reproduces its base corner's numbers exactly, as expected (OpenSTA's
  delay calculation does not consume the CCS noise model at this step).
- **Hold: 0 violations at every one of the 18 corners**, in both runs — no
  hold-side WNS/TNS metric exists in `klt sta`'s report (filed upstream as
  `2AMLogic/klayout-tools#1625`), so no corner can be ranked by hold margin,
  but the record confirms the hold-clean result is unanimous across the
  full corner set rather than merely at one corner.
- **SPEF annotation completeness**: every corner reported
  `spef_annotation.annotation_complete: true` with 139/139 design nets
  annotated and an empty missing-sample list; the record's own definition
  would have marked any incomplete corner non-measurement rather than
  recording it.
- **Cross-check**: `layout/logic_tile.par.json`'s independent in-flow
  parasitic estimate (`estimate_parasitics -global_routing`, a different
  extraction method from the same place-and-route run) agrees with the
  extracted-SPEF numbers to within 0.007 ns of slack at the nominal corner
  and 0.08 ns at the binding slow corner — an independent sanity check on
  the extracted-SPEF numbers this record ratifies from.

The record is equally explicit about what these numbers **do not** support
as a claim (quoted, "What these numbers do not claim"):

- **Ideal, non-propagated clock** — the analysed DEF has a real 3-buffer
  clock tree, but `klt sta` times an SDC-only ideal clock; `clock_skew_ns`
  reads 0 at every corner for that reason, not because the tile has zero
  skew.
- **Extrapolated, not bisected, Fmax.** `fmax_mhz` is
  `report_fmax_metric`'s `1/(T−WNS)` extrapolation from a single 20 ns
  analysis, not a bisection search that re-times the design at
  successively shorter periods, and the record states plainly: *"the
  trustworthy numbers in this record are the slacks and the data-path
  delays; the Fmax column is a derived convenience, and the tile's real
  Fmax is an open question this record does not settle."*
- **First-order lumped RC only** (single-hub star topology, one R and one
  ground C per net, quasi-static, no field solve).
- **No power-delivery network** — no IR-drop-induced timing variation
  modeled.
- **Tile only, no switch matrix and no inter-tile routing** — `spec/
  framework-gaps.md` items G1/G2 (the switch matrix) have not landed, so
  nothing in the record characterizes fabric routing delay.

## Decision

**Ratify `spec/tile-spec.md`'s Timing row as the setup/hold slack-and-
corner-coverage claim the record actually supports — and explicitly do
not ratify an Fmax/MHz operating-frequency number.**

> **Timing (v1, tile BEL logic only — no switch matrix)**: the routed tile
> (`layout/logic_tile.def` / `layout/logic_tile.gds`) is setup- and
> hold-clean — 0 violations, 0 total negative slack — at every one of the
> 18 `sky130_fd_sc_hd` PVT corners the sky130A PDK ships, both with
> unannotated (LEF-only) and SPEF-annotated (extracted-parasitic)
> delays, against a 20 ns non-propagated-clock SDC reference period on
> `clk`. The binding setup corner is `ss_n40C_1v28`: SPEF-annotated WNS
> **15.1760 ns** (LEF-only 15.4650 ns). No corner binds on hold (0
> violations at all 18 corners, both runs). **No Fmax/MHz
> operating-frequency number is ratified by this row** — see "Why no
> Fmax is ratified" below. Scope: this row characterizes the tile's BEL
> logic only; it says nothing about switch-matrix or inter-tile routing
> delay, which do not exist yet (`spec/framework-gaps.md` items G1/G2).
>
> Source: `measurements/timing-characterization/records/
> 20260909-225431-86f71d2.md` (PR #22 / issue #20), regenerable via
> `./flow/sta-sweep.sh`. This decision record: `spec/decisions/
> 0002-tile-timing-spec-ratification.md`.

### Why no Fmax is ratified

The record that is this decision's sole evidentiary source disclaims its
own `fmax_mhz` figure as untrustworthy at the margin this tile actually
measures ("the tile's real Fmax is an open question this record does not
settle"). Ratifying an extrapolated number its own source record flags as
unreliable would be exactly the kind of overclaim `CLAUDE.md`'s
verification-first posture ("no claim without a testbench") exists to
prevent, and would hand a future EE-key review (`ratification/ee-key/`,
Step 2's evidence-tier check) a row it would have to reject on its own
source material. The trustworthy, ratifiable subset of the record is the
slack/violation-count result; the Fmax column is left unratified pending a
future bisected and/or propagated-clock STA run, which would be new
evidence requiring its own decision record, not a promotion of today's
extrapolation.

## Alternatives considered

- **(a) Ratify an Fmax/MHz number from the binding corner's extrapolated
  `fmax_mhz`** (e.g. "≥207 MHz" from `ss_n40C_1v28`'s SPEF-annotated
  207.29 MHz). **Rejected.** The source record itself disclaims this exact
  number's trustworthiness; ratifying it anyway would assert a stronger
  claim than the cited evidence supports, in direct tension with
  `CLAUDE.md`'s evidence-first rule and this repo's own review mechanism
  (the EE key grades a proposed row's evidence tier, not just its
  plausibility).
- **(b) Leave the Timing row unratified until switch-matrix timing (G1/G2),
  propagated-clock STA, and bisected Fmax all land** — i.e. take no action
  in this record. **Rejected.** T1 checklist item 5 needs *some* ratified
  target to verify the tile's already-characterized BEL logic against now
  that PR #22 produced real, corner-complete measured data; declining to
  ratify the trustworthy subset of that data because the untrustworthy
  subset (Fmax) is not ready yet would block genuine progress on a number
  nobody is proposing to ratify anyway.
- **(c) Ratify the setup/hold slack-and-corner-coverage claim only, with an
  explicit no-Fmax carve-out and an explicit tile-only (no switch matrix)
  scope note.** **Chosen** — the maximal claim the cited record actually
  supports, with the record's own disclaimers carried into the ratified
  text rather than dropped.

## Consequences

- `spec/tile-spec.md`'s Timing row moves from "No numbers in this spec" to
  the ratified slack/corner-coverage claim above once this PR merges with
  both `RATIFY-KEY` approvals. `spec/framework-gaps.md` item G4 is not
  edited by this record (out of scope for this issue/PR) but its "Still
  open" list already correctly names switch-matrix timing,
  propagated-clock analysis, and bisected Fmax as the remaining work this
  record does not close.
- T1 checklist item 5 ("full corner verification vs a ratified spec") now
  has an actual ratified target for the tile's BEL-logic timing to be
  checked against. Re-running or extending that verification against the
  now-ratified row, and any broader consumption of it, is explicitly a
  follow-on — not scoped to this record or its PR (per issue #28's own
  framing).
- Any future claim in this repository that the tile "runs at X MHz," in a
  record, in `docs/`, in an issue, or in a PR, remains **unratified** by
  this record and must cite its own decision record backed by bisected
  and/or propagated-clock evidence before publication. This record does
  not license such a claim by omission, and does not supersede the cited
  record's own "what these numbers do not claim" disclaimers.
- Nothing here relaxes, narrows, or reruns the cited PR #22 record; this
  record only decides what subset of its already-measured numbers is fit
  to publish as a spec target. A future decision record may supersede this
  one once switch-matrix timing, propagated-clock STA, or a bisected Fmax
  measurement lands — as a new record, not a silent edit of this one or of
  `spec/tile-spec.md`'s ratified row.
