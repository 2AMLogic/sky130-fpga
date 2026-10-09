#!/usr/bin/env bash
# flow/sta-sweep.sh
#
# Multi-corner timing characterization of the committed routed tile: one
# parasitic extraction from layout/logic_tile.gds, then a standalone `klt
# sta` (OpenSTA) run at every sky130_fd_sc_hd liberty corner the installed
# PDK provides, each corner analysed twice -- once with LEF-only
# (unannotated) parasitics and once with the extracted SPEF annotated in --
# and the trimmed per-corner reports checked against the committed copies
# under measurements/timing-characterization/corners/.
#
# Since issue #68 it also makes ONE multi-corner `klt sta` request
# (`pdk.corners`, all 18 corners in one request/response round trip) over
# the same name-sanitized DEF + SPEF, and commits its trimmed response as
# measurements/timing-characterization/logic_tile.sta.json -- the gradeable
# envelope signoff/block-manifest.json cites for T1 checklist item 5. That
# response is gated by flow/sta_envelope_check.py (exact ratified corner
# set, every corner `timing_status: "constrained"` with non-negative
# setup/hold slack, complete SPEF annotation, fmax consistent with the
# 20 ns reference clock) and cross-checked field-for-field against the
# per-corner single-corner SPEF runs, which keep carrying the name-rewrite
# neutrality control. The sanitized SPEF both annotate is committed beside
# it (measurements/timing-characterization/logic_tile.spef) so the
# parasitics the citation rests on are pinned by committed bytes.
#
# This is the reproducibility harness for spec/framework-gaps.md item G4
# ("Timing characterization -- no inherited numbers"), per issue #20:
# FABulous marks BEL timing as placeholder-constant, so every delay,
# setup/hold and Fmax number this repo publishes has to be earned from
# sky130-specific data. G4's stated verification bar is "a timing report
# under measurements/ ... tracing each published number back to its
# extraction run"; measurements/timing-characterization/ is that report and
# this script is what regenerates it. Mirrors flow/layout.sh's,
# flow/drc.sh's and flow/lvs.sh's "regenerate from source every run"
# check-vs-`--update` pattern.
#
# Why one fixed DEF re-timed N times, not N place-and-route runs:
# characterizing a block means analysing *one* piece of geometry at N
# corners. `klt place-and-route`'s own in-flow corner sweep (the `corners`
# array in layout/logic_tile.par.json) is a different thing -- and its
# numbers are OpenROAD pre-signoff *estimates* from
# `estimate_parasitics -global_routing` (a Steiner-topology Elmore
# estimate), which layout/README.md explicitly disclaims as "not a
# published performance number". `klt sta` re-times the committed routed
# DEF, unmodified, in a fresh OpenSTA session per corner -- see
# klayout-tools' docs/cli/sta.md, "Why this exists".
#
# Why LEF-only *and* SPEF at every corner: an unannotated OpenSTA run
# derives net load from the LEF's pin capacitances alone -- no wire R, no
# wire C. The A/B delta between that and the SPEF-annotated run is the
# interconnect's own contribution, and publishing both is what makes the
# SPEF number checkable rather than merely asserted. Every SPEF run must
# report `spef_annotation.annotation_complete == true`; a run that does not
# is refused here rather than recorded as if it were a measurement.
#
# What this does NOT claim (see measurements/README.md for the full list):
# an ideal (SDC-only, non-propagated) clock, an extrapolated rather than
# bisected fmax_mhz, and first-order lumped-RC parasitics -- not a
# distributed RC ladder and not a field solve.
#
# Issue #113: `--routed` re-targets the whole sweep at the EXPERIMENTAL
# composed tile (layout/experimental/logic_tile_routed.{def,gds}), writing
# to measurements/timing-characterization-experimental/ and adding
# input/output-delay 0 constraints so port-to-port paths are timed. Its
# envelope gate (sta_envelope_check.py --observation) checks structure only
# -- exact 18 corners, decks, complete SPEF annotation, cross-check -- and
# records the verdict as found. See that directory's README.md. Combine with
# `--update` in either order.
#
# Usage:
#   ./flow/sta-sweep.sh            # extract parasitics, sweep every corner,
#                                   # and diff the trimmed per-corner reports,
#                                   # the multi-corner envelope and the
#                                   # sanitized SPEF against the committed
#                                   # copies under
#                                   # measurements/timing-characterization/.
#                                   # Exit 0 iff every corner ran, every SPEF
#                                   # run annotated completely, and nothing
#                                   # drifted.
#   ./flow/sta-sweep.sh --update   # same, but overwrite the committed
#                                   # per-corner reports, envelope and SPEF.
#                                   # Run this (and
#                                   # commit the result, plus a new record
#                                   # under
#                                   # measurements/timing-characterization/records/)
#                                   # after an intentional layout change.
#
# Requires `klt` (klayout-tools) and `openroad` on $PATH, plus a resolvable
# sky130A PDK install (`klt pdk find --pdk sky130A`). Does NOT require
# yosys: unlike flow/lvs.sh this script never re-runs synthesis or
# place-and-route -- it reads only the committed layout/logic_tile.def and
# layout/logic_tile.gds, which is precisely what makes an honest N-corner
# characterization of *one* geometry possible. Scratch output lands in
# flow/build/sta/ (gitignored), same shape as the other flow scripts.
#
# Friction encountered -- see flow/README.md's own section for the full
# writeup and the upstream filings. In short: this design's
# `generate`-block RTL makes the flattened design carry escaped-identifier
# net/instance names containing `/`, `.` and `[]`, which (a) stop `klt
# extract --def-net-connections` from matching the DEF's own (backslashed)
# spelling against the extraction's, so the emitted SPEF has no `*CONN`
# block for any hierarchical net, and (b) stop OpenSTA's SPEF reader from
# resolving those names at all. flow/sta_sanitize_names.py works around
# both with connectivity-preserving, name-only rewrites -- and this script
# proves that rewrite is timing-neutral at every corner by re-running the
# unannotated analysis on the rewritten DEF and refusing to continue unless
# every metric is identical to the committed DEF's own unannotated run.
#
# Exit status: 0 iff extraction succeeds, every corner's LEF-only and SPEF
# runs succeed, every SPEF run reports annotation_complete, the name
# rewrite is proven timing-neutral at every corner, and (in the default,
# non-`--update` mode) every trimmed per-corner report matches its
# committed copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Target selection (issue #113). Default: the ratified BEL-only `logic_tile`.
# `--routed`: the EXPERIMENTAL composed tile `logic_tile_routed` (stand-in
# matrix, ADR-0004 Proposed) -- an additive, separate namespace; see the
# header of this file and measurements/timing-characterization-experimental/
# README.md. The default target's paths, requests and gates are unchanged.
TARGET="bel"
MODE="check"
for arg in "$@"; do
    case "$arg" in
        --update) MODE="update" ;;
        --routed) TARGET="routed" ;;
        *)
            echo "usage: $0 [--routed] [--update]" >&2
            exit 1
            ;;
    esac
done

if [[ "$TARGET" == "routed" ]]; then
    LAYOUT_DIR="$REPO_ROOT/layout/experimental"
    TOP_MODULE="logic_tile_routed"
    TIMING_DIR="$REPO_ROOT/measurements/timing-characterization-experimental"
    STA_BUILD_DIR="$SCRIPT_DIR/build/sta_routed"
    # Boundary constraints: with a clock-only SDC every port-to-port path is
    # unconstrained and `timing_status` would be "unconstrained". Zero
    # input/output delay times in->reg, reg->out and in->out paths against
    # the 20 ns reference period; WNS then reads as 20 ns minus the longest
    # such path. These are reference conventions, not an interface spec.
    IO_CONSTRAINTS=', "input_delay_ns": 0, "output_delay_ns": 0'
    ENVELOPE_GATE_FLAGS="--observation"
    # Plain (unescaped) submodule hierarchy also needs the rewrite -- see
    # sta_sanitize_names.py def_sanitize_hier. BEL-only keeps def-sanitize.
    DEF_SANITIZE_MODE="def-sanitize-hier"
else
    LAYOUT_DIR="$REPO_ROOT/layout"
    TOP_MODULE="logic_tile"
    TIMING_DIR="$REPO_ROOT/measurements/timing-characterization"
    STA_BUILD_DIR="$SCRIPT_DIR/build/sta"
    IO_CONSTRAINTS=""
    ENVELOPE_GATE_FLAGS=""
    DEF_SANITIZE_MODE="def-sanitize"
fi
CORNERS_DIR="$TIMING_DIR/corners"
# The multi-corner envelope cited for T1 item 5 and the sanitized SPEF it
# (and every per-corner SPEF run) annotates -- issue #68.
COMMITTED_ENVELOPE="$TIMING_DIR/${TOP_MODULE}.sta.json"
COMMITTED_SPEF="$TIMING_DIR/${TOP_MODULE}.spef"
STD_CELL_LIBRARY="sky130_fd_sc_hd"
PDK_VARIANT="sky130A"

# Same nominal placeholder period flow/layout.sh uses -- and, as there, NOT
# a timing claim. The published numbers are fmax_mhz, WNS/TNS, the
# violation counts, clock_skew_ns and estimated_power_mw; the SDC period is
# only the reference against which slack is expressed. Keeping it identical
# to flow/layout.sh's keeps this sweep's slack numbers directly comparable
# to layout/logic_tile.par.json's own in-flow estimates.
CLOCK_PORT="clk"
CLOCK_PERIOD_NS=20

# Every sky130_fd_sc_hd liberty corner the sky130A PDK ships, including the
# two `_ccsnoise` variants -- the same 18-corner matrix the sibling digital
# canary sky130-modexp ratified. The 16 distinct PVT points are the ones
# layout/logic_tile.par.json's own in-flow sweep already names; the two
# `_ccsnoise` files are the same PVT points with CCS noise models added,
# run here as well so this sweep covers the installed PDK's liberty set
# exhaustively rather than a hand-picked subset. The list is asserted
# against the PDK's own directory listing below, so a PDK revision that
# adds or drops a corner fails the sweep instead of silently narrowing it.
ALL_CORNERS=(
    ff_100C_1v65 ff_100C_1v95 ff_n40C_1v56 ff_n40C_1v65 ff_n40C_1v76
    ff_n40C_1v95 ff_n40C_1v95_ccsnoise
    tt_025C_1v80 tt_100C_1v80
    ss_100C_1v40 ss_100C_1v60 ss_n40C_1v28 ss_n40C_1v35 ss_n40C_1v40
    ss_n40C_1v44 ss_n40C_1v60 ss_n40C_1v60_ccsnoise ss_n40C_1v76
)

for tool in klt openroad; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
# The committed timing evidence has its own recorded toolchain (issue #68),
# distinct from the layout/ lineage's RECORDED_KLT_VERSION -- see
# flow/tool_versions.sh.
print_tool_version_banner sky130A "$RECORDED_STA_KLT_VERSION" "$RECORDED_STA_OPENROAD_VERSION"

# Same rationale as flow/lvs.sh's own copy of this block -- see
# flow/pdk_root.sh's own header comment for the full writeup.
# shellcheck source=./pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"
export_pdk_root_if_unset "$PDK_VARIANT"
require_pdk_resolvable "$PDK_VARIANT"

COMMITTED_GDS="$LAYOUT_DIR/${TOP_MODULE}.gds"
COMMITTED_DEF="$LAYOUT_DIR/${TOP_MODULE}.def"
for artifact in "$COMMITTED_GDS" "$COMMITTED_DEF"; do
    if [[ ! -f "$artifact" ]]; then
        echo "error: no committed $artifact -- run './flow/layout.sh --update' first" >&2
        exit 1
    fi
done

rm -rf "$STA_BUILD_DIR"
mkdir -p "$STA_BUILD_DIR"

# --- 0. Assert the corner list still matches what the PDK ships ---

LIBS_REF="$(klt pdk find --pdk "$PDK_VARIANT" --format json | python3 -c "import json,sys; print(json.load(sys.stdin)['assets']['libs_ref'])")"
LIB_DIR="$LIBS_REF/${STD_CELL_LIBRARY}/lib"
if [[ ! -d "$LIB_DIR" ]]; then
    echo "error: no liberty directory at $LIB_DIR" >&2
    exit 1
fi
DISCOVERED="$(cd "$LIB_DIR" && ls -1 "${STD_CELL_LIBRARY}"__*.lib 2>/dev/null | sed -e "s/^${STD_CELL_LIBRARY}__//" -e 's/\.lib$//' | sort)"
EXPECTED="$(printf '%s\n' "${ALL_CORNERS[@]}" | sort)"
if [[ "$DISCOVERED" != "$EXPECTED" ]]; then
    echo "error: the installed PDK's ${STD_CELL_LIBRARY} liberty corner set differs from this script's ALL_CORNERS list" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$DISCOVERED") >&2 || true
    echo "       update ALL_CORNERS (and re-run with --update) after confirming the PDK revision change is intended" >&2
    exit 1
fi
echo "=== corner set: ${#ALL_CORNERS[@]} ${STD_CELL_LIBRARY} liberty corners, matching the installed ${PDK_VARIANT} PDK ==="

# --- 1. Derive the DEF rewrites (klayout-tools escaped-identifier gaps) ---

# CONNECTIONS_DEF is what `klt extract --def-net-connections` reads: the
# DEF unescaped, with its NETS record names spelled the way `klt extract`
# itself spells extracted nets since klayout-tools#2145 (`.` -> `_`). Without
# that, every hierarchical net loses its SPEF `*CONN` block again and the
# SPEF runs below fail the annotation guard (klayout-tools#2903, issue #68 -- see
# sta_sanitize_names.py's `def_connections`).
CONNECTIONS_DEF="$STA_BUILD_DIR/${TOP_MODULE}.connections.def"
SANITIZED_DEF="$STA_BUILD_DIR/${TOP_MODULE}.sanitized.def"
echo "=== rewriting escaped identifiers (see flow/sta_sanitize_names.py) ==="
python3 "$SCRIPT_DIR/sta_sanitize_names.py" def-connections "$COMMITTED_DEF" "$CONNECTIONS_DEF"
python3 "$SCRIPT_DIR/sta_sanitize_names.py" "$DEF_SANITIZE_MODE" "$COMMITTED_DEF" "$SANITIZED_DEF"

# --- 2. Extract parasitics once from the committed GDS ---
#
# `--def-net-names` recovers the design's own net names from the DEF->GDS
# merge's labels so the SPEF's `*D_NET` keys line up with what OpenSTA
# times; `--def-net-connections` attaches each net's real (instance, pin)
# connections from the routed DEF, without which every `*D_NET` block is an
# unconnected RC island OpenSTA discards; `--def-pins` derives the genuine
# top-level port set from the DEF's own PINS section (the automatic
# counterpart to the hand-derived `--pins` list flow/lvs.sh builds from the
# as-built netlist -- used here instead so this script needs no synthesis
# or place-and-route re-run); `--abstract-cells` black-boxes the standard
# cells so only the interconnect's parasitics are extracted (the cells'
# own internal delays come from the liberty deck, not from here).

SPEF_RAW="$STA_BUILD_DIR/${TOP_MODULE}.raw.spef"
SPEF="$STA_BUILD_DIR/${TOP_MODULE}.spef"
EXTRACT_SPICE="$STA_BUILD_DIR/${TOP_MODULE}.parasitics.spice"
EXTRACT_RESPONSE="$STA_BUILD_DIR/extract_response.json"

echo "=== klt extract ${TOP_MODULE}.gds --parasitics --spef ==="
if ! klt extract "$COMMITTED_GDS" --deck sky130 \
    --parasitics --spef "$SPEF_RAW" \
    --def-net-names --def-net-connections "$CONNECTIONS_DEF" \
    --def-pins "$COMMITTED_DEF" \
    --abstract-cells "${STD_CELL_LIBRARY}__*" \
    -o "$EXTRACT_SPICE" --format json | tee "$EXTRACT_RESPONSE"; then
    echo "error: klt extract failed (see $EXTRACT_RESPONSE)" >&2
    exit 1
fi
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$EXTRACT_RESPONSE')).get('status') == 'extracted' else 1)"; then
    echo "error: klt extract did not report status 'extracted' (see $EXTRACT_RESPONSE)" >&2
    exit 1
fi

python3 "$SCRIPT_DIR/sta_sanitize_names.py" spef-sanitize "$SPEF_RAW" "$SPEF"

GDS_SHA256="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$COMMITTED_GDS")"
DEF_SHA256="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$COMMITTED_DEF")"
SPEF_SHA256="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$SPEF")"
echo "=== extracted parasitics from ${GDS_SHA256} -> SPEF ${SPEF_SHA256} ==="

# --- 3. Sweep every corner ---

# $1 corner, $2 def path, $3 spef path (or "-"), $4 output response path
run_sta() {
    local corner="$1" def_path="$2" spef_path="$3" response="$4"
    local run_dir spef_field
    run_dir="$(dirname "$response")"
    mkdir -p "$run_dir"
    spef_field=""
    if [[ "$spef_path" != "-" ]]; then
        spef_field="  \"spef\": \"${spef_path}\","
    fi
    cat > "$run_dir/request.json" <<EOF
{
  "schema": "klt.sta.request/1",
  "def": "${def_path}",
  "hdl_toplevel": "${TOP_MODULE}",
  "pdk": { "cell_library": "${STD_CELL_LIBRARY}", "corner": "${corner}" },
${spef_field}
  "constraints": { "clock_port": "${CLOCK_PORT}", "clock_period_ns": ${CLOCK_PERIOD_NS}${IO_CONSTRAINTS} }
}
EOF
    if ! klt sta "$run_dir/request.json" --pdk "$PDK_VARIANT" --format json > "$response" 2>"$run_dir/stderr.log"; then
        echo "error: klt sta failed at corner $corner (see $response / $run_dir/stderr.log)" >&2
        cat "$response" >&2 || true
        return 1
    fi
    return 0
}

status=0
for corner in "${ALL_CORNERS[@]}"; do
    echo "=== ${corner} ==="
    corner_build="$STA_BUILD_DIR/corners/$corner"
    lef_only_response="$corner_build/lef-only/response.json"
    control_response="$corner_build/control/response.json"
    spef_response="$corner_build/spef/response.json"

    run_sta "$corner" "$COMMITTED_DEF" "-" "$lef_only_response"
    run_sta "$corner" "$SANITIZED_DEF" "-" "$control_response"
    run_sta "$corner" "$SANITIZED_DEF" "$SPEF" "$spef_response"

    # The name rewrite must not move a single timing or power number. If it
    # ever did, the SPEF-annotated result would be an analysis of something
    # other than the committed geometry -- so this is a hard stop, not a
    # warning.
    if ! python3 - "$lef_only_response" "$control_response" <<'PYEOF'
import json
import sys

FIELDS = (
    "worst_slack_ns",
    "total_negative_slack_ns",
    "worst_hold_slack_ns",
    "total_negative_hold_slack_ns",
    "timing_status",
    "fmax_mhz",
    "setup_violation_count",
    "hold_violation_count",
    "clock_skew_ns",
    "estimated_power_mw",
)
committed = json.load(open(sys.argv[1], encoding="utf-8"))
rewritten = json.load(open(sys.argv[2], encoding="utf-8"))
drift = [f for f in FIELDS if committed.get(f) != rewritten.get(f)]
if drift:
    print(
        "name-rewrite control failed; these metrics differ between the "
        f"committed DEF and its name-rewritten copy: {', '.join(drift)}",
        file=sys.stderr,
    )
    sys.exit(1)
PYEOF
    then
        echo "error: the name rewrite is not timing-neutral at corner $corner -- refusing to record its SPEF run" >&2
        exit 1
    fi

    if ! python3 -c "
import json, sys
d = json.load(open('$spef_response', encoding='utf-8'))
a = d.get('spef_annotation') or {}
sys.exit(0 if a.get('annotation_complete') is True else 1)
"; then
        echo "error: SPEF annotation incomplete at corner $corner -- this run is NOT a real-parasitics measurement" >&2
        python3 -c "
import json
d = json.load(open('$spef_response', encoding='utf-8'))
print(json.dumps(d.get('spef_annotation'), indent=2))
" >&2 || true
        exit 1
    fi

    committed_corner_dir="$CORNERS_DIR/$corner"
    generated_lef_only="$corner_build/lef-only.sta.json"
    generated_spef="$corner_build/spef.sta.json"
    mkdir -p "$STA_BUILD_DIR/corners-trimmed/$corner"
    python3 "$SCRIPT_DIR/sta_report_trim.py" "$lef_only_response" "$DEF_SHA256" "-" "-" "$generated_lef_only"
    python3 "$SCRIPT_DIR/sta_report_trim.py" "$spef_response" "$DEF_SHA256" "$GDS_SHA256" "$SPEF_SHA256" "$generated_spef"
    cp "$generated_spef" "$STA_BUILD_DIR/corners-trimmed/$corner/spef.sta.json"

    if [[ "$MODE" == "update" ]]; then
        mkdir -p "$committed_corner_dir"
        cp "$generated_lef_only" "$committed_corner_dir/lef-only.sta.json"
        cp "$generated_spef" "$committed_corner_dir/spef.sta.json"
        continue
    fi

    for name in lef-only spef; do
        committed_report="$committed_corner_dir/${name}.sta.json"
        generated_report="$corner_build/${name}.sta.json"
        if [[ ! -f "$committed_report" ]]; then
            echo "error: no committed report at $committed_report -- run '$0 --update' to create it" >&2
            status=1
            continue
        fi
        if ! diff -u "$committed_report" "$generated_report"; then
            echo "error: regenerated $name report at corner $corner differs from the committed copy at $committed_report" >&2
            status=1
        fi
    done
done

# --- 4. One multi-corner request: the gradeable item-5 envelope (issue #68) ---
#
# The same sanitized DEF and SPEF the per-corner SPEF runs above used,
# characterized at all 18 corners by ONE `klt sta` request through its
# native `pdk.corners` list (klayout-tools#1871) -- the response shape
# `klt signoff` grades for T1 item 5. `klt sta` itself re-hashes the DEF
# after the corner loop and refuses to report if it changed, so every entry
# provably describes the same geometry. The gate below then requires the
# exact ratified corner set, constrained non-negative setup/hold at every
# corner, complete SPEF annotation and a 20 ns-consistent fmax, and
# cross-checks every corner entry against the per-corner SPEF report just
# generated (which carries the name-rewrite neutrality control).

echo "=== multi-corner klt sta (pdk.corners, ${#ALL_CORNERS[@]} corners, SPEF-annotated) ==="
multi_build="$STA_BUILD_DIR/multi"
mkdir -p "$multi_build"
corners_json="$(printf '"%s",' "${ALL_CORNERS[@]}")"
corners_json="[${corners_json%,}]"
cat > "$multi_build/request.json" <<EOF
{
  "schema": "klt.sta.request/1",
  "def": "${SANITIZED_DEF}",
  "hdl_toplevel": "${TOP_MODULE}",
  "pdk": { "cell_library": "${STD_CELL_LIBRARY}", "corners": ${corners_json} },
  "spef": "${SPEF}",
  "constraints": { "clock_port": "${CLOCK_PORT}", "clock_period_ns": ${CLOCK_PERIOD_NS}${IO_CONSTRAINTS} }
}
EOF
multi_response="$multi_build/response.json"
if ! klt sta "$multi_build/request.json" --pdk "$PDK_VARIANT" --format json > "$multi_response" 2>"$multi_build/stderr.log"; then
    echo "error: multi-corner klt sta failed (see $multi_response / $multi_build/stderr.log)" >&2
    cat "$multi_response" >&2 || true
    exit 1
fi
generated_envelope="$multi_build/${TOP_MODULE}.sta.json"
python3 "$SCRIPT_DIR/sta_report_trim.py" "$multi_response" "$DEF_SHA256" "$GDS_SHA256" "$SPEF_SHA256" "$generated_envelope"
expect_corners="$(IFS=,; echo "${ALL_CORNERS[*]}")"
if ! python3 "$SCRIPT_DIR/sta_envelope_check.py" "$generated_envelope" $ENVELOPE_GATE_FLAGS \
        --cross-check "$STA_BUILD_DIR/corners-trimmed" --expect-corners "$expect_corners"; then
    echo "error: the multi-corner envelope fails the item-5 gate -- refusing to record it" >&2
    exit 1
fi

if [[ "$MODE" == "update" ]]; then
    cp "$generated_envelope" "$COMMITTED_ENVELOPE"
    cp "$SPEF" "$COMMITTED_SPEF"
    echo "=== per-corner reports written under ${CORNERS_DIR} ==="
    echo "=== multi-corner envelope written to ${COMMITTED_ENVELOPE}, SPEF to ${COMMITTED_SPEF} ==="
    echo "    now add a record under measurements/timing-characterization/records/ (append-only),"
    echo "    refresh signoff/block-manifest.json's item-5 pin (signoff/verify-pins.sh names it) and commit"
    exit 0
fi

for pair in "$COMMITTED_ENVELOPE:$generated_envelope" "$COMMITTED_SPEF:$SPEF"; do
    committed_artifact="${pair%%:*}"
    generated_artifact="${pair#*:}"
    if [[ ! -f "$committed_artifact" ]]; then
        echo "error: no committed $committed_artifact -- run '$0 --update' to create it" >&2
        status=1
    elif ! diff -q "$committed_artifact" "$generated_artifact" >/dev/null; then
        diff -u "$committed_artifact" "$generated_artifact" | head -80 || true
        echo "error: regenerated $(basename "$generated_artifact") differs from the committed copy at $committed_artifact" >&2
        status=1
    fi
done

# Guard against a committed corner directory the sweep no longer produces.
UNEXPECTED="$(cd "$CORNERS_DIR" 2>/dev/null && ls -1d */ 2>/dev/null | sed 's#/$##' | sort | comm -13 <(printf '%s\n' "${ALL_CORNERS[@]}" | sort) - || true)"
if [[ -n "$UNEXPECTED" ]]; then
    echo "error: committed corner directories with no counterpart in this sweep:" >&2
    printf '       %s\n' $UNEXPECTED >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "       run '$0 --update' and commit the result (plus a new record under measurements/timing-characterization/records/)" >&2
    echo "       if the toolchain-version warning printed above fired, rule out toolchain drift (see flow/README.md's 'Toolchain versions' section) before assuming a design regression" >&2
    exit 1
fi

echo "=== committed timing evidence matches regenerated output (reproducible: ${#ALL_CORNERS[@]} corners x {LEF-only, SPEF}, the multi-corner item-5 envelope, and the SPEF) ==="
