#!/usr/bin/env bash
# flow/routed_checks.sh
#
# EXPERIMENTAL DRC / LVS / ERC *observations* on the composed-tile routed
# layout (layout/experimental/logic_tile_routed.gds), plus the observed
# routing pitch / utilization measurement -- issue #108 (G3 physical half).
# Sibling of flow/layout_routed.sh (#102); the BEL-only flows and signed-off
# artifacts (layout/logic_tile.*, signoff/) are NOT touched.
#
# Results are recorded AS FOUND: a violating / mismatching / finding-bearing
# report is a valid, publishable result and does NOT make this script fail.
# Programmable paths are never pruned and no RTL is edited to get clean. The
# stand-in matrix is ADR-0004 (Proposed); nothing here is signoff.
#
# What it checks (it never regenerates the layout -- that is
# flow/layout_routed.sh's job; this runs on the committed experimental
# artifacts, which are one mutually consistent run):
#   DRC  klt drc  (same deck/flags as flow/drc.sh)         -> .drc.json
#   LVS  klt extract + klt lvs against the committed as-built netlist
#        layout/experimental/logic_tile_routed.v, same pipeline as
#        flow/lvs.sh (flow/lvs_sanitize_verilog.py, lvs_declared_pins.py,
#        abstract non-filler sky130_fd_sc_hd cells)         -> .lvs.json
#   ERC  klt erc with the existing flow/erc_supply_spec.json -> .erc.json
#   pitch flow/routed_pitch.py on the committed DEF + par.json -> .pitch.json
# Trimming reuses flow/{drc,lvs,erc}_report_trim.py unchanged.
#
# Artifacts, beside the GDS in layout/experimental/:
#   logic_tile_routed.{drc,lvs,erc,pitch}.json
#   check-records/<UTC>-<gdshash>.json   append-only, one per --update
#
# Usage:
#   ./flow/routed_checks.sh            # rerun, diff against committed reports
#   ./flow/routed_checks.sh --update   # rerun, overwrite reports, append record
#
# Exit 0 iff all tools ran and (check mode) every regenerated report equals
# the committed copy and the latest check-record pins the current GDS and
# reports. The verdicts themselves do not affect the exit status.
#
# Single-unit local runs only (no corner grids): `klt drc/extract/lvs/erc`
# each take seconds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/layout/experimental"
RECORD_DIR="$OUT_DIR/check-records"
BUILD_DIR="$SCRIPT_DIR/build/routed_checks"
TOP="logic_tile_routed"
GDS_REL="layout/experimental/${TOP}.gds"
GDS="$REPO_ROOT/$GDS_REL"
NETLIST="$OUT_DIR/${TOP}.v"
DEF="$OUT_DIR/${TOP}.def"
PAR="$OUT_DIR/${TOP}.par.json"
SPEC="$SCRIPT_DIR/erc_supply_spec.json"
STD_CELL_LIBRARY="sky130_fd_sc_hd"
PDK_VARIANT="sky130A"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    "") ;;
    *) echo "usage: $0 [--update]" >&2; exit 1 ;;
esac

command -v klt >/dev/null 2>&1 || { echo "error: klt not found on PATH" >&2; exit 1; }
for f in "$GDS" "$NETLIST" "$DEF" "$PAR" "$SPEC"; do
    [[ -f "$f" ]] || { echo "error: missing input $f -- run flow/layout_routed.sh --update" >&2; exit 1; }
done

# shellcheck source=./pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"
export_pdk_root_if_unset "$PDK_VARIANT"
require_pdk_resolvable "$PDK_VARIANT"
# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
print_pdk_version_banner "$PDK_VARIANT"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
sha() { python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }

# --- DRC ------------------------------------------------------------------
echo "=== klt drc ${TOP}.gds (deck: sky130; experimental observation) ==="
( cd "$REPO_ROOT" && klt drc "$GDS_REL" --deck sky130 --pdk "$PDK_VARIANT" --format json ) \
    > "$BUILD_DIR/drc.raw" || [[ $? -eq 1 ]] || { echo "error: klt drc failed to run" >&2; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$BUILD_DIR/drc.raw" \
    || { echo "error: klt drc produced no JSON report" >&2; exit 1; }
python3 "$SCRIPT_DIR/drc_report_trim.py" "$BUILD_DIR/drc.raw" "$BUILD_DIR/${TOP}.drc.json"

# --- LVS ------------------------------------------------------------------
echo "=== klt extract + klt lvs ${TOP} (committed as-built netlist; experimental observation) ==="
python3 "$SCRIPT_DIR/lvs_sanitize_verilog.py" "$NETLIST" "$BUILD_DIR/${TOP}.sanitized.v"
DECLARED_PINS="$(python3 "$SCRIPT_DIR/lvs_declared_pins.py" "$NETLIST")"
klt extract "$GDS" --deck sky130 \
    --abstract-cells "${STD_CELL_LIBRARY}__[!f]*" --def-net-names \
    --pins "$DECLARED_PINS" \
    -o "$BUILD_DIR/${TOP}.gate.spice" --format json > "$BUILD_DIR/extract.json" \
    || { echo "error: klt extract failed (see $BUILD_DIR/extract.json)" >&2; exit 1; }
cat > "$BUILD_DIR/lvs_request.json" <<EOF
{
  "schema": "klt.lvs.request/1",
  "engine": "klayout",
  "layout": { "netlist": "${TOP}.gate.spice", "top": "${TOP}" },
  "reference": {
    "netlist": "${TOP}.sanitized.v",
    "top": "${TOP}",
    "form": "gate-level-verilog",
    "library": "${STD_CELL_LIBRARY}"
  }
}
EOF
# klt lvs exits non-zero on a mismatch but still prints the report; any
# other failure leaves no JSON and is caught below.
klt lvs "$BUILD_DIR/lvs_request.json" --format json > "$BUILD_DIR/lvs.raw" || true
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$BUILD_DIR/lvs.raw" \
    || { echo "error: klt lvs produced no JSON report" >&2; exit 1; }
RTL_HASH="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['provenance']['input']['content_hash'])" "$PAR")"
python3 "$SCRIPT_DIR/lvs_report_trim.py" "$BUILD_DIR/lvs.raw" "sha256:$(sha "$GDS")" "$RTL_HASH" \
    "$BUILD_DIR/${TOP}.lvs.json"

# --- ERC ------------------------------------------------------------------
echo "=== klt erc ${TOP}.gds (spec: flow/erc_supply_spec.json; experimental observation) ==="
( cd "$REPO_ROOT" && klt erc "$GDS_REL" flow/erc_supply_spec.json \
    --top "$TOP" --pdk sky130 --format json ) > "$BUILD_DIR/erc.raw" 2>"$BUILD_DIR/erc.err" || true
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$BUILD_DIR/erc.raw" \
    || { echo "error: klt erc produced no JSON report (see $BUILD_DIR/erc.err)" >&2; exit 1; }
python3 "$SCRIPT_DIR/erc_report_trim.py" "$BUILD_DIR/erc.raw" "sha256:$(sha "$GDS")" "sha256:$(sha "$SPEC")" \
    "$(klt --version | awk '{print $2}')" "$BUILD_DIR/${TOP}.erc.json"

# --- routing pitch / utilization measurement ------------------------------
python3 "$SCRIPT_DIR/routed_pitch.py" "$DEF" "$PAR" "$BUILD_DIR/${TOP}.pitch.json"

# --- summary (verdicts as found) ------------------------------------------
python3 - "$BUILD_DIR" "$TOP" <<'PY'
import json, sys
b, top = sys.argv[1:]
d = json.load(open(f"{b}/{top}.drc.json"))
l = json.load(open(f"{b}/{top}.lvs.json"))
e = json.load(open(f"{b}/{top}.erc.json"))
print(f"DRC: status={d.get('status')} violations={d.get('violation_count')}")
print(f"LVS: status={l.get('status')} mismatch_count={l.get('mismatch_count')} "
      f"error_count={l.get('error_count')} power_connectivity={(l.get('power_connectivity') or {}).get('status')}")
print(f"ERC: status={e.get('status')} findings={e.get('erc_finding_count')} "
      f"gates={e.get('gate_count')} antenna_gate_verdicts={e.get('antenna_gate_verdict_counts')}")
PY

REPORTS=("${TOP}.drc.json" "${TOP}.lvs.json" "${TOP}.erc.json" "${TOP}.pitch.json")

if [[ "$MODE" == "update" ]]; then
    for r in "${REPORTS[@]}"; do cp "$BUILD_DIR/$r" "$OUT_DIR/$r"; done
    mkdir -p "$RECORD_DIR"
    python3 - "$REPO_ROOT" "$OUT_DIR" "$RECORD_DIR" "$TOP" "$(klt --version)" <<'PY'
import datetime, hashlib, json, sys
from pathlib import Path
repo, out, rdir, top, klt = sys.argv[1:]
out, rdir = Path(out), Path(rdir)
h = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
reports = [f"{top}.{k}.json" for k in ("drc", "lvs", "erc", "pitch")]
inputs = [f"{top}.{e}" for e in ("gds", "v", "def", "par.json")]
d = json.load(open(out / reports[0])); l = json.load(open(out / reports[1])); e = json.load(open(out / reports[2]))
rec = {
    "schema": "sky130-fpga.routed-checks-record/1",
    "issue": 108,
    "label": "experimental observation; not signoff",
    "inputs_sha256": {n: h(out / n) for n in inputs},
    "reports_sha256": {n: h(out / n) for n in reports},
    "verdicts": {
        "drc": {"status": d.get("status"), "violation_count": d.get("violation_count")},
        "lvs": {"status": l.get("status"), "mismatch_count": l.get("mismatch_count"),
                "error_count": l.get("error_count"),
                "power_connectivity": (l.get("power_connectivity") or {}).get("status")},
        "erc": {"status": e.get("status"), "finding_count": e.get("erc_finding_count"),
                "gate_count": e.get("gate_count")},
    },
    "tools": {"klt": klt},
}
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
path = rdir / f"{stamp}-{rec['inputs_sha256'][inputs[0]][:7]}.json"
assert not path.exists(), "records are append-only"
path.write_text(json.dumps(rec, indent=2, sort_keys=True) + "\n")
print(f"=== reports + record written under {out} ===")
PY
    exit 0
fi

status=0
for r in "${REPORTS[@]}"; do
    if [[ ! -f "$OUT_DIR/$r" ]]; then
        echo "error: no committed $OUT_DIR/$r -- run '$0 --update'" >&2; status=1; continue
    fi
    if ! diff -u "$OUT_DIR/$r" "$BUILD_DIR/$r"; then
        echo "error: regenerated $r differs from committed copy" >&2; status=1
    fi
done
python3 - "$OUT_DIR" "$RECORD_DIR" "$TOP" <<'PY' || status=1
import hashlib, json, sys
from pathlib import Path
out, rdir, top = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
recs = sorted(rdir.glob("*.json")) if rdir.is_dir() else []
if not recs:
    print("error: no check-record", file=sys.stderr); sys.exit(1)
rec = json.load(open(recs[-1]))
bad = [n for grp in ("inputs_sha256", "reports_sha256") for n, s in rec[grp].items()
       if hashlib.sha256((out / n).read_bytes()).hexdigest() != s]
if bad:
    print(f"error: latest check-record {recs[-1].name} does not pin: {bad}", file=sys.stderr); sys.exit(1)
PY
if [[ "$status" -ne 0 ]]; then
    echo "       experimental layout or reports changed without '$0 --update'" >&2
    exit 1
fi
echo "=== committed experimental check reports match regenerated output (verdicts as recorded) ==="
