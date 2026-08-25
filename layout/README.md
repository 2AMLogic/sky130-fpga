# layout

Tile physical design — GDS + DRC/LVS reports.

## Current contents (T1 item 2)

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

Regenerate + check both with:

```
./flow/layout.sh            # regenerate, diff against the committed copies
./flow/layout.sh --update  # regenerate and overwrite the committed copies
```

## What this is, concretely

44.33um x 44.33um die (40% target / 44.17% actual core utilization), 44
standard-cell instances (`sky130_fd_sc_hd`), 0 routing DRC violations and 0
antenna violations from OpenROAD's own detailed-route pass, across all 16
`sky130_fd_sc_hd` PVT corners the flow's default sweep reports. See
`logic_tile.par.json` for the full per-corner numbers.

## What this is NOT (non-goals of this issue, #9)

- **Not DRC/LVS-signed-off.** The 0-violation counts above are OpenROAD's
  own internal routing-stage checks (antenna + TritonRoute detailed-route
  DRC), not a full foundry-rule-deck `klt drc` run or a `klt lvs` netlist
  comparison against this GDS. That signoff is `spec/framework-gaps.md` item
  G3, a separate follow-on issue.
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
  PDN is follow-on work alongside G3's DRC signoff, where it will actually
  matter (no `power` block routes clean here but is not full-chip-ready).
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
