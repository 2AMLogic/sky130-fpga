#!/usr/bin/env bash
# flow/gate-sim-routed.sh   (issue #112, EXPERIMENTAL, observation-only)
#
# Zero-delay gate-level re-run of the UNMODIFIED sim/tb_logic_tile_routed.v
# against the committed synthesized netlist of the experimental composed
# tile (layout/experimental/logic_tile_routed.synth.v) and the
# sky130_fd_sc_hd behavioral cell models. Same pattern as leg 1 of
# flow/sdf-resim.sh, minus the klt/OpenROAD regeneration: the netlist under
# test is the committed one that was placed and routed (#102/#108), so no
# flow tool is needed -- only Icarus Verilog and the sky130A cell models.
#
# Label: composed tile, stand-in matrix (ADR-0004 Proposed), zero-delay,
# functional-only; no timing claim. See sim/README.md for scope/non-claims.
#
# The testbench touches only top-level ports of the DUT (no hierarchical
# references), so flattening/escaped generate-block instance names in the
# netlist do not affect it; no testbench change is required.
#
# Usage: ./flow/gate-sim-routed.sh
# Env: SIM_TIMEOUT_SECONDS / SIM_KILL_AFTER_SECONDS override the simulation
# wall-clock budget (flow/gate_sim_verdict.sh, issue #157).
# Scratch output: flow/build/gate-sim-routed/ (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=flow/gate_sim_verdict.sh
source "$SCRIPT_DIR/gate_sim_verdict.sh"   # wall-clock budget helpers (issue #157)
# shellcheck source=flow/pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"   # sky130_fd_sc_hd model resolution (issue #375)
BUILD_DIR="$SCRIPT_DIR/build/gate-sim-routed"
TB_NAME="tb_logic_tile_routed"
NETLIST="$REPO_ROOT/layout/experimental/logic_tile_routed.synth.v"

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done
gs_budget_check || exit 1
[[ -s "$NETLIST" ]] || { echo "error: missing $NETLIST" >&2; exit 1; }

# Resolve the sky130_fd_sc_hd behavioral models (shared helper, issue #375;
# fixes this script's drifted copy, which accepted a directory holding only
# sky130_fd_sc_hd.v and delayed the failure to the iverilog invocation that
# passes primitives.v below).
CELL_DIR="$(resolve_sky130_cell_models sky130A)" || exit 1

mkdir -p "$BUILD_DIR"
echo "=== $(iverilog -V 2>&1 | head -1) ==="
echo "=== netlist: layout/experimental/logic_tile_routed.synth.v (cells: $(grep -c 'sky130_fd_sc_hd__' "$NETLIST") references) ==="

iverilog -g2012 -s "$TB_NAME" -o "$BUILD_DIR/$TB_NAME.vvp" \
    "$REPO_ROOT/sim/$TB_NAME.v" "$NETLIST" \
    "$CELL_DIR/primitives.v" "$CELL_DIR/sky130_fd_sc_hd.v" \
    2>"$BUILD_DIR/build.log" || { echo "error: compile failed (see $BUILD_DIR/build.log)" >&2; exit 1; }

# bounded by SIM_TIMEOUT_SECONDS (issue #157); a timeout fails the script even
# if a PASS line was printed before it
if ! gs_run_bounded_tee "$TB_NAME (gate-level, zero delay)" "$BUILD_DIR/$TB_NAME.log" \
        vvp "$BUILD_DIR/$TB_NAME.vvp"; then
    echo "error: ${TB_NAME} gate-level simulation run failed (see $BUILD_DIR/$TB_NAME.log)" >&2
    exit 1
fi
if ! grep -q "^PASS: ${TB_NAME}" "$BUILD_DIR/$TB_NAME.log"; then
    echo "error: ${TB_NAME} did not report PASS gate-level, zero delay" >&2
    exit 1
fi
echo "=== ${TB_NAME} PASSES gate-level, zero delay (functional-only; no timing claim) ==="
