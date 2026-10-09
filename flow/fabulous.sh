#!/usr/bin/env bash
# flow/fabulous.sh -- run the pinned FABulous generator on design/fabulous/.
#
# Spec gap G1 (spec/framework-gaps.md). Builds a throwaway venv under
# flow/build/ (never a host-wide install), installs the pinned FABulous
# release, copies design/fabulous/ to a scratch dir so no generated file lands
# in the source tree, runs `load_fabric; run_FABulous_fabric`, then
#   * writes the generator log to design/fabulous/generator.log (committed
#     evidence; ANSI/paths normalized), and
#   * runs flow/fabulous_summary.py to print the emitted file list and
#     config-bit layout, and an iverilog equivalence run of the FABulous BEL
#     against design/rtl/lut4_slice.v, and a differential iverilog run of the
#     FABulous switch matrix against design/rtl/logic_tile_switch_matrix.v
#     (generated output stays in flow/build/, never committed).
#
# Usage: flow/fabulous.sh [--update-log]
#   default       run, print summary, diff the normalized log against the
#                 committed one (exit 1 on drift)
#   --update-log  rewrite design/fabulous/generator.log
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=flow/tool_versions.sh
source "$REPO/flow/tool_versions.sh"

BUILD="$REPO/flow/build"
VENV="$BUILD/fab-venv"
RUN="$BUILD/fabulous-run"
export UV_CACHE_DIR="$BUILD/uv-cache"   # keep uv's cache out of ~/.cache
mkdir -p "$BUILD"

if [[ ! -x "$VENV/bin/FABulous" ]] || \
   [[ "$("$VENV/bin/FABulous" --version 2>&1 | awk '{print $NF}')" != "$RECORDED_FABULOUS_VERSION" ]]; then
    uv venv "$VENV"
    uv pip install --python "$VENV/bin/python" "fabulous-fpga==${RECORDED_FABULOUS_VERSION}"
fi
echo "=== FABulous $("$VENV/bin/FABulous" --version 2>&1 | tail -1) (pinned ${RECORDED_FABULOUS_VERSION}) ==="

rm -rf "$RUN"
mkdir -p "$RUN"
cp -r "$REPO/design/fabulous/." "$RUN/"
rm -f "$RUN/generator.log"

RAW="$BUILD/fabulous-raw.log"
( cd "$RUN" && "$VENV/bin/FABulous" -p . script FABulous.tcl ) >"$RAW" 2>&1 || {
    echo "FABulous generator FAILED; see $RAW" >&2; tail -20 "$RAW" >&2; exit 1; }

# Normalize (order-independent, see below): strip ANSI, rewrite absolute scratch path, drop host tool-probe lines.
NORM="$BUILD/fabulous-norm.log"
sed -e 's/\x1b\[[0-9;]*m//g' -e "s#$RUN#<project>#g" "$RAW" \
  | grep -v -E 'Resolved .* path|not found in PATH|PDK_root' \
  | python3 -c '
import sys
# FABulous 2.2.0 emits tiles in set/hash order (nondeterministic run to run),
# so the committed log is the sorted unique line set, with the tile-name list
# on "Generating tile ..." lines sorted too.
out = set()
for l in sys.stdin.read().splitlines():
    if l.startswith("INFO | Generating tile "):
        l = "INFO | Generating tile " + " ".join(sorted(l.split()[4:]))
    out.add(l)
print("\n".join(sorted(out)))' > "$NORM"

python3 "$REPO/flow/fabulous_summary.py" "$RUN"

echo "=== BEL equivalence (iverilog) ==="
iverilog -g2005 -o "$BUILD/bel_tb" \
    "$REPO/design/fabulous/tb_lut4_ff_bel_equiv.v" \
    "$REPO/design/fabulous/Tile/LOGIC4/lut4_ff_bel.v" \
    "$REPO/design/rtl/lut4_slice.v"
vvp "$BUILD/bel_tb" | tee "$BUILD/bel_tb.out"
grep -q '^PASS' "$BUILD/bel_tb.out"

# Switch-matrix differential check (issue #96): the FABulous-generated
# LOGIC4_switch_matrix.v lives only in the gitignored scratch dir ($RUN).
echo "=== switch-matrix equivalence (iverilog) ==="
iverilog -g2005 -o "$BUILD/sm_tb" \
    "$REPO/design/fabulous/tb_switch_matrix_equiv.v" \
    "$RUN/Tile/LOGIC4/LOGIC4_switch_matrix.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v"
vvp "$BUILD/sm_tb" | tee "$BUILD/sm_tb.out"
grep -q '^PASS: switch_matrix_fabulous_equiv' "$BUILD/sm_tb.out"

if [[ "${1:-}" == "--update-log" ]]; then
    cp "$NORM" "$REPO/design/fabulous/generator.log"
    echo "updated design/fabulous/generator.log"
elif ! diff -u "$REPO/design/fabulous/generator.log" "$NORM"; then
    echo "generator log differs from committed design/fabulous/generator.log" >&2
    exit 1
else
    echo "generator log matches committed copy"
fi
