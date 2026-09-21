# ADR-0003: Re-ratify the tile timing spec row's figure of record from the post-PDN 18-corner STA record

- **Status**: Proposed — ratified upon this PR merging with both
  `RATIFY-KEY` approvals (two-key ratification mechanism,
  `2AMLogic/2am#372`), per the standing ratification-via-PR policy
  (`2AMLogic/2am#357`, 2026-08-19) — the same policy and mechanism that
  ratified ADR-0002, whose evidentiary lineage this record extends.
- **Date**: 2026-09-21
- **Decided by**: Builder (issue #42), updating the figure of record of
  `spec/tile-spec.md`'s Timing row as ratified by
  `spec/decisions/0002-tile-timing-spec-ratification.md`
- **Related**: #42 (this issue), #41 / PR #55 (the power delivery network
  whose merged geometry the successor record measures), #28 / PR #30 /
  ADR-0002 (the original ratification this record extends), #49 (klt
  0.3.0 → 0.5.0 toolchain drift, entangled with the delta this record
  ratifies), `measurements/timing-characterization/records/
  20260921-062500-e8a37ad.md` (the evidence this record ratifies from)

## Context

ADR-0002 ratified `spec/tile-spec.md`'s Timing row from the pre-PDN
18-corner `klt sta` sweep (`measurements/timing-characterization/records/
20260909-225431-86f71d2.md`): setup- and hold-clean at all 18 corners,
binding setup corner `ss_n40C_1v28`, SPEF-annotated WNS 15.1760 ns, no
Fmax ratified. Since then issue #41 (PR #55) added a real power delivery
network to the tile layout (`flow/layout.sh`'s `power` block: met1
followpin row rail, met4/met5 straps, tapcells), which moves the DEF and
GDS the SPEF is extracted from — so the analysed inputs the ratified row
pins by content hash changed legitimately. The post-PDN 18-corner
re-sweep is committed as successor record
`measurements/timing-characterization/records/20260921-062500-e8a37ad.md`
(`record-meta.supersedes: 20260909-225431-86f71d2`), which re-meets every
qualitative criterion of ADR-0002 and explicitly does not re-ratify
anything itself: *"Not a re-ratification. ADR-0002's ruling is untouched;
this record re-meets its criteria against the post-PDN geometry."* It
defers the spec-row update to this issue — deliberately, because editing
a RATIFIED spec row is a spec change, and per `CLAUDE.md` spec changes go
through `spec/` with a decision record. This is that decision record.

## What moved between the two records

Read from the two records' own `record-meta` provenance blocks:

- **Geometry (the analysed inputs)** — `layout/logic_tile.def` moved
  `sha256:de91eee9…` → `sha256:2979e7fb…` and `layout/logic_tile.gds`
  `sha256:a6dc0769…` → `sha256:38498092…`: #41's PDN is inside the
  analysed geometry now. The extracted SPEF (regenerated, not committed)
  moved with them.
- **Toolchain** — klt `0.3.0+gc6dbf66c53c6` → `0.5.0+g2b7caa9939af`.
  The recorded OpenROAD version string is unchanged
  (`26Q3-1278-g4421880472` in both records), and the recorded PDK is
  unchanged (`open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b` in
  both). #41's successor record additionally documents (its
  "Re-verification" section) that the operator-local OpenROAD image has
  since moved past the recorded version and the SPEF-annotation legs
  **cannot currently be re-run** on the verifying host (the escaped-
  identifier annotation regression of klayout-tools#1623/#1624
  resurfacing through a moved tool) — the committed per-corner reports
  remain the recorded-toolchain evidence for the annotated legs.
- **Harness** — `flow/sta-sweep.sh`'s content hash moved (itself a #41
  change; the analysis shape is unchanged), while its two helper
  scripts (`flow/sta_sanitize_names.py`, `flow/sta_report_trim.py`) are
  hash-identical between the records.

Per this issue's own framing the two inputs that matter for reading the
delta are the **PDN geometry** and the **klt 0.3.0 → 0.5.0 toolchain
bump** — but both moved, so the measured WNS move cannot be attributed to
the PDN alone. The committed evidence does not separate the two
contributions, and this record does not claim it does.

## Evidence relied on (from `measurements/timing-characterization/records/20260921-062500-e8a37ad.md`)

- **Setup and hold: 0 violations, 0 total negative slack at every one of
  the 18 `sky130_fd_sc_hd` PVT corners, in both the LEF-only and
  SPEF-annotated runs**, against the same 20 ns non-propagated-clock SDC
  reference period on `clk` — identical qualitative verdicts to the
  superseded record, re-measured on the committed post-PDN geometry.
  These facts are re-derived, not retyped: the repo's summary generator
  (`measurements/generate-characterization-summary.py`) asserts them
  directly against the 36 committed per-corner reports
  (`corners/<corner>/{lef-only,spef}.sta.json`), and
  `./flow/audit-evidence.sh` re-derives the record's PDK-pinning and
  provenance walk — both green on this PR's tree.
- **Binding setup corner**: still **`ss_n40C_1v28`**, SPEF-annotated WNS
  **15.2146 ns** (LEF-only 15.465 ns). Was:
  SPEF-annotated 15.1760 ns (LEF-only 15.4650 ns) in the superseded
  record.
- **The move lives in the annotation legs.** LEF-only binding-corner WNS
  is unchanged (15.4650 → 15.465 ns), so the entire figure-of-record
  move — **+0.0386 ns (≈ +39 ps) of slack** — sits in the LEF→SPEF
  interconnect delta at the binding corner (0.2890 → 0.2504 ns). The
  fastest corner's SPEF-annotated WNS moved the same direction
  (19.5887 → 19.5927 ns, `ff_n40C_1v95`). That is consistent with a
  re-extracted post-PDN SPEF and/or a changed klt
  extraction/annotation engine, and — per "What moved" above — the
  committed evidence does **not** let the ~39 ps be attributed to the
  PDN geometry alone; the klt 0.3.0 → 0.5.0 bump is an unseparated
  possible contributing factor (see #49, which tracks that drift).
- **Fmax caveat unchanged**: `fmax_mhz` remains a single-period
  `1/(T−WNS)` extrapolation (208.967 at the binding corner, SPEF, under
  the successor record), not a bisected measurement — ADR-0002's
  no-Fmax ruling is untouched by this record.

## Decision

**Re-ratify `spec/tile-spec.md`'s Timing row against the successor
record: ADR-0002's ratified claim shape is unchanged, and the row's
figure of record moves from the superseded record's 15.1760 ns /
`20260909-225431-86f71d2` to 15.2146 ns / `20260921-062500-e8a37ad`.**

> **Timing (v1, tile BEL logic only — no switch matrix)**: the routed
> tile (`layout/logic_tile.def` / `layout/logic_tile.gds`, post-PDN
> geometry) is setup- and hold-clean — 0 violations, 0 total negative
> slack — at every one of the 18 `sky130_fd_sc_hd` PVT corners the
> sky130A PDK ships, both with unannotated (LEF-only) and
> SPEF-annotated (extracted-parasitic) delays, against a 20 ns
> non-propagated-clock SDC reference period on `clk`. The binding setup
> corner is `ss_n40C_1v28`: SPEF-annotated WNS **15.2146 ns**
> (LEF-only 15.465 ns). No corner binds on hold (0 violations at all 18
> corners, both runs). **No Fmax/MHz operating-frequency number is
> ratified by this row** — per ADR-0002's no-Fmax ruling, which this
> record does not touch.
>
> Source: `measurements/timing-characterization/records/
> 20260921-062500-e8a37ad.md` (successor of ADR-0002's cited
> `20260909-225431-86f71d2`; regenerable via `./flow/sta-sweep.sh`, see
> the record's own "Re-verification" section for the current
> annotation-leg re-run blocker). This decision record:
> `spec/decisions/0003-tile-timing-spec-re-ratification.md`.

ADR-0002 is **extended, not superseded as a ruling**: its decision (which
subset of a measured record is fit to publish as a spec target, and the
explicit no-Fmax carve-out) stands unchanged; only the figure of record
and the record citation move, because the geometry the row's number
measures moved. Both records stay committed (records are append-only);
`measurements/generate-characterization-summary.py`'s lineage walk from
the current record back to the ADR-0002-cited original still traverses
`20260921-062500-e8a37ad` → `20260909-225431-86f71d2`, so the
ratification's evidence traceability is preserved with no generator
change.

## Alternatives considered

- **(a) Leave the row citing the pre-PDN record.** **Rejected.** The row
  would state a WNS its cited record did not measure on the committed
  layout — the pre-PDN record pins DEF/GDS content
  (`sha256:de91eee9…` / `sha256:a6dc0769…`) that no longer describe the
  tree, which is exactly the "ratified row is backed by a superseded
  record" state this issue exists to clear. `flow/audit-evidence.sh`'s
  supersession carve-out keeps such a citation *legal* (append-only
  records are answered by successors, never rewrote), but legality is
  not currency: the spec-of-record should state the number the
  currently-committed layout measures.
- **(b) Edit the number quietly — in #41's PR or in this one without a
  decision record.** **Rejected.** `CLAUDE.md`: spec changes go through
  `spec/` with a decision record, ratified by the PR that merges it;
  and ADR-0002's own Consequences state that a future supersession is
  "a new record, not a silent edit of this one or of the ratified row."
  #41 deliberately regenerated the *evidence* and left the row to this
  issue; anything else would be the unreviewed spec drift the rule
  exists to prevent.
- **(c) Defer re-ratification until the ~39 ps attribution (PDN vs klt
  toolchain) is bisected by new records.** **Rejected.** The ratifiable
  claim — setup/hold-clean at all 18 corners with the measured WNS on
  the committed geometry under the recorded lineage — does not depend
  on resolving that attribution: both qualitative verdicts and the
  binding corner are identical across the two records, and the move
  keeps the row's claim strictly *stronger* (more slack) than the
  figure it replaces. A separating experiment (re-extracting the
  pre-PDN geometry under klt 0.5.0, or the post-PDN geometry under
  pinned klt 0.3.0) would be new evidence requiring its own record in
  any case — and the SPEF-annotation legs currently cannot be re-run on
  the verifying host at all (upstream tool regression, per the
  successor record), so the bisect is blocked upstream, not merely
  unscheduled. The attribution stays an explicitly open question,
  recorded below, rather than a blocker for the figure of record.

## Consequences

- `spec/tile-spec.md`'s Timing row now carries the re-ratified figure
  (SPEF WNS 15.2146 ns from `20260921-062500-e8a37ad`) alongside
  ADR-0002's original ratification annotation and ADR-0003, once this PR
  merges.
- **No Fmax is ratified by this update either.** The binding-corner
  extrapolated `fmax_mhz` moved 207.29 → 208.967 between the records and
  remains unratified in both; ADR-0002's no-Fmax ruling binds this row
  unchanged.
- **The ~39 ps attribution question (PDN geometry vs klt 0.3.0 → 0.5.0)
  is recorded as open**, entangled with #49's toolchain-drift work. Any
  future record that separates the two contributions is new evidence:
  it needs its own measurement record and, if it moves the figure of
  record, its own decision record superseding this one.
- `measurements/characterization-summary.md` picks the new row up by
  regeneration alone (the generator reads the Timing row live from
  `spec/tile-spec.md` and its source cites stay unchanged); its
  supersedes-chain walk from the current record to the ADR-0002-cited
  original is untouched.
- ADR-0002 is not edited by this record or its PR; it remains the
  ratification-of-principle for the claim shape and the no-Fmax
  carve-out. Both decision records are cited by the updated row, and a
  future decision record superseding *this* one's figure follows the
  same append-only rule this one followed.
