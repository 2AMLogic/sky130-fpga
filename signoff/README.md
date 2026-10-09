# signoff

This block's **graded** gap-to-T1 state — the `klt signoff` block manifest
(issue #52) that replaces the hand-read checklist, per
`docs/design-evidence-tiers.md`
([klayout-tools](https://github.com/2AMLogic/klayout-tools)).

The fleet roll-up consumes exactly these files (2AMLogic/2am#956); a
block's row is identified by the manifest's `block` field.

## Files

- **`block-manifest.json`** — this block's declaration: `block: sky130-fpga`,
  `kind: digital` (RTL flow: yosys synthesis + OpenROAD place-and-route, not
  the hand-captured full-custom sub-case), and per-item evidence citations,
  each pinning the cited envelope's input `content_hash` so a stale
  pairing grades `stale_evidence`, never a false pass.
- **`characterization-evidence.json`** — the opt-in **generic evidence
  envelope** (`"kind": "generic"`) for T1 item 8, the one item that names no
  `klt` verb: a minimal wrapper asserting the aggregated characterization
  record (`measurements/characterization-summary.md`, itself generated from
  the committed reports/records) is current, with its content hash pinned in
  `provenance.input` and in the manifest's item-8 citation.
- **`../measurements/timing-characterization/logic_tile.sta.json`** — not
  in this directory, but cited from here for T1 item 5: the trimmed
  multi-corner `klt sta` response (`pdk.corners`, all 18 ratified corners in
  one request) that `flow/sta-sweep.sh` writes and gates (issue #68; see the
  item-5 row below).
- **`item-1-design-sources.json`, `item-2-layout.json`,
  `item-9-testbenches.json`, `item-10-repo-hygiene.json`** — the
  artifact-anchored generic envelopes for T1 items 1, 2, 9 and 10 (see the
  item rows below).
- **`tier-report.json`** — the committed **evidence record**:
  `klt signoff --manifest block-manifest.json --format json` output,
  verbatim. This is the verdict of record for the block's gap to T1; the
  gap-to-T1 tracker issue (#4) points here instead of carrying its own
  hand-maintained checklist.
- **`verify-pins.sh`** — re-hashes every artifact a manifest pin claims,
  from live bytes. See the header comment for what each pin means and which
  flow command reconciles a drift.

## Regenerate and verify

```
./signoff/verify-pins.sh                                    # every pin still matches live bytes
klt signoff --manifest signoff/block-manifest.json --format json > signoff/tier-report.json
# exit 3 is expected while any T1 item is unmet; exit 0 means T1.
```

`.github/workflows/signoff.yml` runs both on every push/PR and byte-diffs
the fresh grade against the committed `tier-report.json` — a manifest citing
an artifact that has since changed fails the build rather than rotting.

klt is pinned in the workflow to the exact upstream commit whose bundled
checklist graded the committed record; a klt bump must land together with a
regenerated `tier-report.json`. Order matters: finalize
`.github/workflows/signoff.yml` first (the item-10 envelope binds its bytes),
refresh the envelope and manifest hashes, run `verify-pins.sh`, and
regenerate `tier-report.json` last.

## What the record says, item by item (and what it cannot)

`klt signoff` met/unmet grading is mechanical; the rows below state what the
grader **cannot** check — the claim-side disclosures
`docs/design-evidence-tiers.md` makes this repo's responsibility.

**8 of 11 T1 items are `met`: items 1, 2, 3, 4, 5, 8, 9, 10. Item 11 is `unmet`
(`lvs_supply_unproven`); items 6 and 7 render `unmet`/`no_evidence` and are
deliberately uncited.** The grader is pinned at klayout-tools
`3a75c3ae705b7ad3803625255de93bcd982e70c6`. Moving to it changed no row for
items 3, 4, 8 or 11 (item 11 keeps reason `lvs_supply_unproven`); the only
other differences in `tier-report.json` are the grader's own metadata
(a `build` block, `build_t1_item_count`, and the checklist document hash).
Item 5's citation (issue #68) did not need a grader bump. The pinned
grader already recognizes the multi-corner `klt sta` shape (#1959) and its
`timing_status` pass rule. The design-flow klt that produced the envelope
(`0.7.0+g6fd0278268cc`) is a separate pin, `RECORDED_STA_KLT_VERSION` in
`flow/tool_versions.sh`. It descends from the grader commit and carries
byte-identical signoff code.

- **Item 3 (DRC) — met.** `layout/logic_tile.drc.json`, `status: clean`,
  pinned to the committed GDS. The coverage disclosure the item requires,
  quoted from the cited envelope (`coverage` also rides along in the tier
  report's citation): `layers_in_stream_without_rules` lists 23 layers the
  deck has no rule for (labels/pins drawn on li1–met5, nwell/dnwell
  markers, the 65/44 tap-diff, and 78/44–236/0 via/PDK-marker layers);
  `rules_skipped` is exactly the MiM-capacitor family (`capm`/`capm2` width,
  space, separation and enclosure rules plus `met3.enclosing.capm.1`,
  `met4.enclosing.capm2.1`) — this digital tile has no instance of them;
  `deck_scope` is the deck's own chapter list (poly, li, licon, m1–m5,
  nwell, difftap, ct, via, via2, via3, via4, capm, cap2m). A "clean" scoped
  to that coverage is the
  claim — meet it via `--engine klayout` on the foundry's own DRC-DSL deck
  is separate follow-on work (see `layout/README.md`, "DRC scope,
  concretely").
- **Item 4 (LVS) — met.** `layout/logic_tile.lvs.json`, `status: match`,
  pinned to the as-built gate-level reference netlist the compare ran
  against (regenerated + hashed by `flow/lvs.sh` every run;
  `layout_gds_sha256` ties the same report to the committed GDS, and
  `verify-pins.sh` re-checks that tie). Scope disclosure: the compare is
  **signal-connectivity only** — its one warning-severity entry
  (`topology.power_only_pruned`) records the tapcells being pruned, and
  `power_connectivity.status` is `"unchecked"` because the as-built
  reference netlist carries no supply pins (see `layout/README.md`, "LVS
  scope, concretely"). The grader accepts `"unchecked"` here (it is not
  `"mismatch"`); the power half of the item-4 claim is carried by item 11's
  ERC geometry evidence, not by this compare.
- **Item 8 (characterization) — met.** The generic envelope wraps
  `measurements/characterization-summary.md` — the single generated
  aggregate of DRC, LVS, ERC, the 18-corner SPEF-annotated STA sweep, the
  ratified timing row (ADR-0002, WNS figure of record re-ratified by
  ADR-0003) and the SDF re-simulation status — pinned by content hash
  twice (envelope + manifest). `python3 measurements/
  generate-characterization-summary.py --check` must pass when this
  citation is regenerated: a regeneration of it (and then of this envelope,
  the manifest pin, and `tier-report.json`) is the expected cadence whenever
  an evidence source changes — same regen cadence PRs #55/#58/#59 already
  follow.
- **Item 11 (power delivery, structural) — `unmet`, reason
  `lvs_supply_unproven`.** The compound citation is complete and each part
  passes its own gates: the `klt erc` supply run is clean (0 findings:
  every declared supply one island, 0 `missing_tie`, spec stackup covering
  the PDN's met1/met4/met5 straps, live spec hash re-verified), the LVS
  report is the item-4 one, and the `klt place-and-route` response reports
  `power.pdn: true` with `tapcell_master` named. The one missing condition
  is the one the reason names: LVS `power_connectivity.status: "match"`
  against a reference that carries the supplies — impossible today because
  `klt place-and-route`'s as-built netlist is written without power pins
  (upstream klayout-tools#2121 is the tracked fix; `flow/lvs.sh` carries the
  dated re-enable trigger). This row exists (per the issue's acceptance
  criterion) so the fleet roll-up reports the *real* remaining blocker, not
  a hand-wave.
- **Items 1, 2, 9, 10 — met, by artifact-bound generic envelopes**
  (klayout-tools#2718). These items have no `klt` verb behind them. Each is
  cited through a `"kind": "generic"` envelope that declares its `t1_item`,
  names the audited file in `provenance.input.path` (resolved beside the
  envelope, hence the `../` prefix) and pins that file's hash; the manifest
  pins the same hash and the grader re-hashes the file itself
  (`artifact_binding.input_verified: true`). The envelope cannot be cited for
  another item (`wrong_item`), and a changed artifact turns the row
  `unmet`/`stale_evidence`.

  | Item | Envelope | Bound artifact |
  | ---- | -------- | -------------- |
  | 1 Design sources | `item-1-design-sources.json` | `design/netlist/logic_tile_netlist.v` (regenerated by `flow/layout.sh` from `design/rtl/`) |
  | 2 Layout | `item-2-layout.json` | `layout/logic_tile.gds` |
  | 9 Testbenches shipped | `item-9-testbenches.json` | `measurements/claim-traceability.md` (the issue #34 audit; `./flow/audit-evidence.sh` re-derives its machine half) |
  | 10 Repo hygiene | `item-10-repo-hygiene.json` | `.github/workflows/signoff.yml` |

  What the binding does **not** do: the grader verifies bytes and item
  identity, not the substance of the audit; `status: "pass"` is this repo's
  own assertion. Item 1 hashes the netlist only, not the RTL under
  `design/rtl/`. Item 10 hashes the workflow only, so README, `spec/` and
  `LICENSE` are inspected but a change to them does not turn the row stale.
  Because the item-10 binding covers the workflow, any edit to
  `.github/workflows/signoff.yml` (comments included) requires refreshing the
  item-10 envelope hash and the manifest pin (`verify-pins.sh` fails until
  you do), then regenerating `tier-report.json` last. Native DRC or LVS
  envelopes are deliberately not cited for these rows.
- **Item 5 (corner verification against a ratified spec) — met, STA half
  only** (issue #68). Cited envelope:
  `measurements/timing-characterization/logic_tile.sta.json`, the trimmed
  response of **one** `klt sta` request with `pdk.corners` listing all 18
  `sky130_fd_sc_hd` corners ADR-0002 ratified and ADR-0003 re-ratified,
  against the committed routed geometry with the extracted SPEF annotated
  and the 20 ns `clk` reference period. The grader passes it because every
  corner it declares is `timing_status: "constrained"` with non-negative
  setup and hold slack (`citation.kind: "sta"`). The grader only grades the
  corner set the run declared, so `flow/sta_envelope_check.py` adds the
  claim-side checks it cannot make:
  - exactly the 18 ratified corners, none missing, duplicated or extra;
  - zero violations and zero setup and hold TNS at every corner;
  - complete SPEF annotation at every corner;
  - an `fmax_mhz` consistent with a 20 ns period;
  - field-for-field agreement with the per-corner single-corner SPEF
    reports, which carry the name-rewrite neutrality control.

  `flow/sta-sweep.sh` refuses to record an envelope that fails this gate,
  and `verify-pins.sh` re-runs it. Binding setup corner `ss_n40C_1v28`,
  SPEF WNS 15.2145 ns under klt `0.7.0+g6fd0278268cc`. That is -0.1 ps
  against ADR-0003's figure of record of 15.2146 ns. The spec row is
  unchanged; see record `20261008-234741-dc615b4` for every corner's delta.

  **What the pin binds.** The manifest's item-5 `content_hash` is the
  envelope's `provenance.input.content_hash`: the hash of the DEF OpenSTA
  actually analysed. That is the name-sanitized derivative of
  `layout/logic_tile.def`, which `flow/sta-sweep.sh` writes to `flow/build/`
  and does not commit. It is not the hash of the report file, and not the
  hash of the committed DEF. The trimmer drops the envelope's absolute
  scratch `def_path`, so the grader has no file to re-hash and reports
  `input_verified: null`. `verify-pins.sh` closes that gap instead:
  - it regenerates the sanitized DEF from the committed DEF with the same
    `flow/sta_sanitize_names.py def-sanitize`;
  - it requires that hash to equal both the envelope's input pin and the
    manifest pin;
  - it ties the envelope's `layout_def_sha256`, `layout_gds_sha256` and
    `spef_sha256` to the committed DEF, GDS and SPEF
    (`measurements/timing-characterization/logic_tile.spef`, committed
    from this re-sweep on).

  Changing the committed DEF, GDS or SPEF, or the pin, without re-running
  `./flow/sta-sweep.sh --update` fails `verify-pins.sh` with the
  regeneration command.

  **What this citation does not cover.** Item 5's digital text asks for
  multi-corner STA **plus** a bit-exact functional test suite. This
  citation covers the STA half only. The bit-exact functional half is
  currently the zero-delay testbench evidence: `sim/run.sh`'s RTL
  testbenches (`tb_lut4_slice`, `tb_logic_tile`), plus the zero-delay
  gate-level `tb_logic_tile` PASS against the as-built `sky130_fd_sc_hd`
  netlist (record `20260921-062530-e8a37ad`). None of it is a `klt
  functional-verification` envelope, and none of it is cited. The
  timing-correct functional leg, the SDF-annotated gate-level
  re-simulation, is still blocked. That is item 7: klayout-tools#1890
  closed only as a fail-loud guard; re-tried 2026-10-08 under #72, the
  gap is now klayout-tools#2897 (record `20261008-233733-23e6b5e`). The
  grader marks item 5 `met` on the STA envelope alone, so this paragraph
  is the disclosure. Also not covered:
  - propagated-clock timing (the clock is an ideal SDC clock);
  - any Fmax figure (`fmax_mhz` is a `1/(T-WNS)` extrapolation, and none
    is ratified);
  - the switch matrix and inter-tile routing, which have no
    implementation yet.
- **Item 6 — uncited.** The tile's spec rows are functional and timing —
  none is statistical (accuracy/offset/matching), so the Monte-Carlo item
  has nothing to attach to. The tiers doc requires that absence be stated
  explicitly rather than silently omitted: **this block's spec has no
  statistical row.** No `klt yield` evidence exists or is owed.
- **Item 7 — uncited.** The SDF-annotated gate-level re-simulation leg is
  blocked by a real upstream defect (`$sdf_annotate` crashes on escaped
  identifiers, klayout-tools#1890); the zero-delay leg passing is recorded
  in the characterization record but is, by the item's own text, the
  pre-layout run — so no citable envelope exists for this item until
  #1890's successor gap closes (#1890 itself closed 2026-09-16 as a fail-loud guard in klt v0.6.0 only; re-tried under #72, still blocked, now tracked as klayout-tools#2897). No result was fabricated to fill the row.
