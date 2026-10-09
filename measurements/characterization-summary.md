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
| DRC | **clean** (0 violations) | [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) | content hash `sha256:38498092805e` |
| LVS | **match** (1 mismatches, engine `klayout`) | [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) | layout GDS hash `sha256:38498092805e` |
| ERC (supply connectivity + antenna) | **0 findings**, 0 antenna `violate` across 232 gates | [`layout/logic_tile.erc.json`](layout/logic_tile.erc.json) | layout GDS hash `sha256:38498092805e` |
| 18-corner STA sweep | **setup/hold-clean at all 18 corners** (binding setup corner `ss_n40C_1v28`, SPEF WNS 15.2145 ns) | [`measurements/timing-characterization/records/20261008-234741-dc615b4.md`](measurements/timing-characterization/records/20261008-234741-dc615b4.md) | record `20261008-234741-dc615b4`, git revision `dc615b4` |
| Multi-corner `klt sta` envelope (T1 item 5 citation) | **18 corners, every one `timing_status: constrained`, setup/hold slack >= 0** | [`measurements/timing-characterization/logic_tile.sta.json`](measurements/timing-characterization/logic_tile.sta.json) | analysed-DEF hash `sha256:6e1bb79d924d` |
| Ratified timing spec row | **RATIFIED** (ADR-0002) | [`spec/tile-spec.md`](spec/tile-spec.md), [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md) | decision record ADR-0002 |
| SDF-generation + gate-level re-sim | **zero-delay: PASS; SDF-annotated: BLOCKED** (klayout-tools#1890 closed as a fail-loud guard only; capability gap tracked in klayout-tools#2897) | [`measurements/timing-characterization/records/20261008-233733-23e6b5e.md`](measurements/timing-characterization/records/20261008-233733-23e6b5e.md) | record `20261008-233733-23e6b5e`, git revision `23e6b5e` |

## DRC

- **Status**: `clean`, `violation_count`: 0, deck: `sky130`
- **Source**: [`layout/logic_tile.drc.json`](layout/logic_tile.drc.json) (analysed-input hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`)

## LVS

- **Status**: `match`, `mismatch_count`: 1, engine: `klayout`, top: `LOGIC_TILE`
- **Source**: [`layout/logic_tile.lvs.json`](layout/logic_tile.lvs.json) (layout GDS hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`)
- **Warning-severity entries** (0 error-severity): `topology.power_only_pruned`
- **Scope**: signal-connectivity only -- this compare comes from a `gate-level-verilog` reference carrying no supply pins, so it says nothing about power/ground. The power half of the claim is ERC, below. See `layout/README.md`'s "LVS scope, concretely".

## ERC (supply connectivity + antenna)

- **Findings**: 0 (no floating supply island, no `erc.missing_tie`)
- **Antenna**: 0 `violate` across 232 gates (232 `pass_partial`, 0 `pass`, 0 `unchecked`). `pass_partial` is the expected sky130 verdict, not a violation: that PDK's antenna-limit table has no met3-met5 entries, so some graded level of every gate is necessarily `unchecked`.
- **Source**: [`layout/logic_tile.erc.json`](layout/logic_tile.erc.json) (layout GDS hash `sha256:38498092805ec6a6f23cf9e13f57a055f765412595b422b66cf3a24ae6722a7f`, produced by klt `0.5.0+g2b1e55e51bb8.dirty`)
- **Why this is separate from LVS**: the LVS compare above is signal-connectivity only and drops the layout's supply nets. This is the check that actually binds the power half of the claim -- against the pre-PDN layout the same invocation reported 9 findings (7 `erc.missing_tie`, 2 `erc.unconnected_net`). See `layout/README.md`'s "Power delivery network".

## 18-corner STA sweep

- **Coverage**: all 18 `sky130_fd_sc_hd` liberty corners the sky130A PDK ships, 4 runs per corner (LEF-only on the committed DEF, LEF-only on a name-rewritten control DEF, SPEF-annotated on the name-rewritten DEF, and that corner's entry in one multi-corner `pdk.corners` request over the same DEF and SPEF). Cross-checked directly against the 18 per-corner `corners/<corner>/{lef-only,spef}.sta.json` reports: every run is `timing_status: constrained`, setup-violation count, hold-violation count and total negative slack are 0 at every corner in both the LEF-only and SPEF-annotated run, and every SPEF run reports `spef_annotation.annotation_complete: true`.
- **Multi-corner envelope** (the T1 item-5 citation, [`measurements/timing-characterization/logic_tile.sta.json`](measurements/timing-characterization/logic_tile.sta.json)): one `klt sta` response covering exactly these 18 corners, each `timing_status: constrained` with non-negative setup and hold slack, and identical corner-for-corner to the per-corner SPEF reports on WNS, hold WS, `fmax_mhz` and `timing_status`.
- **Binding setup corner** (minimum SPEF-annotated `worst_slack_ns` across all 18 corners): **`ss_n40C_1v28`** -- WNS 15.465 ns (LEF-only) / 15.2145 ns (SPEF-annotated), extrapolated `fmax_mhz` 208.966 (SPEF-annotated).
- **Against the ratified figure of record**: the spec row's binding-corner SPEF WNS is 15.2146 ns (ADR-0003); this sweep, under klt `0.7.0+g6fd0278268cc`, measures 15.2145 ns (-0.1 ps). The ratified criteria (setup/hold-clean at all corners, same binding corner) hold; the row itself is unchanged (a figure-of-record move is an ADR decision).
- **Fastest corner**: `ff_n40C_1v95` -- WNS 19.5926 ns (SPEF-annotated), `fmax_mhz` 2454.84.
- **Fmax caveat carried forward** (per the source record and ADR-0002): `fmax_mhz` is a single-period `1/(T-WNS)` extrapolation, not a bisected measurement -- the slacks above are the trustworthy numbers; no Fmax/MHz figure is ratified anywhere in this repo.
- **Source**: [`measurements/timing-characterization/records/20261008-234741-dc615b4.md`](measurements/timing-characterization/records/20261008-234741-dc615b4.md), harness `flow/sta-sweep.sh`.
- **Record / git revision**: `20261008-234741-dc615b4`, produced at git revision `dc615b4f7f24fca111d69ba4008e2b903ec12875`.

## Ratified timing spec row

- **Status**: ratified (ADR-0002). Current `spec/tile-spec.md` Timing row (read live from the file, not retyped here):

  > **RATIFIED 2026-09-15 (ADR-0002, #28); WNS figure of record re-ratified 2026-09-21 (ADR-0003, #42)** — tile BEL logic only (no switch matrix): setup- and hold-clean (0 violations, 0 TNS) at all 18 `sky130_fd_sc_hd` PVT corners, LEF-only and SPEF-annotated, against a 20 ns non-propagated-clock SDC period on `clk`; binding setup corner `ss_n40C_1v28`, SPEF WNS 15.2146 ns, from the post-PDN successor record `20260921-062500-e8a37ad`. **No Fmax/MHz number ratified** — see `spec/decisions/0003-tile-timing-spec-re-ratification.md`.

- **Source**: [`spec/tile-spec.md`](spec/tile-spec.md) (summary table), decision record [`spec/decisions/0002-tile-timing-spec-ratification.md`](spec/decisions/0002-tile-timing-spec-ratification.md).

## SDF-generation + gate-level re-simulation

- **Zero-delay leg**: PASS (`sim/tb_logic_tile.v`, unmodified, run gate-level against the as-built netlist) -- functional-only, no timing claim.
- **SDF-annotated leg**: BLOCKED. klayout-tools#1890 (`$sdf_annotate` crash on escaped identifiers containing `.`/`[]`, which this design's flattened `generate`-block RTL produces) is closed, but its fix (klt v0.6.0) is only a fail-loud guard on `klt functional-verification`'s `options.sdf` path; a raw `$sdf_annotate` still aborts `vvp` identically (re-verified 2026-10-08) and the remaining capability gap is tracked generically in [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897). Not worked around with a fabricated result. The latest re-try's full `flow/sdf-resim.sh` run under klt 0.6.0 also stops at the DEF-reproducibility gate (toolchain drift); its zero-delay PASS was run by hand on a non-matching netlist, so supporting only.
- **Source**: [`measurements/timing-characterization/records/20261008-233733-23e6b5e.md`](measurements/timing-characterization/records/20261008-233733-23e6b5e.md); post-route SDF artifact: [`measurements/timing-characterization/logic_tile_route.sdf`](measurements/timing-characterization/logic_tile_route.sdf).
- **Record / git revision**: `20261008-233733-23e6b5e`, produced at git revision `23e6b5e0c87d2e6306a4b72aad86475dafd85c46`.

## Regenerating

```
python3 measurements/generate-characterization-summary.py
```

Reads and cross-checks the JSON/markdown sources named above; fails loudly (non-zero exit, no file written) rather than emitting a report that has drifted from them. It does not re-run any tool -- run `./flow/layout.sh`, `./flow/sta-sweep.sh` and/or `./flow/sdf-resim.sh` first if you need to regenerate the underlying evidence itself (see `measurements/README.md`).
