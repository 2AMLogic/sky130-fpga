#!/usr/bin/env bash
# flow/erc.sh
#
# Run a supply-connectivity ERC check (`klt erc`, klayout-tools) against the
# committed tile layout (`layout/logic_tile.gds`, from flow/layout.sh) and
# check the result against the committed report under layout/.
#
# Why this exists (issue #41). `flow/lvs.sh`'s `status: "match"` is a
# **signal-connectivity-only** compare: `klt place-and-route`'s as-built
# `verilog_path` reference netlist carries no supply pins (it is written
# without `-include_pwr_gnd`, per `docs/cli/lvs.md`), so the comparer drops
# the layout's VPWR/VGND/VPB nets rather than failing on them. That is
# harmless when a layout has no power grid to check -- and it is exactly
# what let this repo carry a layout with 15 mutually isolated met1 rails,
# no straps, no vias and no tapcells while citing an LVS "match" toward T1
# item 4. `klt erc` is the check that actually binds the claim: it rebuilds
# the layer-by-layer connectivity model from the GDS geometry alone, so a
# supply net that is drawn but not joined shows up as an island, and a well
# with no tap contact inside it shows up as `erc.missing_tie`.
#
# The supply spec (`flow/erc_supply_spec.json`) must cover **li1 through
# met5**. A spec that stops at met3 reports false islands on a correctly
# strapped layout, because the straps that join the met1 followpin rails
# live on met4/met5 and a stackup that omits them cannot see the join.
#
# Recorded baseline, for reference -- against the pre-PDN layout this issue
# replaced (GDS sha256:a6dc076c...), the same invocation reported 9
# findings: 7 x `erc.missing_tie` (nwell regions with no tap contact inside
# them) and 2 x `erc.unconnected_net` (VPWR and VGND each resolving to
# multiple mutually isolated islands). Against the committed layout it
# reports 0.
#
# Scope note: this is the *supply* half of ERC plus `klt erc`'s per-gate
# antenna-ratio verdict against the PDK's real limit table. It is not
# IR-drop / electromigration analysis (no current densities are computed
# anywhere in this repo -- see layout/README.md's "Power delivery network"
# section for what the PDN claim does and does not cover), and it does not
# re-derive the layout itself (that is flow/layout.sh's job).
#
# Usage:
#   ./flow/erc.sh            # rerun ERC against the committed layout and
#                             # diff the (trimmed) report against the
#                             # committed copy under layout/. Exit 0 iff
#                             # identical and 0 findings; non-zero otherwise.
#   ./flow/erc.sh --update   # rerun ERC and overwrite the committed report.
#                             # Run this (and commit the result) after an
#                             # intentional layout change (i.e. after
#                             # `flow/lvs.sh --update`).
#
# Requires on $PATH: `klt` (klayout-tools). Requires a resolvable sky130A
# PDK install (`klt pdk find --pdk sky130A`) -- not for the connectivity
# model itself (that is pure geometry) but so the PDK-revision banner below
# can pin what the antenna-limit table was resolved against.
#
# Exit status: 0 iff `klt erc` reports `erc_finding_count: 0` and no
# antenna `violate` verdict, and (in the default, non-`--update` mode) the
# regenerated report matches the committed copy; non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
GDS_NAME="logic_tile.gds"
SPEC_NAME="erc_supply_spec.json"
REPORT_NAME="logic_tile.erc.json"
TOP_CELL="logic_tile"
PDK_VARIANT="sky130A"
ERC_PDK="sky130"

MODE="check"
case "${1:-}" in
    --update)
        MODE="update"
        ;;
    "")
        MODE="check"
        ;;
    *)
        echo "usage: $0 [--update]" >&2
        exit 1
        ;;
esac

if ! command -v klt >/dev/null 2>&1; then
    echo "error: klt not found on PATH" >&2
    exit 1
fi

# Shared with flow/drc.sh, flow/layout.sh, flow/lvs.sh and
# flow/sta-sweep.sh (issue #45). Only `require_pdk_resolvable` is used here:
# this script's connectivity model is pure geometry and never shells out to
# `openroad`, so it has no need for `export_pdk_root_if_unset`'s Docker-
# wrapper accommodation.
# shellcheck source=./pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"
require_pdk_resolvable "$PDK_VARIANT"

# `klt erc` writes no provenance block at all (klayout-tools#2036, fixed
# upstream after the klt build this repo pins), so -- exactly as for
# flow/drc.sh and flow/lvs.sh -- this banner is the only place a PDK swap
# becomes visible at run time. The committed report's own
# `layout_gds_sha256`/`supply_spec_sha256` (injected by
# flow/erc_report_trim.py) cover input freshness.
# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
print_klt_version_banner
print_pdk_version_banner "$PDK_VARIANT"

# The klt build actually producing this report, recorded into the committed
# report's own provenance (see erc_report_trim.py). `klt erc` postdates
# RECORDED_KLT_VERSION, so this WILL differ from the klt that produced the
# committed GDS -- that is expected, and recording it is how the committed
# evidence stays honest about it rather than implying one toolchain
# produced everything. The verdict itself is a pure-geometry statement
# about the GDS whose hash the report also pins, so it stays checkable
# regardless of which klt computed it.
KLT_VERSION="$(klt --version 2>/dev/null | awk '{print $2}')"

mkdir -p "$BUILD_DIR"

COMMITTED_GDS="$LAYOUT_DIR/${GDS_NAME}"
COMMITTED_SPEC="$SCRIPT_DIR/${SPEC_NAME}"
COMMITTED_REPORT="$LAYOUT_DIR/${REPORT_NAME}"
RAW_REPORT="$BUILD_DIR/${REPORT_NAME}.raw"
GENERATED_REPORT="$BUILD_DIR/${REPORT_NAME}"

if [[ ! -f "$COMMITTED_GDS" ]]; then
    echo "error: no committed GDS at $COMMITTED_GDS -- run flow/layout.sh --update first" >&2
    exit 1
fi
if [[ ! -f "$COMMITTED_SPEC" ]]; then
    echo "error: no supply spec at $COMMITTED_SPEC" >&2
    exit 1
fi

# Run with repo-root-relative paths so the report's echoed `file`/`spec`
# fields are identical across invoking hosts/checkout locations -- mirrors
# flow/drc.sh's own absolute-path avoidance.
echo "=== klt erc ${GDS_NAME} (spec: flow/${SPEC_NAME}, top: ${TOP_CELL}) ==="
if ! ( cd "$REPO_ROOT" && klt erc "layout/${GDS_NAME}" "flow/${SPEC_NAME}" \
        --top "$TOP_CELL" --pdk "$ERC_PDK" --format json > "$RAW_REPORT" ); then
    echo "error: klt erc failed (see $RAW_REPORT)" >&2
    exit 1
fi

# Verdict gate, before any diffing: a finding list that is not empty, or any
# gate whose antenna verdict is `violate`, is a failure regardless of
# whether it happens to reproduce the committed copy.
python3 - "$RAW_REPORT" <<'PY' || exit 1
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
findings = report.get("erc_findings", []) or []
violating = [g for g in report.get("gates", []) or [] if g.get("antenna_verdict") == "violate"]

print(f"erc findings: {len(findings)}")
print(f"gates: {report.get('gate_count')} (antenna 'violate': {len(violating)})")
for finding in findings[:20]:
    print(f"  {finding.get('rule')}: net={finding.get('net')} layer={finding.get('layer')}")
if len(findings) > 20:
    print(f"  ... and {len(findings) - 20} more")

if findings or violating:
    print(
        "error: klt erc reported findings -- the layout's supply nets are not "
        "fully connected, or a gate exceeds its antenna limit",
        file=sys.stderr,
    )
    sys.exit(1)
PY

LAYOUT_SHA="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$COMMITTED_GDS")"
SPEC_SHA="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$COMMITTED_SPEC")"

python3 "$SCRIPT_DIR/erc_report_trim.py" "$RAW_REPORT" "$LAYOUT_SHA" "$SPEC_SHA" \
    "${KLT_VERSION:-unknown}" "$GENERATED_REPORT"

if [[ "$MODE" == "update" ]]; then
    cp "$GENERATED_REPORT" "$COMMITTED_REPORT"
    echo "=== report written to ${COMMITTED_REPORT} ==="
    exit 0
fi

if [[ ! -f "$COMMITTED_REPORT" ]]; then
    echo "error: no committed report at $COMMITTED_REPORT -- run '$0 --update' to create it" >&2
    exit 1
fi

if ! diff -u "$COMMITTED_REPORT" "$GENERATED_REPORT"; then
    echo "error: regenerated report differs from the committed copy at $COMMITTED_REPORT" >&2
    echo "       layout changed (or the flow is non-reproducible) without regenerating the report -- run '$0 --update' and commit the result" >&2
    echo "       if the klt-version banner above fired, rule out toolchain drift before assuming a design regression:" >&2
    echo "       this report pins provenance.klt_version, and the verdict fields themselves ('erc_finding_count'," >&2
    echo "       antenna 'violate' counts) are what a regression would move -- a diff confined to provenance.klt_version" >&2
    echo "       or to how a passing antenna verdict is *labelled* is a different klt build, not a different layout." >&2
    echo "       See flow/README.md's 'Toolchain versions' section (issue #23)." >&2
    exit 1
fi

echo "=== committed ERC report matches regenerated output (reproducible, 0 findings) ==="
