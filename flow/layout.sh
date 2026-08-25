#!/usr/bin/env bash
# flow/layout.sh
#
# Derive a placed-and-routed sky130 GDS layout for the tile from the
# committed RTL under design/rtl/, via klayout-tools' (`klt`) digital flow
# -- `klt synthesize` (Yosys, mapped against sky130_fd_sc_hd) followed by
# `klt place-and-route` (OpenROAD, floorplan through detailed route, plus
# the DEF->GDS merge) -- and check the result against the committed copy
# under layout/. This is the reproducibility harness for T1 item 2
# (Layout) of docs/design-evidence-tiers.md in 2AMLogic/klayout-tools, per
# issue #9: "committed layout, reproducible from sources -- presence AND
# reproducibility, not a one-off drop." Mirrors flow/synth.sh's and
# sim/run.sh's "regenerate from source every run" pattern.
#
# Scope note: this is layout only -- floorplan/place/route to a routed GDS.
# It does NOT run DRC/LVS signoff, corner verification beyond what OpenROAD's
# own multi-corner STA reports as part of place-and-route, Monte Carlo, or
# PEX -- those are separate, already-tracked follow-on work
# (spec/framework-gaps.md items G3-G4). See layout/README.md for what the
# committed artifacts do and do not claim.
#
# Usage:
#   ./flow/layout.sh            # regenerate the GDS + report and diff both
#                               # against the committed copies under
#                               # layout/. Exit 0 if identical; non-zero if
#                               # they differ or the flow fails.
#   ./flow/layout.sh --update  # regenerate and overwrite the committed
#                               # copies under layout/. Run this (and commit
#                               # the result) after an intentional RTL
#                               # change.
#
# Requires on $PATH: `klt` (klayout-tools), a native `yosys` build (see the
# YoWASP note below), and `openroad`. Requires a resolvable sky130A PDK
# install (`klt pdk find --pdk sky130A`; $PDK_ROOT/$PDK, volare, or ciel).
#
# Exit status: 0 iff synthesis + place-and-route succeed and (in the
# default, non-`--update` mode) both the regenerated GDS (after timestamp
# canonicalization -- see flow/gds_canonicalize.py) and the regenerated
# report (after volatile-field trimming -- see flow/par_report_trim.py)
# match their committed copies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTL_DIR="$REPO_ROOT/design/rtl"
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
TOP_MODULE="logic_tile"
GDS_NAME="logic_tile.gds"
REPORT_NAME="logic_tile.par.json"

# Nominal placeholder only -- NOT a timing claim. Real timing/Fmax
# characterization is deferred to spec/framework-gaps.md item G4; this
# value exists solely because `klt place-and-route` requires
# constraints.clock_period_ns once target_stage reaches "place" or later
# (a clock tree has no meaning without a target period). Chosen loose
# enough (50 MHz) to be trivially met by this small a design so CTS/routing
# have a real, achievable target to route to without this flow accidentally
# reading as a performance claim -- see layout/README.md.
CLOCK_PERIOD_NS=20
CLOCK_PORT="clk"

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

for tool in klt openroad; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

# Prefer a native yosys build over any WASI-sandboxed (YoWASP) one earlier
# on $PATH -- a YoWASP yosys cannot open a `klt synthesize`-generated .ys
# script living outside its sandbox's preopened directories, and fails with
# a confusing "No such file or directory" for a file that plainly exists.
# Verified live (issue #9); filed generically as
# https://github.com/2AMLogic/klayout-tools/issues/1368. Mirrors the same
# workaround klayout-tools' own tests/corpus/*/regenerate.sh scripts already
# use ("prepend /usr/bin so a native yosys build is used, if present").
if [[ -x /usr/bin/yosys ]]; then
    PATH="/usr/bin:$PATH"
fi
if ! command -v yosys >/dev/null 2>&1; then
    echo "error: yosys not found on PATH" >&2
    exit 1
fi

if ! klt pdk find --pdk sky130A >/dev/null 2>&1; then
    echo "error: no sky130A PDK install resolvable (klt pdk find --pdk sky130A failed)" >&2
    echo "       set \$PDK_ROOT/\$PDK, or install via volare/ciel" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$LAYOUT_DIR"

SYNTH_REQUEST="$BUILD_DIR/synth_request.json"
PAR_REQUEST="$BUILD_DIR/par_request.json"
SYNTH_RESPONSE="$BUILD_DIR/synth_response.json"
PAR_RESPONSE="$BUILD_DIR/par_response.json"
SYNTH_NETLIST="$BUILD_DIR/.klt/synthesize/${TOP_MODULE}_synth.v"
RAW_GDS="$BUILD_DIR/.klt/place-and-route/${TOP_MODULE}.gds"
GENERATED_GDS="$BUILD_DIR/${GDS_NAME}"
GENERATED_REPORT="$BUILD_DIR/${REPORT_NAME}"
COMMITTED_GDS="$LAYOUT_DIR/${GDS_NAME}"
COMMITTED_REPORT="$LAYOUT_DIR/${REPORT_NAME}"

cat > "$SYNTH_REQUEST" <<EOF
{
  "schema": "klt.synthesize.request/1",
  "engine": "yosys",
  "sources": ["${RTL_DIR}/lut4_slice.v", "${RTL_DIR}/logic_tile.v"],
  "hdl_toplevel": "${TOP_MODULE}",
  "pdk": { "cell_library": "sky130_fd_sc_hd", "corner": "tt_025C_1v80" },
  "constraints": { "clock_period_ns": ${CLOCK_PERIOD_NS} }
}
EOF

echo "=== klt synthesize ${TOP_MODULE} (sky130_fd_sc_hd) ==="
if ! klt synthesize "$SYNTH_REQUEST" --pdk sky130A --format json | tee "$SYNTH_RESPONSE"; then
    echo "error: klt synthesize failed (see $SYNTH_RESPONSE)" >&2
    exit 1
fi
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$SYNTH_RESPONSE')).get('status') == 'ok' else 1)"; then
    echo "error: klt synthesize did not report status ok (see $SYNTH_RESPONSE)" >&2
    exit 1
fi

if [[ ! -s "$SYNTH_NETLIST" ]]; then
    echo "error: klt synthesize did not produce a netlist at $SYNTH_NETLIST" >&2
    exit 1
fi

cat > "$PAR_REQUEST" <<EOF
{
  "schema": "klt.place_and_route.request/1",
  "engine": "openroad",
  "netlist": "${SYNTH_NETLIST}",
  "hdl_toplevel": "${TOP_MODULE}",
  "pdk": { "cell_library": "sky130_fd_sc_hd", "corner": "tt_025C_1v80" },
  "floorplan": {
    "method": "utilization",
    "utilization_pct": 40,
    "aspect_ratio": 1.0,
    "core_margin_um": 2.0,
    "site": "unithd"
  },
  "io": { "layer_h": "met3", "layer_v": "met2" },
  "constraints": { "clock_port": "${CLOCK_PORT}", "clock_period_ns": ${CLOCK_PERIOD_NS} },
  "seed": 1,
  "target_stage": "route"
}
EOF

echo "=== klt place-and-route ${TOP_MODULE} (sky130_fd_sc_hd, OpenROAD) ==="
if ! klt place-and-route "$PAR_REQUEST" --pdk sky130A --format json | tee "$PAR_RESPONSE"; then
    echo "error: klt place-and-route failed (see $PAR_RESPONSE)" >&2
    exit 1
fi
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$PAR_RESPONSE')).get('stage_reached') == 'route' else 1)"; then
    echo "error: klt place-and-route did not reach the 'route' stage (see $PAR_RESPONSE)" >&2
    exit 1
fi

if [[ ! -s "$RAW_GDS" ]]; then
    echo "error: klt place-and-route did not produce a GDS at $RAW_GDS" >&2
    exit 1
fi

# Canonicalize away the embedded per-structure timestamps klt's DEF->GDS
# merge stamps with the wall-clock time of the merge -- see
# flow/gds_canonicalize.py's own header comment and
# https://github.com/2AMLogic/klayout-tools/issues/1367. Without this step,
# two runs of the identical, seeded request produce a functionally
# identical but not byte-identical GDS, breaking the plain diff below.
python3 "$SCRIPT_DIR/gds_canonicalize.py" "$RAW_GDS" "$GENERATED_GDS"

# Trim volatile (local-path / tool-version) fields out of the response
# before comparing/committing -- see flow/par_report_trim.py's own header
# comment.
python3 "$SCRIPT_DIR/par_report_trim.py" "$PAR_RESPONSE" "$GENERATED_REPORT"

if [[ "$MODE" == "update" ]]; then
    cp "$GENERATED_GDS" "$COMMITTED_GDS"
    cp "$GENERATED_REPORT" "$COMMITTED_REPORT"
    echo "=== GDS written to ${COMMITTED_GDS} ==="
    echo "=== report written to ${COMMITTED_REPORT} ==="
    exit 0
fi

if [[ ! -f "$COMMITTED_GDS" ]]; then
    echo "error: no committed GDS at $COMMITTED_GDS -- run '$0 --update' to create it" >&2
    exit 1
fi
if [[ ! -f "$COMMITTED_REPORT" ]]; then
    echo "error: no committed report at $COMMITTED_REPORT -- run '$0 --update' to create it" >&2
    exit 1
fi

status=0
if ! cmp -s "$COMMITTED_GDS" "$GENERATED_GDS"; then
    echo "error: regenerated GDS (after timestamp canonicalization) differs from the committed copy at $COMMITTED_GDS" >&2
    status=1
fi
if ! diff -u "$COMMITTED_REPORT" "$GENERATED_REPORT"; then
    echo "error: regenerated report differs from the committed copy at $COMMITTED_REPORT" >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "       RTL changed (or the flow is non-reproducible) without regenerating the layout -- run '$0 --update' and commit the result" >&2
    exit 1
fi

echo "=== committed layout matches regenerated output (reproducible) ==="
