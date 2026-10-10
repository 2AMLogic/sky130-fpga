# flow

Synthesis and place-and-route tooling — the `yosys` + `nextpnr` flow
referenced by `CLAUDE.md` for the fabric itself, plus `klayout-tools` (`klt`)
for sky130 physical design (layout, DRC/LVS, place-and-route).

## Toolchain versions

`flow/layout.sh`'s and `flow/sta-sweep.sh`'s check mode (the `./flow/*.sh`
default, no-argument invocation) diffs freshly regenerated output against
the artifacts committed under `layout/` and
`measurements/timing-characterization/`. That diff is only a meaningful
reproducibility check against the **same** `klt` (klayout-tools) and
OpenROAD versions that produced the committed copies — `klt`/OpenROAD make
no output-format stability guarantee across releases, and neither this repo
nor klayout-tools currently pins one.

**Recorded toolchain** (produced the artifacts currently committed under
`layout/` and `measurements/timing-characterization/`, per
`layout/logic_tile.erc.json`'s own `provenance.klt_version` pin and the
successor records
`measurements/timing-characterization/records/20260921-062500-e8a37ad.md` /
`20260921-062530-e8a37ad.md`):

| Tool | Version |
|------|---------|
| `klt` (klayout-tools) | `0.5.0+g2b7caa9939af` |
| OpenROAD | `26Q3-1278-g4421880472` |
| KLayout (via `klt`) | `0.30.12` (last recorded under the 0.3.0 pin; not re-pinnable from the current reports, which do not echo it) |

**Recorded STA toolchain** (issue #68). This produced the timing evidence
`flow/sta-sweep.sh` currently commits under
`measurements/timing-characterization/`:
- the 36 per-corner reports;
- the multi-corner item-5 envelope `logic_tile.sta.json`;
- the sanitized SPEF `logic_tile.spef`.

Record:
`measurements/timing-characterization/records/20261008-234741-dc615b4.md`.

| Tool | Version |
|------|---------|
| `klt` (klayout-tools) | `0.7.0+g6fd0278268cc` (`RECORDED_STA_KLT_VERSION`) |
| OpenROAD | `26Q3-1510-g6cb3f2b704` (`RECORDED_STA_OPENROAD_VERSION`; image pinned by digest in the host wrapper) |

This was a deliberate design-flow upgrade. Only a `klt sta` that emits
`timing_status` (klayout-tools#1865) and accepts `pdk.corners`
(klayout-tools#1871) produces an envelope `klt signoff` can grade for T1
item 5. It is pinned **separately** from `RECORDED_KLT_VERSION` because the
layout artifacts were not regenerated, and they do not regenerate
byte-identically under the newer toolchain (record
`20261008-233733-23e6b5e`). Bumping the shared pin would misstate their
lineage. Measured drift against the 0.5.0 lineage:
- every LEF-only WNS is unchanged;
- SPEF-annotated WNS moves by -0.1 to +0.9 ps;
- the binding corner `ss_n40C_1v28` moves 15.2146 -> 15.2145 ns, -0.1 ps
  against ADR-0003's figure of record;
- every verdict is unchanged.

`flow/sta-sweep.sh` prints its banner against this pair.

**Recorded LVS toolchain** (issue #69). This produced the committed
`layout/logic_tile.lvs.json`:

| Tool | Version |
|------|---------|
| `klt` (klayout-tools) | `0.7.0+g4cbdfa769875` (`RECORDED_LVS_KLT_VERSION`; PyPI `klayout-tools==0.7.0`) |
| OpenROAD (reference-netlist regeneration only) | `26Q3-1510-g6cb3f2b704` |

Bump rule, as for the STA pin: a deliberate design-flow upgrade, pinned
**separately** from `RECORDED_KLT_VERSION`. Re-enabling `klt lvs`'s
power-connectivity check needs a klt carrying klayout-tools#2121 (merge
commit `fa034fb670d8`, 2026-09-19). The 0.5.0 layout pin is 30 commits
behind that merge; `0.7.0+g4cbdfa769875` is 725 commits past it (checked
with the GitHub compare API). The GDS, DEF and par report were not
regenerated: `./flow/lvs.sh --update-report` rewrites only the LVS report,
and `layout/logic_tile.gds` stayed byte-identical. ERC and PAR keep
their own lineages (`provenance.klt_version` in the ERC report;
`RECORDED_KLT_VERSION` for PAR). Reproduce in a throwaway env without
touching the host klt:
`uvx --from "klayout-tools==0.7.0" klt ...`, or put that klt first on
`$PATH` and run `./flow/lvs.sh`. `flow/lvs.sh` prints its klt banner
against this value. The `flow/layout.sh` it calls prints its own banner
against `RECORDED_KLT_VERSION`, and that one warns.

`flow/layout.sh`, `flow/sta-sweep.sh` and `flow/sdf-resim.sh` all source
`flow/tool_versions.sh` and print the installed `klt`/OpenROAD versions at
the top of every run, with a warning if they differ from the table above
(`RECORDED_KLT_VERSION` / `RECORDED_OPENROAD_VERSION` in that file;
`flow/sta-sweep.sh` compares against `RECORDED_STA_KLT_VERSION` /
`RECORDED_STA_OPENROAD_VERSION` instead). This is
**informational, not enforced** — there is no pinned container image, so a
mismatch does not abort the script. (CI exists: see "Continuous integration"
below for what it does and does not reproduce.)

### Recorded PDK revision

The same file also pins the **PDK** revision the committed artifacts were
produced against (`RECORDED_PDK_VERSION`, issue #34):

| | Revision |
|---|---|
| sky130A | `open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b` |

Unlike the tool versions, this one is mostly redundant — `klt
place-and-route` and `klt sta` write `provenance.pdk.{name,version}` into
their own reports, so `layout/logic_tile.par.json` and all 36 per-corner
reports under `measurements/timing-characterization/corners/` already carry
it, and check mode's diff fails if the installed PDK differs. **`klt drc`
and `klt lvs` now pin it in-artifact too**: on klt builds after the
klayout-tools#1901 fix both write a real `provenance.pdk.{name,version}`
(pre-fix builds wrote `provenance.pdk: null` even when invoked with
`--pdk sky130A`), and the committed `layout/logic_tile.drc.json` /
`layout/logic_tile.lvs.json` have carried the in-artifact pin since the
2026-09-21 re-stamp (issue #41, PR #55). The one committed report that
still records no PDK revision is `layout/logic_tile.erc.json` — `klt erc`
writes no provenance block at all and reads no PDK install
(klayout-tools#2036) — so that claim inherits its pin from
`RECORDED_PDK_VERSION`. `flow/drc.sh` and `flow/lvs.sh` therefore print
`print_pdk_version_banner` — the same warn-on-mismatch shape, now a
double-check on top of the in-artifact pins and the stated pin for the
ERC claim. T1 checklist item 9 ("every claimed measurement has a
committed testbench and a pinned PDK version") is what this is for; the
full claim-by-claim walk is `measurements/claim-traceability.md`.

**Known drift (issue #23, unverified byte-level root cause):** running
check mode against `klt 0.4.0` instead of the recorded toolchain has been
observed to report `flow/layout.sh` non-reproducibility (differing
`wirelength_um`, plus a fill-cell placement diff) and `flow/sta-sweep.sh`
`spef.sta.json` diffs confined to the `spef_sha256` provenance field —
while every *numeric* field in both reports (worst-case slack, total
negative slack, nets-annotated counts, status) reproduced exactly at every
corner. This looks like a `klt place-and-route` / `klt extract --spef`
output-formatting change between those two `klt` releases, not a
correctness regression, but that has not been confirmed by a byte-level
diff against an archived `0.3.0` run. **If your check-mode run fails and
the toolchain-version warning above fired, rule out toolchain drift before
treating the failure as a design regression** — re-run against the recorded
toolchain if available, or inspect whether the diff is confined to
provenance/byte-format fields (as in the known case above) versus an actual
numeric/status change.

**2026-09-21 re-stamp and its verification (issue #41).** The post-PDN
artifacts were produced under klt `0.5.0+g2b7caa9939af`; the check-mode
diffs of `flow/layout.sh`, `flow/lvs.sh`, `flow/drc.sh` and `flow/erc.sh`
were then re-verified byte-reproducible on the same tree under klt
`0.5.0+g2b1e55e51bb8.dirty` — the GDS and DEF regenerate byte-identical,
and every verdict field (DRC clean/0, LVS match/1-warning,
ERC 0 findings/0 antenna violations, par slacks/wirelength/utilization)
is unchanged. Two envelope-only differences of the newer klt were
normalized rather than papered over: `flow/par_report_trim.py` now strips
the per-run `engine_logs[]` bookkeeping (random invocation ids), and
`flow/drc.sh` / `flow/lvs.sh` resolve the PDK themselves so the
resolution-path `provenance.pdk.source` string the newer klt writes stays
deterministic. One moving part is **outside** this repo's control and is
currently blocking re-runs of the SPEF-annotated legs of
`flow/sta-sweep.sh` and the SDF-update gate of `flow/sdf-resim.sh` on the
verifying host: the operator-local `openroad` wrapper runs an unpinned
`openroad/orfs:latest` image (now `26Q3-2276-g4a7cf9b22a`, recorded
toolchain `26Q3-1278`), under whose OpenSTA build the SPEF annotation of
this design's escaped-identifier nets regresses to incomplete
(klayout-tools#1623/#1624 family — `partially_unannotated_driver_count:
40`, `annotation_complete: false` at the first corner). Both harnesses
correctly refuse to record on such a run; the committed per-corner
reports and the committed SDF remain the recorded-toolchain evidence,
and the successor records under
`measurements/timing-characterization/records/` document that lineage.
**Correction (issue #68).** The annotation regression on the
`flow/sta-sweep.sh` legs was misattributed to the OpenROAD image. Under
OpenROAD `26Q3-1510` it is fully explained by a `klt extract` change:
since klayout-tools#2145, dotted net names are written as `_` in the SPEF.
`--def-net-connections` still keys its pin table by the dotted DEF names,
so the 40 hierarchical nets lost their `*CONN` blocks. Filed as
klayout-tools#2903, and worked around by
`flow/sta_sanitize_names.py def-connections`. With the workaround the
sweep runs annotation-complete at every corner (record
`20261008-234741-dc615b4`). The `26Q3-2276` image was not re-tested, and
the `flow/sdf-resim.sh` leg was not re-examined.

## Continuous integration

`.github/workflows/flow-evidence.yml` (issue #109) runs
`flow/audit-evidence.sh` on pull requests touching `flow/`,
`design/rtl/logic_tile.v`, `layout/` or `measurements/` (and, in the same job,
`flow/check_status_claims.py`, below). It needs no
toolchain, so it is exactly reproducible on a stock runner and fails on a
drifted claim or pinned script hash (the #53 failure mode). Other workflows:
`signoff.yml` (manifest re-grade), `rtl-sim.yml` (Icarus testbenches),
`fabulous-nextpnr.yml` (G1 logs).

Not run in CI, and why (recorded as the finding of issue #109 rather than
weakening any check mode):

- `flow/layout.sh` (and `flow/lvs.sh`, which re-runs its check mode)
  regenerates GDS/DEF byte-for-byte against artifacts produced by klt
  `RECORDED_KLT_VERSION` and OpenROAD `RECORDED_OPENROAD_VERSION`. Those are
  development builds (git-suffixed klt; a specific OpenROAD build) with no
  published package or download this repo can fetch from the pins: PyPI
  carries only plain `klayout-tools` releases, which per
  `RECORDED_*_KLT_VERSION` notes do not regenerate byte-identically.
- `flow/layout_routed.sh` likewise needs the pinned `openroad`.
- All klt flows also need a sky130A install at `RECORDED_PDK_VERSION`
  (an open_pdks commit); no reproducible, pinned fetch of that revision is
  recorded in `flow/tool_versions.sh`.
- `flow/sta-sweep.sh` (18 corners) and `flow/sdf-resim.sh` are too heavy for
  per-PR CI; a scheduled job is a possible later step.

Unblocking these requires published artifacts for the pinned OpenROAD and PDK
revisions (or re-stamping the committed artifacts under a fetchable
toolchain); pins would still live only in `flow/tool_versions.sh`.

## Current contents

### `flow/generated_tile_replay.sh` - committed streams through the generated LOGIC4 tile (issue #140)

Run by `flow/fabulous.sh` after it has generated into `flow/build/fabulous-run/`
(by hand: `flow/generated_tile_replay.sh flow/build/fabulous-run flow/build`).
It compiles `sim/tb_logic_tile_bitstream.v` with `-DGEN_TILE` against the
generated `LOGIC4.v` and its generated ConfigMem, matrix and BELs, and also
against `design/rtl/logic_tile_routed.v`. Every baseline, corpus and
pin-experiment stream is replayed through the generated tile's
`FrameData`/`FrameStrobe` ports and checked with the independent oracles.
Three scratch composition mutations must each fail functionally. It then runs
the LUT basis diagnostic (issue #172): `flow/lut_basis.py <out dir>` assembles
73 diagnostic streams (one-hot INIT for every address of every BEL, plus
all-ones/all-zero clearing cases) through the existing assembler, and
`sim/tb_lut_basis.v` checks every BEL output against the selected address on
both compositions, with three scratch mutants (LUT-input permutation, BEL
INIT-bit swap, BEL A/B slice swap) that must fail on the predicted cases.
Unit tests: `flow/test_lut_basis.py` (run by `sim/run.sh`). Takes about
3 minutes, iverilog only, run serially. EXPERIMENTAL; details and non-claims
are in `sim/README.md`, evidence in `sim/generated_tile_replay.txt`.

### `flow/nextpnr.sh` - nextpnr on the generated LOGIC4 model (G1, issue #87)

Runs `flow/fabulous.sh` (with `FABULOUS_SKIP_TILE_REPLAY=1`: only the model is
needed, so the integrated replay above is skipped there), then pinned yosys + `nextpnr-generic --uarch fabulous`
(YosysHQ OSS CAD Suite tarball, sha256-verified, unpacked into the untracked
`flow/build/oss-cad-suite/`; pins in `flow/tool_versions.sh`) on
`design/fabulous/nextpnr/top.v`, and diffs the normalized log against the
committed `design/fabulous/nextpnr.log` (`--update-log` rewrites it). Needs
network on first run (~750 MB download); nothing is installed host-wide.

### `flow/bitstream.sh` - FASM to bitstream fixtures (G5/G6 harness, issue #74)

Runs `flow/nextpnr.sh` (which now also maps the registered example
`design/fabulous/nextpnr/top_reg.v`), freezes the generated bitStreamSpec /
ConfigMem / pip model, assembles each design's FASM with
`flow/fasm_to_bitstream.py`, requires FABulous's own `bit_gen genBitstream` to
produce a byte-identical stream, and diffs the result against the committed
`sim/bitstream/` fixtures (`--update` rewrites them). `./sim/run.sh` uses the
committed fixtures only (no mapping tool). Experimental single-LOGIC4 harness
coverage; see `sim/README.md`. `python3 flow/test_fasm_to_bitstream.py` runs the
assembler/decoder unit tests (stdlib only).

### `flow/corpus.sh` - bounded single-tile routability corpus (issue #115)

EXPERIMENTAL decision evidence for ADR-0004 item 3. Runs `flow/bitstream.sh`
(pinned toolchain, model, baseline fixtures), then `flow/corpus_run.py`:
every (case, seed) of `design/fabulous/corpus/corpus.json` is synthesized,
topology-checked, mapped with the pinned nextpnr, and classified (`success`,
`route_fail`, `route_nonconvergent`, `capacity_packing`; synthesis, topology
and tool problems fail the run and are never reported as unroutability). Each
success is assembled, byte-compared with FABulous `bit_gen genBitstream` and
simulated against an independent oracle; any deviation from the recorded
`expect` fails the run with an evidence-review message. `--update` rewrites
`sim/bitstream/corpus/`; `--append-record FILE` appends a dated record. Needs
the `flow/nextpnr.sh` prerequisites plus Icarus Verilog. See
`design/fabulous/corpus/README.md`.

### `flow/synth.sh` — generic-cell netlist (T1 item 1 follow-up)

`flow/synth.sh` derives a **generic-cell** (technology-independent) netlist
from the committed tile RTL under `design/rtl/` via `yosys`
(`proc; opt; memory; opt; techmap; opt` — no sky130 standard-cell/liberty
mapping). This is the second half of the T1 "Design sources" pass condition
(per `docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`, quoted in
issue #5/#7): *"committed design sources plus the derived netlist,
regenerated on design change — presence AND reproducibility, not a one-off
drop."*

The derived netlist is checked in at `design/netlist/logic_tile_netlist.v`
(**presence**), and `flow/synth.sh` re-derives it from `design/rtl/` on every
invocation and diffs the result against that committed copy
(**reproducibility**) — mirroring `sim/run.sh`'s "recompile from source every
run" pattern rather than trusting a one-off hand-run artifact.

Running:

```
./flow/synth.sh            # regenerate the netlist, diff against the
                            # committed copy under design/netlist/.
                            # Exit 0 if identical (RTL and netlist are in
                            # sync); non-zero if they differ or synthesis
                            # fails.

./flow/synth.sh --update   # regenerate the netlist and overwrite the
                            # committed copy. Run this (and commit the
                            # result) after an intentional design/rtl/
                            # change.
```

Requires [yosys](https://github.com/YosysHQ/yosys) on `PATH`. Scratch output
(the yosys script, log, and raw netlist before the header-comment strip
described below) lands in `flow/build/` (gitignored) — same
non-committed-scratch shape as `sim/build/`.

The regenerated netlist's `/* Generated by Yosys <version> */` header comment
is stripped before comparing/writing, so upgrading the yosys version alone
does not produce a spurious diff — only an actual RTL/netlist-shape change
does.

Exit status is `0` iff synthesis succeeds and (in the default, non-`--update`
mode) the regenerated netlist matches the committed copy.

**Out of scope here**: sky130 standard-cell mapping / physical design (this
is a plain generic-cell netlist — `$_MUX_`/`$_SDFFE_PP0P_`-class primitives,
not liberty-mapped), and the FABulous-style tile/fabric description (switch
matrix, routing — unconfirmed pending `spec/framework-gaps.md` item G1).
sky130 mapping and place-and-route are `flow/layout.sh`'s job, below.

### `flow/layout.sh` — sky130 GDS layout (T1 item 2)

`flow/layout.sh` takes the same committed RTL under `design/rtl/` through
klayout-tools' (`klt`) digital flow — `klt synthesize` (Yosys, mapped
against `sky130_fd_sc_hd`) followed by `klt place-and-route` (OpenROAD:
floorplan through detailed route, plus the DEF->GDS merge) — producing a
placed-and-routed sky130 GDS. This is the T1 "Layout" pass condition (item 2
of `docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`, per issue
#9): *"committed layout, reproducible from sources — presence AND
reproducibility, not a one-off drop."*

The liberty-mapped netlist `klt synthesize` produces here is **not** the
same artifact as `design/netlist/logic_tile_netlist.v` above (that one stays
generic-cell only, per its own scope) — it is regenerated fresh into
`flow/build/` (gitignored scratch) on every `flow/layout.sh` run, never
committed on its own. The committed deliverables are the GDS, the routed
DEF and the place-and-route report, all three under `layout/` and all three
from the same run — see `layout/README.md` for what they contain and what
they deliberately do not claim (no DRC/LVS signoff, no timing/Fmax claim,
no power delivery network — all separate follow-on work; the DEF exists so
`flow/sta-sweep.sh` below can characterize that exact geometry).

The `klt.place_and_route.request/1` document submitted to `klt
place-and-route` is generated by `flow/par_request.py`, shared with
`flow/sdf-resim.sh` below — both scripts describe the *same* run (issue
#44), so the request body is single-sourced there rather than duplicated as
a second hand-written heredoc; see that script's own header comment.

Running:

```
./flow/layout.sh            # regenerate the GDS + DEF + report, diff
                            # against the committed copies under layout/.
                            # Exit 0 if identical; non-zero if they differ
                            # or the flow fails.

./flow/layout.sh --update  # regenerate and overwrite the committed copies
                            # under layout/. Run this (and commit the
                            # result) after an intentional design/rtl/
                            # change.
```

Requires `klt` (klayout-tools), a native `yosys` build, and `openroad` on
`PATH`, plus a resolvable sky130A PDK install (`klt pdk find --pdk
sky130A`). Scratch output (generated request JSON, raw `klt` responses, the
synthesized netlist, and every P&R stage artifact) lands in `flow/build/`
(gitignored), same non-committed-scratch shape as `flow/synth.sh`'s own.

Two post-processing steps happen before comparing/committing, mirroring
`flow/synth.sh`'s own version-header strip:

- `flow/gds_canonicalize.py` zeroes the wall-clock timestamps `klt`'s
  DEF->GDS merge embeds in every GDSII structure, so two runs of the
  identical seeded request compare as byte-identical (verified: the
  underlying DEF is already byte-identical across runs — this is purely a
  GDS-container-format artifact). See `layout/README.md`'s "Reproducibility
  note" and the filed tool gap,
  [`2AMLogic/klayout-tools#1367`](https://github.com/2AMLogic/klayout-tools/issues/1367).
- `flow/par_report_trim.py` strips local-absolute-path and bare
  tool-version fields out of `klt place-and-route`'s JSON response before it
  is committed as `layout/logic_tile.par.json`, so a toolchain upgrade alone
  does not produce a spurious diff (same rationale as the Yosys-version
  header strip above).

**Friction encountered**: the default `yosys` this environment resolved on
`PATH` was a WASI-sandboxed (YoWASP) build, which cannot open a `klt
synthesize`-generated `.ys` script living outside its sandbox — `klt
synthesize` fails with a confusing "No such file or directory" for a file
that plainly exists. `flow/layout.sh` works around this by preferring a
native `/usr/bin/yosys` when present (mirroring the same workaround already
used internally by klayout-tools' own `tests/corpus/*/regenerate.sh`
scripts). Filed generically as
[`2AMLogic/klayout-tools#1368`](https://github.com/2AMLogic/klayout-tools/issues/1368),
since neither the CLI nor `docs/cli/synthesize.md` warn about it.

**Out of scope here**: DRC/LVS signoff (`flow/drc.sh` / `flow/lvs.sh`
below), extracted-parasitics timing characterization (`flow/sta-sweep.sh`
below — `klt place-and-route`'s own built-in multi-corner sweep is a
pre-signoff *estimate*, not a characterization), and Monte Carlo. See
`layout/README.md` for the full list of what the committed artifacts do and
do not claim.

### `flow/layout_routed.sh` — EXPERIMENTAL composed-tile physical canary (G2, issue #102)

Additive sibling of `flow/layout.sh` for the composed tile
`design/rtl/logic_tile_routed.v` (4x `lut4_slice` + generated
`logic_tile_switch_matrix`, flat 158-bit `cfg`). It reuses
`flow/par_request.py`, `flow/par_report_trim.py` and
`flow/gds_canonicalize.py`, but has its own build directory
(`flow/build/routed/`) and artifact namespace (`layout/experimental/`); the
BEL-only `flow/layout.sh`, `layout/logic_tile.*` and the signoff pins are
untouched.

```
./flow/layout_routed.sh            # regenerate, compare every artifact, and
                                   # verify the latest run record pins them
./flow/layout_routed.sh --update   # overwrite artifacts, append a run record
```

Artifacts under `layout/experimental/`, all from one run:
`logic_tile_routed.gds` (canonicalized), `.def`, `.v` (klt's as-built
netlist), `.synth.v` (yosys netlist fed to place-and-route), `.par.json`
(trimmed report; `flow/layout_routed.sh` additionally drops the nested
`power.placed.def_path` local path) and `run-records/*.json` (append-only:
source and artifact sha256, tool versions, synthesis/P&R metrics, and a
structural analysis of the as-built netlist computed by
`flow/layout_routed_record.py` -- port widths, matrix/BEL hierarchy
prefixes, and a cell-level combinational-cycle SCC check).

What it establishes: the composed RTL (same-index stand-in matrix, ADR-0004
still Proposed) synthesizes against `sky130_fd_sc_hd`, places and routes
through OpenROAD to the `route` stage, with the matrix (`u_sm/`) and four
BELs (`g_slice[i].u_slice/`) present in the as-built netlist and the `cfg`
(158) and 4x4 edge ports intact. What it does NOT establish: DRC/LVS/ERC
(see `flow/routed_checks.sh` below for the experimental observations), characterized or extracted timing (the klt slack
numbers are OpenROAD estimates against a placeholder 20 ns clock with no
I/O delays), nextpnr routability, or shared-reset compliance (the four BEL
reset pins are independently routed through the matrix). No programmable path
was pruned; the cycle check found no intra-tile cycle because matrix BEL
inputs select only from tile inputs and BEL outputs only reach tile outputs,
but inter-tile abutment loops are invisible to a single-tile run.

### `flow/drc.sh` — DRC clean report (T1 item 3)

`flow/drc.sh` runs a full sky130 foundry-rule-deck DRC check (`klt drc`,
klayout-tools' headless curated engine) against the committed tile GDS
(`layout/logic_tile.gds`, from `flow/layout.sh` above) and checks the
result against the committed report at `layout/logic_tile.drc.json`. This
is the T1 "DRC clean" pass condition (item 3 of
`docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`, per issue
#11): *"latest `klt drc` JSON report with `status: clean`, fresh
(provenance matching current sources)."*

Running:

```
./flow/drc.sh            # rerun DRC against the committed GDS, diff the
                          # (trimmed) report against the committed copy
                          # under layout/, and verify provenance freshness
                          # via `klt drc --check`. Exit 0 iff clean,
                          # reproducible, and fresh.
./flow/drc.sh --update   # rerun DRC and overwrite the committed report.
                          # Run this (and commit the result) after an
                          # intentional layout change (i.e. after
                          # `flow/layout.sh --update`).
```

Requires `klt` (klayout-tools) on `PATH`, plus a resolvable sky130A PDK
install (`klt pdk find --pdk sky130A`). Scratch output (the raw `klt drc`
response before trimming) lands in `flow/build/` (gitignored), same
non-committed-scratch shape as the other flow scripts.

`flow/drc_report_trim.py` strips bare tool-version fields
(`provenance.klt_version`/`klayout_version`) out of the response before
committing, mirroring `flow/par_report_trim.py`'s identical rationale — a
`klt`/KLayout upgrade alone should not produce a spurious diff. The
content-addressed provenance this issue's "freshness ... verifiable later"
acceptance criterion relies on (`provenance.input.content_hash`,
`provenance.deck.content_hash`) is left untouched, and `flow/drc.sh`'s last
step (`klt drc --check`) re-hashes the committed GDS and deck and confirms
they still match what the committed report recorded.

**No friction filed**: `klt drc` (curated engine, default) ran cleanly
end to end against this layout on the first attempt — no missing
capability, awkward interface, or incorrect result encountered. The one
alternate path tried, `--engine klayout` (a PDK-native DRC-DSL deck via a
standalone `klayout` binary), fails with a clear, documented error in this
environment (no standalone `klayout` binary on `PATH`) rather than a
confusing one — expected behavior per `klt drc --help`, not a tool gap. See
`layout/README.md`'s "DRC scope, concretely" section for exactly what the
curated-engine "clean" verdict does and does not cover.

**Out of scope here**: LVS (`klt lvs`, `spec/framework-gaps.md` item G3's
other half — see `flow/lvs.sh` below, issue #12) and the PDK-native
`--engine klayout` DRC-DSL signoff path (not exercised — see above).

### `flow/lvs.sh` — LVS clean report (T1 item 4)

`flow/lvs.sh` runs `klt lvs` comparing `layout/logic_tile.gds` against its
own as-built gate-level reference netlist and checks the result against the
committed report at `layout/logic_tile.lvs.json`. This is the T1 "LVS
clean" pass condition (item 4 of `docs/design-evidence-tiers.md` in
`2AMLogic/klayout-tools`, per issue #12): *"latest LVS report with `status:
match`, fresh, engine named."*

**Reference-netlist form**: `design/netlist/logic_tile_netlist.v`
(`flow/synth.sh`'s generic-cell netlist) cannot topologically match a
`sky130_fd_sc_hd`-built layout, so this uses `klt lvs`'s documented
"Digital gate-level LVS" path instead (`reference.form =
"gate-level-verilog"`, `docs/cli/lvs.md`): the layout side is `klt extract
--abstract-cells 'sky130_fd_sc_hd__*' --def-net-names` against
`layout/logic_tile.gds`, and the reference side is `klt place-and-route`'s
own as-built `verilog_path` netlist from the *same* synthesize +
place-and-route run (`flow/layout.sh`).

**Why the same run, not the committed GDS as some independent artifact** (a
real, live finding from building this evidence): re-running
`flow/layout.sh`'s synth + place-and-route sequence in an environment whose
`yosys`/OpenROAD build differs from whatever produced the
currently-committed layout is not just *physically* non-reproducible
(differing wirelength/timing numbers) but can be *logically*
non-reproducible too — verified live: two independent place-and-route runs
in the *same* environment (same seed, same synthesized netlist) produce a
byte-identical as-built netlist, but comparing a netlist regenerated in a
*different* environment against a layout built by yet another environment
found 8 `sky130_fd_sc_hd__mux4_2` instances that could not be
topologically matched — two environments' synthesis genuinely picked a
different (if functionally equivalent) gate-level structure for those
instances. An LVS "match" is therefore only honest when the layout and its
reference netlist come from the identical run — `./flow/lvs.sh --update`
regenerates and commits `layout/logic_tile.gds` and
`layout/logic_tile.par.json` (via `flow/layout.sh --update`) together with
`layout/logic_tile.lvs.json`, so all three describe the same, LVS-proven
circuit. Since the GDS content changes, `layout/logic_tile.drc.json`'s own
provenance is re-derived (`flow/drc.sh --update`) in the same pass whenever
this happens, so all four committed layout artifacts stay mutually
consistent. **Exception (issue #69):** the committed LVS report came from
`./flow/lvs.sh --update-report`, a cross-run compare of the unchanged GDS
against a reference regenerated under the LVS klt pin. A restructuring
between runs would fail it as a topology mismatch, so its `match` stays
honest. See `layout/README.md`'s "LVS scope, concretely".

Running:

```
./flow/lvs.sh            # regenerate the as-built reference netlist, run
                          # LVS against the already-committed GDS, and diff
                          # the (trimmed) report against the committed copy
                          # under layout/. Does NOT touch layout/'s
                          # committed GDS/report.
./flow/lvs.sh --update   # regenerate AND commit a fresh, mutually
                          # consistent layout/logic_tile.gds,
                          # logic_tile.par.json, and logic_tile.lvs.json.
                          # Refuses to write a non-"match" report. Run
                          # ./flow/drc.sh --update afterward to keep the
                          # DRC report's provenance in sync with the new
                          # GDS.
./flow/lvs.sh --update-report
                          # as check mode, but overwrite only
                          # layout/logic_tile.lvs.json; GDS/DEF/par report
                          # untouched. For a klt change to the compare
                          # itself (issue #69).
```

Every mode refuses a report whose `power_connectivity.status` is not
`"match"` (issue #69). Under klt `>= 0.6.0`, stage artifacts land in
`.klt/<stage>/run-<id>/`; `flow/lvs.sh` and `flow/layout.sh` fall back to
the newest `run-*` copy, as `flow/sdf-resim.sh` already did.

Requires everything `flow/layout.sh` requires (`klt`, a native `yosys`
build, `openroad`, a resolvable sky130A PDK); LVS itself runs fully
headless via `klt`'s own bundled `klayout` Python package. `flow/lvs.sh`
also auto-exports `$PDK_ROOT`/`$PDK` (only when unset) from `klt pdk
find`'s own resolved root before delegating to `flow/layout.sh` — some
local `openroad` installs are thin Docker wrappers that only mount
`$PDK_ROOT` into the container when that variable is set in the invoking
shell, even when `klt pdk find` itself resolves the PDK fine via a
different search path.

**Friction encountered — escaped identifiers.** This design's
`generate`-block RTL (`design/rtl/logic_tile.v`'s `g_slice[N].u_slice`)
produces an as-built netlist whose internal net/instance names are
Verilog *escaped* identifiers containing `[`, `]`, `.`, `/` — a real `klt
lvs` parsing gap in its `reference.form = "gate-level-verilog"` converter,
filed generically as
[`2AMLogic/klayout-tools#1371`](https://github.com/2AMLogic/klayout-tools/issues/1371).
`flow/lvs_sanitize_verilog.py` works around this with a
connectivity-preserving, name-only rewrite before handing the netlist to
`klt lvs`. `flow/lvs_declared_pins.py` derives the layout side's `--pins`
allow-list from the same as-built netlist's own port declarations, since a
flat `klt extract` promotes every DEF-recovered internal net name to a
top-level pin by default. `flow/lvs_report_trim.py` strips local-path and
tool-version fields out of the response before committing, and injects
`layout_gds_sha256`/`rtl_input_sha256` (content-addressed provenance tied
to the persistent, git-tracked GDS and RTL sources — not the ephemeral
scratch netlists `klt lvs`'s own `environment.*_sha256` hash) so freshness
is verifiable later without re-running the flow.

**Power connectivity (issue #69).** `klt lvs`'s inline
power-connectivity check is on, and the committed report says `match`:
power pins `VGND`/`VPB`/`VPWR`, 63 instances, 0 findings. It was disabled
by issue #49 because under `--abstract-cells` the pre-#2121 extraction
split each row's n-well into a row-local `VPB` net. klayout-tools#2082
showed that was an artifact; #2121 fixed it. This is layout-side pin
consistency, not a supply-integrity check: it does not count islands or
check well taps. That remains `flow/erc.sh`'s job.

**Out of scope here**: the `netgen` LVS engine (not exercised — this uses
`klt lvs`'s default `"klayout"` engine). The netlist compare itself is
**signal-connectivity only**, per `docs/cli/lvs.md`: the
`gate-level-verilog` reference is written without `-include_pwr_gnd`, so it
carries no supply pins and the comparer *drops* the layout's `VPWR`/`VGND`/
`VPB` nets rather than failing on them — 21 of the committed report's
`net_correspondence` entries have `reference: null` for exactly that
reason. This README previously called that "not a gap here, since there is
no power connectivity for this mode to miss", which stopped being true the
moment a PDN existed and was never a safe thing to assert anyway: a
signal-only `match` reads identically whether the layout is fully strapped
or has fifteen mutually isolated rails (issue #41). The supply-island and
well-tie half of the claim is `flow/erc.sh`, below.

### `flow/erc.sh` — supply connectivity + antenna (T1 items 11 and the power half of 4)

`flow/erc.sh` runs `klt erc` over the committed `layout/logic_tile.gds`
with `flow/erc_supply_spec.json` and commits the verdict as
`layout/logic_tile.erc.json`. It rebuilds the layer-by-layer connectivity
model from the GDS geometry alone — no reference netlist — so a supply net
that is drawn but not joined surfaces as `erc.unconnected_net` and a well
with no tap contact inside it surfaces as `erc.missing_tie`. This is the
T1 checklist **item 11 (power delivery, structural)** evidence — approved
as klt#2025 on 2026-09-17, tracked by issues #51 and #4, first committed
honestly unmet in PR #54 and met here — and the **power-connectivity half
of T1 item 4** (issue #41). Against the committed layout it reports **0
findings** and 0 antenna `violate` verdicts across 232 gates; against the
pre-PDN layout (GDS `sha256:a6dc076c…`) the same invocation reported **9
findings** — 7 `erc.missing_tie` plus 2 `erc.unconnected_net` — and PR
#54's tie-less spec measured that same layout at VPWR 7 / VGND 8 islands.
That gap is the whole reason this script exists.

Two things about the spec are load-bearing:

- **It must cover li1 through met5.** A spec that stops at met3 reports
  false islands on a correctly strapped layout, because the straps joining
  the met1 followpin rails live on met4/met5.
- **`VPB` is checked as a tie rule, not as a net.** The n-well body is not
  a drawn conductor on any routing layer, so it is covered by the
  `nwell_tap` entry (every `nwell` region must contain a `tap` contact
  reaching `li1` on `VPWR`) rather than by island analysis. `klt#2169`
  (well+tie collapse, filed from gf180-drone-fc F-034) prescribed
  tie-less specs as the interim and was fixed and closed upstream on
  2026-09-20; the committed report's gates stay intact (232/no false
  short/honest `missing_tie: 0`) precisely because the producing klt
  build carries that fix — the report pins the build in
  `provenance.klt_version`.

Running:

```
./flow/erc.sh            # rerun klt erc against the committed GDS +
                          # supply spec, gate on a clean verdict, diff the
                          # (trimmed) report against the committed copy
                          # under layout/, and verify the report still
                          # content-hash-pins both inputs
                          # (provenance.input ↔ GDS,
                          # provenance.spec ↔ supply spec).
./flow/erc.sh --update   # rerun and overwrite the committed report (run
                          # after ./flow/layout.sh --update, or after any
                          # supply-spec edit).
```

Requires only `klt`, `python3` and a resolvable sky130A PDK rev on `$PATH`
(the `--pdk sky130` switch selects klt's *built-in antenna-ratio table*
only — the connectivity model itself is a pure geometry pass over the
committed GDS and spec JSON and opens no PDK install).

**Toolchain note**: `klt erc` postdates `RECORDED_KLT_VERSION`, so this
report cannot have been produced by the same klt as the committed GDS. The
script prints a klt-version banner and records the producing build in the
report's own `provenance.klt_version` rather than leaving the discrepancy
implicit. The verdict is a pure-geometry statement about the GDS whose hash
the same block pins, so it stays checkable independently of that.

**Out of scope here**: IR drop, electromigration and current density —
nothing in this repo computes them. `klt erc` answers "is every supply
shape actually joined, and is every well tapped", a topology question, not
"is the grid wide enough"; the LVS `power_connectivity` verdict is
`flow/lvs.sh`'s (re-enabled by issue #69 once klayout-tools#2121 fixed the
greybox well artifact), and the `klt signoff --manifest` grading pass is
issue #52's.

### `flow/sta-sweep.sh` — multi-corner timing characterization (G4)

`flow/sta-sweep.sh` extracts parasitics once from the committed
`layout/logic_tile.gds` and then re-times the committed
`layout/logic_tile.def` with `klt sta` (standalone OpenSTA) at **every**
`sky130_fd_sc_hd` liberty corner the installed sky130A PDK ships — 18 of
them — twice per corner: once with LEF-only (unannotated) parasitics and
once with the extracted SPEF annotated in. The trimmed per-corner reports
are committed under
`measurements/timing-characterization/corners/<corner>/{lef-only,spef}.sta.json`
and diff-checked on every run, with the human-readable account under
`measurements/timing-characterization/records/` (append-only).

This is `spec/framework-gaps.md` item **G4 — Timing characterization (no
inherited numbers)**, per issue #20. FABulous marks BEL timing as
placeholder-constant, so no delay, setup/hold or Fmax number can be
inherited; G4's verification bar is "a timing report under `measurements/`
... tracing each published number back to its extraction run".

Running:

```
./flow/sta-sweep.sh            # re-extract, re-sweep every corner, and
                                # diff every per-corner report against the
                                # committed copy. Exit 0 iff every corner
                                # ran, every SPEF run annotated completely,
                                # and nothing drifted.
./flow/sta-sweep.sh --update   # same, but overwrite the committed
                                # per-corner reports (then add a new record
                                # under
                                # measurements/timing-characterization/records/)
```

Requires `klt` and `openroad` on `PATH` plus a resolvable sky130A PDK.
Notably it does **not** require `yosys`: unlike `flow/lvs.sh` this script
never re-runs synthesis or place-and-route. That is the point — `klt sta`
analyses *one fixed piece of geometry* at N corners, whereas re-running
`klt place-and-route` per corner would produce N different placements and
routings (global placement and detailed routing are seeded but not
corner-invariant), i.e. a sweep of N designs rather than a characterization
of one. Scratch output lands in `flow/build/sta/` (gitignored).

Why the routed DEF had to be committed for this: a GDS carries geometry but
no instance/net connectivity for OpenSTA to link against, so `klt sta`
needs the DEF. `flow/layout.sh` now writes and diff-checks
`layout/logic_tile.def` alongside the GDS and the P&R report, from the same
run — no canonicalization needed, since the DEF is already byte-reproducible
across runs of the identical seeded request (`layout/README.md`'s
"Reproducibility note").

`flow/sta_report_trim.py` strips local-path, tool-version and per-run
`engine_log` fields out of each `klt sta` response before committing (same
rationale as `flow/par_report_trim.py`). It also injects
`layout_def_sha256`, `layout_gds_sha256` and `spef_sha256`:
content-addressed provenance tying every published number back to the
git-tracked DEF, the GDS the SPEF was extracted from, and the SPEF it was
annotated with (mirroring what `flow/lvs_report_trim.py` does for LVS).

**The T1 item-5 envelope (issue #68).** After the per-corner loop the
sweep makes **one** multi-corner `klt sta` request. It uses `pdk.corners`
with all 18 corners, the same sanitized DEF and SPEF, and the same 20 ns
`clk` constraint. The trimmed response is committed as
`measurements/timing-characterization/logic_tile.sta.json`, the envelope
`signoff/block-manifest.json` cites for item 5. It is recorded only if
`flow/sta_envelope_check.py` passes, which requires:
- exactly the 18 ratified corners, with none missing, duplicated or extra;
- every corner `timing_status: "constrained"` with non-negative setup and
  hold slack, zero violations and zero TNS;
- complete SPEF annotation;
- `fmax_mhz` consistent with the 20 ns period;
- field-for-field agreement with that corner's single-corner SPEF report.

The sanitized SPEF is committed beside it (`logic_tile.spef`). Check mode
diffs both, and `signoff/verify-pins.sh` re-runs the gate and re-derives
the analysed DEF without klt.

**Friction encountered — escaped identifiers, again.** This design's
`generate`-block RTL (`design/rtl/logic_tile.v`'s `g_slice[N].u_slice`)
makes the flattened design carry net/instance names that are Verilog
*escaped* identifiers containing `[`, `]`, `.` and `/`. Five real
klayout-tools gaps fell out of building this harness, all filed
generically:

- [`klayout-tools#1623`](https://github.com/2AMLogic/klayout-tools/issues/1623)
  — `klt extract --def-net-connections` matches the DEF's net names
  literally, without removing the DEF's own backslash escapes, so every
  hierarchical net silently gets **no `*CONN` block**: a `*D_NET` whose RC
  network has no pin node and therefore contributes nothing to any delay.
  Measured here: 40 of 152 `*D_NET` blocks, including every net on the
  critical path. Same family as
  [`#1371`](https://github.com/2AMLogic/klayout-tools/issues/1371), the
  LVS-side gap `flow/lvs_sanitize_verilog.py` already works around.
- [`klayout-tools#1624`](https://github.com/2AMLogic/klayout-tools/issues/1624)
  — `klt sta` reported `spef_annotation.annotation_complete: true` for a
  SPEF whose annotation OpenSTA's `read_spef` then discarded entirely,
  leaving every setup/hold number bit-identical to the unannotated run (and
  `estimated_power_mw` moving, which makes it look even more like a real
  annotation). The correlation probe uses `get_nets`, which resolves these
  names; `read_spef` uses a different resolver, which does not.
- [`klayout-tools#1625`](https://github.com/2AMLogic/klayout-tools/issues/1625)
  — `klt sta` reports `hold_violation_count` but no hold-side WNS/TNS, so
  corners cannot be ranked by hold margin in a characterization sweep.
- [`klayout-tools#2903`](https://github.com/2AMLogic/klayout-tools/issues/2903)
  (issue #68): since the dotted-net-name rewrite of
  [`#2145`](https://github.com/2AMLogic/klayout-tools/issues/2145),
  `klt extract` writes `a.b/_n_` as `*D_NET a_b/_n_`. `--def-net-connections`
  still keys its pin table by the DEF's dotted name, so #1623's failure
  mode came back: the 40 hierarchical nets got no `*CONN` block, and every
  SPEF run failed the annotation guard (`partially_unannotated_driver_count:
  40`, `delay_changed: false`). `flow/sta_sanitize_names.py def-connections`
  hands the extractor a DEF whose NETS record names are spelled the way it
  now spells them.
- [`klayout-tools#1627`](https://github.com/2AMLogic/klayout-tools/issues/1627)
  — `klt extract --spef` stamps a wall-clock `*DATE` into the SPEF header,
  so two runs of the identical extraction against the identical GDS produce
  SPEFs that differ in exactly that one line. Same class of gap as
  [`#1367`](https://github.com/2AMLogic/klayout-tools/issues/1367) (the
  DEF->GDS merge timestamps `flow/gds_canonicalize.py` already zeroes).

`flow/sta_sanitize_names.py` works around #1623 and #1624 with
connectivity-preserving, name-only rewrites of the DEF and the SPEF (see
that script's header for the exact mapping and why it cannot change a
timing verdict), and works around #1627 by rewriting the SPEF's `*DATE`
line to a constant in the same pass. #1625 is not worked around — the
record simply states what it can and cannot say about hold.

**The workaround is not taken on trust.** `flow/sta-sweep.sh` runs the
unannotated analysis on the committed DEF *and* on the name-rewritten DEF
at every corner and refuses to record that corner's SPEF run unless every
timing and power metric is identical between them. So the rewrite is proven
timing-neutral in the same run that relies on it, at every corner, rather
than argued for in a comment.

**Out of scope here**: propagated-clock STA and a bisected (rather than
`1/(T−WNS)`-extrapolated) Fmax — both listed as tool follow-ups in
`docs/cli/sta.md`, and deliberately not hand-rolled as local OpenSTA
scripts; SDF-back-annotated gate-level re-simulation (a separate follow-on
that can cite this sweep's DEF/SPEF); and the switch matrix / inter-tile
routing, which has no implementation to characterize yet
(`spec/framework-gaps.md` G1/G2). See `measurements/README.md` for the full
list of what the committed numbers do and do not claim.

### `flow/sdf-resim.sh` — SDF-annotated gate-level re-simulation (T1 item 7, issue #29)

The follow-on named above. `flow/sdf-resim.sh` re-runs the same synthesize +
place-and-route request `flow/layout.sh` uses — both build their
`klt.place_and_route.request/1` document from the single shared
`flow/par_request.py` (issue #44), so this and `flow/layout.sh` cannot
silently diverge on the request they submit — adding `post_route_spef` +
`post_route_sdf` (klayout-tools issue #1002) so that run's own post-route
`read_spef` OpenSTA session also writes a real IEEE-1497 SDF —
`measurements/timing-characterization/logic_tile_route.sdf` (canonicalized:
`flow/sdf_canonicalize.py` strips the volatile `(DATE ...)` header line, the
SDF sibling of `flow/sta_sanitize_names.py`'s SPEF `*DATE` rewrite). The
regenerated DEF is diffed **byte-identical** against the committed
`layout/logic_tile.def` before the SDF is trusted — same geometry
`flow/sta-sweep.sh` already characterized, not a different run.

`sim/tb_logic_tile.v` then runs gate-level, unmodified, against the as-built
netlist from that same run: zero delay (**passes**), and SDF-annotated via a
generated `$sdf_annotate`-carrying elaboration root
(`flow/sdf_annotate_shim.py`, mirroring `klt functional-verification`'s own
`_write_sdf_annotate_shim` idiom — used directly rather than through that
verb's CLI because `sim/tb_logic_tile.v` is a plain Verilog testbench, not
cocotb, and converting it is out of this issue's scope).

**Friction encountered — a crash, not a silent gap.** The SDF-annotated leg
deterministically crashes `vvp` (`ERROR: NULL handle passed to vpi_scan.` /
an assertion failure, SIGABRT) on this design's `generate`-block-flattened
escaped identifiers — the same `[`, `]`, `.`, `/` family as the
`flow/sta_sanitize_names.py` friction above, but hitting Icarus's
`$sdf_annotate`/`vvp` this time rather than OpenSTA's SPEF reader. Bisected
to a minimal, from-scratch, non-sky130 15-line reproduction (any
`INTERCONNECT` entry whose escaped identifier contains a literal `.` or
`[`/`]`, independent of file size) and confirmed reproducing identically
through `klt functional-verification`'s own `options.sdf` path, not just
this repo's hand-wired mechanism — filed generically as
[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890) (closed 2026-09-16, but only as a fail-loud guard in klt v0.6.0 -- re-tried 2026-10-08 under #72, still blocked; the remaining gap is [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897)). Note: klt >= 0.6.0 also moved stage artifacts under `.klt/<stage>/run-<id>/`; `flow/sdf-resim.sh` resolves both layouts, but under klt 0.6.0 / OpenROAD 26Q3-1510 its DEF-reproducibility gate fails (toolchain drift, see record `20261008-233733-23e6b5e`).
Not worked around with a fabricated SDF or a faked result:
`flow/sdf-resim.sh` re-attempts this leg every run and treats *reproducing
the cited crash* as the expected, checked-in outcome — a clean pass, a
different failure, or no crash at all is a script failure, since it would
mean the upstream issue's status changed and this evidence needs a fresh
look.

Running:

```
./flow/sdf-resim.sh            # regenerate, verify the DEF/SDF/record, and
                                # confirm both legs reproduce their recorded
                                # outcome. Exit 0 iff the zero-delay leg
                                # PASSes and the SDF-annotated leg reproduces
                                # the exact cited crash.
./flow/sdf-resim.sh --update   # same, but overwrite the committed SDF
                                # (then add a new record under
                                # measurements/timing-characterization/records/)
```

Requires `klt`, `openroad`, a native `yosys` build, a resolvable sky130A PDK,
**and Icarus Verilog 13.0+** for the gate-level legs (`options.sdf`'s own
documented minimum, for `-ginterconnect`) — a separate, newer requirement
than `sim/run.sh`'s plain RTL-level regression. See `resolve_icarus13()` in
the script for how a non-default install location (`$ICARUS13_BIN_DIR`) is
resolved. `sim/tb_lut4_slice.v` is not attempted: `lut4_slice` has no
independently placed-and-routed layout of its own (only as a sub-instance
flattened inside the routed `logic_tile`), so a literal gate-level re-run of
that testbench would need a new physical-design artifact — out of scope
here; see `spec/framework-gaps.md` G4 and `sim/README.md`.

Full method, provenance and result:
`measurements/timing-characterization/records/20260915-133517-234b13b.md`.

### `flow/audit-evidence.sh` — claim → harness → pinned-PDK audit (T1 item 9, issue #34)

T1 checklist item 9 requires that **every claimed measurement** has a
committed testbench/harness and a pinned PDK version. The claim-by-claim
walk is published as `measurements/claim-traceability.md`; this script is
the part that does not go stale. It re-derives that audit from the committed
tree:

1. every record under `measurements/*/records/*.md` names a `harness` that
   exists, and pins `provenance.pdk.version` equal to
   `RECORDED_PDK_VERSION`;
2. every `content_hash` a record pins still describes the committed file
   (a mismatch fails unless it is an explicit, commit-cited entry in
   `flow/audit_evidence.py`'s `ALLOWED_INPUT_DRIFT`);
3. every committed report JSON under `layout/` (recursively, so the
   experimental composed tile's `layout/experimental/*.json` reports are
   covered, issue #149) and `measurements/` pins that
   same PDK revision — or is listed explicitly in
   `flow/audit_evidence.py`'s `PDK_NULL_UPSTREAM_GAP`. Only
   `layout/logic_tile.erc.json` is a live null gap there (`klt erc` writes
   no provenance block and reads no PDK install, klayout-tools#2036) plus
   the single scoped `layout/experimental/logic_tile_routed.erc.json`
   (same `klt erc` producer, spec and trimmer; it content-hash-pins its
   GDS; no other experimental report is exempt); the
   `klt drc`/`klt lvs` entries are retained as regression guards — those
   two reports have pinned the PDK in-artifact since the 2026-09-21
   re-stamp (klayout-tools#1901 was fixed upstream before klt 0.5.0) —
   and the explicit listing is what stops a *new* PDK-less report type
   from quietly joining them.

```
./flow/audit-evidence.sh   # exit 0 iff every claim is traceable and PDK-pinned
```

**Needs no toolchain at all** — no `klt`, no `openroad`, no `yosys`, no PDK
install, no network; it reads committed files plus
`flow/tool_versions.sh`'s `RECORDED_PDK_VERSION`. There is no `--update`
mode: `measurements/*/records/` is append-only, so a failure is fixed by
correcting the tree, by adding a new record, or — for a deliberate,
method-neutral change — by adding a cited allowance, never by rewriting a
published record.

### `flow/routed_checks.sh` — EXPERIMENTAL DRC/LVS/ERC observations + routing-pitch measurement (G3, issue #108)

Runs the pinned `klt drc`, `klt extract` + `klt lvs`, and `klt erc` (existing
`flow/erc_supply_spec.json`, unchanged) against the **committed**
`layout/experimental/logic_tile_routed.gds` and its committed as-built
netlist, reusing `flow/drc_report_trim.py`, `lvs_report_trim.py`,
`erc_report_trim.py`, `lvs_sanitize_verilog.py`, `lvs_declared_pins.py`,
`pdk_root.sh` and `tool_versions.sh` (no copies). It never regenerates the
layout. `flow/routed_pitch.py` additionally extracts the DEF track pitch,
routed segments/length per layer, via counts and utilization.

```
./flow/routed_checks.sh            # rerun; diff against committed reports and
                                   # verify the latest check-record pins them
./flow/routed_checks.sh --update   # overwrite reports, append a check-record
```

Outputs beside the GDS: `logic_tile_routed.{drc,lvs,erc,pitch}.json` and
append-only `check-records/*.json` (separate from `run-records/`). Verdicts
are recorded **as found** and do not affect the exit status: a dirty result
is a valid finding. Nothing is pruned or edited to get clean; this is an
observation of the ADR-0004-Proposed stand-in matrix, not signoff.

### `flow/sta-sweep.sh --routed` — EXPERIMENTAL composed-tile 18-corner STA (G4, issue #113)

Stand-in matrix, ADR-0004 Proposed -- observation, not spec. The same script
and 18 ratified corners as the BEL-only sweep above, re-targeted with
`--routed` (combinable with `--update`) at
`layout/experimental/logic_tile_routed.{def,gds}`; results land in
`measurements/timing-characterization-experimental/` (see its README for what
is and is not claimed), and the BEL-only paths, requests and gate are
unchanged. Differences, all additive and only active under `--routed`:

- `input_delay_ns`/`output_delay_ns` = 0 are added to every `klt sta`
  request, otherwise port-to-port paths are unconstrained.
- `flow/sta_sanitize_names.py def-sanitize-hier` also rewrites plain
  (unescaped) `u_sm/...` hierarchy names, which the composed tile has and
  the BEL-only DEF never did; without it OpenSTA drops ~1500 SPEF records and
  `annotation_complete` is false (the sweep refuses such a run).
- the envelope gate runs `flow/sta_envelope_check.py --observation`: exact
  corner set, decks, complete annotation and single-corner cross-check are
  still required, but non-negative slack is not -- the verdict is recorded
  as found.

Check mode (`./flow/sta-sweep.sh --routed`) regenerates everything and diffs
it against the committed files (about 2.5 minutes, single-process). It reads
only the committed experimental DEF/GDS and does not re-run synthesis or
place-and-route (`flow/layout_routed.sh` owns those; its artifacts already
include the DEF and GDS the SPEF is extracted from, so no SPEF step was needed
there).

### `flow/check_status_claims.py` — README/framework-gaps status drift check (issue #125)

Status facts quoted in `README.md` and `spec/framework-gaps.md` (ADR-0004/0005
status, DRC/LVS verdicts, corner count, binding corner, T1 met/item counts)
carry an explicit marker, e.g. `<!-- status-claim: adr-0004=Proposed -->`.
The checker compares each marker with its committed source (the ADR `Status`
line, `layout/logic_tile.{drc,lvs}.json`, `measurements/characterization-summary.md`,
`signoff/tier-report.json`). It does not parse free prose. `README.md` must
carry every key, so deleting a marker also fails; an unknown key fails.

```
python3 flow/check_status_claims.py          # exit 0 iff every marker holds
python3 flow/test_check_status_claims.py     # unit tests, incl. deliberately wrong fixtures
```

When evidence changes (e.g. an ADR is ratified), update the marker value and
its surrounding prose together; the check fails until you do. Needs no
toolchain; run in CI by `.github/workflows/flow-evidence.yml`.

### `flow/gen_bitstream_format.py` — as-built bitstream-format table + drift check (issue #131)

Renders `design/bitstream-format.md` (per-bit table: frame, frame bit,
position, owner BEL or switch-matrix mux, meaning; per-mux select encodings;
decoded `top_io.cfg` / `top_reg.cfg` fixtures) from
`sim/bitstream/logic4_configmem.map` plus the frozen `tile_specs` in
`sim/bitstream/fabric_spec.json` (the map alone only carries cfg-bit ->
position; field names come from the spec). Generation fails if any of the 158
bits has zero or two owners, if the split is not 68 BEL + 90 matrix, or if a
fixture does not decode through the tables. The document is an **experimental
as-built harness format**, not the ratified-fabric format; G6 stays OPEN.

```
python3 flow/gen_bitstream_format.py           # rewrite the document
python3 flow/gen_bitstream_format.py --check   # exit 1 (with a diff) if stale
python3 flow/test_gen_bitstream_format.py      # incl. changed-map-entry failure
```

Needs no toolchain; `--check` runs in `.github/workflows/flow-evidence.yml`.
