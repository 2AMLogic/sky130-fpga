#!/usr/bin/env bash
# flow/layout_routed.sh
#
# EXPERIMENTAL physical canary for the composed tile `logic_tile_routed`
# (4x lut4_slice + generated logic_tile_switch_matrix behind the flat 158-bit
# cfg port) -- issue #102, the G2 composed-tile physical follow-on
# (spec/framework-gaps.md). Additive sibling of flow/layout.sh: the BEL-only
# `logic_tile` flow, its layout/logic_tile.* evidence and its signoff pins are
# NOT touched; this script has its own build directory (flow/build/routed)
# and its own artifact namespace (layout/experimental/).
#
# Scope: synthesis + floorplan/place/route + DEF->GDS only, through the same
# klt synthesize / klt place-and-route request helpers as flow/layout.sh
# (flow/par_request.py, flow/par_report_trim.py, flow/gds_canonicalize.py).
# No DRC/LVS/ERC, no extracted-parasitics timing, no nextpnr-routability and
# no shared-reset compliance claim. The matrix is the same-index stand-in
# (spec/decisions/0004 is Proposed); nothing here ratifies it.
# Programmable paths are never pruned: whatever the tools do with the
# configurable feedback structure is recorded as observed.
#
# Artifacts (all from ONE run), under layout/experimental/:
#   logic_tile_routed.gds       canonicalized routed GDS
#   logic_tile_routed.def       routed DEF (verbatim)
#   logic_tile_routed.v         as-built netlist (klt place-and-route's own)
#   logic_tile_routed.synth.v   yosys netlist fed to place-and-route
#   logic_tile_routed.par.json  trimmed place-and-route report
#   run-records/                append-only provenance (one JSON per --update)
#
# Usage:
#   ./flow/layout_routed.sh            # regenerate and compare with committed
#   ./flow/layout_routed.sh --update   # regenerate, overwrite, append a record
#
# Exit 0 iff synthesis + P&R reach 'route' and (check mode) every artifact
# matches and the latest run record pins the current sources and artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTL_DIR="$REPO_ROOT/design/rtl"
OUT_DIR="$REPO_ROOT/layout/experimental"
RECORD_DIR="$OUT_DIR/run-records"
BUILD_DIR="$SCRIPT_DIR/build/routed"
TOP_MODULE="logic_tile_routed"
SOURCES=("$RTL_DIR/lut4_slice.v" "$RTL_DIR/logic_tile_switch_matrix.v" "$RTL_DIR/logic_tile_routed.v")

# Nominal placeholder, NOT a timing claim (see flow/layout.sh). Needed only
# because klt place-and-route requires a clock period at the route stage.
CLOCK_PERIOD_NS=20
CLOCK_PORT="clk"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    "") ;;
    *) echo "usage: $0 [--update]" >&2; exit 1 ;;
esac

for tool in klt openroad; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done

# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
print_tool_version_banner

# Native yosys over YoWASP -- see flow/layout.sh.
if [[ -x /usr/bin/yosys ]]; then PATH="/usr/bin:$PATH"; fi
command -v yosys >/dev/null 2>&1 || { echo "error: yosys not found on PATH" >&2; exit 1; }

# shellcheck source=./pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"
require_pdk_resolvable "sky130A"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR" "$RECORD_DIR"

SYNTH_REQUEST="$BUILD_DIR/synth_request.json"
PAR_REQUEST="$BUILD_DIR/par_request.json"
SYNTH_RESPONSE="$BUILD_DIR/synth_response.json"
PAR_RESPONSE="$BUILD_DIR/par_response.json"
# klt >= 0.7 nests synthesis outputs under a per-run id directory; the build
# dir is wiped each run so at most one run dir exists per stage. Paths are resolved
# after each stage (see `resolve`).
resolve() { ls -1 "$BUILD_DIR/.klt/$1/$2" "$BUILD_DIR/.klt/$1"/*/"$2" 2>/dev/null | head -1 || true; }
SYNTH_NETLIST="" RAW_GDS="" GEN_DEF="" GEN_NETLIST=""
GEN_GDS="$BUILD_DIR/${TOP_MODULE}.gds"
GEN_REPORT="$BUILD_DIR/${TOP_MODULE}.par.json"

python3 - "$SYNTH_REQUEST" "$CLOCK_PERIOD_NS" "$TOP_MODULE" "${SOURCES[@]}" <<'PY'
import json, sys
out, period, top, *srcs = sys.argv[1:]
json.dump({
    "schema": "klt.synthesize.request/1", "engine": "yosys",
    "sources": srcs, "hdl_toplevel": top,
    "pdk": {"cell_library": "sky130_fd_sc_hd", "corner": "tt_025C_1v80"},
    "constraints": {"clock_period_ns": int(period)},
}, open(out, "w"), indent=2)
PY

# klt resolves its working directory (.klt/) relative to the request file.
echo "=== klt synthesize ${TOP_MODULE} (sky130_fd_sc_hd) ==="
klt synthesize "$SYNTH_REQUEST" --pdk sky130A --format json | tee "$SYNTH_RESPONSE" >/dev/null
python3 -c "import json,sys; sys.exit(0 if json.load(open('$SYNTH_RESPONSE')).get('status') == 'ok' else 1)" \
    || { echo "error: klt synthesize not ok (see $SYNTH_RESPONSE)" >&2; exit 1; }
SYNTH_NETLIST="$(resolve synthesize "${TOP_MODULE}_synth.v")"
[[ -s "$SYNTH_NETLIST" ]] || { echo "error: no synth netlist at $SYNTH_NETLIST" >&2; exit 1; }

python3 "$SCRIPT_DIR/par_request.py" "$SYNTH_NETLIST" "$PAR_REQUEST" \
    --hdl-toplevel "$TOP_MODULE" --clock-port "$CLOCK_PORT" --clock-period-ns "$CLOCK_PERIOD_NS"

echo "=== klt place-and-route ${TOP_MODULE} (sky130_fd_sc_hd, OpenROAD) ==="
if ! klt place-and-route "$PAR_REQUEST" --pdk sky130A --format json | tee "$PAR_RESPONSE" >/dev/null; then
    echo "error: klt place-and-route failed (see $PAR_RESPONSE); BLOCKED -- do not claim routing" >&2
    exit 1
fi
python3 -c "import json,sys; sys.exit(0 if json.load(open('$PAR_RESPONSE')).get('stage_reached') == 'route' else 1)" \
    || { echo "error: place-and-route did not reach 'route' (see $PAR_RESPONSE)" >&2; exit 1; }
RAW_GDS="$(resolve place-and-route "${TOP_MODULE}.gds")"
GEN_DEF="$(resolve place-and-route "${TOP_MODULE}.def")"
GEN_NETLIST="$(resolve place-and-route "${TOP_MODULE}.v")"
for f in "$RAW_GDS" "$GEN_DEF" "$GEN_NETLIST"; do
    [[ -s "$f" ]] || { echo "error: missing P&R output $f" >&2; exit 1; }
done

python3 "$SCRIPT_DIR/gds_canonicalize.py" "$RAW_GDS" "$GEN_GDS"
python3 "$SCRIPT_DIR/par_report_trim.py" "$PAR_RESPONSE" "$GEN_REPORT"
# par_report_trim.py leaves the nested power.placed.def_path (an absolute
# local path) in place; drop it here so the committed report is
# machine-independent. (Experimental target only -- the BEL-only report is
# deliberately untouched.)
python3 - "$GEN_REPORT" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.get("power", {}).get("placed", {}).pop("def_path", None)
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
open(p, "a").write("\n")
PY

# artifact name -> generated path
declare -A ART=(
    ["${TOP_MODULE}.gds"]="$GEN_GDS"
    ["${TOP_MODULE}.def"]="$GEN_DEF"
    ["${TOP_MODULE}.v"]="$GEN_NETLIST"
    ["${TOP_MODULE}.synth.v"]="$SYNTH_NETLIST"
    ["${TOP_MODULE}.par.json"]="$GEN_REPORT"
)


if [[ "$MODE" == "update" ]]; then
    for name in "${!ART[@]}"; do cp "${ART[$name]}" "$OUT_DIR/$name"; done
    python3 "$SCRIPT_DIR/layout_routed_record.py" write \
        --repo "$REPO_ROOT" --out-dir "$OUT_DIR" --record-dir "$RECORD_DIR" \
        --top "$TOP_MODULE" --clock-period-ns "$CLOCK_PERIOD_NS" \
        --synth-response "$SYNTH_RESPONSE" --par-response "$GEN_REPORT" \
        --klt "$(klt --version)" --openroad "$(openroad -version 2>&1 | head -1)" \
        --yosys "$(yosys -V 2>&1 | head -1)" \
        "${SOURCES[@]}"
    echo "=== experimental artifacts written to ${OUT_DIR} ==="
    exit 0
fi

status=0
for name in "${!ART[@]}"; do
    committed="$OUT_DIR/$name"
    if [[ ! -f "$committed" ]]; then
        echo "error: no committed $committed -- run '$0 --update'" >&2; status=1; continue
    fi
    if ! cmp -s "$committed" "${ART[$name]}"; then
        echo "error: regenerated $name differs from committed copy" >&2; status=1
    fi
done
python3 "$SCRIPT_DIR/layout_routed_record.py" check \
    --repo "$REPO_ROOT" --out-dir "$OUT_DIR" --record-dir "$RECORD_DIR" \
    --top "$TOP_MODULE" "${SOURCES[@]}" || status=1
if [[ "$status" -ne 0 ]]; then
    echo "       sources changed or flow non-reproducible -- see flow/README.md 'Toolchain versions'; rerun with --update" >&2
    exit 1
fi
echo "=== committed experimental layout matches regenerated output (reproducible) ==="
