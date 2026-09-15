# measurements

Characterization evidence. Originally scaffolded for post-tape-out silicon
characterization; extended — per `spec/framework-gaps.md` item **G4 —
Timing characterization (no inherited numbers)** — to hold **pre-silicon
extracted timing**, since real measurements only exist after tape-out but
`CLAUDE.md`'s rule that "timing claims come only from characterized data"
binds long before then.

FABulous marks BEL timing as placeholder-constant, so this repo cannot
inherit a single delay, setup/hold or Fmax number from the framework. G4's
verification bar is "a timing report under `measurements/` ... tracing each
published number back to its extraction run" — that is what this directory
is.

## Contents

### `characterization-summary.md` — one aggregated, current artifact (T1 item 8)

[`characterization-summary.md`](characterization-summary.md) pulls DRC, LVS,
the 18-corner STA sweep, the ratified `spec/tile-spec.md` timing row (ADR-0002)
and the SDF-generation/gate-level re-simulation result into a single current
snapshot, each entry naming its status, its source record/report path, and
the commit/run it was derived from. It is **generated**, not hand-typed: every
number in it is read from, or cross-checked against, the JSON/markdown
sources it cites — regenerate it after any of those sources changes with:

```
python3 measurements/generate-characterization-summary.py
```

(`--check` fails non-zero without writing if the committed file has drifted
from its sources.) See `measurements/generate-characterization-summary.py`
for exactly what each section cross-checks.

### `claim-traceability.md` — claim → harness → pinned-PDK audit (T1 item 9, issue #34)

Every result this repo publishes as evidence, traced to the committed
testbench or flow script that produces it and to the sky130A PDK revision it
was produced against — including the claims in `layout/` and `sim/`, not
just this directory's. The repo's single pinned PDK source is
`RECORDED_PDK_VERSION` in `flow/tool_versions.sh`; most artifacts carry that
revision in their own `provenance.pdk` block, and the audit names the ones
that inherit it instead (and why).

`./flow/audit-evidence.sh` re-derives the whole audit from the committed
tree — no `klt`, no PDK install, no network — so a new record, a new report
type, an edited harness a record already pins by hash, or a PDK swap fails
the check instead of quietly invalidating the published table.

### `timing-characterization/` — multi-corner extracted-parasitics STA

The `logic_tile` block's timing, characterized from the committed layout.

```
timing-characterization/
  records/<YYYYMMDD-HHMMSS>-<7-char sha>.md   append-only characterization records
  corners/<corner>/lef-only.sta.json          per-corner klt sta report, unannotated
  corners/<corner>/spef.sta.json              per-corner klt sta report, SPEF-annotated
```

`records/` is **append-only**: a record is never edited in place. A new
measurement adds a new record whose `record-meta` header names the record it
`supersedes`; the superseded record stays in the tree as the historical
account of what was true then. (Same convention as the sibling digital
canary `sky130-modexp`'s `verification/records/`.) The per-corner JSON under
`corners/` is *not* append-only — it always describes the current committed
layout, and `flow/sta-sweep.sh` diff-checks it on every run.

The current record is
[`records/20260909-225431-86f71d2.md`](timing-characterization/records/20260909-225431-86f71d2.md).
A second record,
[`records/20260915-133517-234b13b.md`](timing-characterization/records/20260915-133517-234b13b.md),
covers the separate SDF-generation + gate-level-resimulation experiment
below — it does not supersede this one.

### `timing-characterization/logic_tile_route.sdf` — SDF-annotated gate-level re-simulation (T1 item 7, issue #29)

A real post-route SDF (`klt place-and-route --post_route_sdf`), regenerated
and diff-checked by `flow/sdf-resim.sh` against the exact geometry this
directory's own 18-corner sweep already characterized (byte-identical DEF).
`sim/tb_logic_tile.v` re-runs unmodified, gate-level, against the as-built
netlist from that same run: zero delay **passes**; the SDF-annotated leg is
**blocked** by a real, generically-reproducible upstream defect in
`$sdf_annotate`'s handling of this design's `generate`-block-flattened
escaped identifiers, filed as
[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890)
rather than worked around with a fabricated result. Full method and the
crash bisection:
[`records/20260915-133517-234b13b.md`](timing-characterization/records/20260915-133517-234b13b.md).

**What was measured.** One fixed piece of routed geometry — the committed
`layout/logic_tile.def`, byte-identical across every run — re-timed in a
fresh OpenSTA session (`klt sta`) at **every one of the 18
`sky130_fd_sc_hd` liberty corners the sky130A PDK ships** (16 distinct PVT
points plus the two `_ccsnoise` variants). Each corner was analysed twice:
once with LEF-only (unannotated) parasitics, and once with first-order
lumped-RC parasitics extracted from the committed `layout/logic_tile.gds`
(`klt extract --parasitics --spef`) annotated in. Every SPEF run reported
`spef_annotation.annotation_complete: true`; a run that did not would be
refused by the harness rather than recorded as a measurement.

Reported per corner: setup WNS/TNS, setup- and hold-violation counts,
`fmax_mhz`, `clock_skew_ns` and `estimated_power_mw`, for both the
unannotated and the annotated run — plus die/core area from
`layout/logic_tile.par.json`, so the "Fmax, area and power across the corner
set" triple sits in one place.

**Headline results** (full table and caveats in the record):

| | Corner | SPEF-annotated |
| --- | --- | ---: |
| Binding (worst) corner for setup | `ss_n40C_1v28` | WNS 15.1760 ns @ 20 ns, `fmax_mhz` 207.29 |
| Fastest corner | `ff_n40C_1v95` | WNS 19.5887 ns, `fmax_mhz` 2431.13 |
| Hold | — | 0 hold violations at **all 18** corners, both runs |
| Interconnect penalty at the binding corner | `ss_n40C_1v28` | −0.2890 ns setup slack (LEF-only → SPEF) |

**What these numbers do NOT claim:**

- **Not a bisected Fmax.** `fmax_mhz` is `report_fmax_metric`'s `1/(T−WNS)`
  extrapolation from a single 20 ns analysis, not a bisection search. With
  15–19.6 ns of slack against that period the extrapolation runs far
  outside the range actually analysed. **The slacks are the trustworthy
  numbers; the Fmax column is a derived convenience.**
- **Not a propagated-clock analysis.** The SDC clock is ideal, so
  `clock_skew_ns` reads 0 at every corner even though the DEF contains a
  real clock tree. That is not a zero-skew claim.
- **Not a sign-off-grade parasitic model.** One lumped series R and one
  ground C per net in a star topology (plus vertical-overlap coupling) —
  no distributed RC ladder, no field solve, quasi-static.
- **Not a spec number.** `spec/tile-spec.md`'s timing rows still read "No
  numbers in this spec". Publishing any of these into the spec is a spec
  change and needs its own decision record; this directory is the evidence
  such a record would cite, not the ruling.
- **Not the fabric.** Only the logic tile's BELs exist to characterize —
  the switch matrix and inter-tile routing (`spec/framework-gaps.md`
  G1/G2) have not landed, so no fabric routing delay is characterized
  anywhere here.
- **Not a full post-layout functional verification.** SDF-back-annotated
  gate-level re-simulation (issue #29) has a real SDF and a zero-delay
  gate-level PASS, but no SDF-annotated pass/fail result — blocked on
  [klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890),
  see `logic_tile_route.sdf` above. `sim/` holds the functional evidence.
- **Not silicon.** Nothing here is measured on a fabricated part.

### Silicon characterization

Empty until tape-out. Post-silicon measurements will land alongside
`timing-characterization/` under their own subdirectory, following the same
append-only `records/` convention.

## Reproducing

From a clean checkout, with `klt`, `openroad`, a native `yosys` and a
resolvable sky130A PDK (`klt pdk find --pdk sky130A`) available:

```
./flow/layout.sh      # verify the committed GDS + DEF + P&R report regenerate byte-identically
./flow/sta-sweep.sh   # re-extract parasitics, re-sweep all 18 corners, diff every committed report
./flow/sdf-resim.sh   # regenerate the post-route SDF + gate-level re-simulation (needs Icarus 13.0+)
```

`./flow/audit-evidence.sh` needs none of that — it re-checks every claim's
harness and PDK pin (`claim-traceability.md` above) from committed files
alone, so it runs in any clean checkout.

`./flow/sta-sweep.sh` exits 0 only if every corner ran, every SPEF run
annotated completely, the harness's own name-rewrite timing-neutrality
control passed at every corner, and every regenerated per-corner report
matches its committed copy. `./flow/sta-sweep.sh --update` regenerates and
overwrites those committed reports — run it (and add a new record under
`timing-characterization/records/`) after an intentional layout change.

See `flow/README.md`'s `flow/sta-sweep.sh` section for the harness's own
design notes, including the klayout-tools gaps it works around.
