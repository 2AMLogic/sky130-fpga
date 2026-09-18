#!/usr/bin/env bash
# flow/sdf-resim.sh
#
# T1 checklist item 7 (Epic #4, issue #29): post-layout, PEX-based
# re-verification with a real SDF back-annotation. PR #22 (issue #20)
# already landed the extraction -> SPEF path (`klt extract --parasitics
# --spef`) and the 18-corner `klt sta` sweep of the routed tile
# (measurements/timing-characterization/) -- this script is the remaining
# step: derive a real, characterized SDF from that same routed geometry
# and re-run sim/tb_logic_tile.v gate-level against it.
#
# Two legs, run every invocation:
#
#   1. SDF generation + zero-delay gate-level re-simulation (works today).
#      `klt place-and-route --post_route_spef --post_route_sdf` re-runs the
#      same synthesize + place-and-route request flow/layout.sh uses,
#      opting in to writing a real IEEE-1497 SDF from that run's own
#      post-route `read_spef` OpenSTA session (`spef_sta.sdf_path`, issue
#      #1002 in klayout-tools) -- the *natural* producer of the file this
#      item needs, not a synthetic stand-in. The regenerated DEF is
#      diffed byte-for-byte against the committed layout/logic_tile.def
#      first: only a run that reproduces the *exact* geometry PR #22
#      already characterized is trustworthy evidence for this item.
#      sim/tb_logic_tile.v then runs UNMODIFIED, gate-level, against the
#      as-built sky130_fd_sc_hd netlist from that same run -- zero delay,
#      but a real functional check that the mapped-and-routed tile still
#      passes its own tile-level testbench.
#
#   2. The SDF-annotated re-run (currently blocked, cited, not faked).
#      Applying the real SDF from leg 1 via Icarus's `$sdf_annotate` --
#      the same mechanism `klt functional-verification`'s `options.sdf`
#      uses internally (flow/sdf_annotate_shim.py mirrors its generated
#      shim byte-for-byte in spirit, since this design's testbenches are
#      plain Verilog, not cocotb, and so need no `options.sdf` at all --
#      see "Why not `klt functional-verification` directly" below) --
#      deterministically crashes `vvp` (`NULL handle passed to vpi_scan`,
#      SIGABRT) on ANY `INTERCONNECT` entry whose escaped identifier
#      contains a literal `.` or `[`/`]`, which is exactly what this
#      design's `generate`-block RTL (design/rtl/logic_tile.v's
#      `g_slice[N].u_slice`) produces once flattened. Filed generically
#      (no design-specific detail) against klayout-tools as
#      https://github.com/2AMLogic/klayout-tools/issues/1890, confirmed
#      reproducing identically through `klt functional-verification`'s own
#      `options.sdf` CLI path, not just this script's hand-wired
#      `$sdf_annotate`. This script re-attempts leg 2 every run and treats
#      *reproducing that exact, cited crash* as the expected, checked-in
#      outcome (exit 0) -- an unexpected result (a clean pass, a different
#      failure, or no crash at all) means the upstream bug's status
#      changed and this repo's evidence needs a fresh look, so that case
#      is a script failure (exit 1), not a silent "still broken, move on".
#
# Why not `klt functional-verification` directly for leg 2: that verb's
# `options.sdf` is real and independently confirmed to hit the identical
# upstream crash (see the filed issue) -- so going through it would not
# avoid the blocker. It also requires a cocotb Python `testbench.module`,
# which sim/tb_logic_tile.v is not (it is its own self-checking Verilog
# elaboration root, predating and out of scope to convert for this issue).
# flow/sdf_annotate_shim.py generates the same "second elaboration root
# carrying $sdf_annotate" idiom that verb's own
# `_write_sdf_annotate_shim` uses, so this script exercises the identical
# Icarus mechanism `options.sdf` would, just without requiring a cocotb
# port of the existing testbench.
#
# sim/tb_lut4_slice.v is deliberately NOT re-run here: `lut4_slice` has no
# independently placed-and-routed layout of its own (only as a
# `g_slice[N].u_slice` sub-instance flattened inside the routed
# `logic_tile`, per design/README.md) -- generating one would be a new
# physical-design artifact, out of this issue's scope (see
# spec/framework-gaps.md G4). See sim/README.md for the full accounting.
#
# Usage:
#   ./flow/sdf-resim.sh            # regenerate + check against the
#                                   # committed SDF and recorded outcome.
#                                   # Exit 0 iff the DEF reproduces PR #22's
#                                   # characterized geometry, the committed
#                                   # SDF matches, the zero-delay gate-level
#                                   # check passes, AND the SDF-annotated
#                                   # attempt reproduces the exact cited
#                                   # upstream crash.
#   ./flow/sdf-resim.sh --update  # same, but overwrite the committed SDF.
#                                   # Run this (and commit the result, plus
#                                   # a new record under
#                                   # measurements/timing-characterization/records/)
#                                   # after an intentional layout change.
#
# Requires `klt`, `openroad`, a native `yosys` build, a resolvable sky130A
# PDK, and an Icarus Verilog 13.0+ build for the gate-level legs (the
# `-ginterconnect` flag `options.sdf`'s own documented minimum -- see
# resolve_icarus13() below for how this script finds one; the distro
# `iverilog` package on many systems is still 12.x). Scratch output lands
# in flow/build/sdf-resim/ (gitignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTL_DIR="$REPO_ROOT/design/rtl"
SIM_DIR="$REPO_ROOT/sim"
MEAS_DIR="$REPO_ROOT/measurements/timing-characterization"
BUILD_DIR="$SCRIPT_DIR/build/sdf-resim"
TOP_MODULE="logic_tile"
TB_NAME="tb_logic_tile"
CLOCK_PERIOD_NS=20
CLOCK_PORT="clk"
SDF_CORNER="typ"
SDF_NAME="logic_tile_route.sdf"
COMMITTED_SDF="$MEAS_DIR/${SDF_NAME}"

# The exact crash klayout-tools#1890 documents. Grepped against vvp's
# stderr to confirm leg 2 reproduces the SAME cited blocker, not a new one.
KNOWN_CRASH_SIGNATURE="NULL handle passed to vpi_scan"
GAP_ISSUE_URL="https://github.com/2AMLogic/klayout-tools/issues/1890"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    "") MODE="check" ;;
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

# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
print_tool_version_banner

# Same native-yosys-over-YoWASP preference as flow/layout.sh -- see that
# script's own comment / klayout-tools#1368.
if [[ -x /usr/bin/yosys ]]; then
    PATH="/usr/bin:$PATH"
fi
if ! command -v yosys >/dev/null 2>&1; then
    echo "error: yosys not found on PATH" >&2
    exit 1
fi

if ! klt pdk find --pdk sky130A >/dev/null 2>&1; then
    echo "error: no sky130A PDK install resolvable (klt pdk find --pdk sky130A failed)" >&2
    exit 1
fi

# Resolve an Icarus Verilog 13.0+ toolchain for the gate-level legs.
# `options.sdf`'s own documented minimum (klayout-tools docs/cli/
# functional-verification.md, "Icarus 13.0 or newer") is `-ginterconnect`,
# which a 12.x `iverilog` (the Ubuntu noble distro package, for instance)
# rejects outright with exit 255 -- so this resolves a specific 13+ build
# rather than trusting whatever `iverilog`/`vvp` happen to be first on
# $PATH (sim/run.sh's RTL-level regression has no such requirement and
# uses the distro default). Override with $ICARUS13_BIN_DIR if your 13+
# build lives somewhere other than the two locations checked here.
resolve_icarus13() {
    local candidate
    for candidate in "${ICARUS13_BIN_DIR:-}" "/opt/iverilog-13/bin" ""; do
        local iv="${candidate:+$candidate/}iverilog"
        if command -v "$iv" >/dev/null 2>&1; then
            local ver
            ver="$("$iv" -V 2>&1 | head -1 | grep -oE '[0-9]+' | head -1 || true)"
            if [[ -n "$ver" && "$ver" -ge 13 ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

ICARUS13_DIR="$(resolve_icarus13 || true)"
if [[ -z "$ICARUS13_DIR" ]]; then
    echo "error: no Icarus Verilog 13.0+ build found (checked \$ICARUS13_BIN_DIR, /opt/iverilog-13/bin, \$PATH)" >&2
    echo "       options.sdf-equivalent gate-level runs require -ginterconnect, which needs Icarus 13+" >&2
    exit 1
fi
IVERILOG="${ICARUS13_DIR:+$ICARUS13_DIR/}iverilog"
VVP="${ICARUS13_DIR:+$ICARUS13_DIR/}vvp"
echo "=== using $("$IVERILOG" -V 2>&1 | head -1) ($IVERILOG) ==="

mkdir -p "$BUILD_DIR" "$MEAS_DIR"

LIBS_REF="$(klt pdk find --pdk sky130A --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assets", {}).get("libs_ref", ""))' 2>/dev/null || true)"
CELL_VERILOG_DIR=""
for candidate in \
    "${LIBS_REF:+$LIBS_REF/sky130_fd_sc_hd/verilog}" \
    "$HOME/.volare/sky130A/libs.ref/sky130_fd_sc_hd/verilog"; do
    if [[ -n "$candidate" && -f "$candidate/sky130_fd_sc_hd.v" ]]; then
        CELL_VERILOG_DIR="$candidate"
        break
    fi
done
if [[ -z "$CELL_VERILOG_DIR" ]]; then
    echo "error: could not resolve sky130_fd_sc_hd behavioral Verilog cell models" >&2
    exit 1
fi

# ---------------------------------------------------------------------- #
# Leg 1a: synthesize + place-and-route with post_route_spef/post_route_sdf.
# Same request shape as flow/layout.sh's SYNTH_REQUEST/PAR_REQUEST -- this
# is the *same design run through the same flow*, opting in to two extra
# fields, not a different characterization.
# ---------------------------------------------------------------------- #

SYNTH_REQUEST="$BUILD_DIR/synth_request.json"
PAR_REQUEST="$BUILD_DIR/par_request.json"
SYNTH_RESPONSE="$BUILD_DIR/synth_response.json"
PAR_RESPONSE="$BUILD_DIR/par_response.json"
SYNTH_NETLIST="$BUILD_DIR/.klt/synthesize/${TOP_MODULE}_synth.v"
ROUTED_NETLIST="$BUILD_DIR/.klt/place-and-route/${TOP_MODULE}.v"
GENERATED_DEF="$BUILD_DIR/.klt/place-and-route/${TOP_MODULE}.def"
COMMITTED_DEF="$REPO_ROOT/layout/${TOP_MODULE}.def"

cat >"$SYNTH_REQUEST" <<EOF
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
if [[ ! -s "$SYNTH_NETLIST" ]]; then
    echo "error: klt synthesize did not produce a netlist at $SYNTH_NETLIST" >&2
    exit 1
fi

# Same request shape as flow/layout.sh -- single-sourced in
# flow/par_request.py (issue #44) so the two scripts cannot silently
# diverge on the fields they share. This is the *same design run through
# the same flow*, opting in to the two extra post_route_spef/
# post_route_sdf fields via CLI flags rather than a second hand-written
# heredoc.
python3 "$SCRIPT_DIR/par_request.py" \
    "$SYNTH_NETLIST" "$PAR_REQUEST" \
    --hdl-toplevel "$TOP_MODULE" \
    --clock-port "$CLOCK_PORT" \
    --clock-period-ns "$CLOCK_PERIOD_NS" \
    --post-route-spef \
    --post-route-sdf

echo "=== klt place-and-route ${TOP_MODULE} (sky130_fd_sc_hd, OpenROAD, +post_route_sdf) ==="
if ! klt place-and-route "$PAR_REQUEST" --pdk sky130A --format json | tee "$PAR_RESPONSE"; then
    echo "error: klt place-and-route failed (see $PAR_RESPONSE)" >&2
    exit 1
fi

STAGE_REACHED="$(python3 -c "import json; print(json.load(open('$PAR_RESPONSE')).get('stage_reached'))")"
if [[ "$STAGE_REACHED" != "route" ]]; then
    echo "error: klt place-and-route did not reach the 'route' stage (got: $STAGE_REACHED)" >&2
    exit 1
fi

if [[ ! -s "$ROUTED_NETLIST" ]]; then
    echo "error: klt place-and-route did not produce a routed netlist at $ROUTED_NETLIST" >&2
    exit 1
fi
if [[ ! -s "$GENERATED_DEF" ]]; then
    echo "error: klt place-and-route did not produce a routed DEF at $GENERATED_DEF" >&2
    exit 1
fi

# The load-bearing check: this run's geometry must be the SAME geometry PR
# #22's 18-corner sweep already characterized. The routed DEF is byte-
# reproducible across runs of the identical, seeded request (flow/
# layout.sh's own header note; verified live for this script), so a plain
# diff -- not a canonicalized one -- is the right check.
if ! diff -q "$GENERATED_DEF" "$COMMITTED_DEF" >/dev/null 2>&1; then
    echo "error: regenerated DEF differs from the committed layout/${TOP_MODULE}.def" >&2
    echo "       this run's SDF would not describe the geometry PR #22 already characterized" >&2
    echo "       run ./flow/layout.sh first to confirm reproducibility, or rule out toolchain drift (flow/README.md)" >&2
    exit 1
fi
echo "=== regenerated DEF matches committed layout/${TOP_MODULE}.def (same characterized geometry) ==="

SDF_PATH="$(python3 -c "import json; print(json.load(open('$PAR_RESPONSE')).get('spef_sta', {}).get('sdf_path') or '')")"
ANNOTATION_COMPLETE="$(python3 -c "import json; print(json.load(open('$PAR_RESPONSE')).get('spef_sta', {}).get('annotation_complete'))")"
if [[ -z "$SDF_PATH" || ! -s "$SDF_PATH" ]]; then
    echo "error: klt place-and-route did not write an SDF (spef_sta.sdf_path empty or missing)" >&2
    exit 1
fi
if [[ "$ANNOTATION_COMPLETE" != "True" ]]; then
    echo "error: spef_sta.annotation_complete was not true -- SDF was written from an incomplete SPEF annotation" >&2
    exit 1
fi
echo "=== real post-route SDF written: $SDF_PATH (spef_sta.annotation_complete: true) ==="

# ---------------------------------------------------------------------- #
# Canonicalize + check/update the committed SDF.
# ---------------------------------------------------------------------- #

GENERATED_SDF_CANON="$BUILD_DIR/${SDF_NAME}"
python3 "$SCRIPT_DIR/sdf_canonicalize.py" "$SDF_PATH" "$GENERATED_SDF_CANON"

if [[ "$MODE" == "update" ]]; then
    cp "$GENERATED_SDF_CANON" "$COMMITTED_SDF"
    echo "=== updated $COMMITTED_SDF ==="
elif [[ ! -f "$COMMITTED_SDF" ]]; then
    echo "error: $COMMITTED_SDF does not exist -- run with --update to create it" >&2
    exit 1
elif ! diff -q "$GENERATED_SDF_CANON" "$COMMITTED_SDF" >/dev/null 2>&1; then
    echo "error: regenerated SDF differs from the committed $COMMITTED_SDF" >&2
    echo "       run './flow/sdf-resim.sh --update' and commit the result if this is intentional" >&2
    diff "$GENERATED_SDF_CANON" "$COMMITTED_SDF" | head -20 >&2 || true
    exit 1
fi
echo "=== committed SDF matches regenerated output (reproducible) ==="

# ---------------------------------------------------------------------- #
# Leg 1b: zero-delay gate-level re-simulation of sim/tb_logic_tile.v,
# UNMODIFIED, against the as-built netlist from the same run.
# ---------------------------------------------------------------------- #

ZERO_DELAY_VVP="$BUILD_DIR/${TB_NAME}_zero_delay.vvp"
ZERO_DELAY_LOG="$BUILD_DIR/${TB_NAME}_zero_delay.log"

echo "=== compiling ${TB_NAME} gate-level (zero delay) ==="
if ! "$IVERILOG" -g2012 -gspecify -ginterconnect -T "$SDF_CORNER" \
    -s "$TB_NAME" \
    -o "$ZERO_DELAY_VVP" \
    "$SIM_DIR/${TB_NAME}.v" \
    "$ROUTED_NETLIST" \
    "$CELL_VERILOG_DIR/primitives.v" \
    "$CELL_VERILOG_DIR/sky130_fd_sc_hd.v" \
    2>"$BUILD_DIR/${TB_NAME}_zero_delay_build.log"; then
    echo "error: gate-level compile failed for ${TB_NAME} (see $BUILD_DIR/${TB_NAME}_zero_delay_build.log)" >&2
    exit 1
fi

echo "=== running ${TB_NAME} gate-level (zero delay) ==="
if ! "$VVP" "$ZERO_DELAY_VVP" | tee "$ZERO_DELAY_LOG"; then
    echo "error: gate-level simulation run failed for ${TB_NAME}" >&2
    exit 1
fi
if ! grep -q "^PASS: ${TB_NAME}" "$ZERO_DELAY_LOG"; then
    echo "error: ${TB_NAME} did not report PASS at gate level, zero delay (see $ZERO_DELAY_LOG)" >&2
    exit 1
fi
echo "=== ${TB_NAME} PASSES gate-level, zero delay, against the as-built sky130_fd_sc_hd netlist ==="

# ---------------------------------------------------------------------- #
# Leg 2: the SDF-annotated attempt. Expected to reproduce the exact,
# cited upstream crash (klayout-tools#1890) -- see this script's header.
# ---------------------------------------------------------------------- #

SDF_SHIM="$BUILD_DIR/klt_sdf_annotate.v"
python3 "$SCRIPT_DIR/sdf_annotate_shim.py" "$SDF_SHIM" "$COMMITTED_SDF" "${TB_NAME}.dut"

SDF_ANNOTATED_VVP="$BUILD_DIR/${TB_NAME}_sdf_annotated.vvp"
SDF_ANNOTATED_LOG="$BUILD_DIR/${TB_NAME}_sdf_annotated.log"

echo "=== compiling ${TB_NAME} gate-level (SDF-annotated, $SDF_CORNER corner) ==="
if ! "$IVERILOG" -g2012 -gspecify -ginterconnect -T "$SDF_CORNER" \
    -s "$TB_NAME" -s klt_sdf_annotate \
    -o "$SDF_ANNOTATED_VVP" \
    "$SIM_DIR/${TB_NAME}.v" \
    "$ROUTED_NETLIST" \
    "$CELL_VERILOG_DIR/primitives.v" \
    "$CELL_VERILOG_DIR/sky130_fd_sc_hd.v" \
    "$SDF_SHIM" \
    2>"$BUILD_DIR/${TB_NAME}_sdf_annotated_build.log"; then
    echo "error: gate-level+SDF compile failed for ${TB_NAME} (see $BUILD_DIR/${TB_NAME}_sdf_annotated_build.log)" >&2
    exit 1
fi

echo "=== running ${TB_NAME} gate-level (SDF-annotated) -- expected to crash, see klayout-tools#1890 ==="
set +e
"$VVP" "$SDF_ANNOTATED_VVP" >"$SDF_ANNOTATED_LOG" 2>&1
SDF_RUN_EXIT=$?
set -e

if grep -q "$KNOWN_CRASH_SIGNATURE" "$SDF_ANNOTATED_LOG"; then
    echo "=== SDF-annotated leg reproduces the cited, known upstream blocker (exit $SDF_RUN_EXIT) ==="
    echo "    $KNOWN_CRASH_SIGNATURE -- see $GAP_ISSUE_URL"
    echo "    tail of transcript:"
    tail -5 "$SDF_ANNOTATED_LOG" | sed 's/^/    /'
else
    echo "error: SDF-annotated leg did NOT reproduce the expected, cited crash (exit $SDF_RUN_EXIT)" >&2
    echo "       this means klayout-tools#1890's status changed (fixed, or a different failure) --" >&2
    echo "       re-characterize this evidence rather than trusting a changed, uninvestigated result" >&2
    echo "       transcript: $SDF_ANNOTATED_LOG" >&2
    tail -20 "$SDF_ANNOTATED_LOG" >&2 || true
    exit 1
fi

echo "=== flow/sdf-resim.sh: all legs completed with their expected, evidenced outcome ==="
