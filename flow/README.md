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
`layout/logic_tile.par.json`'s own provenance block and
`measurements/timing-characterization/records/20260909-225431-86f71d2.md`):

| Tool | Version |
|------|---------|
| `klt` (klayout-tools) | `0.3.0+gc6dbf66c53c6` |
| OpenROAD | `26Q3-1278-g4421880472` |
| KLayout (via `klt`) | `0.30.12` |

`flow/layout.sh`, `flow/sta-sweep.sh` and `flow/sdf-resim.sh` all source
`flow/tool_versions.sh` and print the installed `klt`/OpenROAD versions at
the top of every run, with a warning if they differ from the table above
(`RECORDED_KLT_VERSION` / `RECORDED_OPENROAD_VERSION` in that file). This is
**informational, not enforced** — this repo has no CI and no pinned
container image (a possible follow-up, out of scope here), so a mismatch
does not abort the script.

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
and `klt lvs` do not**: both emit `provenance.pdk: null` even when invoked
with `--pdk sky130A` (filed upstream as klayout-tools#1901), so
`layout/logic_tile.drc.json` and `layout/logic_tile.lvs.json` record no PDK
revision and their diffs cannot notice a PDK swap. `flow/drc.sh` and
`flow/lvs.sh` therefore print `print_pdk_version_banner` — the same
warn-on-mismatch shape, and for those two claims the only place a PDK swap
becomes visible at all. T1 checklist item 9 ("every claimed measurement has
a committed testbench and a pinned PDK version") is what this is for; the
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

## Current contents

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
consistent.

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
```

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

**Out of scope here**: the `netgen` LVS engine (not exercised — this uses
`klt lvs`'s default `"klayout"` engine) and a power-connectivity check
(this compare is signal-connectivity only, per `docs/cli/lvs.md` — not a
gap here, since `layout/README.md`'s "No power delivery network" note
means there is no power connectivity for this mode to miss).

### `flow/erc.sh` — ERC supply report (T1 item 11, issue #51)

`flow/erc.sh` runs klayout-tools' `klt erc` against the committed
`layout/logic_tile.gds` with the committed supply spec
(`layout/erc-supply-spec.json`), and checks the result against the
committed report at `layout/logic_tile.erc.json`. This is the T1 item 11
("power delivery, structural") evidence artifact — item 11 was added to
the checklist as
[klayout-tools#2025](https://github.com/2AMLogic/klayout-tools/pull/2025)
on 2026-09-17 and tracked here by issue #51 and the gap-to-T1 tracker.
Unlike items 3-4's clean/match gates, this harness does **not** gate the
run on a clean verdict: the committed report is *expected* to carry
findings while the layout has no power delivery network — `VPWR`
currently resolves to 7 electrical islands and `VGND` to 8 (the 15
isolated met1 rails issue #41 names), so the finding set is the recorded
evidence, and `--update` rewrites it whenever the geometry changes. Read
`layout/README.md`'s "ERC scope, concretely" section for the full
what-this-claim-covers contract (antenna verdicts unchecked by design,
`erc.missing_tie` not computed — the spec declares no `ties[]`,
klayout-tools#2169 — and the well-tie evidence that does stand in).

Running:

```
./flow/erc.sh            # rerun klt erc against the committed GDS +
                          # supply spec, diff the (trimmed) report against
                          # the committed copy under layout/, and verify
                          # the report still content-hash-pins both inputs
                          # (provenance.input ↔ GDS,
                          # provenance.spec ↔ supply spec).
./flow/erc.sh --update   # rerun and overwrite the committed report (run
                          # after ./flow/layout.sh --update, or after any
                          # supply-spec edit).
```

Requires only `klt` and `python3` on `$PATH` — **no PDK install, no
`openroad`/`yosys`**: `klt erc` is a pure geometry connectivity pass over
the committed GDS and spec JSON. (`klt erc`'s own `--pdk` switch selects
klt's *built-in antenna-ratio table*, not a PDK install; it is
deliberately not passed, per the issue-#51 note that the antenna verdict
is not item 11's subject — klayout-tools#1994.)

**Out of scope here**: IR-drop/EM (`klt power`, deliberately outside item
11), the PDN work itself (issue #41), the LVS `power_connectivity` verdict
(needs the PDN-bearing layout, issue #50), and the `klt signoff --manifest`
grading pass (issue #52).

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

`flow/sta_report_trim.py` strips local-path and tool-version fields out of
each `klt sta` response before committing (same rationale as
`flow/par_report_trim.py`) and injects `layout_def_sha256` / `spef_sha256`,
content-addressed provenance tying every published number back to the
git-tracked DEF and to the SPEF it was annotated with (mirroring what
`flow/lvs_report_trim.py` does for LVS).

**Friction encountered — escaped identifiers, again.** This design's
`generate`-block RTL (`design/rtl/logic_tile.v`'s `g_slice[N].u_slice`)
makes the flattened design carry net/instance names that are Verilog
*escaped* identifiers containing `[`, `]`, `.` and `/`. Four real
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
[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890).
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
3. every committed report JSON under `layout/`/`measurements/` pins that
   same PDK revision — or is one of the two `klt drc`/`klt lvs` reports
   whose `provenance.pdk` is null for the filed upstream reason
   (klayout-tools#1901), listed explicitly so a *new* PDK-less report type
   cannot quietly join them.

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
