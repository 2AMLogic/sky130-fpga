#!/usr/bin/env bash
#
# sim/sdf_port_interconnect/run.sh
#
# Minimal reproducer for issue #250: why `$sdf_annotate` rejects a subset of
# a real post-route SDF's `INTERCONNECT` entries, and exactly which subset.
#
# Context. Record measurements/timing-characterization/records/
# 20261017-sdf-sanitize-d811bcd.md Result 3 observed 28 of 179 `INTERCONNECT`
# entries rejected with `Could not find intermodpath!` /
# `Could not insert intermodpath!`, every one of them sourced from a
# top-level input port bit, and recorded that "the cause of the 28
# rejections was not isolated; it is not a name problem". This script
# isolates it on a hand-written fixture -- no OpenROAD, no `klt`, no
# place-and-route, no routed tile.
#
# The finding this script pins: the deciding variable is the FANOUT of the
# source net, not the source's spelling. On a bit-selected top-level port
# net with physical fanout N, Icarus 13.0 annotates exactly ONE destination
# -- the one belonging to the last-declared instance on that net -- and
# rejects the other N-1. Scalar port nets and instance-pin-sourced nets are
# unaffected at any fanout. See the record named in README.md.
#
# What this does NOT do: it does not change flow/sdf-resim.sh, does not
# regenerate any SDF, and is deliberately NOT part of ./sim/run.sh (that
# loop compiles RTL with `-g2012 -Wall` and no specify/interconnect flags,
# so it cannot run this fixture at all).
#
# Method, mirroring flow/sdf-resim.sh leg 2 exactly:
#   * the same compile flags            -g2012 -gspecify -ginterconnect -T typ
#   * the same two elaboration roots    -s <testbench> -s klt_sdf_annotate
#   * the same shim generator           flow/sdf_annotate_shim.py
#   * an ABSOLUTE SDF path, which that shim enforces (a relative path is one
#     `SDF WARNING` away from a silent zero-delay run)
#   * the same Icarus 13.0+ resolution  resolve_icarus13(), below
#
# It differs from flow/sdf-resim.sh in one deliberate way: the sky130A cell
# models are resolved to flow/tool_versions.sh's RECORDED_PDK_VERSION
# exactly, and the run fails loud if that revision is not installed. A
# measurement that silently used whichever PDK `klt pdk find` happened to
# resolve would not be reproducible, and on at least one host that is a
# different revision from the pinned one.
#
# Verdicts come from parsing `SDF ERROR` / `SDF WARNING` / `VPI error` lines
# out of the `vvp` transcript and mapping them onto each entry by SDF line
# number -- never from `vvp`'s exit code, which is 0 even when every
# annotation was skipped. Each verdict is then corroborated independently:
# the case SDF is rescaled to a large delay and the driving testbench's
# `EDGE` timestamps are diffed against an un-annotated baseline, so
# "applied" means an observed timing shift and "rejected" means a provably
# unchanged waveform -- not just a quiet or noisy transcript.
#
# Usage:
#   ./sim/sdf_port_interconnect/run.sh
#
# Environment:
#   ICARUS13_BIN_DIR   same override flow/sdf-resim.sh honours
#   PDK_ROOT           volare/ciel root holding the pinned sky130A revision
#
# Exit status: 0 when every case produced a verdict AND every verdict and
# rejected-entry count matches the expectation table below (so this doubles
# as a regression guard on the recorded result); non-zero on any toolchain
# failure or any divergence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/sim/build/sdf_port_interconnect"
SHIM="$REPO_ROOT/flow/sdf_annotate_shim.py"
CLASSIFY="$SCRIPT_DIR/classify_sdf_log.py"
PREDICT="$SCRIPT_DIR/predict_fanout_rejections.py"
DUT_V="$SCRIPT_DIR/port_interconnect_dut.v"
COMMITTED_SDF="$REPO_ROOT/measurements/timing-characterization/logic_tile_route.sdf"
SDF_CORNER="typ"

# The delay every committed case SDF carries, and the value the
# corroboration leg rescales it to. The rescaled value is large enough to be
# unmistakable at the testbench's 1ps precision and larger than every
# IOPATH delay in the pinned cell library (all 0:0:0 in sky130_fd_sc_hd.v).
CASE_DELAY="0.100:0.100:0.100"
PROBE_DELAY="3.000:3.000:3.000"

CASES=(
  # <case-sdf-basename>|<expected per-case verdict>|<expected rejected count>|<description>
  #
  # The expectation table IS the recorded result: run.sh asserts against it,
  # so this script is a regression guard on the record and not merely a
  # printer. Verdicts: APPLIED (no entry rejected), REJECTED (every entry
  # rejected), MIXED (some of each). The rejected count is exact.
  "fanout4_bitsel_first|REJECTED|1|bit-selected port net in[0], fanout 4, FIRST-declared destination u_a0.S0"
  "fanout4_bitsel_last|APPLIED|0|bit-selected port net in[0], fanout 4, LAST-declared destination u_a3.S0"
  "fanout4_bitsel_all|MIXED|3|all 4 entries on in[0]: only the last-declared destination is annotatable"
  "fanout2_bitsel_first|REJECTED|1|bit-selected port net in[1], fanout 2, first-declared destination u_b0.S0"
  "fanout2_bitsel_all|MIXED|1|both entries on in[1]: 1 of 2 annotatable"
  "fanout1_bitsel|APPLIED|0|bit-selected port net in[2], fanout 1 -- THE DISCRIMINATOR"
  "fanout1_bitsel_mux4_1|APPLIED|0|bit-selected port net in[4], fanout 1, on mux4_1"
  "fanout2_bitsel_nospecify|REJECTED|1|bit-selected port net in[3], fanout 2, destination has NO specify block"
  "fanout4_scalar_all|APPLIED|0|SCALAR port net clk, fanout 4, all 4 entries"
  "fanout4_instpin_all|APPLIED|0|instance-pin source u_a3.X, fanout 4, all 4 entries"
  "buffered_port_all|APPLIED|0|BUFFER REMEDY: u_buf.X at fanout 2, source is a cell output pin"
  "iopath_with_interconnect|APPLIED|0|an IOPATH entry alongside a fanout-1 INTERCONNECT entry"
  "committed_shape_miniature|MIXED|4|miniature of the committed SDF's affected population (4 of 15)"
)

TESTBENCHES=(
  "tb_port_interconnect_noop"
  "tb_port_interconnect_drive"
)

FAILURES=0

fail() {
    echo "DIVERGENCE: $*" >&2
    FAILURES=$((FAILURES + 1))
}

# -------------------------------------------------------------------- #
# Toolchain resolution.
# -------------------------------------------------------------------- #

# The same contract as flow/sdf-resim.sh:resolve_icarus13(): honour
# $ICARUS13_BIN_DIR, then /opt/iverilog-13/bin, then $PATH, and carry
# found/not-found entirely in the exit status (issue #43) -- an empty printed
# string is the legitimate "found on $PATH, no prefix needed" answer. A 12.x
# `iverilog` must NOT be accepted: it rejects `-ginterconnect` outright, and
# accepting it would turn this into a silent zero-delay run that measures
# nothing. `sed -n 1p` rather than `head -1` because `head` closes the pipe
# early, and a SIGPIPE'd `iverilog` under `set -o pipefail` aborts the run.
resolve_icarus13() {
    local candidate
    local -a candidates=()
    if [[ -n "${ICARUS13_BIN_DIR:-}" ]]; then
        candidates+=("$ICARUS13_BIN_DIR")
    fi
    candidates+=("/opt/iverilog-13/bin" "")
    for candidate in "${candidates[@]}"; do
        local iv="${candidate:+$candidate/}iverilog"
        if command -v "$iv" >/dev/null 2>&1; then
            local ver
            ver="$("$iv" -V 2>&1 | sed -n '1p' | grep -oE '[0-9]+' | sed -n '1p' || true)"
            if [[ -n "$ver" && "$ver" -ge 13 ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

if ! ICARUS13_DIR="$(resolve_icarus13)"; then
    echo "error: no Icarus Verilog 13.0+ build found (checked \$ICARUS13_BIN_DIR, /opt/iverilog-13/bin, \$PATH)" >&2
    echo "       this reproducer needs -ginterconnect, which 12.x does not have; a 12.x run would be" >&2
    echo "       silently zero-delay and would not measure what this script claims to measure" >&2
    if command -v iverilog >/dev/null 2>&1; then
        echo "       nearest candidate on \$PATH: $(iverilog -V 2>&1 | sed -n '1p')" >&2
    fi
    exit 1
fi
IVERILOG="${ICARUS13_DIR:+$ICARUS13_DIR/}iverilog"
VVP="${ICARUS13_DIR:+$ICARUS13_DIR/}vvp"
IVERILOG_VERSION="$("$IVERILOG" -V 2>&1 | sed -n '1p')"

# RECORDED_PDK_VERSION -- the single pinned PDK source flow/audit_evidence.py
# checks every record's `provenance.pdk.version` against. Sourcing this file
# defines variables and functions only; it runs no tool.
# shellcheck source=../../flow/tool_versions.sh
source "$REPO_ROOT/flow/tool_versions.sh"
PDK_SHA="${RECORDED_PDK_VERSION##* }"

CELL_VERILOG_DIR=""
for candidate in \
    "${PDK_ROOT:+$PDK_ROOT}"/*/sky130/versions/"$PDK_SHA"/sky130A/libs.ref/sky130_fd_sc_hd/verilog \
    "${PDK_ROOT:+$PDK_ROOT}"/sky130/versions/"$PDK_SHA"/sky130A/libs.ref/sky130_fd_sc_hd/verilog \
    "$HOME"/.volare/*/sky130/versions/"$PDK_SHA"/sky130A/libs.ref/sky130_fd_sc_hd/verilog \
    "$HOME"/.ciel/*/sky130/versions/"$PDK_SHA"/sky130A/libs.ref/sky130_fd_sc_hd/verilog; do
    if [[ -f "$candidate/sky130_fd_sc_hd.v" ]]; then
        CELL_VERILOG_DIR="$candidate"
        break
    fi
done
if [[ -z "$CELL_VERILOG_DIR" ]]; then
    echo "error: the pinned sky130A revision was not found." >&2
    echo "       flow/tool_versions.sh pins: $RECORDED_PDK_VERSION" >&2
    echo "       looked for .../versions/$PDK_SHA/sky130A/libs.ref/sky130_fd_sc_hd/verilog under" >&2
    echo "       \$PDK_ROOT, ~/.volare and ~/.ciel. Set PDK_ROOT to the root that holds it." >&2
    if command -v klt >/dev/null 2>&1; then
        echo "       (\`klt pdk find\` currently resolves:" \
             "$(klt pdk find --pdk sky130A --format json 2>/dev/null \
                | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null \
                || echo unknown)" \
             "-- this script will not substitute a different revision.)" >&2
    fi
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=============================================================="
echo "SDF INTERCONNECT fanout reproducer (issue #250)"
echo "=============================================================="
echo "iverilog         : $IVERILOG_VERSION ($IVERILOG)"
echo "pinned PDK       : $RECORDED_PDK_VERSION"
echo "cell models      : $CELL_VERILOG_DIR"
echo "compile flags    : -g2012 -gspecify -ginterconnect -T $SDF_CORNER"
echo "elaboration roots: -s <testbench> -s klt_sdf_annotate"
echo

# -------------------------------------------------------------------- #
# Helpers.
# -------------------------------------------------------------------- #

# compile_and_run <tb> <abs-sdf-path> <tag>  ->  $BUILD_DIR/<tag>.out
compile_and_run() {
    local tb="$1" sdf="$2" tag="$3"
    local shim_v="$BUILD_DIR/${tag}_shim.v"
    local vvp_out="$BUILD_DIR/${tag}.vvp"

    python3 -I "$SHIM" "$shim_v" "$sdf" "${tb}.dut"

    if ! "$IVERILOG" -g2012 -gspecify -ginterconnect -T "$SDF_CORNER" \
        -s "$tb" -s klt_sdf_annotate \
        -o "$vvp_out" \
        "$SCRIPT_DIR/${tb}.v" \
        "$DUT_V" \
        "$CELL_VERILOG_DIR/primitives.v" \
        "$CELL_VERILOG_DIR/sky130_fd_sc_hd.v" \
        "$shim_v" \
        2>"$BUILD_DIR/${tag}_build.err"; then
        echo "error: compile failed for $tag (see $BUILD_DIR/${tag}_build.err)" >&2
        return 1
    fi
    # vvp's exit status is deliberately IGNORED for the verdict: it is 0 even
    # when every annotation was skipped. The transcript is the evidence.
    "$VVP" "$vvp_out" >"$BUILD_DIR/${tag}.out" 2>&1 || true
    return 0
}

classify() { python3 -I "$CLASSIFY" --sdf "$1" --log "$2"; }

# -------------------------------------------------------------------- #
# Leg A: per-entry applied/rejected verdict, under BOTH testbenches.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg A: per-entry verdicts"
echo "=============================================================="
for row in "${CASES[@]}"; do
    IFS='|' read -r case_name expected expected_rejects description <<<"$row"
    case_sdf="$SCRIPT_DIR/${case_name}.sdf"
    if [[ ! -f "$case_sdf" ]]; then
        echo "error: missing case SDF $case_sdf" >&2
        exit 1
    fi

    echo "--------------------------------------------------------------"
    echo "CASE $case_name"
    echo "  $description"
    echo "  expected: $expected ($expected_rejects rejected)"

    for tb in "${TESTBENCHES[@]}"; do
        tag="${case_name}__${tb}"
        compile_and_run "$tb" "$case_sdf" "$tag" || { FAILURES=$((FAILURES + 1)); continue; }
        echo "  [$tb]"
        classify "$case_sdf" "$BUILD_DIR/${tag}.out" | sed 's/^/    /'
    done
    echo
done

# -------------------------------------------------------------------- #
# Leg B: corroborate every verdict with the waveform. An entry Icarus
# printed no error for, but whose delay never moves an edge, is NOT a
# working annotation; an entry it rejected must leave the waveform
# bit-identical to the un-annotated baseline. That distinction is the whole
# point of this leg, and it is what makes "applied" a measurement rather
# than an inference from a quiet transcript.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg B: delay corroboration (case delay rescaled to $PROBE_DELAY)"
echo "=============================================================="

# Un-annotated baseline: a valid SDF with an empty ABSOLUTE block, so the
# same two-root compile runs with nothing to annotate.
BASELINE_SDF="$BUILD_DIR/baseline_empty.sdf"
cat >"$BASELINE_SDF" <<'EOF'
(DELAYFILE
 (SDFVERSION "3.0")
 (DESIGN "port_interconnect_dut")
 (DATE "generated baseline, no entries")
 (VENDOR "sky130-fpga")
 (PROGRAM "sim/sdf_port_interconnect/run.sh")
 (VERSION "1.0")
 (DIVIDER .)
 (TIMESCALE 1ns)
 (CELL
  (CELLTYPE "port_interconnect_dut")
  (INSTANCE)
  (DELAY
   (ABSOLUTE
   )
  )
 )
)
EOF

compile_and_run "tb_port_interconnect_drive" "$BASELINE_SDF" "baseline" \
    || { echo "error: baseline run failed" >&2; exit 1; }
grep '^EDGE ' "$BUILD_DIR/baseline.out" >"$BUILD_DIR/baseline.edges" || true
if [[ ! -s "$BUILD_DIR/baseline.edges" ]]; then
    echo "error: baseline produced no EDGE lines -- the probe is not measuring anything" >&2
    exit 1
fi

for row in "${CASES[@]}"; do
    IFS='|' read -r case_name expected expected_rejects description <<<"$row"
    probe_sdf="$BUILD_DIR/${case_name}_probe.sdf"
    sed "s/${CASE_DELAY//./\\.}/$PROBE_DELAY/g" "$SCRIPT_DIR/${case_name}.sdf" >"$probe_sdf"
    tag="${case_name}__probe"
    compile_and_run "tb_port_interconnect_drive" "$probe_sdf" "$tag" \
        || { FAILURES=$((FAILURES + 1)); continue; }
    grep '^EDGE ' "$BUILD_DIR/${tag}.out" >"$BUILD_DIR/${tag}.edges" || true

    if diff -q "$BUILD_DIR/baseline.edges" "$BUILD_DIR/${tag}.edges" >/dev/null 2>&1; then
        shift_seen="no"
    else
        shift_seen="yes"
    fi
    printf '%-28s delay observed: %s   (expected: %s)\n' \
        "$case_name" "$shift_seen" \
        "$([[ "$expected" == "REJECTED" ]] && echo no || echo yes)"
    if [[ "$shift_seen" == "yes" ]]; then
        diff "$BUILD_DIR/baseline.edges" "$BUILD_DIR/${tag}.edges" | sed 's/^/    /' || true
    fi

    case "$expected" in
        REJECTED)
            [[ "$shift_seen" == "no" ]] \
                || fail "$case_name: Icarus rejected every entry, yet an edge moved"
            ;;
        APPLIED|MIXED)
            [[ "$shift_seen" == "yes" ]] \
                || fail "$case_name: no SDF error was reported, yet no edge moved -- the annotation did not take effect"
            ;;
    esac
done
echo

# -------------------------------------------------------------------- #
# Leg C: SDF entry order does not decide which entry survives. Built by
# reversing the committed fanout4_bitsel_all.sdf entry order, so the SAME
# four entries are presented back-to-front.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg C: SDF entry order independence"
echo "=============================================================="
REV_SDF="$BUILD_DIR/fanout4_bitsel_all_reversed.sdf"
python3 -I - "$SCRIPT_DIR/fanout4_bitsel_all.sdf" "$REV_SDF" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).readlines()
body = [i for i, l in enumerate(lines) if "(INTERCONNECT" in l]
first, last = body[0], body[-1]
reordered = lines[:first] + list(reversed(lines[first:last + 1])) + lines[last + 1:]
open(dst, "w").writelines(reordered)
PYEOF
compile_and_run "tb_port_interconnect_drive" "$REV_SDF" "reversed" \
    || { echo "error: reversed-order run failed" >&2; exit 1; }
echo "entries, reversed file order:"
grep -n '(INTERCONNECT' "$REV_SDF" | sed 's/^/    /'
echo "verdicts:"
classify "$REV_SDF" "$BUILD_DIR/reversed.out" | sed 's/^/    /'
FWD_SURVIVOR="$(classify "$SCRIPT_DIR/fanout4_bitsel_all.sdf" \
    "$BUILD_DIR/fanout4_bitsel_all__tb_port_interconnect_drive.out" \
    | awk '$1 == "APPLIED" { print $NF }')"
REV_SURVIVOR="$(classify "$REV_SDF" "$BUILD_DIR/reversed.out" \
    | awk '$1 == "APPLIED" { print $NF }')"
echo "survivor, forward order : ${FWD_SURVIVOR:-<none>}"
echo "survivor, reversed order: ${REV_SURVIVOR:-<none>}"
if [[ -n "$FWD_SURVIVOR" && "$FWD_SURVIVOR" == "$REV_SURVIVOR" ]]; then
    echo "=> the surviving entry is the same one in both orders: SDF order is not the variable"
else
    fail "the surviving entry changed with SDF order (forward '$FWD_SURVIVOR' vs reversed '$REV_SURVIVOR')"
fi
echo

# -------------------------------------------------------------------- #
# Leg D: the relative-SDF-path guard. flow/sdf_annotate_shim.py must refuse
# a relative path rather than emit a shim that silently zero-delays.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg D: relative SDF path is refused"
echo "=============================================================="
if python3 -I "$SHIM" "$BUILD_DIR/relpath_shim.v" \
        "sim/sdf_port_interconnect/fanout1_bitsel.sdf" \
        "tb_port_interconnect_drive.dut" >/dev/null 2>"$BUILD_DIR/relpath.err"; then
    fail "a relative SDF path was accepted"
else
    echo "relative path refused, as required:"
    sed -n '$p' "$BUILD_DIR/relpath.err" | sed 's/^/    /'
fi
echo

# -------------------------------------------------------------------- #
# Leg E: verdict-table assertion.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg E: verdicts and rejected-entry counts match the record"
echo "=============================================================="
for row in "${CASES[@]}"; do
    IFS='|' read -r case_name expected expected_rejects description <<<"$row"
    for tb in "${TESTBENCHES[@]}"; do
        log="$BUILD_DIR/${case_name}__${tb}.out"
        got="$(python3 -I "$CLASSIFY" --sdf "$SCRIPT_DIR/${case_name}.sdf" --log "$log" --verdict-only)"
        got_rejects="$(classify "$SCRIPT_DIR/${case_name}.sdf" "$log" | grep -c '^REJECTED' || true)"
        if [[ "$got" != "$expected" || "$got_rejects" != "$expected_rejects" ]]; then
            fail "$case_name / $tb -> $got ($got_rejects rejected), expected $expected ($expected_rejects rejected)"
        else
            printf '%-28s %-30s %-8s %s rejected\n' "$case_name" "$tb" "$got" "$got_rejects"
        fi
    done
done
echo

# -------------------------------------------------------------------- #
# Leg F: testbench sensitivity (issue #250 AC 5, first question). If the
# cause were a race against VPI callback scheduling once time advances past
# 0, a bench that never drives the DUT and finishes at t=1 should differ
# from one that drives every input across 80 ns.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg F: testbench sensitivity (no-op vs driving)"
echo "=============================================================="
for row in "${CASES[@]}"; do
    IFS='|' read -r case_name expected expected_rejects description <<<"$row"
    a="$(classify "$SCRIPT_DIR/${case_name}.sdf" "$BUILD_DIR/${case_name}__tb_port_interconnect_noop.out")"
    b="$(classify "$SCRIPT_DIR/${case_name}.sdf" "$BUILD_DIR/${case_name}__tb_port_interconnect_drive.out")"
    if [[ "$a" == "$b" ]]; then
        printf '%-28s identical under both testbenches\n' "$case_name"
    else
        printf '%-28s DIFFERS between testbenches:\n' "$case_name"
        diff <(echo "$a") <(echo "$b") | sed 's/^/    /' || true
        fail "$case_name: verdicts depend on the testbench"
    fi
done
echo

# -------------------------------------------------------------------- #
# Leg G: apply the model to the committed logic_tile SDF and check that it
# predicts record 20261017-sdf-sanitize-d811bcd's observed 28 rejections and
# their sink-pin distribution. Pure parsing -- no simulation, no PDK, no
# place-and-route -- and the only leg that connects this fixture to the
# artifact the claim is about.
# -------------------------------------------------------------------- #
echo "=============================================================="
echo "Leg G: the model's prediction for the committed SDF"
echo "=============================================================="
if [[ -f "$COMMITTED_SDF" ]]; then
    python3 -I "$PREDICT" --sdf "$COMMITTED_SDF" --expect-rejections 28 \
        --expect-sinks 'S0=12,S1=12,A=4' || FAILURES=$((FAILURES + 1))
else
    fail "committed SDF $COMMITTED_SDF is missing"
fi
echo

echo "=============================================================="
if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS: sdf_port_interconnect -- every case produced a verdict, every"
    echo "      verdict and count matches the record, and the model predicts the"
    echo "      committed SDF's 28 rejections exactly."
    echo "      iverilog: $IVERILOG_VERSION"
    echo "      PDK:      $RECORDED_PDK_VERSION"
    exit 0
fi
echo "FAIL: sdf_port_interconnect -- $FAILURES divergence(s) from the recorded result." >&2
echo "      Scratch transcripts: $BUILD_DIR" >&2
exit 1
