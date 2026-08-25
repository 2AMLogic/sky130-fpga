# layout

Tile physical design — GDS + DRC/LVS reports.

## Current contents (T1 items 2-4)

- `logic_tile.gds` — a placed-and-routed sky130 GDS for the tile
  (`logic_tile` = 4x `lut4_slice`, per `design/rtl/`), synthesized against
  `sky130_fd_sc_hd` and floorplanned/placed/routed via klayout-tools'
  (`klt`) digital flow (`klt synthesize` -> `klt place-and-route`, backed by
  Yosys + OpenROAD). Regenerated and diff-checked against `design/rtl/` by
  `flow/layout.sh` on every invocation — see `flow/README.md`.
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

Regenerate + check all with:

```
./flow/layout.sh            # regenerate GDS + P&R report, diff against the
                            # committed copies
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
                              # consistent GDS + P&R report + LVS report
                              # together (see "LVS scope, concretely"
                              # below for why) -- run ./flow/drc.sh --update
                              # afterward to keep the DRC report in sync.
```

## What this is, concretely

44.33um x 44.33um die (40% target / 44.17% actual core utilization), 44
standard-cell instances (`sky130_fd_sc_hd`), 0 routing DRC violations and 0
antenna violations from OpenROAD's own detailed-route pass, across all 16
`sky130_fd_sc_hd` PVT corners the flow's default sweep reports. See
`logic_tile.par.json` for the full per-corner numbers.

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

## What this is NOT (non-goals of this issue, #9)
- **Not a timing claim.** `constraints.clock_period_ns` in
  `flow/layout.sh` (20ns / 50MHz) is a deliberately loose placeholder that
  exists only because `klt place-and-route` requires *some* target period
  once routing is reached — it is not a characterized Fmax. Real timing
  characterization (extracted parasitics + STA against sky130 corners) is
  `spec/framework-gaps.md` item G4, not yet done. The `fmax_mhz` /
  `*_slack_ns` fields in `logic_tile.par.json` are OpenROAD's own
  pre-signoff estimates from this placed-and-routed netlist — evidence the
  flow ran successfully and met its (loose) placeholder target, not a
  published performance number.
- **No power delivery network.** This first pass has no `power` block in
  the `klt place-and-route` request (no PDN straps/tapcells) — matching the
  precedent of klayout-tools' own `sky130_fd_sc_hd` worked example, which
  reaches a clean route without one (unlike some other cell libraries; see
  `docs/cli/place-and-route.md` in `2AMLogic/klayout-tools`). A committed
  PDN is separate follow-on work, where it will actually matter (no
  `power` block routes clean here but is not full-chip-ready) — see "LVS
  scope, concretely" above for why its absence is not a gap for the LVS
  compare specifically.
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
