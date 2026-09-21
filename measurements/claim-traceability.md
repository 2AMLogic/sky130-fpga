# Claim traceability audit (T1 checklist item 9)

**Audited**: 2026-09-15, against `c3c6757` (issue #34, Epic #4 Phase 4).
**Re-audited**: 2026-09-21, for the post-PDN tree (issue #41) — rows 5–13
gained the new ERC claim and the successor records; `./flow/audit-evidence.sh`
re-derives this walk's machine half on every run.
**Re-derive with**: `./flow/audit-evidence.sh` — no toolchain, no PDK
install and no network needed; it reads only committed files.

T1 checklist item 9 of `docs/design-evidence-tiers.md` (in
`2AMLogic/klayout-tools`) requires that **every claimed measurement** has a
committed testbench or flow script and a **pinned PDK version**, so that a
claim's reproducibility does not depend on whichever PDK happened to be
installed when it was run. Epic #4's 2026-09-14 status update marked item 9
*partial*: the testbenches and the STA flow were committed and
`layout/logic_tile.par.json` pinned the PDK, but the claim set had never
been walked end-to-end. This file is that walk, and
`flow/audit-evidence.sh` is the part of it that stays true after today.

The repo's **single pinned PDK source** is `RECORDED_PDK_VERSION` in
`flow/tool_versions.sh`:

```
sky130A, open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b
```

Every claim below either carries that revision in its own artifact, or
inherits it from that one source. The audit script fails if any committed
report pins a *different* revision, so the table and the tree cannot drift
apart silently.

## Every published claim, and what backs it

"Claim" here means a result this repo publishes as evidence — a pass/fail
verdict, a measured number, or a clean/match status — not a design
intention or a spec target.

| # | Claim (where published) | Committed harness / testbench | PDK pin |
|---|---|---|---|
| 1 | `PASS: tb_lut4_slice -- 79 checks, 0 failures` — LUT4 truth-table programmability, registered/combinational select, clock-enable, reset (`sim/README.md`) | `sim/tb_lut4_slice.v`, run by `sim/run.sh` against `design/rtl/lut4_slice.v` | **n/a by construction** — behavioral RTL under Icarus Verilog; no sky130 cell, liberty or PDK file is read. See "PDK-independent claims" below. |
| 2 | `PASS: tb_logic_tile -- 4 checks, 0 failures` — per-slice LUT config, per-slice clock-enable, shared reset (`sim/README.md`) | `sim/tb_logic_tile.v`, run by `sim/run.sh` against `design/rtl/logic_tile.v` | **n/a by construction** — same as #1. |
| 3 | Derived generic-cell netlist reproduces from RTL (`design/netlist/logic_tile_netlist.v`, `flow/README.md`) | `flow/synth.sh` (yosys, no liberty mapping) | **n/a by construction** — technology-independent synthesis; no PDK input. |
| 4 | Die/core area, utilization, wirelength, component counts; GDS+DEF+report regenerate byte-identically (`layout/README.md`, `layout/logic_tile.par.json`) | `flow/layout.sh` (+ `flow/gds_canonicalize.py`, `flow/par_report_trim.py`) | **In-artifact** — `layout/logic_tile.par.json` → `provenance.pdk.{name,version}`. |
| 5 | DRC `status: "clean"`, 0 violations, full-deck (`layout/README.md`, `layout/logic_tile.drc.json`) | `flow/drc.sh` (+ `flow/drc_report_trim.py`) | **In-artifact (since the klt build carrying the klayout-tools#1901 fix)** — `layout/logic_tile.drc.json` → `provenance.pdk.{name,version}`; `flow/drc.sh` resolves the PDK itself so the resolution-path `source` string stays deterministic. On pre-fix klt builds the report wrote `provenance.pdk: null` and inherited from the banner — the historic state G-1 below documents. |
| 6 | LVS `status: "match"` (signal-connectivity compare; the PDN's tapcells pruned as a single `topology.power_only_pruned` warning — 0 errors) (`layout/README.md`, `layout/logic_tile.lvs.json`) | `flow/lvs.sh` (+ `flow/lvs_sanitize_verilog.py`, `flow/lvs_declared_pins.py`, `flow/lvs_report_trim.py`) | **In-artifact (same klt #1901-fix state as #5)** — `layout/logic_tile.lvs.json` → `provenance.pdk.{name,version}`, deterministic for the same reason (`flow/lvs.sh` resolves the PDK). The power-connectivity half of this item is claim #13. |
| 7 | 18-corner STA: per-corner setup WNS/TNS, violation counts, `fmax_mhz`, power, LEF-only vs. SPEF-annotated; binding setup corner `ss_n40C_1v28`, SPEF WNS 15.2146 ns (post-PDN; was 15.1760 ns pre-PDN) (`measurements/timing-characterization/records/20260921-062500-e8a37ad.md`) | `flow/sta-sweep.sh` (+ `flow/sta_sanitize_names.py`, `flow/sta_report_trim.py`), named as `harness` in the record's own `record-meta` | **In-artifact, twice** — the record's `record-meta.provenance.pdk.version`, and `provenance.pdk` in each of the 36 per-corner reports. Gap G-2 below. |
| 8 | Per-corner report set: 36 files (18 corners × LEF-only/SPEF) (`measurements/timing-characterization/corners/`) | `flow/sta-sweep.sh` regenerates and diffs all 36 on every run | **In-artifact** — all 36 carry the identical pinned revision (asserted by `flow/audit-evidence.sh`). |
| 9 | Post-route SDF is real `klt place-and-route --post_route_sdf` output for the byte-identical committed DEF (`measurements/timing-characterization/logic_tile_route.sdf`) | `flow/sdf-resim.sh` (+ `flow/sdf_canonicalize.py`) | **Inherited** — SDF headers carry PVT but no PDK revision; pinned by record `20260921-062530-e8a37ad`'s `record-meta`, which also content-hashes this exact file. |
| 10 | Zero-delay gate-level `PASS: tb_logic_tile -- 4 checks, 0 failures` against the as-built `sky130_fd_sc_hd` netlist (`measurements/.../records/20260921-062530-e8a37ad.md`, `sim/README.md`) | `flow/sdf-resim.sh` re-running `sim/tb_logic_tile.v` **unmodified** (+ `flow/sdf_annotate_shim.py`) | **In-artifact** — record `record-meta.provenance.pdk.version`. Reads the PDK's `sky130_fd_sc_hd` behavioral models, so the pin is load-bearing here. |
| 11 | SDF-annotated leg **blocked** by klayout-tools#1890, reproduced on every run (same record) | `flow/sdf-resim.sh`, which treats a *changed* crash signature as a failure | **In-artifact** — same record. |
| 12 | Ratified timing row: setup/hold-clean at all 18 corners, binding corner `ss_n40C_1v28`, SPEF WNS 15.1760 ns, **no Fmax ratified** (`spec/decisions/0002-tile-timing-spec-ratification.md`, `spec/tile-spec.md`) | No harness of its own — a ruling **on** claim #7, citing it by path. Regenerate the underlying evidence with `./flow/sta-sweep.sh`. | **Inherited** — via the claim-#7 record lineage: ADR-0002 cites the 20260909 original, which remains committed; the post-PDN successor record `20260921-062500-e8a37ad` re-meets the ruling's criteria (WNS 15.2146 ns). |
| 13 | ERC supply-connectivity + antenna: `erc_finding_count: 0` (no floating supply island, no `missing_tie`), 0 antenna `violate` verdicts across 232 gates — the power half of T1 item 4 (`layout/README.md`, `layout/logic_tile.erc.json`) | `flow/erc.sh` (+ `flow/erc_report_trim.py`, `flow/erc_supply_spec.json`) | **Inherited** — `klt erc` writes no provenance block at all (klayout-tools#2036); the trimmed report pins its analysed GDS and supply spec by content hash, and the PDK revision is pinned by `flow/erc.sh`'s banner plus the explicit `PDK_NULL_UPSTREAM_GAP` entry in `flow/audit_evidence.py`. Gap G-4 below. |

`spec/decisions/0001-fabric-framework-choice.md` publishes no measurement —
it is a framework-selection decision — so it has no row.

### PDK-independent claims (#1–#3)

Claims #1–#3 are marked "n/a by construction", not "unpinned". `sim/run.sh`
compiles behavioral RTL with Icarus Verilog and `flow/synth.sh` runs yosys
with no liberty file; neither opens a PDK path, so there is no PDK revision
that could change their result and nothing to pin. Every claim that *does*
read a sky130 file — liberty, LEF, GDS deck, or `sky130_fd_sc_hd`
behavioral models — is pinned in the table above. The gate-level re-run of
`tb_logic_tile.v` (claim #10) is the same testbench source as claim #2 but
a *different* claim precisely because it does read PDK cell models.

## Gaps found, and their disposition

### G-1 — `klt drc` / `klt lvs` record no PDK revision (fixed here; filed upstream)

`layout/logic_tile.drc.json` and `layout/logic_tile.lvs.json` both carry
`provenance.pdk: null`, even though `flow/drc.sh` invokes `klt drc ... --pdk
sky130A`. Confirmed live against klt 0.5.0 during this audit: a fresh `klt
drc layout/logic_tile.gds --deck sky130 --pdk sky130A` still emits
`"pdk": null` while populating `deck` and `input`. The DRC-clean and
LVS-match claims (T1 items 3 and 4) therefore recorded **no PDK revision at
all**, and their check-mode diffs could not notice a PDK swap.

- **Fixed in this PR**: `flow/tool_versions.sh` gains `RECORDED_PDK_VERSION`
  plus `print_pdk_version_banner`, and `flow/drc.sh` / `flow/lvs.sh` now
  print it and warn when the resolved PDK differs from the pinned revision.
  That makes `flow/tool_versions.sh` the single pinned source these two
  claims inherit from, and makes a PDK swap visible at run time.
- **Filed upstream** (per `CLAUDE.md`'s friction protocol, described
  generically): klayout-tools#1901 — `klt drc`/`klt lvs` leave
  `provenance.pdk` null despite an explicit `--pdk`, unlike `klt sta` and
  `klt place-and-route`. When that lands, these two reports will pin the PDK
  in-artifact like every other report and the allowance in
  `flow/audit_evidence.py`'s `PDK_NULL_UPSTREAM_GAP` can be dropped.
- **Landed for the current tree**: issue #41's 2026-09-21 re-stamps under
  the newer klt carry the fix — both `layout/logic_tile.drc.json` and
  `layout/logic_tile.lvs.json` now pin `provenance.pdk.{name,version}`
  in-artifact (rows 5–6). The `PDK_NULL_UPSTREAM_GAP` entries for those
  two files stay for as long as a null-era report could be re-stamped by a
  pre-fix klt build; the only live entry is now the ERC one (G-4 below).

### G-2 — a pinned harness hash had drifted (accounted for, not papered over)

Record `20260909-225431-86f71d2` content-hashes its own harness,
`flow/sta-sweep.sh`. That hash no longer matches the committed file: commit
`f38523e` (PR #25, issue #23) edited the harness after the record was
published, to add the `flow/tool_versions.sh` banner and one extra
check-mode error line. Records are append-only, so the record cannot be
edited to match.

The drift is **print-only** — the diff touches no part of the extraction,
the corner list, the SDC constraints, the report trimming or the diff logic,
so it cannot move the record's numbers. It is recorded as an explicit,
commit-cited entry in `flow/audit_evidence.py`'s `ALLOWED_INPUT_DRIFT`
rather than ignored, so any *further* drift on that file — or any drift on
another pinned input — fails the audit rather than hiding behind this one.

### G-3 — not a gap in item 9, but noted: toolchain drift is unresolved

Check-mode reproducibility (not claim traceability) is currently failing on
this machine for a reason already tracked: the installed klt is 0.5.0 while
the committed artifacts were produced with klt 0.3.0, and
`./flow/drc.sh`'s diff fails on klt's *own built-in deck* hash
(`sha256:5afac7…` → `sha256:a903ac…`, `released: false` → `true`) with
`status: "clean"`, 0 violations and an unchanged input hash. That is issue
#23's known toolchain drift, not a PDK or traceability problem, and
regenerating the committed evidence against a newer toolchain is out of
scope for this audit — it would need its own record. Item 9 asks whether a
claim's harness and PDK are pinned and committed; it does not ask whether
the *tool* is pinned, which this repo explicitly does not do (see
`flow/README.md`, "Toolchain versions").

### G-4 — `klt erc` records no provenance block (filed upstream)

`klt erc` (which postdates every klt version this repo has recorded)
writes no provenance block at all — no PDK revision, no analysed-input
hash. `flow/erc_report_trim.py` synthesizes the drc-shaped provenance
block the committed `layout/logic_tile.erc.json` carries, content-hashing
the exact GDS it analysed and the exact supply spec it resolved nets
against, and `flow/erc.sh` prints the PDK banner so a swap is visible at
run time. Filed upstream (per the friction protocol, described generically)
as klayout-tools#2036; the `PDK_NULL_UPSTREAM_GAP` entry in
`flow/audit_evidence.py` is the audit's half of the accommodation until
it lands. This is the power half of T1 item 4 — the half `klt lvs`
structurally cannot check — so the pin discipline here is load-bearing
for the claim issue #41 re-substantiated.

## What this audit does not cover

- **It does not re-run the measurements.** It checks that each published
  claim names a committed harness, that the harness exists, that the hashes
  a record pins still describe the committed files, and that the PDK
  revision is pinned. Re-deriving the numbers is `./flow/sta-sweep.sh`,
  `./flow/sdf-resim.sh`, `./flow/layout.sh`, `./flow/drc.sh`,
  `./flow/lvs.sh` and `./sim/run.sh` — unchanged by this audit.
- **It does not grade the claims.** Whether a number is trustworthy is the
  business of each record's own "what these numbers do not claim" section
  and of `spec/decisions/`; this audit only asks whether the claim is
  traceable and pinned.
- **It does not extend to claims that do not exist yet.** Bitstream-level
  fabric verification (`spec/framework-gaps.md` G5), switch-matrix timing
  (G1/G2) and post-silicon measurement have no claims in the tree, so they
  have no rows. Adding one later means adding a record — which
  `flow/audit-evidence.sh` will immediately require to name a harness and
  pin the PDK.
