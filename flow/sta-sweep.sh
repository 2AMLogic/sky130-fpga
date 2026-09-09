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
# Usage:
#   ./flow/sta-sweep.sh            # extract parasitics, sweep every corner,
#                                   # and diff the trimmed per-corner reports
#                                   # against the committed copies under
#                                   # measurements/timing-characterization/.
#                                   # Exit 0 iff every corner ran, every SPEF
#                                   # run annotated completely, and nothing
#                                   # drifted.
#   ./flow/sta-sweep.sh --update   # same, but overwrite the committed
#                                   # per-corner reports. Run this (and
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
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
STA_BUILD_DIR="$BUILD_DIR/sta"
CORNERS_DIR="$REPO_ROOT/measurements/timing-characterization/corners"
TOP_MODULE="logic_tile"
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

# Same rationale as flow/lvs.sh's own copy of this block: some local
# `openroad` installs are thin Docker wrappers that only mount $PDK_ROOT
# into the container when that variable is set in the invoking shell, even
# though `klt pdk find` resolves the PDK fine without it.
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

UNESCAPED_DEF="$STA_BUILD_DIR/${TOP_MODULE}.unescaped.def"
SANITIZED_DEF="$STA_BUILD_DIR/${TOP_MODULE}.sanitized.def"
echo "=== rewriting escaped identifiers (see flow/sta_sanitize_names.py) ==="
python3 "$SCRIPT_DIR/sta_sanitize_names.py" def-unescape "$COMMITTED_DEF" "$UNESCAPED_DEF"
python3 "$SCRIPT_DIR/sta_sanitize_names.py" def-sanitize "$COMMITTED_DEF" "$SANITIZED_DEF"

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
    --def-net-names --def-net-connections "$UNESCAPED_DEF" \
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
  "constraints": { "clock_port": "${CLOCK_PORT}", "clock_period_ns": ${CLOCK_PERIOD_NS} }
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
    python3 "$SCRIPT_DIR/sta_report_trim.py" "$lef_only_response" "$DEF_SHA256" "-" "$generated_lef_only"
    python3 "$SCRIPT_DIR/sta_report_trim.py" "$spef_response" "$DEF_SHA256" "$SPEF_SHA256" "$generated_spef"

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

if [[ "$MODE" == "update" ]]; then
    echo "=== per-corner reports written under ${CORNERS_DIR} ==="
    echo "    now add a record under measurements/timing-characterization/records/ (append-only) and commit both"
    exit 0
fi

# Guard against a committed corner directory the sweep no longer produces.
UNEXPECTED="$(cd "$CORNERS_DIR" 2>/dev/null && ls -1d */ 2>/dev/null | sed 's#/$##' | sort | comm -13 <(printf '%s\n' "${ALL_CORNERS[@]}" | sort) - || true)"
if [[ -n "$UNEXPECTED" ]]; then
    echo "error: committed corner directories with no counterpart in this sweep:" >&2
    printf '       %s\n' $UNEXPECTED >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "       run '$0 --update' and commit the result (plus a new record under measurements/timing-characterization/records/)" >&2
    exit 1
fi

echo "=== committed per-corner timing reports match regenerated output (reproducible, ${#ALL_CORNERS[@]} corners x {LEF-only, SPEF}) ==="
