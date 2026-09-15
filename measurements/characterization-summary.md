<!-- GENERATED FILE -- do not hand-edit.
     Regenerate with: python3 measurements/generate-characterization-summary.py
     Every number below is read from, or asserted present in, the source
     artifacts cited in each section -- see
     measurements/generate-characterization-summary.py for the checks. -->

# Characterization summary

One aggregated, current snapshot of the tile's design-evidence artifacts -- klayout-tools design-evidence ladder T1 checklist **item 8**. Each row below names a piece of append-only evidence that lives elsewhere in this repo; this file does not introduce any new claim, spec change, or number -- it names, cross-checks, and cites what already exists.

## At a glance

| Evidence | Status | Source | Derived from |
| --- | --- | --- | --- |
| DRC | **clean** (0 violations) | [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) | commit `8a42d84 2026-09-09 17:12:56 -0700` |
| LVS | **match** (0 mismatches, engine `klayout`) | [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) | commit `8a42d84 2026-09-09 17:12:56 -0700` |
| 18-corner STA sweep | **setup/hold-clean at all 18 corners** (binding setup corner `ss_n40C_1v28`, SPEF WNS 15.176 ns) | [`measurements/timing-characterization/records/20260909-225431-86f71d2.md`](measurements/timing-characterization/records/20260909-225431-86f71d2.md) | record `20260909-225431-86f71d2`, git revision `86f71d2` |
| Ratified timing spec row | **RATIFIED** (ADR-0002) | [`spec/tile-spec.md`](spec/tile-spec.md), [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md) | commit `234b13b 2026-09-15 13:15:44 +0000` (tile-spec.md), `234b13b 2026-09-15 13:15:44 +0000` (ADR-0002) |
| SDF-generation + gate-level re-sim | **zero-delay: PASS; SDF-annotated: BLOCKED** (klayout-tools#1890) | [`measurements/timing-characterization/records/20260915-133517-234b13b.md`](measurements/timing-characterization/records/20260915-133517-234b13b.md) | record `20260915-133517-234b13b`, git revision `234b13b` |

## DRC

- **Status**: `clean`, `violation_count`: 0, deck: `sky130`
- **Source**: [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) (analysed-input hash `sha256:a6dc076c0b8d9d314098755f313d4c30f4f8fc7aa57cd411627e3cdc497be452`)
- **Committed at**: `8a42d84 2026-09-09 17:12:56 -0700`

## LVS

- **Status**: `match`, `mismatch_count`: 0, engine: `klayout`, top: `LOGIC_TILE`
- **Source**: [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) (layout GDS hash `sha256:a6dc076c0b8d9d314098755f313d4c30f4f8fc7aa57cd411627e3cdc497be452`)
- **Committed at**: `8a42d84 2026-09-09 17:12:56 -0700`

## 18-corner STA sweep

- **Coverage**: all 18 `sky130_fd_sc_hd` liberty corners the sky130A PDK ships, 3 runs per corner (LEF-only on the committed DEF, LEF-only on a name-rewritten control DEF, SPEF-annotated on the name-rewritten DEF). Cross-checked directly against the 18 per-corner `corners/<corner>/{lef-only,spef}.sta.json` reports: setup-violation count, hold-violation count and total negative slack are 0 at every corner in both the LEF-only and SPEF-annotated run, and every SPEF run reports `spef_annotation.annotation_complete: true`.
- **Binding setup corner** (minimum SPEF-annotated `worst_slack_ns` across all 18 corners): **`ss_n40C_1v28`** -- WNS 15.465 ns (LEF-only) / 15.176 ns (SPEF-annotated), extrapolated `fmax_mhz` 207.295 (SPEF-annotated).
- **Fastest corner**: `ff_n40C_1v95` -- WNS 19.5887 ns (SPEF-annotated), `fmax_mhz` 2431.13.
- **Fmax caveat carried forward** (per the source record and ADR-0002): `fmax_mhz` is a single-period `1/(T-WNS)` extrapolation, not a bisected measurement -- the slacks above are the trustworthy numbers; no Fmax/MHz figure is ratified anywhere in this repo.
- **Source**: [`measurements/timing-characterization/records/20260909-225431-86f71d2.md`](measurements/timing-characterization/records/20260909-225431-86f71d2.md), harness `flow/sta-sweep.sh`.
- **Record / git revision**: `20260909-225431-86f71d2`, produced at git revision `86f71d22fce3e7bd5c40389cd7c3822628826b64`. Committed at: `8a42d84 2026-09-09 17:12:56 -0700`.

## Ratified timing spec row

- **Status**: ratified (ADR-0002). Current `spec/tile-spec.md` Timing row (read live from the file, not retyped here):

  > **RATIFIED 2026-09-15 (ADR-0002, #28)** — tile BEL logic only (no switch matrix): setup- and hold-clean (0 violations, 0 TNS) at all 18 `sky130_fd_sc_hd` PVT corners, LEF-only and SPEF-annotated, against a 20 ns non-propagated-clock SDC period on `clk`; binding setup corner `ss_n40C_1v28`, SPEF WNS 15.1760 ns. **No Fmax/MHz number ratified** — see `spec/decisions/0002-tile-timing-spec-ratification.md`.

- **Source**: [`spec/tile-spec.md`](spec/tile-spec.md) (summary table), decision record [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md).
- **Committed at**: `234b13b 2026-09-15 13:15:44 +0000` (tile-spec.md), `234b13b 2026-09-15 13:15:44 +0000` (ADR-0002).

## SDF-generation + gate-level re-simulation

- **Zero-delay leg**: PASS (`sim/tb_logic_tile.v`, unmodified, run gate-level against the as-built netlist) -- functional-only, no timing claim.
- **SDF-annotated leg**: BLOCKED by a real, generically-reproducible upstream defect in `$sdf_annotate` (crashes on escaped identifiers containing `.`/`[]`, which this design's flattened `generate`-block RTL produces) -- filed as [klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890), not worked around with a fabricated result.
- **Source**: [`measurements/timing-characterization/records/20260915-133517-234b13b.md`](measurements/timing-characterization/records/20260915-133517-234b13b.md); post-route SDF artifact: [`measurements/timing-characterization/logic_tile_route.sdf`](measurements/timing-characterization/logic_tile_route.sdf).
- **Record / git revision**: `20260915-133517-234b13b`, produced at git revision `234b13b845299ff0b9e479ea95229a5963ebf9ea`. Committed at: `6f3bb57 2026-09-15 13:55:12 +0000`.

## Regenerating

```
python3 measurements/generate-characterization-summary.py
```

Reads and cross-checks the JSON/markdown sources named above; fails loudly (non-zero exit, no file written) rather than emitting a report that has drifted from them. It does not re-run any tool -- run `./flow/layout.sh`, `./flow/sta-sweep.sh` and/or `./flow/sdf-resim.sh` first if you need to regenerate the underlying evidence itself (see `measurements/README.md`).
