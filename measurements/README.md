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
- **Not post-layout functional verification.** SDF-back-annotated
  gate-level re-simulation is separate follow-on work; `sim/` holds the
  functional evidence and is unaffected by this directory.
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
```

`./flow/sta-sweep.sh` exits 0 only if every corner ran, every SPEF run
annotated completely, the harness's own name-rewrite timing-neutrality
control passed at every corner, and every regenerated per-corner report
matches its committed copy. `./flow/sta-sweep.sh --update` regenerates and
overwrites those committed reports — run it (and add a new record under
`timing-characterization/records/`) after an intentional layout change.

See `flow/README.md`'s `flow/sta-sweep.sh` section for the harness's own
design notes, including the klayout-tools gaps it works around.
