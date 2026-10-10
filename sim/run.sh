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
#   ./sim/run.sh --mutation [--record]
#                           # RTL mutation check (issue #124): mutate a copy of
#                           # design/rtl/ in sim/build/, require every
#                           # non-allowlisted mutant to FAIL some testbench.
#                           # Not part of the default path; see sim/README.md.
#
# Requires Icarus Verilog (iverilog/vvp) and python3 on PATH (no mapping tool:
# the bitstream fixtures under sim/bitstream/ are committed; flow/bitstream.sh
# regenerates and verifies them).
#
# Exit status: 0 if every testbench reports PASS with zero failures,
# non-zero otherwise.
#
# Every vvp run is bounded by a per-simulation wall-clock budget
# (SIM_TIMEOUT_SECONDS, default in flow/gate_sim_verdict.sh; SIM_KILL_AFTER_SECONDS
# grace before a forced kill). A run that exceeds it fails the suite as an
# infrastructure error, naming the testbench/fixture, budget and log path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RTL_DIR="$REPO_ROOT/design/rtl"
BUILD_DIR="$SCRIPT_DIR/build"
# Wall-clock budget for every simulator run (issue #157): SIM_TIMEOUT_SECONDS /
# SIM_KILL_AFTER_SECONDS, validated here; helpers live with the verdict
# classifier in flow/gate_sim_verdict.sh.
# shellcheck source=../flow/gate_sim_verdict.sh
source "$REPO_ROOT/flow/gate_sim_verdict.sh"
gs_budget_check || exit 1

mkdir -p "$BUILD_DIR"

if [[ "${1:-}" == "--mutation" ]]; then
    shift
    for tool in iverilog vvp python3; do
        command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
    done
    # Mutants run strictly serially inside mutation.py (shared-host rule).
    exec python3 -I "$SCRIPT_DIR/mutation.py" "$@"
fi

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
    "tb_logic_tile_gapfill:${RTL_DIR}/lut4_slice.v ${RTL_DIR}/logic_tile.v ${RTL_DIR}/logic_tile_switch_matrix.v ${RTL_DIR}/logic_tile_routed.v"
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
    if ! gs_run_bounded_tee "${name}" "$log_file" vvp "$out_bin"; then
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

echo "=== LUT basis stream generator unit tests (flow/test_lut_basis.py, issue #172) ==="
if python3 -I "$REPO_ROOT/flow/test_lut_basis.py" >"$BUILD_DIR/test_lut_basis.log" 2>&1 \
   && grep -q '^OK' "$BUILD_DIR/test_lut_basis.log"; then
    echo "PASS: test_lut_basis ($(grep -o '^Ran [0-9]* tests' "$BUILD_DIR/test_lut_basis.log"), 0 failures)"
else
    cat "$BUILD_DIR/test_lut_basis.log" >&2
    echo "error: LUT basis generator unit tests failed" >&2
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
        if ! gs_run_bounded_tee "${name}[${dname}] $stem" "$log_file" vvp "$out_bin" "${bs_args[@]}" +mutate; then
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
            bad_log="${bad%.bin}.log"; rc=0
            gs_run_bounded "${name}[${dname}] malformed $(basename "$bad")" "$bad_log" \
                vvp "$out_bin" +bin="$bad" +map="$BS_DIR/logic4_configmem.map" +wiring="$BS_DIR/$stem.wiring" \
                +design="$dname" +expect_reject || rc=$?
            if [[ "$rc" -ne 0 ]]; then
                echo "error: loader check of malformed stream $(basename "$bad") [${dname}] did not complete (rc=$rc; infrastructure failure, see $bad_log)" >&2
                overall_status=1
            elif grep -q "^PASS: ${name}\[${dname}\] loader rejected" "$bad_log"; then
                nrej=$((nrej + 1))
            else
                echo "error: loader accepted malformed stream $(basename "$bad") [${dname}]" >&2
                overall_status=1
            fi
        done
        echo "loader malformed-input rejections [${dname}]: ${nrej}/${nbad}"
    done
fi

# ---------------------------------------------------------------------------
# Routability-corpus fixtures (issue #115 -- EXPERIMENTAL decision evidence for
# ADR-0004 item 3, see design/fabulous/corpus/README.md). Every (case, seed)
# of design/fabulous/corpus/corpus.json that mapped successfully has its
# assembled stream committed under sim/bitstream/corpus/ (index.txt lists
# "<stem> <oracle>"); each is re-assembled from its FASM, loaded through the
# same loader and checked against its independent oracle. Non-routable
# probes have no fixture and no PASS by construction. Regenerating against the
# pinned mapper (and the recorded expected failures) is flow/corpus.sh.
CORPUS_DIR="$BS_DIR/corpus"
echo "=== corpus outcome-classification unit tests (flow/test_corpus_run.py) ==="
if python3 "$REPO_ROOT/flow/test_corpus_run.py" >"$BUILD_DIR/test_corpus_run.log" 2>&1 \
   && grep -q '^OK' "$BUILD_DIR/test_corpus_run.log"; then
    echo "PASS: test_corpus_run ($(grep -o '^Ran [0-9]* tests' "$BUILD_DIR/test_corpus_run.log"), 0 failures)"
else
    cat "$BUILD_DIR/test_corpus_run.log" >&2
    echo "error: corpus classification unit tests failed" >&2
    overall_status=1
fi
echo "=== corpus fixtures reproduce from committed FASM (flow/fasm_to_bitstream.py check) ==="
if ! python3 "$BS_TOOL" check "$CORPUS_DIR" --snapshot-dir "$BS_DIR"; then
    echo "error: committed sim/bitstream/corpus fixtures drifted from the assembler output" >&2
    overall_status=1
fi
echo "=== registered-BEL fixture metadata (issue #156: BEL A/B/C/D each registered, placement pinned) ==="
if python3 -I "$REPO_ROOT/flow/test_check_regbel_fixtures.py" >"$BUILD_DIR/test_check_regbel_fixtures.log" 2>&1 \
   && grep -q '^OK' "$BUILD_DIR/test_check_regbel_fixtures.log"; then
    echo "PASS: test_check_regbel_fixtures ($(grep -o '^Ran [0-9]* tests' "$BUILD_DIR/test_check_regbel_fixtures.log"), 0 failures)"
else
    cat "$BUILD_DIR/test_check_regbel_fixtures.log" >&2
    echo "error: regbel fixture-metadata unit tests failed" >&2
    overall_status=1
fi
python3 -I "$REPO_ROOT/flow/check_regbel_fixtures.py" "$REPO_ROOT" || overall_status=1
if [[ -f "$out_bin" ]]; then
    n_corpus=0
    while read -r stem oracle; do
        [[ -z "$stem" ]] && continue
        n_corpus=$((n_corpus + 1))
        log_file="$BUILD_DIR/${name}_${stem}.log"
        echo "=== running ${name} [${oracle}] corpus fixture ${stem} (with perturbation checks) ==="
        if ! gs_run_bounded_tee "${name}[${oracle}] corpus $stem" "$log_file" \
                vvp "$out_bin" +bin="$CORPUS_DIR/$stem.bin" +map="$BS_DIR/logic4_configmem.map" \
                +wiring="$CORPUS_DIR/$stem.wiring" +design="$oracle" +mutate; then
            echo "error: simulation run failed for ${stem}" >&2
            overall_status=1
            continue
        fi
        if ! grep -q "^PASS: ${name}\[${oracle}\]" "$log_file"; then
            echo "error: ${name} [${oracle}] ${stem} did not report PASS (see $log_file)" >&2
            overall_status=1
        fi
        sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log_file" | cut -d= -f2)"
        py_cfg="$(python3 "$BS_TOOL" decode "$CORPUS_DIR/$stem.bin" --snapshot "$BS_DIR/fabric_spec.json")"
        rec_cfg="$(tr -d '\n' < "$CORPUS_DIR/$stem.cfg")"
        if [[ -z "$sim_cfg" || "$sim_cfg" != "$py_cfg" || "$sim_cfg" != "$rec_cfg" ]]; then
            echo "error: [${stem}] loaded cfg mismatch: sim=$sim_cfg python=$py_cfg recorded=$rec_cfg" >&2
            overall_status=1
        fi
    done < "$CORPUS_DIR/index.txt"
    echo "corpus fixtures simulated: ${n_corpus}"
fi

# ---------------------------------------------------------------------------
# Pin-experiment fixtures (issue #145 -- EXPERIMENTAL, separate from the baseline
# corpus above). The three successful distinct-pin fan4 streams of
# flow/pin_experiment.py, exported opt-in with `flow/pin_experiment.sh
# --export-fixtures`, are committed under sim/bitstream/pin_experiment/ and
# replayed here with the independent fan4 oracle, perturbation checks, assembler
# reproduction and cfg cross-checks (sim/pin_fixture_replay.sh). Needs no mapper.
# Missing/empty index, wrong case count, missing/drifted files, simulator errors
# or an absent terminal verdict fail the suite.
echo "=== unit tests for the pin-experiment fixture tooling (flow/test_pin_experiment.py, flow/test_pin_fixtures.py) ==="
for t in test_pin_experiment test_pin_fixtures; do
    if python3 "$REPO_ROOT/flow/$t.py" >"$BUILD_DIR/$t.log" 2>&1 && grep -q '^OK' "$BUILD_DIR/$t.log"; then
        echo "PASS: $t ($(grep -o '^Ran [0-9]* tests' "$BUILD_DIR/$t.log"), 0 failures)"
    else
        cat "$BUILD_DIR/$t.log" >&2
        echo "error: $t failed" >&2
        overall_status=1
    fi
done
if [[ -f "$out_bin" ]]; then
    echo "=== pin-experiment fixtures (experimental, sim/bitstream/pin_experiment, with perturbation checks) ==="
    "$SCRIPT_DIR/pin_fixture_replay.sh" "$out_bin" rtl || overall_status=1
    echo "=== pin-experiment negative tests (scratch copies; each defect MUST be rejected) ==="
    "$SCRIPT_DIR/pin_fixture_negative.sh" "$out_bin" rtl || overall_status=1
else
    echo "error: ${name} did not compile; pin-experiment fixtures NOT replayed" >&2
    overall_status=1
fi

if [[ "$overall_status" -eq 0 ]]; then
    echo "=== all testbenches PASS ==="
else
    echo "=== one or more testbenches FAILED ==="
fi

exit "$overall_status"
