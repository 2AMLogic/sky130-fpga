# layout

Tile physical design — GDS + DRC/LVS reports.

## Current contents (T1 items 2-3)

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

Regenerate + check all three with:

```
./flow/layout.sh            # regenerate GDS + P&R report, diff against the
                            # committed copies
./flow/layout.sh --update  # regenerate and overwrite the committed copies

./flow/drc.sh               # rerun DRC against the committed GDS, diff the
                            # report against the committed copy, and verify
                            # provenance freshness
./flow/drc.sh --update     # rerun DRC and overwrite the committed report
                            # (run after ./flow/layout.sh --update)
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
- **LVS is separate.** `klt lvs` (netlist-vs-layout comparison) is not run
  here — that is `spec/framework-gaps.md` item G3's other half, filed as
  its own follow-on issue (#12).

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
  PDN is follow-on work alongside G3's LVS signoff (#12), where it will
  actually matter (no `power` block routes clean here but is not
  full-chip-ready).
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
