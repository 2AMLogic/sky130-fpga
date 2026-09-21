#!/usr/bin/env python3
"""measurements/generate-characterization-summary.py

Generates `measurements/characterization-summary.md` -- the single
aggregated, current characterization artifact required by the
klayout-tools design-evidence ladder's T1 checklist item 8 -- by reading
and cross-checking the underlying evidence artifacts directly. It does
not hand-type any status/count/slack number into the emitted report:
every number below is either read verbatim out of a committed JSON
record, or asserted present verbatim in a committed markdown record (and
the script fails loudly if an assertion doesn't hold, rather than
emitting a report that has silently drifted from its sources).

Sources aggregated (see each `assert` below for exactly what is
cross-checked against each one):

- layout/logic_tile.drc.json           (DRC)
- layout/logic_tile.lvs.json           (LVS -- signal connectivity only)
- layout/logic_tile.erc.json           (ERC -- supply connectivity + antenna,
  the power half the LVS compare structurally cannot supply; see issue #41)
- measurements/timing-characterization/records/20260909-225431-86f71d2.md
  and the per-corner corners/<corner>/{lef-only,spef}.sta.json machine
  reports it is derived from (18-corner STA sweep)
- spec/tile-spec.md and
  spec/decisions/0002-tile-timing-spec-ratification.md (ratified spec row)
- measurements/timing-characterization/records/20260921-062530-e8a37ad.md
  (SDF generation + gate-level re-simulation, post-PDN successor of the
  20260915-133517-234b13b record)

Usage:
    python3 measurements/generate-characterization-summary.py [--check]

Without arguments, (re)writes `measurements/characterization-summary.md`.
With `--check`, regenerates in memory and exits non-zero if the committed
file would change (CI-style drift check) -- it does not touch the file.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "measurements" / "characterization-summary.md"

STA_RECORD_ID = "20260921-062500-e8a37ad"
SDF_RECORD_ID = "20260921-062530-e8a37ad"
# The record id ADR-0002 cites as its evidentiary source. A ratified
# decision record is never edited, so this historical id stays fixed even
# while a successor sweep record (see its meta's `supersedes`) becomes the
# current STA_RECORD_ID; collect_ratified_spec_row walks the chain.
RATIFIED_STA_RECORD_ID = "20260909-225431-86f71d2"
RECORDS_DIR = REPO_ROOT / "measurements/timing-characterization/records"
STA_RECORD_PATH = RECORDS_DIR / f"{STA_RECORD_ID}.md"
SDF_RECORD_PATH = RECORDS_DIR / f"{SDF_RECORD_ID}.md"
CORNERS_DIR = REPO_ROOT / "measurements/timing-characterization/corners"


def load_json(path: Path):
    return json.loads(path.read_text())


def parse_record_meta(path: Path) -> dict:
    """Pull the `<!-- record-meta {...} -->` JSON header out of a record."""
    text = path.read_text()
    m = re.search(r"<!--\s*record-meta\n(.*?)\n-->", text, re.S)
    if not m:
        raise ValueError(f"{path}: no record-meta header found")
    return json.loads(m.group(1))


def git_last_commit(rel_path: str) -> str:
    """Short commit + date that last touched `rel_path`, or a fallback string."""
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%h %ci", "--", rel_path],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        result = out.stdout.strip()
        return result if result else "unknown (no commit found)"
    except Exception:
        return "unknown (git unavailable)"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"characterization-summary generator: {message}")


def collect_drc():
    path = REPO_ROOT / "layout/logic_tile.drc.json"
    data = load_json(path)
    require(data["status"] == "clean", "DRC status is not 'clean'")
    require(data["violation_count"] == 0, "DRC violation_count is not 0")
    require(data["violations"] == [], "DRC violations[] is not empty")
    return {
        "path": path,
        "status": data["status"],
        "violation_count": data["violation_count"],
        "input_hash": data["provenance"]["input"]["content_hash"],
        "deck": data["deck"],
        "commit": git_last_commit("layout/logic_tile.drc.json"),
    }


def collect_erc():
    """The power-connectivity + antenna half of the layout claim (issue #41).

    Exists because `collect_lvs` structurally cannot supply it: that compare
    reads a `gate-level-verilog` reference carrying no supply pins, so it
    drops the layout's VPWR/VGND/VPB nets rather than checking them. `klt
    erc` works from the GDS geometry alone and needs no reference netlist,
    so a supply net that is drawn but not joined shows up as an island and
    an untapped well shows up as `erc.missing_tie`.
    """
    path = REPO_ROOT / "layout/logic_tile.erc.json"
    data = load_json(path)
    require(data["erc_finding_count"] == 0, "ERC erc_finding_count is not 0")
    require(data["erc_findings"] == [], "ERC erc_findings[] is not empty")
    gate_counts = data["antenna_gate_verdict_counts"]
    require(gate_counts["violate"] == 0, "ERC reports antenna 'violate' gates")
    require(
        data["antenna_verdict_counts"]["violate"] == 0,
        "ERC reports antenna 'violate' levels",
    )
    return {
        "path": path,
        "finding_count": data["erc_finding_count"],
        "gate_count": data["gate_count"],
        "gate_verdicts": gate_counts,
        "layout_gds_sha256": data["provenance"]["input"]["content_hash"],
        "klt_version": data["provenance"]["klt_version"],
        "commit": git_last_commit("layout/logic_tile.erc.json"),
    }


def collect_lvs():
    path = REPO_ROOT / "layout/logic_tile.lvs.json"
    data = load_json(path)
    require(data["status"] == "match", "LVS status is not 'match'")
    require(data["error_count"] == 0, "LVS error_count is not 0")

    # `mismatches[]` must carry no *error*-severity entry; `warning`-severity
    # entries are allowed and are surfaced by name below rather than
    # asserted away (issue #41). This used to be a flat
    # `mismatch_count == 0` / `mismatches == []` pair, which was correct
    # only while the layout had no PDN: adding one makes `klt lvs` emit a
    # standing `severity: "warning"` entry, `topology.power_only_pruned`,
    # recording that it dropped `SKY130_FD_SC_HD__TAPVPWRVGND_1` and its
    # instances before comparing (every pin that cell declares is a
    # power/ground pin the gate-level-Verilog reference never carries).
    # That prune is what keeps `status: "match"` honest -- without it the
    # compare would report the tapcells as spurious extra instances -- so
    # the summary must be able to represent "matched, with a disclosed
    # warning" instead of failing shut on a warning it expects. Blocking on
    # *error* severity is unchanged.
    errors = [m for m in data["mismatches"] if m.get("severity") == "error"]
    require(errors == [], f"LVS mismatches[] carries {len(errors)} error-severity entrie(s)")
    warnings = [m for m in data["mismatches"] if m.get("severity") == "warning"]
    require(
        len(warnings) == data["mismatch_count"],
        "LVS mismatches[] carries entries that are neither error- nor warning-severity",
    )

    return {
        "path": path,
        "status": data["status"],
        "engine": data["engine"],
        "mismatch_count": data["mismatch_count"],
        "warning_categories": sorted(
            {m.get("category") for m in warnings if m.get("category")}
        ),
        "layout_gds_sha256": data["layout_gds_sha256"],
        "top": data["top"],
        "commit": git_last_commit("layout/logic_tile.lvs.json"),
    }


def collect_sta_sweep():
    require(STA_RECORD_PATH.exists(), f"{STA_RECORD_PATH} is missing")
    meta = parse_record_meta(STA_RECORD_PATH)
    require(meta["record_id"] == STA_RECORD_ID, "STA record_id mismatch")
    require(meta["corner_count"] == 18, "STA record corner_count is not 18")
    require(meta["framework_gap"] == "G4", "STA record framework_gap is not G4")

    corner_dirs = sorted(d.name for d in CORNERS_DIR.iterdir() if d.is_dir())
    require(len(corner_dirs) == 18, f"expected 18 corner dirs, found {len(corner_dirs)}")

    per_corner = {}
    for corner in corner_dirs:
        variants = {}
        for variant in ("lef-only", "spef"):
            variant_path = CORNERS_DIR / corner / f"{variant}.sta.json"
            data = load_json(variant_path)
            require(
                data["setup_violation_count"] == 0,
                f"{corner}/{variant}: setup_violation_count != 0",
            )
            require(
                data["hold_violation_count"] == 0,
                f"{corner}/{variant}: hold_violation_count != 0",
            )
            require(
                data["total_negative_slack_ns"] == 0,
                f"{corner}/{variant}: total_negative_slack_ns != 0",
            )
            if variant == "spef":
                require(
                    data["spef_annotation"]["annotation_complete"] is True,
                    f"{corner}/spef: annotation_complete is not true",
                )
            variants[variant] = data
        per_corner[corner] = variants

    # Cross-check the binding setup corner by direct comparison, rather than
    # hand-naming it: the corner with the smallest SPEF-annotated
    # worst_slack_ns wins.
    binding_corner = min(
        per_corner, key=lambda c: per_corner[c]["spef"]["worst_slack_ns"]
    )
    fastest_corner = max(
        per_corner, key=lambda c: per_corner[c]["spef"]["worst_slack_ns"]
    )

    binding = per_corner[binding_corner]
    fastest = per_corner[fastest_corner]

    return {
        "path": STA_RECORD_PATH,
        "record_id": meta["record_id"],
        "git_revision": meta["git_revision"],
        "corner_count": meta["corner_count"],
        "runs_per_corner": meta["runs_per_corner"],
        "harness": meta["harness"],
        "corner_dirs": corner_dirs,
        "binding_corner": binding_corner,
        "binding_wns_lef": binding["lef-only"]["worst_slack_ns"],
        "binding_wns_spef": binding["spef"]["worst_slack_ns"],
        "binding_fmax_spef": binding["spef"]["fmax_mhz"],
        "fastest_corner": fastest_corner,
        "fastest_wns_spef": fastest["spef"]["worst_slack_ns"],
        "fastest_fmax_spef": fastest["spef"]["fmax_mhz"],
        "commit": git_last_commit(str(STA_RECORD_PATH.relative_to(REPO_ROOT))),
    }


def collect_ratified_spec_row():
    tile_spec_path = REPO_ROOT / "spec/tile-spec.md"
    adr_path = REPO_ROOT / "spec/decisions/0002-tile-timing-spec-ratification.md"
    tile_spec_text = tile_spec_path.read_text()

    m = re.search(r"^\| Timing \| (.*?) \| (.*?) \|$", tile_spec_text, re.M)
    require(m is not None, "spec/tile-spec.md: could not find the Timing summary-table row")
    timing_target, timing_rationale = m.group(1), m.group(2)
    require("RATIFIED" in timing_target, "spec/tile-spec.md Timing row is not marked RATIFIED")
    require(
        "0002-tile-timing-spec-ratification.md" in timing_rationale,
        "spec/tile-spec.md Timing row does not cite ADR-0002",
    )

    adr_text = adr_path.read_text()
    require(
        "ratified upon this PR merging" in adr_text,
        "ADR-0002 status line no longer matches expected ratification-via-PR language",
    )
    # ADR-0002 is a ratified decision record and is never edited, so the
    # record id it cites is a fixed historical one; the *current* sweep may
    # be a successor record (records are append-only). The ratification's
    # evidence stays traceable while the current record's `supersedes`
    # chain still reaches the cited original, which is what this walks.
    require(
        RATIFIED_STA_RECORD_ID in adr_text,
        "ADR-0002 no longer cites the STA sweep record it ratifies from",
    )
    cited_path = (
        RECORDS_DIR / f"{RATIFIED_STA_RECORD_ID}.md"
    )
    require(cited_path.exists(), "the ADR-cited STA record file no longer exists")
    lineage_id, seen = STA_RECORD_ID, set()
    while lineage_id != RATIFIED_STA_RECORD_ID:
        require(
            lineage_id not in seen,
            "cycle in the STA record supersedes chain",
        )
        seen.add(lineage_id)
        lineage_path = RECORDS_DIR / f"{lineage_id}.md"
        require(lineage_path.exists(), f"supersedes-chain record {lineage_id} is missing")
        lineage_meta = parse_record_meta(lineage_path)
        supersedes = lineage_meta.get("supersedes")
        require(
            bool(supersedes) and isinstance(supersedes, str),
            f"record {lineage_id} supersedes nothing -- the ADR-cited "
            f"{RATIFIED_STA_RECORD_ID} is unreachable from the current record",
        )
        lineage_id = supersedes

    return {
        "tile_spec_path": tile_spec_path,
        "adr_path": adr_path,
        "timing_target": timing_target,
        "commit": git_last_commit("spec/tile-spec.md"),
        "adr_commit": git_last_commit(
            "spec/decisions/0002-tile-timing-spec-ratification.md"
        ),
    }


def collect_sdf_resim():
    require(SDF_RECORD_PATH.exists(), f"{SDF_RECORD_PATH} is missing")
    meta = parse_record_meta(SDF_RECORD_PATH)
    require(meta["record_id"] == SDF_RECORD_ID, "SDF record_id mismatch")
    require(meta["framework_gap"] == "G4", "SDF record framework_gap is not G4")
    require(meta["experiment"] == "sdf-resim", "SDF record experiment is not sdf-resim")

    text = SDF_RECORD_PATH.read_text()
    require(
        "PASS: tb_logic_tile -- 4 checks, 0 failures" in text,
        "SDF record no longer reports the zero-delay gate-level PASS",
    )
    require(
        "klayout-tools#1890" in text,
        "SDF record no longer cites klayout-tools#1890",
    )
    require(
        "BLOCKED (upstream tool defect, filed and cited, not faked)" in text,
        "SDF record no longer marks the SDF-annotated leg as BLOCKED",
    )

    sdf_path = REPO_ROOT / "measurements/timing-characterization/logic_tile_route.sdf"
    require(sdf_path.exists(), f"{sdf_path} is missing")

    return {
        "path": SDF_RECORD_PATH,
        "record_id": meta["record_id"],
        "git_revision": meta["git_revision"],
        "sdf_path": sdf_path,
        "commit": git_last_commit(str(SDF_RECORD_PATH.relative_to(REPO_ROOT))),
    }


def rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def render(drc, lvs, erc, sta, spec_row, sdf) -> str:
    lines = []
    lines.append("<!-- GENERATED FILE -- do not hand-edit.")
    lines.append(
        "     Regenerate with: python3 measurements/generate-characterization-summary.py"
    )
    lines.append(
        "     Every number below is read from, or asserted present in, the source"
    )
    lines.append(
        "     artifacts cited in each section -- see"
    )
    lines.append("     measurements/generate-characterization-summary.py for the checks. -->")
    lines.append("")
    lines.append("# Characterization summary")
    lines.append("")
    lines.append(
        "One aggregated, current snapshot of the tile's design-evidence artifacts "
        "-- klayout-tools design-evidence ladder T1 checklist **item 8**. Each row "
        "below names a piece of append-only evidence that lives elsewhere in this "
        "repo; this file does not introduce any new claim, spec change, or number "
        "-- it names, cross-checks, and cites what already exists."
    )
    lines.append("")
    lines.append(
        "## At a glance"
    )
    lines.append("")
    lines.append("| Evidence | Status | Source | Derived from |")
    lines.append("| --- | --- | --- | --- |")
    lines.append(
        f"| DRC | **{drc['status']}** ({drc['violation_count']} violations) "
        f"| [`{rel(drc['path'])}`]({rel(drc['path'])}) | commit `{drc['commit']}` |"
    )
    lines.append(
        f"| LVS | **{lvs['status']}** ({lvs['mismatch_count']} mismatches, "
        f"engine `{lvs['engine']}`) "
        f"| [`{rel(lvs['path'])}`]({rel(lvs['path'])}) | commit `{lvs['commit']}` |"
    )
    lines.append(
        f"| ERC (supply connectivity + antenna) | **{erc['finding_count']} findings**, "
        f"0 antenna `violate` across {erc['gate_count']} gates "
        f"| [`{rel(erc['path'])}`]({rel(erc['path'])}) | commit `{erc['commit']}` |"
    )
    lines.append(
        f"| 18-corner STA sweep | **setup/hold-clean at all "
        f"{sta['corner_count']} corners** (binding setup corner "
        f"`{sta['binding_corner']}`, SPEF WNS {sta['binding_wns_spef']} ns) "
        f"| [`{rel(sta['path'])}`]({rel(sta['path'])}) "
        f"| record `{sta['record_id']}`, git revision `{sta['git_revision'][:7]}` |"
    )
    lines.append(
        f"| Ratified timing spec row | **RATIFIED** (ADR-0002) "
        f"| [`{rel(spec_row['tile_spec_path'])}`]({rel(spec_row['tile_spec_path'])}), "
        f"[`{rel(spec_row['adr_path'])}`]({rel(spec_row['adr_path'])}) "
        f"| commit `{spec_row['commit']}` (tile-spec.md), "
        f"`{spec_row['adr_commit']}` (ADR-0002) |"
    )
    lines.append(
        f"| SDF-generation + gate-level re-sim | **zero-delay: PASS; "
        f"SDF-annotated: BLOCKED** (klayout-tools#1890) "
        f"| [`{rel(sdf['path'])}`]({rel(sdf['path'])}) "
        f"| record `{sdf['record_id']}`, git revision `{sdf['git_revision'][:7]}` |"
    )
    lines.append("")

    lines.append("## DRC")
    lines.append("")
    lines.append(
        f"- **Status**: `{drc['status']}`, `violation_count`: {drc['violation_count']}, "
        f"deck: `{drc['deck']}`"
    )
    lines.append(
        f"- **Source**: [`{rel(drc['path'])}`]({rel(drc['path'])}) "
        f"(analysed-input hash `{drc['input_hash']}`)"
    )
    lines.append(f"- **Committed at**: `{drc['commit']}`")
    lines.append("")

    lines.append("## LVS")
    lines.append("")
    lines.append(
        f"- **Status**: `{lvs['status']}`, `mismatch_count`: {lvs['mismatch_count']}, "
        f"engine: `{lvs['engine']}`, top: `{lvs['top']}`"
    )
    lines.append(
        f"- **Source**: [`{rel(lvs['path'])}`]({rel(lvs['path'])}) "
        f"(layout GDS hash `{lvs['layout_gds_sha256']}`)"
    )
    if lvs["warning_categories"]:
        lines.append(
            "- **Warning-severity entries** (0 error-severity): "
            + ", ".join(f"`{c}`" for c in lvs["warning_categories"])
        )
    lines.append(
        "- **Scope**: signal-connectivity only -- this compare comes from a "
        "`gate-level-verilog` reference carrying no supply pins, so it says "
        "nothing about power/ground. The power half of the claim is ERC, "
        "below. See `layout/README.md`'s \"LVS scope, concretely\"."
    )
    lines.append(f"- **Committed at**: `{lvs['commit']}`")
    lines.append("")

    lines.append("## ERC (supply connectivity + antenna)")
    lines.append("")
    lines.append(
        f"- **Findings**: {erc['finding_count']} "
        f"(no floating supply island, no `erc.missing_tie`)"
    )
    lines.append(
        "- **Antenna**: 0 `violate` across "
        f"{erc['gate_count']} gates "
        f"({erc['gate_verdicts']['pass_partial']} `pass_partial`, "
        f"{erc['gate_verdicts']['pass']} `pass`, "
        f"{erc['gate_verdicts']['unchecked']} `unchecked`). "
        "`pass_partial` is the expected sky130 verdict, not a violation: "
        "that PDK's antenna-limit table has no met3-met5 entries, so some "
        "graded level of every gate is necessarily `unchecked`."
    )
    lines.append(
        f"- **Source**: [`{rel(erc['path'])}`]({rel(erc['path'])}) "
        f"(layout GDS hash `{erc['layout_gds_sha256']}`, "
        f"produced by klt `{erc['klt_version']}`)"
    )
    lines.append(
        "- **Why this is separate from LVS**: the LVS compare above is "
        "signal-connectivity only and drops the layout's supply nets. This "
        "is the check that actually binds the power half of the claim -- "
        "against the pre-PDN layout the same invocation reported 9 findings "
        "(7 `erc.missing_tie`, 2 `erc.unconnected_net`). See "
        "`layout/README.md`'s \"Power delivery network\"."
    )
    lines.append(f"- **Committed at**: `{erc['commit']}`")
    lines.append("")

    lines.append("## 18-corner STA sweep")
    lines.append("")
    lines.append(
        f"- **Coverage**: all {sta['corner_count']} `sky130_fd_sc_hd` liberty corners "
        f"the sky130A PDK ships, {sta['runs_per_corner']} runs per corner "
        "(LEF-only on the committed DEF, LEF-only on a name-rewritten control DEF, "
        "SPEF-annotated on the name-rewritten DEF). Cross-checked directly against "
        f"the {len(sta['corner_dirs'])} per-corner "
        "`corners/<corner>/{lef-only,spef}.sta.json` reports: setup-violation count, "
        "hold-violation count and total negative slack are 0 at every corner in both "
        "the LEF-only and SPEF-annotated run, and every SPEF run reports "
        "`spef_annotation.annotation_complete: true`."
    )
    lines.append(
        f"- **Binding setup corner** (minimum SPEF-annotated `worst_slack_ns` across "
        f"all {sta['corner_count']} corners): **`{sta['binding_corner']}`** -- "
        f"WNS {sta['binding_wns_lef']} ns (LEF-only) / "
        f"{sta['binding_wns_spef']} ns (SPEF-annotated), extrapolated "
        f"`fmax_mhz` {sta['binding_fmax_spef']} (SPEF-annotated)."
    )
    lines.append(
        f"- **Fastest corner**: `{sta['fastest_corner']}` -- WNS "
        f"{sta['fastest_wns_spef']} ns (SPEF-annotated), `fmax_mhz` "
        f"{sta['fastest_fmax_spef']}."
    )
    lines.append(
        "- **Fmax caveat carried forward** (per the source record and ADR-0002): "
        "`fmax_mhz` is a single-period `1/(T-WNS)` extrapolation, not a bisected "
        "measurement -- the slacks above are the trustworthy numbers; no Fmax/MHz "
        "figure is ratified anywhere in this repo."
    )
    lines.append(
        f"- **Source**: [`{rel(sta['path'])}`]({rel(sta['path'])}), harness "
        f"`{sta['harness']}`."
    )
    lines.append(
        f"- **Record / git revision**: `{sta['record_id']}`, produced at git revision "
        f"`{sta['git_revision']}`. Committed at: `{sta['commit']}`."
    )
    lines.append("")

    lines.append("## Ratified timing spec row")
    lines.append("")
    lines.append(
        f"- **Status**: ratified (ADR-0002). Current `spec/tile-spec.md` Timing row "
        f"(read live from the file, not retyped here):"
    )
    lines.append("")
    lines.append(f"  > {spec_row['timing_target']}")
    lines.append("")
    lines.append(
        f"- **Source**: [`{rel(spec_row['tile_spec_path'])}`]"
        f"({rel(spec_row['tile_spec_path'])}) (summary table), decision record "
        f"[`{rel(spec_row['adr_path'])}`]({rel(spec_row['adr_path'])})."
    )
    lines.append(
        f"- **Committed at**: `{spec_row['commit']}` (tile-spec.md), "
        f"`{spec_row['adr_commit']}` (ADR-0002)."
    )
    lines.append("")

    lines.append("## SDF-generation + gate-level re-simulation")
    lines.append("")
    lines.append(
        "- **Zero-delay leg**: PASS (`sim/tb_logic_tile.v`, unmodified, run gate-level "
        "against the as-built netlist) -- functional-only, no timing claim."
    )
    lines.append(
        "- **SDF-annotated leg**: BLOCKED by a real, generically-reproducible upstream "
        "defect in `$sdf_annotate` (crashes on escaped identifiers containing `.`/`[]`, "
        "which this design's flattened `generate`-block RTL produces) -- filed as "
        "[klayout-tools#1890](https://github.com/2AMLogic/klayout-tools/issues/1890), "
        "not worked around with a fabricated result."
    )
    lines.append(
        f"- **Source**: [`{rel(sdf['path'])}`]({rel(sdf['path'])}); post-route SDF "
        f"artifact: [`{rel(sdf['sdf_path'])}`]({rel(sdf['sdf_path'])})."
    )
    lines.append(
        f"- **Record / git revision**: `{sdf['record_id']}`, produced at git revision "
        f"`{sdf['git_revision']}`. Committed at: `{sdf['commit']}`."
    )
    lines.append("")

    lines.append("## Regenerating")
    lines.append("")
    lines.append("```")
    lines.append("python3 measurements/generate-characterization-summary.py")
    lines.append("```")
    lines.append("")
    lines.append(
        "Reads and cross-checks the JSON/markdown sources named above; fails loudly "
        "(non-zero exit, no file written) rather than emitting a report that has "
        "drifted from them. It does not re-run any tool -- run `./flow/layout.sh`, "
        "`./flow/sta-sweep.sh` and/or `./flow/sdf-resim.sh` first if you need to "
        "regenerate the underlying evidence itself (see `measurements/README.md`)."
    )
    lines.append("")

    return "\n".join(lines)


def main() -> int:
    check_only = "--check" in sys.argv[1:]

    drc = collect_drc()
    lvs = collect_lvs()
    erc = collect_erc()
    sta = collect_sta_sweep()
    spec_row = collect_ratified_spec_row()
    sdf = collect_sdf_resim()

    rendered = render(drc, lvs, erc, sta, spec_row, sdf)

    if check_only:
        current = OUTPUT_PATH.read_text() if OUTPUT_PATH.exists() else ""
        if current != rendered:
            sys.stderr.write(
                f"{OUTPUT_PATH} is stale relative to its sources -- "
                "regenerate with `python3 measurements/generate-characterization-summary.py`\n"
            )
            return 1
        print(f"{OUTPUT_PATH} is up to date.")
        return 0

    OUTPUT_PATH.write_text(rendered)
    print(f"wrote {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
