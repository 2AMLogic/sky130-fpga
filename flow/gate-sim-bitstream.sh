#!/usr/bin/env bash
# flow/gate-sim-bitstream.sh   (issue #119, EXPERIMENTAL, observation-only)
#
# Zero-delay gate-level run of the UNMODIFIED sim/tb_logic_tile_bitstream.v
# with both committed bitstream fixtures (sim/bitstream/top_io.bin, top_reg.bin)
# against the committed synthesized netlist of the experimental composed tile
# (layout/experimental/logic_tile_routed.synth.v) and the sky130_fd_sc_hd
# behavioral models. The netlist replaces design/rtl/ in the DUT; the frame
# loader and boundary pads remain SIMULATION MODELS inside the testbench.
#
# Label: experimental same-index switch matrix (ADR-0004/0005 Proposed),
# zero-delay, functional observation only. No SDF/timing, no ratified-fabric
# claim, no inter-tile claim.
#
# Usage:
#   ./flow/gate-sim-bitstream.sh              # both fixtures, must PASS
#   ./flow/gate-sim-bitstream.sh --negative   # also prove wrong results FAIL
# Exit: nonzero on missing iverilog/vvp, missing PDK models, compile error,
# simulation error, missing PASS line, or (with --negative) a negative case
# that is wrongly accepted.
# Scratch output: flow/build/gate-sim-bitstream/ (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/gate-sim-bitstream"
TB_NAME="tb_logic_tile_bitstream"
NETLIST="$REPO_ROOT/layout/experimental/logic_tile_routed.synth.v"
BS_DIR="$REPO_ROOT/sim/bitstream"
NEGATIVE=0
[[ "${1:-}" == "--negative" ]] && NEGATIVE=1

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done
[[ -s "$NETLIST" ]] || { echo "error: missing $NETLIST" >&2; exit 1; }

LIBS_REF=""
if command -v klt >/dev/null 2>&1; then
    LIBS_REF="$(klt pdk find --pdk sky130A --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assets", {}).get("libs_ref", ""))' 2>/dev/null || true)"
fi
CELL_DIR=""
for c in "${LIBS_REF:+$LIBS_REF/sky130_fd_sc_hd/verilog}" \
         "${PDK_ROOT:+$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog}" \
         "$HOME/.volare/sky130A/libs.ref/sky130_fd_sc_hd/verilog"; do
    if [[ -n "$c" && -f "$c/sky130_fd_sc_hd.v" && -f "$c/primitives.v" ]]; then CELL_DIR="$c"; break; fi
done
[[ -n "$CELL_DIR" ]] || { echo "error: could not resolve sky130_fd_sc_hd Verilog cell models (set PDK_ROOT)" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
echo "=== $(iverilog -V 2>&1 | head -1) ==="
echo "=== netlist: layout/experimental/logic_tile_routed.synth.v sha256 $(sha256sum "$NETLIST" | cut -d' ' -f1) ==="
echo "=== models: $CELL_DIR sha256(sky130_fd_sc_hd.v) $(sha256sum "$CELL_DIR/sky130_fd_sc_hd.v" | cut -d' ' -f1) ==="

build() {  # build <netlist> <out.vvp>
    iverilog -g2012 -s "$TB_NAME" -I "$REPO_ROOT/sim" -o "$2" \
        "$REPO_ROOT/sim/$TB_NAME.v" "$1" \
        "$CELL_DIR/primitives.v" "$CELL_DIR/sky130_fd_sc_hd.v" \
        2>"$BUILD_DIR/build.log" || { echo "error: compile failed (see $BUILD_DIR/build.log)" >&2; return 1; }
}

# run_one <vvp> <bin> <wiring> <design> <log> ; prints log; returns 0 iff PASS line and vvp ok
run_one() {
    local vvp_bin="$1" bin="$2" wiring="$3" dname="$4" log="$5" rc=0
    vvp "$vvp_bin" +bin="$bin" +map="$BS_DIR/logic4_configmem.map" +wiring="$wiring" \
        +design="$dname" +mutate >"$log" 2>&1 || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    grep -q "^PASS: ${TB_NAME}\[${dname}\]" "$log" && ! grep -q "^FAIL" "$log"
}

build "$NETLIST" "$BUILD_DIR/$TB_NAME.vvp" || exit 1

status=0
for entry in "comb:top_io" "reg:top_reg"; do
    dname="${entry%%:*}"; stem="${entry#*:}"
    log="$BUILD_DIR/${TB_NAME}_${dname}.log"
    echo "=== gate-level ${TB_NAME} [${dname}] bitstream sim/bitstream/$stem.bin (zero delay, +mutate) ==="
    if run_one "$BUILD_DIR/$TB_NAME.vvp" "$BS_DIR/$stem.bin" "$BS_DIR/$stem.wiring" "$dname" "$log"; then
        grep -E "^(CFG=|baseline|PASS)" "$log"
        # the loaded cfg must equal the recorded cfg (same stream read as in RTL suite)
        sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log" | cut -d= -f2)"
        rec_cfg="$(tr -d '\n' < "$BS_DIR/$stem.cfg")"
        if [[ "$sim_cfg" != "$rec_cfg" ]]; then
            echo "error: [$dname] loaded cfg $sim_cfg != recorded $rec_cfg" >&2; status=1
        fi
    else
        echo "error: [$dname] gate-level run did not PASS (see $log)" >&2
        tail -n 15 "$log" >&2 || true
        status=1
    fi
done

if [[ "$NEGATIVE" -eq 1 ]]; then
    echo "=== negative checks (each MUST be reported as FAIL by the same pass criterion) ==="
    # N1: wrong program for the oracle -- top_io bitstream judged as the registered design.
    if run_one "$BUILD_DIR/$TB_NAME.vvp" "$BS_DIR/top_io.bin" "$BS_DIR/top_reg.wiring" reg "$BUILD_DIR/neg_wrong_bitstream.log"; then
        echo "error: negative N1 (wrong bitstream vs oracle) was ACCEPTED" >&2; status=1
    else
        echo "negative N1 OK: top_io.bin judged against the reg oracle -> $(grep -m1 -E '^(FAIL|PASS)' "$BUILD_DIR/neg_wrong_bitstream.log" || echo 'no PASS line')"
    fi
    # N2: corrupted netlist (scratch copy; every nand2_1 -> nor2_1).
    sed 's/sky130_fd_sc_hd__nand2_1/sky130_fd_sc_hd__nor2_1/g' "$NETLIST" >"$BUILD_DIR/corrupt.synth.v"
    if cmp -s "$NETLIST" "$BUILD_DIR/corrupt.synth.v"; then
        echo "error: negative N2 could not corrupt the netlist copy" >&2; status=1
    elif build "$BUILD_DIR/corrupt.synth.v" "$BUILD_DIR/corrupt.vvp"; then
        n2ok=1
        for entry in "comb:top_io" "reg:top_reg"; do
            dname="${entry%%:*}"; stem="${entry#*:}"
            if run_one "$BUILD_DIR/corrupt.vvp" "$BS_DIR/$stem.bin" "$BS_DIR/$stem.wiring" "$dname" "$BUILD_DIR/neg_corrupt_$dname.log"; then
                n2ok=0
            fi
            echo "negative N2 [$dname]: $(grep -m1 -E '^(FAIL|PASS)' "$BUILD_DIR/neg_corrupt_$dname.log" || echo 'no PASS line')"
        done
        # a corrupted netlist is only required to be caught by at least one fixture it affects
        if grep -q '^PASS' "$BUILD_DIR/neg_corrupt_comb.log" && grep -q '^PASS' "$BUILD_DIR/neg_corrupt_reg.log"; then
            echo "error: negative N2 (corrupted netlist) was ACCEPTED by both fixtures" >&2; status=1
        else
            echo "negative N2 OK: corrupted netlist rejected"
        fi
    else
        status=1
    fi
fi

if [[ "$status" -ne 0 ]]; then echo "=== gate-sim-bitstream FAILED ===" >&2; exit 1; fi
echo "=== ${TB_NAME} PASSES gate-level, zero delay, both fixtures (functional observation only; no timing claim) ==="
