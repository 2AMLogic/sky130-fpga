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
- **`../spec/tile-spec.json`, `item-6-not-applicable.json`** — the recorded
  item 6 `not_applicable` outcome (issue #212): a JSON rendering of the
  ratified spec rows and the per-row statement of why none is statistical,
  both content-hash-pinned in the manifest's `"6"` entry (see the item 6
  row below).
- **`item-2-layout.json`** — the artifact-anchored generic envelope for T1
  item 2 (see the item rows below).
- **`item-{1,9,10}-inventory.json`** — the versioned
  `t1-attestation-inventory` files (issue #236) listing every RTL file,
  testbench/harness, and hygiene file/CI lane each claim covers.
- **`item-1-design-sources.json`, `item-9-testbenches.json`,
  `item-10-repo-hygiene.json`** — the **tool-produced** envelopes for items
  1, 9 and 10, written by `klt signoff --attest N --inventory …`. Never
  hand-edit them. Each records a per-file hash check, so editing any
  inventoried file makes `--check` fail.
- **`tier-report.json`** — the committed **evidence record**:
  `klt signoff --manifest block-manifest.json --format json` output,
  verbatim. This is the verdict of record for the block's gap to T1; the
  gap-to-T1 tracker issue (#4) points here instead of carrying its own
  hand-maintained checklist.
- **`verify-pins.sh`** — re-hashes every artifact a manifest pin claims,
  from live bytes. See the header comment for what each pin means and which
  flow command reconciles a drift.

## Regenerate and verify

Items 1, 9 and 10 (needs `yosys` for item 1's local-only freshness check;
use the pinned klt, e.g. `KLT="uvx --from klayout-tools==0.8.0 klt"`):

```
for p in "1 design-sources" "9 testbenches" "10 repo-hygiene"; do set -- $p
  $KLT signoff --attest $1 --inventory signoff/item-$1-inventory.json -o signoff/item-$1-$2.json
done
# then copy each envelope's provenance.input.content_hash (the inventory's
# hash) into signoff/block-manifest.json, and continue below.
```

CI runs `klt signoff --attest N --inventory … --check <envelope>` for each
(exit 3 on drift). Item 1's `flow/synth.sh` freshness command is
`local_only`: CI carries its committed outcome and still re-hashes the RTL
and netlist, so an RTL edit without a re-attest fails CI.

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

**9 of 11 T1 items are `met`: items 1, 2, 3, 4, 5, 8, 9, 10, 11. Item 6
renders `not_applicable` (issue #212; counted apart in
`t1_not_applicable_count`, never as `met`). Item 7 renders
`unmet`/`no_evidence` and is deliberately uncited.** Item 11
moved from `unmet`/`lvs_supply_unproven` to `met` in issue #69, when the LVS
report gained `power_connectivity.status: "match"` (see its row below). The
grader is pinned at the PyPI release `klayout-tools==0.8.0` (issue #227).
Moving to it from the dev commit `7755612adb51` changed one item's status:
item 5 went `met` to `unmet`/`partial_coverage` (`missing_kinds:
["functional-verification"]`), because 0.8.0 derives item-5 spec-row coverage
from the envelopes' `spec_row` tags (klayout-tools#3768/#3778) and the
manifest cites only the `klt sta` envelope. The record is committed as
graded, not relaxed. Issue #228 supplied the missing evidence (a cited
`klt functional-verification` envelope, see the item 5 row) and item 5 is `met`
again.
Item 10's citation hash moved with the workflow bytes, and the grader
metadata (`build`, ruleset id, checklist document hash, item 4 and 6 text)
changed. The earlier move from
`3a75c3ae705b7ad3803625255de93bcd982e70c6` changed no item's status except
item 6 (`unmet`/`no_evidence` to `not_applicable`); item 10's citation hash
moved with the workflow bytes and item 11's grader note text was reworded.
Earlier, moving to the `3a75c3ae…` pin had changed no row for
items 3, 4, 8 or 11 (item 11 kept reason `lvs_supply_unproven` until
issue #69); the only
other differences in `tier-report.json` are the grader's own metadata
(a `build` block, `build_t1_item_count`, and the checklist document hash).
Item 5's citation (issue #68) did not need a grader bump. The pinned
grader already recognizes the multi-corner `klt sta` shape (#1959) and its
`timing_status` pass rule. The design-flow klt that produced the envelope
(now `0.8.0`, issue #228) is a separate pin, `RECORDED_STA_KLT_VERSION` in
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
  0 errors. The manifest pins the report's `provenance.input.content_hash`
  (`sha256:193095a1…`), which hashes the layout-side SPICE netlist
  `klt extract` produced from the committed GDS. `layout_gds_sha256` ties
  the same report to the committed GDS, and `verify-pins.sh` re-checks that
  tie. Since issue #69, `power_connectivity.status` is `"match"` (power
  pins `VGND`/`VPB`/`VPWR`, 63 instances, 0 findings), produced by klt
  `0.7.0` onward (klayout-tools#2121) and re-stamped under `0.8.0` in issue
  #228 (`RECORDED_LVS_KLT_VERSION`). The 0.8.0 compare is `status: match` with
  top-level pin anchoring on (`options.anchor_top_level_pins` unset, i.e. the
  default; 94 pins anchored, none rejected); the report is otherwise unchanged
  apart from 0.8.0's added fields and `schema_version: 2`. Before that it was `"unchecked"`, because
  `flow/lvs.sh` disabled the check. Scope disclosure:
  - The netlist compare is **signal-connectivity only**: the as-built
    reference carries no supply pins.
  - Its two warning-severity entries are `topology.power_only_pruned` (the
    16 tapcells pruned) and `topology.top_level_pins_anchored` (94
    top-level pins anchored by name).
  - The power check is layout-side pin consistency, not island count or
    well taps. Those stay with item 11's ERC evidence.
  - The reference netlist came from a different run than the GDS, under the
    newer klt (`flow/lvs.sh --update-report`). The GDS is unchanged.

  See `layout/README.md`, "LVS scope, concretely".
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
- **Item 11 (power delivery, structural) — met** (issue #69). The
  compound citation has three parts, each passing its own gates:
  - The `klt erc` supply run is clean: 0 findings, every declared supply
    one island, 0 `missing_tie`, a spec stackup covering the PDN's
    met1/met4/met5 straps, and the live spec hash re-verified.
  - The LVS report is the item-4 one, now with
    `power_connectivity.status: "match"`.
  - The `klt place-and-route` response reports `power.pdn: true` with
    `tapcell_master` named.

  The grader's `power_delivery` block in `tier-report.json` echoes this:
  supply nets `VPWR`/`VGND`, `pdn: true`, strap layers met1/met4/met5,
  tapcell `sky130_fd_sc_hd__tapvpwrvgnd_1`, `power_connectivity_status:
  "match"`. Until issue #69 the row was `unmet`/`lvs_supply_unproven`.
  `flow/lvs.sh` disabled the LVS power check because the pre-#2121
  `--abstract-cells` extraction split each row's n-well into a row-local
  `VPB` net. klayout-tools#2082 showed that was an artifact, #2121 fixed it,
  and klt `0.7.0+g4cbdfa769875` carries the fix. Disclosures the grader
  cannot make:
  - The ERC part grades `check_status: "clean_partial"` with
    `coverage_qualification.reason: "partial_coverage"`. The skipped
    entries are antenna levels with `missing_antenna_limit` (sky130's
    antenna table has no met3–met5 limits, klayout-tools#1997). That was
    already true of the report; the `met` row now surfaces it in
    `tier-report.json`.
  - `supply_unlabelled_islands` is `{}`: the supply spec declares no
    `nets[].roles`, so the severed-unlabelled-rail question was not asked.
    That means "not measured", not zero.
  - `VNB` is not among the LVS power pins; the abstracted cells expose no
    `VNB` pin.
  - Structural only: no IR drop, EM or current-density analysis.
- **Items 1, 9, 10 — met, by tool-produced attestation envelopes** (issue
  #236; klayout-tools#2844). `klt signoff --attest N --inventory
  signoff/item-N-inventory.json` runs the checks the inventory declares and
  emits the `"kind": "generic"` envelope (`attestation.producer: "klt signoff
  --attest"`); its `status` is derived from those checks, not asserted. The
  envelope pins the inventory's bytes in `provenance.input`, and its
  `attestation.checks[]` carry a per-file hash for every member, so the
  binding covers the whole set. `klt signoff --attest N --inventory … --check
  <envelope>` (run by the signoff CI lane) exits 3 when any member changed.

  | Item | Envelope | Inventory members |
  | ---- | -------- | ----------------- |
  | 1 Design sources | `item-1-design-sources.json` | all four `design/rtl/*.v` files plus `design/netlist/logic_tile_netlist.v`, whose freshness command is `./flow/synth.sh` (yosys; `local_only`) |
  | 9 Testbenches shipped | `item-9-testbenches.json` | every `sim/tb_*.v`, the cocotb test, the FABulous equivalence benches, `measurements/claim-traceability.md`, the audit scripts; cold start `./flow/audit-evidence.sh`; PDK and tool pins |
  | 10 Repo hygiene | `item-10-repo-hygiene.json` | `README.md`, `LICENSE`, `spec/tile-spec.md`, every `.github/workflows/*.yml`; check: the status-claim checker's unit tests |

  Limits: item 1's yosys freshness command cannot run on the CI runner, so
  CI proves the RTL and netlist bytes are unchanged since the last local
  attest rather than re-synthesizing; run the attest command locally after
  any RTL edit. The check commands are fixed by the inventory, so the
  attestation says "these files, at these hashes, passed these commands" and
  nothing about the substance of the audit beyond that. Item 2 remains an
  artifact-bound generic envelope on `layout/logic_tile.gds`
  (klayout-tools#2718: `item-2-layout.json`). Native DRC or LVS envelopes are
  deliberately not cited for these rows.
- **Item 5 (corner verification against a ratified spec) — `met`** (STA:
  issue #68; functional verification: issue #228). Two cited envelopes. The
  first:
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
  SPEF WNS 15.2145 ns under klt `0.8.0` (unchanged from `0.7.0`). That is -0.1 ps
  against ADR-0003's figure of record of 15.2146 ns. The spec row is
  unchanged; see record `20261008-234741-dc615b4` for every corner's delta; the
  klt 0.8.0 re-sweep (`20261027-201500-9111a08`) moved no number.

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

  **The functional-verification member** (issue #228).
  `signoff/item-5-functional-verification.json` is the `klt
  functional-verification` envelope of `sim/cocotb/test_bitstream_fabric.py`
  (6 cocotb tests, all pass), generated by `flow/functional-verification.sh`
  from the run's own `results.xml`. The committed FABulous frame streams
  (`sim/bitstream/top_io.bin`, `top_reg.bin`) are decoded by the
  repository's stream decoder into the `cfg` port of
  `design/rtl/logic_tile_routed.v` and the mapped designs' function is
  checked against independent oracles. A one-off manual negative control (flipping a used
  switch-matrix select bit of the loaded `cfg`) made the comb/reg tests fail;
  it is not a committed test. Honest limits:
  - It is zero-delay RTL on the G1 harness fabric: no timing, no inter-tile
    routing. It is the cocotb counterpart of `sim/tb_logic_tile_bitstream.v`
    for the `comb` and `reg` designs; it does not repeat that testbench's
    `+mutate` sweep, its Verilog-side loader checks, or the corpus designs.
  - The manifest declares `spec_rows` for item 5 (`timing` -> the STA
    envelope, `switch-matrix-routing-tracks` -> the functional-verification
    envelope). The grader reports `row_sources: "asserted"` for both: 0.8.0
    derives rows from `spec_row` tags only on `klt sim` `measurements[]`, and
    neither envelope has them. The row-to-envelope assignment is this repo's
    claim, not a grader finding.
  - `klt functional-verification` envelopes carry no input hash, so the
    manifest cannot pin one (pinning grades `unverifiable_provenance`).
    Freshness is `flow/functional-verification.sh` check mode (byte-exact
    reproduction of the committed envelope); `verify-pins.sh` checks only its
    internal consistency. The only normalisation applied to the envelope is
    machine-local paths and per-test wall-clock time.
  - The timing-correct functional leg, the SDF-annotated gate-level
    re-simulation, is still blocked. That is item 7: klayout-tools#1890 closed
    only as a fail-loud guard; re-tried 2026-10-08 under #72, the gap is now
    klayout-tools#2897 (record `20261008-233733-23e6b5e`).

  Not covered by the STA member:
  - propagated-clock timing (the clock is an ideal SDC clock);
  - any Fmax figure (`fmax_mhz` is a `1/(T-WNS)` extrapolation, and none
    is ratified);
  - the switch matrix and inter-tile routing, which have no
    implementation yet.
- **Item 6 — `not_applicable`.** The tile's spec rows are architectural and
  timing; none is statistical (accuracy/offset/matching), so there is no
  Monte-Carlo claim to evidence. The tiers doc requires that absence be
  stated explicitly: **this block's spec has no statistical row. No
  `klt yield` evidence exists or is owed.** The statement is now
  machine-checkable (klayout-tools#2865): the manifest's `"6"` entry cites
  `spec/tile-spec.json` and `signoff/item-6-not-applicable.json`, and editing
  either file renders the item `unmet`/`stale_evidence`. What it does **not**
  claim: `spec/tile-spec.md` is still **Draft**, and the JSON lists only the
  rows the markdown itself marks ratified — the architectural routing-track
  count and the ADR-0002/0003 timing row. The other rows (LUT count, FF
  arrangement, carry, tile I/O, fabric size, bitstream) carry no ratification
  stamp and the physical routing pitch is explicitly deferred (G3), so they
  are absent from the JSON rather than overclaimed; none of them is
  statistical either. Ratifying them is a spec change (decision record), not
  part of this record.
- **Item 7 — uncited.** The SDF-annotated gate-level re-simulation leg is
  blocked by a real upstream defect (`$sdf_annotate` crashes on escaped
  identifiers, klayout-tools#1890); the zero-delay leg passing is recorded
  in the characterization record but is, by the item's own text, the
  pre-layout run — so no citable envelope exists for this item until
  #1890's successor gap closes (#1890 itself closed 2026-09-16 as a fail-loud guard in klt v0.6.0 only; re-tried under #72, still blocked, now tracked as klayout-tools#2897). No result was fabricated to fill the row.
