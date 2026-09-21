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
  from the same `klt place-and-route` run): `status: "match"`,
  `error_count: 0`, and one `severity: "warning"` entry recording that the
  PDN's tapcells were pruned before the compare (see "LVS scope,
  concretely"). Regenerated and checked by `flow/lvs.sh` on every invocation.
  This is the **signal-connectivity** half of T1 item 4 (LVS clean) of
  `docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`, per issue
  #12 — the compare does not look at power/ground at all, so it is only
  half the claim. See "LVS scope, concretely" below for exactly what it
  does and does not cover, and `logic_tile.erc.json` immediately below for
  the other half.
- `flow/erc_supply_spec.json` — the `klt erc` **supply spec** for both the
  T1 checklist **item 11** (power delivery, structural —
  klayout-tools#2025, tracked by issues #51 and #4) and the
  **power-connectivity half of T1 item 4** (issue #41): `VPWR`/`VGND`
  declared as `nets[]` entries with `"kind": "supply"`, a stackup over
  **li1 through met5** (the layers that join the row rails to each other
  live on met4/met5 — a spec that stops lower reports false islands), the
  full via stack through via4, and an `nwell_tap` entry under `ties[]`
  (every `nwell` region must contain a 65/44 tap contact reaching li1 on
  `VPWR`), which is what checks `VPB` and produces the `erc.missing_tie`
  verdict. `ties[]` is safe to declare on the post-#2169 klt builds:
  that issue (well+tie collapse, false `erc.supply_short`) was filed,
  fixed and closed upstream on 2026-09-20, and the committed
  `logic_tile.erc.json` pins the producing klt build in its own
  provenance. See "ERC scope, concretely" below.
- `logic_tile.erc.json` — a `klt erc` supply-connectivity + antenna report
  against `logic_tile.gds`: `erc_finding_count: 0` (no floating supply
  island, no `erc.missing_tie`), 0 antenna `violate` verdicts across 232
  gates. Regenerated and checked by `flow/erc.sh` on every invocation.
  This is the **power-connectivity** half of T1 item 4 and it exists
  because the LVS compare above structurally cannot supply it (issue #41):
  `klt place-and-route`'s as-built `verilog_path` reference netlist carries
  no supply pins, so `klt lvs` drops the layout's VPWR/VGND/VPB nets rather
  than failing on them. Its `provenance.klt_version` records the klt build
  that produced it, which is **not** `flow/tool_versions.sh`'s
  `RECORDED_KLT_VERSION` — `klt erc` postdates that pin, so this report
  necessarily comes from a newer klt than the committed GDS did. The
  verdict is a pure-geometry statement about the GDS whose hash the same
  provenance block pins, so it stays checkable regardless.
  Before the PDN landed, the `klt erc` runs of both specs reported the
  baseline honestly — this spec's invocation gave **7 `erc.missing_tie`**
  plus **2 `erc.unconnected_net`** findings (GDS `sha256:a6dc076c…`), and
  the spec PR #54 shipped for the pre-PDN tree
  measured the same layout at VPWR 7 / VGND 8 islands — against a layout
  whose LVS report nonetheless said `match`.

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
                              # ./flow/drc.sh --update and
                              # ./flow/erc.sh --update afterward to keep
                              # those two reports in sync.

./flow/erc.sh                # rerun the supply-connectivity + antenna ERC
                              # against the committed GDS and diff the
                              # report against the committed copy. Exit 0
                              # iff 0 findings and reproducible.
./flow/erc.sh --update       # rerun ERC and overwrite the committed report
                              # (run after ./flow/lvs.sh --update)

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

44.33um x 44.33um die (40% target / 45.48% actual core utilization), 47
logic `sky130_fd_sc_hd` instances plus 149 physical-only `fill_*` cells and
16 `tapvpwrvgnd_1` tapcells (212 components total — see "Power delivery
network" below), 0 routing DRC violations and 0 antenna violations from
OpenROAD's own detailed-route pass, across all 16 `sky130_fd_sc_hd` PVT
corners the flow's default sweep reports. See `logic_tile.par.json` for the
full per-corner numbers.

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
  deck rules were skipped because their layers are absent from the stream
  (`rules_skipped`) — so "clean" is scoped to what was actually checked,
  not asserted blind. **Since the PDN landed (issue #41) that scope is
  wider**: met4, met5 and via4 now carry real geometry (the power straps
  and their via stack), so the met5 width/space, via4 width/space and
  met4/met5 via4-enclosure rules that used to sit in `rules_skipped` are
  now actually checked. What remains skipped is the MiM-capacitor family
  (`capm`/`capm2`, plus `met4.enclosing.capm2.1`), which this digital tile
  has no instance of. *Signal* routing is still met1-met3 only, per
  `flow/layout.sh`'s `io.layer_h`/`layer_v` — met4/met5 carry supply only.
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
- **Which PDK revision this was run against**: as of the klt build carrying
  the klayout-tools#1901 fix, `layout/logic_tile.drc.json` pins it
  in-artifact (`provenance.pdk.{name,version}`; `flow/drc.sh` resolves the
  PDK itself so the resolution-path `source` field stays deterministic).
  On pre-fix klt builds the same report wrote `provenance.pdk: null` and
  the pin was inherited instead from `flow/tool_versions.sh`
  (`RECORDED_PDK_VERSION`), printed with a warning on mismatch at the top
  of every `flow/drc.sh` / `flow/lvs.sh` run — which remains the fallback
  path, and the LVS claim below carries its pin the same way. See
  `measurements/claim-traceability.md` (T1 item 9) and
  `./flow/audit-evidence.sh`.

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
  pins" note: `verilog_path` is written without `-include_pwr_gnd`). The
  tell is visible in the committed report itself: `net_correspondence`
  carries 21 entries with `reference: null` — 7 `VGND`, 7 `VPWR`, 7 `VPB`
  — layout supply nets the comparer *dropped* rather than failed on,
  because the reference netlist has nothing to match them against.
  **Reading `status: "match"` as a statement about power is therefore a
  category error**, and this README used to make it (issue #41): it cited
  this report for T1 item 4 while, three sections down, describing a layout
  with no power grid at all. A signal-only match is silent about power
  whether the layout is fully strapped or has 15 mutually isolated rails.
  The power half of the claim is `logic_tile.erc.json` / `flow/erc.sh`,
  which works from the GDS geometry and needs no reference netlist. This is
  also not a device-parameter (transistor-level) check — the abstracted
  black-box cells carry no device geometry to compare.
- **The PDN's tapcells are invisible to this compare, by construction.**
  The committed report carries one `severity: "warning"` mismatch entry,
  `topology.power_only_pruned`: `klt lvs` removed
  `SKY130_FD_SC_HD__TAPVPWRVGND_1` and all 16 of its instances from the
  layout side before comparing, because every pin that cell declares is a
  power/ground pin the gate-level-Verilog reference never carries. That is
  correct behavior for a physical-only cell — dropping it is what keeps
  `status: "match"` honest rather than reporting 16 spurious extra
  instances — but it means **LVS says nothing about whether the tapcells
  are there or where they are**. `flow/erc.sh`'s `erc.missing_tie` check
  is what covers that: it is well-region-driven, so a missing or
  mis-placed tap is a finding regardless of what the netlist declares.
  (Relatedly: the `fill_*` cells the flow inserts to close row gaps are why
  `flow/lvs.sh` abstracts `sky130_fd_sc_hd__[!f]*` rather than `__*`;
  `tapvpwrvgnd_1` does not start with `f`, so it *is* abstracted — and then
  pruned, as above.)
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

## Power delivery network (issue #41)

`flow/layout.sh`'s `klt place-and-route` request carries a `power` block,
so the committed layout has an actual, connected power grid rather than the
disconnected row rails it carried until issue #41. As built:

| | |
|---|---|
| Nets | `VPWR` / `VGND`, `global_connect` on |
| Row rail | `met1` followpins, 0.48um wide on the 5.44um row pitch — 15 stripes (8 VGND, 7 VPWR) over the standard-cell PG pins |
| Straps | `met4` 1.6um / 27.14um pitch / 13.57um offset, `met5` 1.6um / 27.2um pitch / 13.6um offset |
| Connects | met1-met4 and met4-met5, i.e. a full via stack (via1/2/3/4) from the row rail to the top strap |
| Tapcells | 16 x `sky130_fd_sc_hd__tapvpwrvgnd_1`, one per well region |
| Special nets | 15 `FOLLOWPIN` + 51 `STRIPE` segments in `logic_tile.def` |

The strap geometry follows the pattern already in production on this PDK in
sibling repos (`sky130-modexp`, `sky130-sar-adc`) rather than being tuned
here; nothing in this repo sizes it against a current budget (see "What this
is NOT" below).

**What proves it is connected.** Not the LVS report — see "LVS scope,
concretely" above for why `status: "match"` is structurally silent about
power. `flow/erc.sh` runs `klt erc` over the GDS geometry with a supply
spec (`flow/erc_supply_spec.json`) covering li1 through met5, rebuilding
the layer-by-layer connectivity model from shapes alone, and commits the
verdict as `logic_tile.erc.json`. Against the committed layout it reports
**0 findings**; against the pre-PDN layout (GDS `sha256:a6dc076c…`) the
identical invocation reported **7 `erc.missing_tie`** (nwell regions with
no tap contact inside them) **and 2 `erc.unconnected_net`** (VPWR and VGND
each resolving to multiple mutually isolated islands).

**Where `VPB` is covered.** The LVS report drops three supply nets, not two
— 7 `VGND`, 7 `VPWR` *and* 7 `VPB` (see "LVS scope, concretely" above) —
but `flow/erc_supply_spec.json` declares only `VPWR` and `VGND` under
`nets`. That is not an omission: `VPB` is the n-well body net, which is not
a drawn conductor on any routing layer but the `nwell` (64/20) region
itself. The spec covers it as a **tie rule** rather than a net — the
`nwell_tap` entry requires every `nwell` region to contain a `tap` (65/44)
contact joining it to `li1` on net `VPWR`. So "is VPB connected" is asked
and answered as `erc.missing_tie`, which is exactly the check that had 7
findings before the PDN landed and has 0 now. Checking it as an ordinary
supply net instead would be wrong: the well is a diffusion region, so it
has no met1–met5 geometry for an island analysis to walk.

**What the antenna half says.** The same report carries `klt erc`'s
per-gate antenna verdicts: 0 `violate` across all 232 gates. Every gate
rolls up to `pass_partial` rather than `pass`, which is the expected
verdict on this PDK and not a violation — sky130's antenna-ratio limit
table has no met3/met4/met5 entries, so some graded level of every gate is
necessarily `unchecked` (klayout-tools#1997). `flow/erc_report_trim.py`
summarizes the ~600 KB per-gate array into the two histograms the report
commits, and spills any `violate` or `unchecked` gate in full, so the
summary cannot hide a violation.

**The supply spec must reach met5.** A spec that stops at met3 reports
false islands on a correctly strapped layout: the straps that join the met1
followpin rails to each other live on met4/met5, so a stackup that omits
those layers cannot see the join and reports every rail as its own island.

## ERC scope, concretely (issues #41 + #51)

`layout/logic_tile.erc.json` + `flow/erc_supply_spec.json` are the **T1
checklist item 11 (power delivery, structural)** evidence — `klt erc`'s
supply-spec run, approved as
[klayout-tools#2025](https://github.com/2AMLogic/klayout-tools/pull/2025)
(2026-09-17), tracked by issues #51 and #4 — and, with the LVS report
above carrying item 4's signal half, also the **power-connectivity half of
T1 item 4** (issue #41). The item landed in two recorded steps: the honest
no-PDN baseline first (PR #54: spec + harness + the committed
`erc_finding_count: 2` report — VPWR 7 islands, VGND 8, `missing_tie` not
computed), and the PDN + clean verdict second (issue #41, this PR).

- **What it checks**: every declared supply net resolving to exactly one
  electrical island, and — through the `nwell_tap` tie rule — every
  `nwell` region containing a tap contact reaching `li1` on `VPWR`
  (the `VPB` question, answered as `erc.missing_tie`). The stackup covers
  li1 through met5 with the full via stack; `klt erc` is a pure
  geometry/connectivity extraction (a `klayout.db.LayoutToNetlist` wire
  graph, no device recognition), so the connectivity half reads no PDK
  install. This is the *structural* question ("is the supply connected to
  what it powers"), not the *analysis* one (IR-drop/EM, `klt power`,
  deliberately outside item 11).
- **What the committed report says**: `erc_finding_count: 0` — every
  supply one island, `missing_tie: 0`, zero `supply_short`, zero
  `floating_gate`, over all 232 extracted gate nets, plus the antenna
  half above. **T1 item 11 is met for this tile**, and item 4's power
  half with it; the gap-to-T1 tracker (#4) can record both.
- **The `ties[]` history** ([klayout-tools#2169](https://github.com/2AMLogic/klayout-tools/issues/2169)):
  PR #54's spec deliberately declared **no `ties[]`** — the interim the
  upstream issue prescribed while a real routed well+tie spec collapsed
  `klt erc`'s connectivity model into one island with a **false**
  `erc.supply_short` (reproduced four ways in gf180-drone-fc F-034);
  `klt signoff` grades a no-ties spec `supply_spec_incomplete`
  (klayout-tools#2199) for exactly that reason. #2169 was fixed and
  closed upstream on 2026-09-20, after which the tie rule is sound:
  this spec carries it, and the committed report — gate count intact
  (232), no short, honest `missing_tie: 0` — pins the producing klt
  build in `provenance.klt_version`, so the claim is checkable against
  exactly the build class that computes it. A *pre*-fix klt running
  check mode against this spec+report fails visibly (verdict fields
  move), which is the reproducibility layer working, not a harness
  defect.
- **Freshness/reproducibility**: `flow/erc.sh` re-runs
  `klt erc layout/logic_tile.gds flow/erc_supply_spec.json --top
  logic_tile --pdk sky130 --format json` from the repo root on every
  invocation (the `--pdk` switch selects only klt's built-in
  antenna-ratio table — the connectivity model opens no PDK path),
  summarizes the per-gate antenna array (`flow/erc_report_trim.py`),
  re-verifies both of the report's content-hash pins (the committed
  GDS and the committed spec), gates on a clean verdict *before* any
  diff is trusted, and byte-diffs against the committed report.

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
- **A connected PDN, but not an IR-drop sign-off.** See "Power delivery
  network" above for what the grid is and what it is checked against. What
  it is *not* is an electrical-margin claim: nothing in this repo computes
  current density, IR drop or electromigration, so no timing or
  reliability number here accounts for supply droop. `klt erc` answers
  "is every supply shape actually joined, and is every well tapped" — a
  topology question — not "is the grid wide enough". Sizing the grid
  against a real current budget is separate follow-on work.
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
