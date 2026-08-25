#!/usr/bin/env bash
# flow/lvs.sh
#
# Run LVS comparing the tile layout (layout/logic_tile.gds) against its
# as-built gate-level reference netlist -- the reproducibility harness for
# T1 item 4 (LVS clean) of docs/design-evidence-tiers.md in
# 2AMLogic/klayout-tools, per issue #12. Mirrors flow/layout.sh's and
# flow/drc.sh's "regenerate from source every run" pattern.
#
# Reference-netlist form: per issue #12's curator notes, `design/netlist/
# logic_tile_netlist.v` (flow/synth.sh's generic-cell netlist) cannot
# topologically match a sky130_fd_sc_hd-built layout, so this uses `klt
# lvs`'s documented "Digital gate-level LVS" path instead
# (`reference.form = "gate-level-verilog"`, docs/cli/lvs.md): the layout
# side is `klt extract --abstract-cells 'sky130_fd_sc_hd__*' --def-net-names`
# against `layout/logic_tile.gds`, and the reference side is `klt
# place-and-route`'s own as-built `verilog_path` netlist from the *same*
# synthesize + place-and-route run (flow/layout.sh).
#
# Why the same run, not the already-committed GDS as-is (a real, live
# finding from building this LVS evidence): re-running flow/layout.sh's
# synth + place-and-route sequence in an environment whose yosys/OpenROAD
# build differs from whatever produced the currently-committed
# layout/logic_tile.gds/.par.json is not just *physically*
# non-reproducible (differing wirelength/timing numbers -- already
# documented in flow/layout.sh's own header) but can be *logically*
# non-reproducible too: verified live building this issue's evidence, two
# independent place-and-route runs in the *same* environment (same seed,
# same synthesized netlist) produce a byte-identical as-built netlist and
# report, but comparing an as-built netlist regenerated in a *different*
# environment against the layout committed by yet another environment
# found 8 `sky130_fd_sc_hd__mux4_2` instances (2 per `lut4_slice`, all 4
# slices) that could not be topologically matched -- i.e. two
# environments' synthesis genuinely picked a different (if functionally
# equivalent) gate-level structure for those instances. An LVS "match" is
# therefore only honest when the layout and its reference netlist come
# from the identical run, which is what `--update` mode below does: it
# refreshes layout/logic_tile.gds and layout/logic_tile.par.json (via
# `flow/layout.sh --update`) together with layout/logic_tile.lvs.json, so
# all three describe the same, LVS-proven circuit -- not scope creep onto
# #9/#11, but the direct consequence of validating those artifacts here.
# The default (non-`--update`) mode never writes to layout/ -- see "Usage"
# below for what a mismatch there means.
#
# Escaped-identifier workaround: this design's `generate`-block RTL
# (design/rtl/logic_tile.v's `g_slice[N].u_slice`) produces an as-built
# netlist whose internal net/instance names are Verilog *escaped*
# identifiers containing `[`, `]`, `.`, `/` -- a real `klt lvs` parsing gap
# in its `reference.form = "gate-level-verilog"` converter, filed
# generically at https://github.com/2AMLogic/klayout-tools/issues/1371.
# This script works around that gap with a connectivity-preserving,
# name-only rewrite (flow/lvs_sanitize_verilog.py) before handing the
# netlist to `klt lvs` -- see that script's own header comment for why the
# rewrite cannot change the compare's verdict. It also derives the layout
# side's `--pins` allow-list from the same as-built netlist's own port
# declarations (flow/lvs_declared_pins.py), since a flat `klt extract`
# promotes every DEF-recovered internal net name to a top-level pin by
# default, and this design's internal names would otherwise vastly
# outnumber (and so, with no allow-list, never line up against) the
# reference's genuine top-level ports.
#
# Usage:
#   ./flow/lvs.sh            # regenerate the as-built reference netlist
#                              (flow/layout.sh, default check mode -- does
#                              NOT touch layout/), extract the already-
#                              committed layout/logic_tile.gds, run LVS,
#                              and diff the (trimmed) report against the
#                              committed copy under layout/. Exit 0 iff
#                              status is "match" and the report is
#                              unchanged; non-zero if either the layout is
#                              stale for this environment's toolchain (see
#                              above) or the report has drifted.
#   ./flow/lvs.sh --update   # regenerate AND commit a fresh, mutually
#                              consistent layout/logic_tile.gds,
#                              logic_tile.par.json (via `flow/layout.sh
#                              --update`), and logic_tile.lvs.json. Refuses
#                              to write a non-"match" LVS report.
#
# Requires everything flow/layout.sh requires (klt, a native yosys build,
# openroad, a resolvable sky130A PDK), plus nothing else -- LVS itself runs
# fully headless via `klt`'s own bundled `klayout` Python package.
#
# Local-environment robustness: if $PDK_ROOT is unset, this script exports
# it (and $PDK) from `klt pdk find`'s own resolved root before delegating
# to flow/layout.sh. This is not a klt/klayout-tools gap -- it accommodates
# a machine-local detail this issue's evidence-gathering ran into: some
# local `openroad` installs are thin Docker wrappers (see e.g.
# `~/.local/bin/openroad`, "Local dev wrapper (not repo-managed)") that
# only mount $PDK_ROOT into the container when that variable is set in the
# invoking shell, even though `klt pdk find` itself resolves the PDK fine
# via a different search path (e.g. a default volare root) with no
# $PDK_ROOT set at all. Exporting it here (only when not already set, so an
# operator's explicit configuration is never overridden) makes this flow
# robust to that without requiring every invoking environment to know about
# it up front.
#
# Exit status: 0 iff LVS reports status "match" and (in the default,
# non-`--update` mode) the trimmed report matches the committed copy;
# non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
LVS_BUILD_DIR="$BUILD_DIR/lvs"
TOP_MODULE="logic_tile"
GDS_NAME="logic_tile.gds"
REPORT_NAME="logic_tile.lvs.json"
STD_CELL_LIBRARY="sky130_fd_sc_hd"
PDK_VARIANT="sky130A"

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

COMMITTED_GDS="$LAYOUT_DIR/${GDS_NAME}"
COMMITTED_REPORT="$LAYOUT_DIR/${REPORT_NAME}"

if [[ "$MODE" != "update" && ! -f "$COMMITTED_GDS" ]]; then
    echo "error: no committed GDS at $COMMITTED_GDS -- run flow/layout.sh --update first" >&2
    exit 1
fi

# See "Local-environment robustness" above.
if [[ -z "${PDK_ROOT:-}" ]]; then
    RESOLVED_ROOT="$(klt pdk find --pdk "$PDK_VARIANT" --format json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('root',''))" 2>/dev/null || true)"
    if [[ -n "$RESOLVED_ROOT" ]]; then
        export PDK_ROOT="$RESOLVED_ROOT"
        export PDK="$PDK_VARIANT"
    fi
fi

if ! klt pdk find --pdk "$PDK_VARIANT" >/dev/null 2>&1; then
    echo "error: no $PDK_VARIANT PDK install resolvable (klt pdk find --pdk $PDK_VARIANT failed)" >&2
    echo "       set \$PDK_ROOT/\$PDK, or install via volare/ciel" >&2
    exit 1
fi

mkdir -p "$LVS_BUILD_DIR"

# --- 1. Regenerate the layout + as-built reference netlist (same run) ---

LAYOUT_LOG="$LVS_BUILD_DIR/layout_regenerate.log"
if [[ "$MODE" == "update" ]]; then
    echo "=== regenerating + committing ${TOP_MODULE}'s layout (flow/layout.sh --update) ==="
    "$SCRIPT_DIR/layout.sh" --update | tee "$LAYOUT_LOG"
else
    echo "=== regenerating ${TOP_MODULE}'s as-built netlist (flow/layout.sh, check mode) ==="
    set +e
    "$SCRIPT_DIR/layout.sh" >"$LAYOUT_LOG" 2>&1
    LAYOUT_STATUS=$?
    set -e
    if [[ "$LAYOUT_STATUS" -ne 0 ]]; then
        echo "note: flow/layout.sh's own committed-copy diff did not pass in this environment (see $LAYOUT_LOG)." >&2
        echo "      That means this environment's toolchain cannot reproduce the currently-committed layout --" >&2
        echo "      run './flow/lvs.sh --update' to regenerate and commit a fresh, mutually consistent" >&2
        echo "      layout/logic_tile.gds + logic_tile.par.json + logic_tile.lvs.json triple. Continuing to" >&2
        echo "      compare the already-committed GDS against this run's reference netlist -- a mismatch below" >&2
        echo "      is the expected, honest consequence of that same non-reproducibility, not a new defect." >&2
    fi
fi

SYNTH_RESPONSE="$BUILD_DIR/synth_response.json"
AS_BUILT_NETLIST="$BUILD_DIR/.klt/place-and-route/${TOP_MODULE}.v"

if [[ ! -s "$AS_BUILT_NETLIST" ]]; then
    echo "error: no as-built netlist at $AS_BUILT_NETLIST -- flow/layout.sh did not reach place-and-route (see $LAYOUT_LOG)" >&2
    exit 1
fi
if [[ ! -s "$SYNTH_RESPONSE" ]]; then
    echo "error: no synth response at $SYNTH_RESPONSE (see $LAYOUT_LOG)" >&2
    exit 1
fi

# --- 2. Work around the escaped-identifier parsing gap (klayout-tools#1371) ---

SANITIZED_NETLIST="$LVS_BUILD_DIR/${TOP_MODULE}.sanitized.v"
echo "=== sanitizing escaped identifiers (klayout-tools#1371 workaround) ==="
python3 "$SCRIPT_DIR/lvs_sanitize_verilog.py" "$AS_BUILT_NETLIST" "$SANITIZED_NETLIST"

DECLARED_PINS="$(python3 "$SCRIPT_DIR/lvs_declared_pins.py" "$AS_BUILT_NETLIST")"

# --- 3. Extract the layout side from layout/logic_tile.gds ---
#
# In --update mode this is the GDS step 1 just (re)wrote, so it is
# guaranteed to be from the same run as $AS_BUILT_NETLIST above. In the
# default check mode it is whatever is already committed -- see the
# "Why the same run" note above for what a mismatch there means.

GATE_SPICE="$LVS_BUILD_DIR/${TOP_MODULE}.gate.spice"
EXTRACT_RESPONSE="$LVS_BUILD_DIR/extract_response.json"

echo "=== klt extract ${GDS_NAME} (abstracted ${STD_CELL_LIBRARY} cells) ==="
if ! klt extract "$COMMITTED_GDS" --deck sky130 \
    --abstract-cells "${STD_CELL_LIBRARY}__*" --def-net-names \
    --pins "$DECLARED_PINS" \
    -o "$GATE_SPICE" --format json | tee "$EXTRACT_RESPONSE"; then
    echo "error: klt extract failed (see $EXTRACT_RESPONSE)" >&2
    exit 1
fi
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$EXTRACT_RESPONSE')).get('status') == 'extracted' else 1)"; then
    echo "error: klt extract did not report status 'extracted' (see $EXTRACT_RESPONSE)" >&2
    exit 1
fi

# --- 4. Run klt lvs ---

# Relative filenames (not absolute paths) here: `klt lvs` resolves a
# request file's relative paths against the request file's own directory
# (docs/cli/lvs.md's `<request>` bullet), and both netlists already live
# alongside $LVS_REQUEST in $LVS_BUILD_DIR.
LVS_REQUEST="$LVS_BUILD_DIR/lvs_request.json"
LVS_RESPONSE="$LVS_BUILD_DIR/lvs_response.json"
GENERATED_REPORT="$LVS_BUILD_DIR/${REPORT_NAME}"

cat > "$LVS_REQUEST" <<EOF
{
  "schema": "klt.lvs.request/1",
  "engine": "klayout",
  "layout": { "netlist": "$(basename "$GATE_SPICE")", "top": "${TOP_MODULE}" },
  "reference": {
    "netlist": "$(basename "$SANITIZED_NETLIST")",
    "top": "${TOP_MODULE}",
    "form": "gate-level-verilog",
    "library": "${STD_CELL_LIBRARY}"
  }
}
EOF

echo "=== klt lvs ${TOP_MODULE} (layout/${GDS_NAME} vs. as-built gate-level-verilog reference) ==="
if ! klt lvs "$LVS_REQUEST" --format json | tee "$LVS_RESPONSE"; then
    echo "error: klt lvs failed (see $LVS_RESPONSE)" >&2
    exit 1
fi
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$LVS_RESPONSE')).get('status') == 'match' else 1)"; then
    echo "error: klt lvs did not report status 'match' (see $LVS_RESPONSE) -- refusing to commit a non-clean LVS report" >&2
    if [[ "$MODE" != "update" ]]; then
        echo "       if this is due to the non-reproducibility note above, run './flow/lvs.sh --update' instead" >&2
    fi
    exit 1
fi

# --- 5. Trim + record content-addressed provenance ---

LAYOUT_GDS_SHA256="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$COMMITTED_GDS")"
RTL_INPUT_SHA256="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['provenance']['input']['content_hash'])" "$SYNTH_RESPONSE")"

python3 "$SCRIPT_DIR/lvs_report_trim.py" "$LVS_RESPONSE" "$LAYOUT_GDS_SHA256" "$RTL_INPUT_SHA256" "$GENERATED_REPORT"

if [[ "$MODE" == "update" ]]; then
    cp "$GENERATED_REPORT" "$COMMITTED_REPORT"
    echo "=== LVS report written to ${COMMITTED_REPORT} (status: match) ==="
    exit 0
fi

if [[ ! -f "$COMMITTED_REPORT" ]]; then
    echo "error: no committed LVS report at $COMMITTED_REPORT -- run '$0 --update' to create it" >&2
    exit 1
fi

status=0
if ! diff -u "$COMMITTED_REPORT" "$GENERATED_REPORT"; then
    echo "error: regenerated LVS report differs from the committed copy at $COMMITTED_REPORT" >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "       run '$0 --update' and commit the result" >&2
    exit 1
fi

echo "=== committed LVS report matches regenerated output (reproducible, status: match) ==="
