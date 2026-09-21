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
| DRC | **clean** (0 violations) | [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) | commit `e8a37ad 2026-09-21 00:25:53 -0700` |
| LVS | **match** (1 mismatches, engine `klayout`) | [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) | commit `e8a37ad 2026-09-21 00:25:53 -0700` |
| ERC (supply connectivity + antenna) | **0 findings**, 0 antenna `violate` across 232 gates | [`layout/logic_tile.erc.json`](layout/logic_tile.erc.json) | commit `e8a37ad 2026-09-21 00:25:53 -0700` |
| 18-corner STA sweep | **setup/hold-clean at all 18 corners** (binding setup corner `ss_n40C_1v28`, SPEF WNS 15.2146 ns) | [`measurements/timing-characterization/records/20260921-062500-e8a37ad.md`](measurements/timing-characterization/records/20260921-062500-e8a37ad.md) | record `20260921-062500-e8a37ad`, git revision `e8a37ad` |
| Ratified timing spec row | **RATIFIED** (ADR-0002) | [`spec/tile-spec.md`](spec/tile-spec.md), [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md) | commit `234b13b 2026-09-15 13:15:44 +0000` (tile-spec.md), `234b13b 2026-09-15 13:15:44 +0000` (ADR-0002) |
| SDF-generation + gate-level re-sim | **zero-delay: PASS; SDF-annotated: BLOCKED** (klayout-tools#1890) | [`measurements/timing-characterization/records/20260921-062530-e8a37ad.md`](measurements/timing-characterization/records/20260921-062530-e8a37ad.md) | record `20260921-062530-e8a37ad`, git revision `e8a37ad` |

## DRC

- **Status**: `clean`, `violation_count`: 0, deck: `sky130`
- **Source**: [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) (analysed-input hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`)
- **Committed at**: `e8a37ad 2026-09-21 00:25:53 -0700`

## LVS

- **Status**: `match`, `mismatch_count`: 1, engine: `klayout`, top: `LOGIC_TILE`
- **Source**: [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) (layout GDS hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`)
- **Warning-severity entries** (0 error-severity): `topology.power_only_pruned`
- **Scope**: signal-connectivity only -- this compare comes from a `gate-level-verilog` reference carrying no supply pins, so it says nothing about power/ground. The power half of the claim is ERC, below. See `layout/README.md`'s "LVS scope, concretely".
- **Committed at**: `e8a37ad 2026-09-21 00:25:53 -0700`

## ERC (supply connectivity + antenna)

- **Findings**: 0 (no floating supply island, no `erc.missing_tie`)
- **Antenna**: 0 `violate` across 232 gates (232 `pass_partial`, 0 `pass`, 0 `unchecked`). `pass_partial` is the expected sky130 verdict, not a violation: that PDK's antenna-limit table has no met3-met5 entries, so some graded level of every gate is necessarily `unchecked`.
- **Source**: [`layout/logic_tile.erc.json`](layout/logic_tile.erc.json) (layout GDS hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`, produced by klt `0.5.0+g2b1e55e51bb8.dirty`)
- **Why this is separate from LVS**: the LVS compare above is signal-connectivity only and drops the layout's supply nets. This is the check that actually binds the power half of the claim -- against the pre-PDN layout the same invocation reported 9 findings (7 `erc.missing_tie`, 2 `erc.unconnected_net`). See `layout/README.md`'s "Power delivery network".
- **Committed at**: `e8a37ad 2026-09-21 00:25:53 -0700`

## 18-corner STA sweep

- **Coverage**: all 18 `sky130_fd_sc_hd` liberty corners the sky130A PDK ships, 3 runs per corner (LEF-only on the committed DEF, LEF-only on a name-rewritten control DEF, SPEF-annotated on the name-rewritten DEF). Cross-checked directly against the 18 per-corner `corners/<corner>/{lef-only,spef}.sta.json` reports: setup-violation count, hold-violation count and total negative slack are 0 at every corner in both the LEF-only and SPEF-annotated run, and every SPEF run reports `spef_annotation.annotation_complete: true`.
- **Binding setup corner** (minimum SPEF-annotated `worst_slack_ns` across all 18 corners): **`ss_n40C_1v28`** -- WNS 15.465 ns (LEF-only) / 15.2146 ns (SPEF-annotated), extrapolated `fmax_mhz` 208.967 (SPEF-annotated).
- **Fastest corner**: `ff_n40C_1v95` -- WNS 19.5927 ns (SPEF-annotated), `fmax_mhz` 2455.04.
- **Fmax caveat carried forward** (per the source record and ADR-0002): `fmax_mhz` is a single-period `1/(T-WNS)` extrapolation, not a bisected measurement -- the slacks above are the trustworthy numbers; no Fmax/MHz figure is ratified anywhere in this repo.
- **Source**: [`measurements/timing-characterization/records/20260921-062500-e8a37ad.md`](measurements/timing-characterization/records/20260921-062500-e8a37ad.md), harness `flow/sta-sweep.sh`.
- **Record / git revision**: `20260921-062500-e8a37ad`, produced at git revision `e8a37ad641c7913495f8e9aa14d5dd4c1bf93d45`. Committed at: `unknown (no commit found)`.

## Ratified timing spec row

- **Status**: ratified (ADR-0002). Current `spec/tile-spec.md` Timing row (read live from the file, not retyped here):

  > **RATIFIED 2026-09-15 (ADR-0002, #28)** — tile BEL logic only (no switch matrix): setup- and hold-clean (0 violations, 0 TNS) at all 18 `sky130_fd_sc_hd` PVT corners, LEF-only and SPEF-annotated, against a 20 ns non-propagated-clock SDC period on `clk`; binding setup corner `ss_n40C_1v28`, SPEF WNS 15.1760 ns. **No Fmax/MHz number ratified** — see `spec/decisions/0002-tile-timing-spec-ratification.md`.

- **Source**: [`spec/tile-spec.md`](spec/tile-spec.md) (summary table), decision record [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md).
- **Committed at**: `234b13b 2026-09-15 13:15:44 +0000` (tile-spec.md), `234b13b 2026-09-15 13:15:44 +0000` (ADR-0002).

## SDF-generation + gate-level re-simulation

- **Zero-delay leg**: PASS (`sim/tb_logic_tile.v`, unmodified, run gate-level against the as-built netlist) -- functional-only, no timing claim.
- **SDF-annotated leg**: BLOCKED by a real, generically-reproducible upstream defect in `$sdf_annotate` (crashes on escaped identifiers containing `.`/`[]`, which this design's flattened `generate`-block RTL produces) -- filed as [klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890), not worked around with a fabricated result.
- **Source**: [`measurements/timing-characterization/records/20260921-062530-e8a37ad.md`](measurements/timing-characterization/records/20260921-062530-e8a37ad.md); post-route SDF artifact: [`measurements/timing-characterization/logic_tile_route.sdf`](measurements/timing-characterization/logic_tile_route.sdf).
- **Record / git revision**: `20260921-062530-e8a37ad`, produced at git revision `e8a37ad641c7913495f8e9aa14d5dd4c1bf93d45`. Committed at: `unknown (no commit found)`.

## Regenerating

```
python3 measurements/generate-characterization-summary.py
```

Reads and cross-checks the JSON/markdown sources named above; fails loudly (non-zero exit, no file written) rather than emitting a report that has drifted from them. It does not re-run any tool -- run `./flow/layout.sh`, `./flow/sta-sweep.sh` and/or `./flow/sdf-resim.sh` first if you need to regenerate the underlying evidence itself (see `measurements/README.md`).
