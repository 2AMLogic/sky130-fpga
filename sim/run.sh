#!/usr/bin/env bash
# sim/run.sh
#
# Regenerate and run every self-checking testbench under sim/ against the
# committed RTL under design/rtl/. This is the reproducibility harness for
# the design-evidence "presence AND reproducibility" pass condition (see
# docs/design-evidence-tiers.md in 2AMLogic/klayout-tools, and issue #5):
# there is no one-off hand-run artifact -- every run recompiles from source
# and re-derives its own pass/fail result.
#
# Usage:
#   ./sim/run.sh            # build + run all testbenches, report pass/fail
#
# Requires Icarus Verilog (iverilog/vvp) on PATH.
#
# Exit status: 0 if every testbench reports PASS with zero failures,
# non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTL_DIR="$REPO_ROOT/design/rtl"
BUILD_DIR="$SCRIPT_DIR/build"

mkdir -p "$BUILD_DIR"

if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
    echo "error: Icarus Verilog (iverilog/vvp) not found on PATH" >&2
    exit 1
fi

# name:rtl-sources (space-separated, RTL first so dependents can reference
# already-defined modules)
TESTBENCHES=(
    "tb_lut4_slice:${RTL_DIR}/lut4_slice.v"
    "tb_logic_tile:${RTL_DIR}/lut4_slice.v ${RTL_DIR}/logic_tile.v"
)

overall_status=0

for entry in "${TESTBENCHES[@]}"; do
    name="${entry%%:*}"
    rtl_sources="${entry#*:}"
    tb_source="$SCRIPT_DIR/${name}.v"
    out_bin="$BUILD_DIR/${name}.out"
    log_file="$BUILD_DIR/${name}.log"

    echo "=== building ${name} ==="
    # shellcheck disable=SC2086 # intentional word-splitting of rtl_sources
    if ! iverilog -g2012 -Wall -o "$out_bin" $rtl_sources "$tb_source" 2>&1 | tee "${log_file}.compile"; then
        echo "error: compile failed for ${name}" >&2
        overall_status=1
        continue
    fi

    echo "=== running ${name} ==="
    if ! vvp "$out_bin" | tee "$log_file"; then
        echo "error: simulation run failed for ${name}" >&2
        overall_status=1
        continue
    fi

    if ! grep -q "^PASS: ${name}" "$log_file"; then
        echo "error: ${name} did not report PASS (see $log_file)" >&2
        overall_status=1
    fi
done

if [[ "$overall_status" -eq 0 ]]; then
    echo "=== all testbenches PASS ==="
else
    echo "=== one or more testbenches FAILED ==="
fi

exit "$overall_status"
