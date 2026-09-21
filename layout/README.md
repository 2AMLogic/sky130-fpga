# layout

Tile physical design — GDS + routed DEF + DRC/LVS/ERC reports.

## Current contents (T1 items 2-4, 11)

- `logic_tile.gds` — a placed-and-routed sky130 GDS for the tile
  (`logic_tile` = 4x `lut4_slice`, per `design/rtl/`), synthesized against
  `sky130_fd_sc_hd` and floorplanned/placed/routed via klayout-tools'
  (`klt`) digital flow (`klt synthesize` -> `klt place-and-route`, backed by
  Yosys + OpenROAD). Regenerated and diff-checked against `design/rtl/` by
  `flow/layout.sh` on every invocation — see `flow/README.md`.
- `logic_tile.def` — the routed DEF from the **same** `klt place-and-route`
  run as `logic_tile.gds` above: the same geometry in the form a
  connectivity-aware tool can link against. Committed because a standalone,
  multi-corner `klt sta` characterization (`flow/sta-sweep.sh`,
  `measurements/timing-characterization/`) re-times one fixed piece of
  routed geometry at N corners, and a GDS alone carries no instance/net
  connectivity for OpenSTA to link. Unlike the GDS it needs no
  canonicalization — the DEF is already byte-reproducible across runs of
  the identical, seeded request (see "Reproducibility note" below).
  Regenerated and diff-checked by `flow/layout.sh` alongside the GDS and
  the P&R report.
- `logic_tile.par.json` — the place-and-route run's own metrics report
  (die/core area, utilization, wirelength, per-corner setup/hold slack,
  routing DRC/antenna violation counts), trimmed of local-path and
  tool-version fields so it is comparable across machines. This is the
  "place-and-route log/report establishing the tile met its target pitch
  and area" evidence `spec/framework-gaps.md` item G2 calls for.
- `logic_tile.drc.json` — a full-deck `klt drc` (klayout-tools) DRC report
  against `logic_tile.gds`: `status: "clean"`, 0 violations, run against
  klt's built-in `sky130` rule deck. Regenerated and checked (rerun +
  reproducibility diff + `klt drc --check` provenance-freshness check) by
  `flow/drc.sh` on every invocation. This is T1 item 3 (DRC clean) of
  `docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`, per issue
  #11 — see "DRC scope, concretely" below for exactly what this claim does
  and does not cover.
- `logic_tile.lvs.json` — a `klt lvs` (klayout-tools, `"klayout"` engine)
  LVS report comparing `logic_tile.gds` against its own as-built
  gate-level reference netlist (`reference.form = "gate-level-verilog"`,
  from the same `klt place-and-route` run): `status: "match"`, 0
  mismatches. Regenerated and checked by `flow/lvs.sh` on every invocation.
  This is T1 item 4 (LVS clean) of `docs/design-evidence-tiers.md` in
  `2AMLogic/klayout-tools`, per issue #12 — see "LVS scope, concretely"
  below for exactly what this claim does and does not cover.
- `erc-supply-spec.json` — the T1 checklist item 11 (power delivery,
  structural, klayout-tools#2025) `klt erc` **supply spec**: `VPWR`/`VGND`
  declared as `nets[]` entries with `"kind": "supply"`, a `stackup` over
  the routing levels this block actually uses (poly/li1/met1–met4, with
  `active_layer` on the gate role), the licon1/mcon/via1–via3 via stack,
  and `label_layer`s only where the merged GDS carries supply pin text.
  It deliberately declares **no `ties[]`** — klayout-tools#2169 — so
  `erc.missing_tie` is *not computed* by any run of it; see the file's
  own comment block (which documents every entry's derivation, per issue
  #51) and "ERC scope, concretely" below.
- `logic_tile.erc.json` — the committed `klt erc --format json` report of
  that spec against `logic_tile.gds`, its `provenance.input.content_hash`
  pinning the committed GDS (the same `sha256:a6dc076c…` the DRC/LVS
  reports cite). Its current verdict is the honest, recorded state of
  this block's power delivery: **not one island per supply** — `VPWR`
  resolves to 7 disconnected electrical islands, `VGND` to 8 (the 15
  isolated met1 rails issue #41 names) — which is why T1 item 11 is
  **unmet** here, not a harness failure. Regenerated and diff-checked by
  `flow/erc.sh` on every invocation. See "ERC scope, concretely" (issue
  #51) for exactly what this claim does and does not cover.

Regenerate + check all with:

```
./flow/layout.sh            # regenerate GDS + DEF + P&R report, diff
                            # against the committed copies
./flow/layout.sh --update  # regenerate and overwrite the committed copies

./flow/drc.sh               # rerun DRC against the committed GDS, diff the
                            # report against the committed copy, and verify
                            # provenance freshness
./flow/drc.sh --update     # rerun DRC and overwrite the committed report
                            # (run after ./flow/layout.sh --update)

./flow/lvs.sh                # rerun LVS against the committed GDS and its
                              # freshly-regenerated as-built reference
                              # netlist, and diff the report against the
                              # committed copy. Does NOT touch the
                              # committed GDS/P&R report.
./flow/lvs.sh --update       # regenerate AND commit a fresh, mutually
                              # consistent GDS + DEF + P&R report + LVS
                              # report together (see "LVS scope,
                              # concretely" below for why) -- run
                              # ./flow/drc.sh --update afterward to keep
                              # the DRC report in sync.

./flow/erc.sh                # rerun klt erc (spec: layout/erc-supply-spec.json)
                              # against the committed GDS, diff the report
                              # against the committed copy, and verify it
                              # still content-hash-pins the committed GDS
                              # and spec. Needs no PDK install.
./flow/erc.sh --update      # rerun and overwrite the committed ERC report
                              # (run after ./flow/layout.sh --update, and
                              # after any supply-spec edit)

./flow/sta-sweep.sh          # re-extract parasitics from the committed GDS
                              # and re-time the committed DEF at all 18
                              # liberty corners, diffing every per-corner
                              # report under measurements/. Does NOT touch
                              # anything in layout/.
./flow/sta-sweep.sh --update # same, but overwrite the committed per-corner
                              # reports (run after any layout change, and
                              # add a new record under
                              # measurements/timing-characterization/records/)
```

## What this is, concretely

44.33um x 44.33um die (40% target / 44.17% actual core utilization), 47
logic `sky130_fd_sc_hd` instances plus 138 physical-only `fill_*` cells
(185 components total — see "Row rail, not a PDN" below), 0 routing DRC
violations and 0 antenna violations from OpenROAD's own detailed-route
pass, across all 16 `sky130_fd_sc_hd` PVT corners the flow's default sweep
reports. See `logic_tile.par.json` for the full per-corner numbers.

## DRC scope, concretely (issue #11)

`logic_tile.drc.json`'s `status: "clean"` is a full-deck `klt drc` run
(klayout-tools) against `logic_tile.gds` using klt's default **curated**
engine — KLayout's native `Region`-primitive checks, run fully headless
(no GUI/Qt, no standalone `klayout` binary), against klt's own built-in
`sky130` rule deck. Precisely:

- **What it checks**: `klt deck info --deck sky130` reports device-class
  coverage for `nfet`/`pfet`/`pnp`/`sky130_fd_pr__model__cap_mim`(`_m4`)/
  `resistor`; the report's own `coverage` block records exactly which
  layers were checked (`layers_checked`), which layers present in the
  stream have no deck rule (`layers_in_stream_without_rules`), and which
  deck rules were skipped because their layers (met4/met5/capm/capm2/via4
  — this tile's I/O only routes up to met3, per `flow/layout.sh`'s
  `io.layer_h`/`layer_v`) are absent from the stream (`rules_skipped`) —
  so "clean" is scoped to what was actually checked, not asserted blind.
- **What it is not**: klt's own `klt deck info` reports this build's
  `sky130` deck as `"released": false` (a klt-internal maturity flag, not a
  correctness claim about this run), and this is the **curated** engine's
  in-house deck — not klt's alternate `--engine klayout` PDK-native
  DRC-DSL path (`klt drc --engine klayout`, which shells out to a
  standalone `klayout` binary to run sky130's own `.lydrc` signoff deck via
  KLayout's DRC-DSL). That engine was not exercised here: this environment
  has no standalone `klayout` binary on `PATH` (`klt drc --engine klayout`
  fails cleanly with "binary not found on PATH" — expected, documented
  behavior per `klt drc --help`, not a tool gap). A full foundry-signoff
  DRC-DSL pass, if wanted, is separate follow-on work.
- **LVS is separate.** `klt lvs` (netlist-vs-layout comparison) is
  `spec/framework-gaps.md` item G3's other half — see "LVS scope,
  concretely" below (issue #12).
- **Which PDK revision this was run against** is *not* in the report:
  `klt drc` writes `provenance.pdk: null` even though `flow/drc.sh` invokes
  it with `--pdk sky130A` (filed upstream as klayout-tools#1901). The PDK
  revision for this claim — and for the LVS claim below, same gap — is
  pinned in `flow/tool_versions.sh` (`RECORDED_PDK_VERSION`) and printed,
  with a warning on mismatch, at the top of every `flow/drc.sh` /
  `flow/lvs.sh` run. See `measurements/claim-traceability.md` (T1 item 9)
  and `./flow/audit-evidence.sh`.

## LVS scope, concretely (issue #12)

`logic_tile.lvs.json`'s `status: "match"` is a `klt lvs` run (klayout-tools,
default `"klayout"` engine, `klayout.db.NetlistComparer`) comparing
`logic_tile.gds` against `klt place-and-route`'s own as-built gate-level
Verilog netlist from the same run (`reference.form =
"gate-level-verilog"`, `docs/cli/lvs.md`'s "Digital gate-level LVS" path),
since the generic-cell `design/netlist/logic_tile_netlist.v` cannot
topologically match a `sky130_fd_sc_hd`-built layout (see
`design/README.md`). Precisely:

- **What it checks**: every `sky130_fd_sc_hd` standard-cell instance is
  abstracted to a pin-only black box on both sides (`klt extract
  --abstract-cells 'sky130_fd_sc_hd__*' --def-net-names`), so the compare
  is device/net/pin *topology* only — 44 standard-cell instances, 0
  mismatches, `counts.pins`/`counts.nets` both sides matching once the
  layout's internal, DEF-recovered net names are demoted from top-level
  pins via `--pins` (see `flow/README.md`'s `flow/lvs.sh` section).
- **What it is not**: this compare is **signal-connectivity only** — no
  power/ground pins are compared (`docs/cli/lvs.md`'s "No power/ground
  pins" note: `verilog_path` is written without `-include_pwr_gnd`). This
  is not a gap for this tile specifically: per "No power delivery network"
  below, this layout has no PDN to begin with, so there is no power
  connectivity for this mode to miss. It is also not a device-parameter
  (transistor-level) check — the abstracted black-box cells carry no
  device geometry to compare.
- **Why the layout and reference netlist must come from the same run**:
  verified live while building this evidence — two independent
  `klt place-and-route` runs in the *same* environment (same seed, same
  synthesized netlist) reproduce a byte-identical as-built netlist, but a
  netlist regenerated in a *different* toolchain environment than whatever
  built the committed GDS found 8 `sky130_fd_sc_hd__mux4_2` instances (2
  per `lut4_slice`, all 4 slices) that could not be topologically matched
  — different environments' synthesis genuinely picked a different (if
  functionally equivalent) gate-level structure for those instances. So
  `logic_tile.gds`/`logic_tile.par.json` here are the pair
  `flow/lvs.sh --update` most recently regenerated together with
  `logic_tile.lvs.json` from the identical synth + place-and-route run —
  not independently re-derived artifacts that merely happen to agree.
- **Escaped-identifier workaround**: this design's `generate`-block RTL
  (`design/rtl/logic_tile.v`'s `g_slice[N].u_slice`) produces an as-built
  netlist whose internal names are Verilog *escaped* identifiers
  (`\g_slice[0].u_slice/_01_`), which `klt lvs`'s
  `reference.form = "gate-level-verilog"` converter misparses — a real,
  generically-filed tool gap
  ([`2AMLogic/klayout-tools#1371`](https://github.com/2AMLogic/klayout-tools/issues/1371)).
  `flow/lvs_sanitize_verilog.py` works around it with a
  connectivity-preserving, name-only rewrite before the compare — see that
  script's own header comment for why the rewrite cannot change the
  verdict.

## ERC scope, concretely (issue #51)

`logic_tile.erc.json` + `erc-supply-spec.json` are the **T1 checklist item
11 (power delivery, structural)** evidence — `klt erc`'s supply-spec run,
approved as
[klayout-tools#2025](https://github.com/2AMLogic/klayout-tools/pull/2025)
on 2026-09-17 and tracked by issues #51 and #4. Precisely:

- **What it checks**: every declared supply net resolving to exactly **one**
  electrical island. The spec declares `VPWR`/`VGND` (`kind: "supply"`, the
  row-rail pair `logic_tile.par.json`'s `power.row_rail` names), a
  poly→li1→met1→met2→met3→met4 stackup with `active_layer` on the gate
  role (`poly ∩ diff` gate identification excludes the fill cells' oxide-
  free poly), the licon1/mcon/via1–via3 via stack, and `label_layer`s only
  on li1.label (67/5) and met1.label (68/5) — the only two layers the merged
  GDS carries supply pin text on. A `klt erc` run over this model is a pure
  geometry/connectivity extraction (a `klayout.db.LayoutToNetlist` wire
  graph, no device recognition): no PDK install is read and no netlist
  input exists — this is the
  *structural* question ("is the supply connected to what it powers"), not
  the *analysis* one (IR-drop/EM, `klt power`, deliberately outside item 11).
- **What the committed report says, honestly**: `erc_finding_count: 2` —
  `VPWR` resolves to **7** disconnected electrical islands and `VGND` to
  **8** (`erc.unconnected_net`, zero `erc.supply_short`, zero
  `erc.floating_gate` over all 232 extracted gate nets). This is not a
  harness failure or a spec tuned to fail: it is the electrical
  confirmation of what "Row rail, not a PDN" below has said all along —
  the 15 per-row met1 rails never bridge vertically (8 + 7 = 15, the rail
  count issue #41 derives independently from the DEF's `SPECIALNETS`).
  **T1 item 11 is therefore unmet in this repo**, exactly as the gap-to-T1
  tracker's eleventh row records; closing it requires the PDN work tracked
  in #41 (and, per #42, a timing re-ratification against the PDN-bearing
  layout once it exists).
- **What it does not cover, per the item's own text**: the antenna verdicts
  in the report are all `unchecked` — `--pdk` (klt's built-in
  antenna-ratio table) is deliberately not passed, because an antenna or
  floating-gate finding is a real defect but is *not* item 11's subject and
  does not block it
  ([klayout-tools#1994](https://github.com/2AMLogic/klayout-tools/issues/1994)).
  `erc.missing_tie` is **not computed** — the spec declares no `ties[]`
  (a real routed standard-cell design under `klt erc`'s current `ties[]`
  collapses into one island and reports a FALSE `erc.supply_short` —
  [klayout-tools#2169](https://github.com/2AMLogic/klayout-tools/issues/2169),
  reproduced four ways in gf180-drone-fc's FRICTION F-034), so the check is
  absent from the run's scope entirely: an **absence of evidence, not
  evidence of absence** — `klt signoff`'s tier-verdict renders a no-ties
  spec `supply_spec_incomplete` for exactly this reason
  (klayout-tools#2199). The well-tie evidence that does stand in: the
  merged GDS carries the standard cells' own well/bulk PG pin text (201
  `VPB` labels on nwell.label 64/5, 201 `VNB` on pwell.label 64/59) plus
  the supply pin labels above — but the layout has **no drawn ties at all**
  (zero 65/44 tap geometry, `power.tapcell_master: null`), which is part
  of the same #41 gap. For completeness, the item's digital-column extras
  are also unmet here: the place-and-route request has no `power` block
  (`power.pdn: false`, `straps: []`), and the LVS compare is
  signal-connectivity-only (see "LVS scope, concretely" above), so there is
  no `power_connectivity: "match"` to cite — those land with the PDN work
  too.
- **Freshness/reproducibility**: `flow/erc.sh` re-runs
  `klt erc layout/logic_tile.gds layout/erc-supply-spec.json --top
  logic_tile --format json` from the repo root on every invocation, trims
  the tool-version fields (`flow/erc_report_trim.py`, same convention as
  the DRC/LVS reports), byte-diffs against the committed report, and
  re-verifies both of the report's content-hash pins
  (`provenance.input.content_hash` = the committed GDS — the same
  `sha256:a6dc076c…` the DRC and LVS reports cite — and
  `provenance.spec.content_hash` = the committed supply spec). No PDK
  install is involved anywhere in the check.

## What this is NOT (non-goals of this issue, #9)
- **Not a timing claim — the numbers in `logic_tile.par.json` still are
  not one.** `constraints.clock_period_ns` in `flow/layout.sh` (20ns /
  50MHz) is a deliberately loose placeholder that exists only because `klt
  place-and-route` requires *some* target period once routing is reached —
  it is not a characterized Fmax. The `fmax_mhz` / `*_slack_ns` fields in
  `logic_tile.par.json` are OpenROAD's own pre-signoff estimates
  (`estimate_parasitics -global_routing`) from this placed-and-routed
  netlist — evidence the flow ran successfully and met its (loose)
  placeholder target, not a published performance number. **The
  characterized timing lives elsewhere**: `spec/framework-gaps.md` item G4
  is addressed by `measurements/timing-characterization/`, which re-times
  the committed `logic_tile.def` with parasitics extracted from
  `logic_tile.gds` at all 18 `sky130_fd_sc_hd` liberty corners
  (`flow/sta-sweep.sh`). Read that record — and its own "what these
  numbers do not claim" list — before citing any timing number from this
  repo.
- **Row rail, not a PDN.** The `klt place-and-route` request still has no
  `power` block (no PDN straps, no tapcells). klt does unconditionally draw
  a `met1` `-followpins` row rail over the standard-cell VPWR/VGND pins
  before global routing, and place `fill_*` cells to close row gaps, as a
  routing *obstruction* — without it the router may legally route a signal
  across an unfilled gap on the same `met1` the row rail occupies, a
  `klt drc`-invisible short once a filler's PG strap lands there
  (klayout-tools#1442). That is a correctness guard, not electrical
  completeness: there is no strap grid, no tapcell, and no IR-drop
  analysis, so no timing or reliability number here accounts for supply
  droop. A committed PDN is separate follow-on work — see "LVS scope,
  concretely" above for why its absence is not a gap for the LVS compare
  specifically, and note that the `fill_*` cells it inserts are why
  `flow/lvs.sh` abstracts `sky130_fd_sc_hd__[!f]*` rather than `__*`.
- **Not the tile's switch matrix / inter-tile routing.** Same BEL-level
  scope as `design/rtl/` — see `design/README.md`.

## Reproducibility note: GDS timestamp canonicalization

Two runs of the identical, seeded `klt place-and-route` request produce a
byte-identical DEF but **not** a byte-identical GDS — `klt`'s DEF->GDS merge
(KLayout, in-process) stamps each GDSII structure with the wall-clock time of
the merge. `flow/layout.sh` canonicalizes this away (zeroing those embedded
timestamp fields — see `flow/gds_canonicalize.py`) before diffing/committing,
so the reproducibility check compares actual layout content, not merge
wall-clock time. Filed upstream as a klayout-tools tool gap:
https://github.com/2AMLogic/klayout-tools/issues/1367.
