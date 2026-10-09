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
# Requires Icarus Verilog (iverilog/vvp) and python3 on PATH (no mapping tool:
# the bitstream fixtures under sim/bitstream/ are committed; flow/bitstream.sh
# regenerates and verifies them).
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

# Drift guard (#99): the switch-matrix RTL and the testbench include are
# generated from the .list file by design/gen/gen_switch_matrix.py. Regenerate
# into the gitignored build dir and require byte-identity with the committed
# copies, so a hand edit or stale generated file cannot leave CI green.
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found on PATH (needed for the generated-RTL drift guard)" >&2
    exit 1
fi

GEN_DIR="$BUILD_DIR/gen_check"
mkdir -p "$GEN_DIR"
REGEN_CMD="python3 design/gen/gen_switch_matrix.py design/fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list design/rtl/logic_tile_switch_matrix.v sim/switch_matrix_tb_gen.vh"
python3 "$REPO_ROOT/design/gen/gen_switch_matrix.py" \
    "$REPO_ROOT/design/fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list" \
    "$GEN_DIR/logic_tile_switch_matrix.v" \
    "$GEN_DIR/switch_matrix_tb_gen.vh"
drift=0
diff -u "$RTL_DIR/logic_tile_switch_matrix.v" "$GEN_DIR/logic_tile_switch_matrix.v" || drift=1
diff -u "$SCRIPT_DIR/switch_matrix_tb_gen.vh" "$GEN_DIR/switch_matrix_tb_gen.vh" || drift=1
if [[ "$drift" -ne 0 ]]; then
    echo "error: committed generated switch-matrix files differ from generator output." >&2
    echo "       regenerate from the repo root with:" >&2
    echo "       $REGEN_CMD" >&2
    exit 1
fi
echo "=== generated switch-matrix files match generator output ==="

# name:rtl-sources (space-separated, RTL first so dependents can reference
# already-defined modules)
TESTBENCHES=(
    "tb_lut4_slice:${RTL_DIR}/lut4_slice.v"
    "tb_logic_tile:${RTL_DIR}/lut4_slice.v ${RTL_DIR}/logic_tile.v"
    "tb_switch_matrix:${RTL_DIR}/logic_tile_switch_matrix.v"
    "tb_logic_tile_routed:${RTL_DIR}/lut4_slice.v ${RTL_DIR}/logic_tile_switch_matrix.v ${RTL_DIR}/logic_tile_routed.v"
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
    if ! iverilog -g2012 -Wall -I "$SCRIPT_DIR" -o "$out_bin" $rtl_sources "$tb_source" 2>&1 | tee "${log_file}.compile"; then
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

# ---------------------------------------------------------------------------
# Bitstream-driven harness test (issue #74, G5/G6 -- EXPERIMENTAL single-LOGIC4
# harness coverage, see sim/README.md). A bitstream produced by the pinned
# yosys/nextpnr/FABulous flow (committed under sim/bitstream/ together with its
# FASM, routed-netlist summary and generated-spec snapshot) is loaded through a
# model of the FABulous frame interface into the 158-bit cfg of
# logic_tile_routed; no mapping tool is needed here. Regenerating/verifying the
# fixtures against the pinned mapper is flow/bitstream.sh.
BS_DIR="$SCRIPT_DIR/bitstream"
BS_TOOL="$REPO_ROOT/flow/fasm_to_bitstream.py"

echo "=== bitstream assembler unit tests (flow/test_fasm_to_bitstream.py) ==="
if python3 "$REPO_ROOT/flow/test_fasm_to_bitstream.py" >"$BUILD_DIR/test_fasm_to_bitstream.log" 2>&1 \
   && grep -q '^OK' "$BUILD_DIR/test_fasm_to_bitstream.log"; then
    echo "PASS: test_fasm_to_bitstream ($(grep -o '^Ran [0-9]* tests' "$BUILD_DIR/test_fasm_to_bitstream.log"), 0 failures)"
else
    cat "$BUILD_DIR/test_fasm_to_bitstream.log" >&2
    echo "error: assembler unit tests failed" >&2
    overall_status=1
fi

echo "=== bitstream fixtures reproduce from committed FASM (flow/fasm_to_bitstream.py check) ==="
if ! python3 "$BS_TOOL" check "$BS_DIR"; then
    echo "error: committed sim/bitstream fixtures drifted from the assembler output" >&2
    overall_status=1
fi

name=tb_logic_tile_bitstream
out_bin="$BUILD_DIR/${name}.out"
echo "=== building ${name} ==="
if ! iverilog -g2012 -Wall -I "$SCRIPT_DIR" -o "$out_bin" \
        "$RTL_DIR/lut4_slice.v" "$RTL_DIR/logic_tile_switch_matrix.v" "$RTL_DIR/logic_tile_routed.v" \
        "$SCRIPT_DIR/${name}.v" 2>&1 | tee "$BUILD_DIR/${name}.log.compile"; then
    echo "error: compile failed for ${name}" >&2
    overall_status=1
else
    # design-name : fixture stem
    for entry in "comb:top_io" "reg:top_reg"; do
        dname="${entry%%:*}"; stem="${entry#*:}"
        bs_args=(+bin="$BS_DIR/$stem.bin" +map="$BS_DIR/logic4_configmem.map" +wiring="$BS_DIR/$stem.wiring" +design="$dname")
        log_file="$BUILD_DIR/${name}_${dname}.log"
        echo "=== running ${name} [${dname}] (bitstream sim/bitstream/$stem.bin, with perturbation checks) ==="
        if ! vvp "$out_bin" "${bs_args[@]}" +mutate | tee "$log_file"; then
            echo "error: simulation run failed for ${name} [${dname}]" >&2
            overall_status=1
            continue
        fi
        if ! grep -q "^PASS: ${name}\[${dname}\]" "$log_file"; then
            echo "error: ${name} [${dname}] did not report PASS (see $log_file)" >&2
            overall_status=1
        fi
        # three independent reads of the same stream must agree on the tile vector:
        # the simulation loader, the python decoder, and the assembler's own record.
        sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log_file" | cut -d= -f2)"
        py_cfg="$(python3 "$BS_TOOL" decode "$BS_DIR/$stem.bin" --snapshot "$BS_DIR/fabric_spec.json")"
        rec_cfg="$(tr -d '\n' < "$BS_DIR/$stem.cfg")"
        if [[ -z "$sim_cfg" || "$sim_cfg" != "$py_cfg" || "$sim_cfg" != "$rec_cfg" ]]; then
            echo "error: [${dname}] loaded cfg mismatch: sim=$sim_cfg python=$py_cfg recorded=$rec_cfg" >&2
            overall_status=1
        else
            echo "cfg cross-check [${dname}]: simulation loader == python decoder == recorded cfg ($sim_cfg)"
        fi
        # malformed streams must be rejected by the loader (the generator
        # overwrites the same file names each run)
        python3 "$SCRIPT_DIR/bitstream_corrupt.py" "$BS_DIR/$stem.bin" "$BUILD_DIR/bitstream_bad_${dname}" >/dev/null
        nrej=0; nbad=0
        for bad in "$BUILD_DIR/bitstream_bad_${dname}"/*.bin; do
            nbad=$((nbad + 1))
            if vvp "$out_bin" +bin="$bad" +map="$BS_DIR/logic4_configmem.map" +wiring="$BS_DIR/$stem.wiring" \
                   +design="$dname" +expect_reject | grep -q "^PASS: ${name}\[${dname}\] loader rejected"; then
                nrej=$((nrej + 1))
            else
                echo "error: loader accepted malformed stream $(basename "$bad") [${dname}]" >&2
                overall_status=1
            fi
        done
        echo "loader malformed-input rejections [${dname}]: ${nrej}/${nbad}"
    done
fi

if [[ "$overall_status" -eq 0 ]]; then
    echo "=== all testbenches PASS ==="
else
    echo "=== one or more testbenches FAILED ==="
fi

exit "$overall_status"
