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
# Scratch output: flow/build/gate-sim-routed/ (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/gate-sim-routed"
TB_NAME="tb_logic_tile_routed"
NETLIST="$REPO_ROOT/layout/experimental/logic_tile_routed.synth.v"

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done
[[ -s "$NETLIST" ]] || { echo "error: missing $NETLIST" >&2; exit 1; }

# Resolve the sky130_fd_sc_hd behavioral models (same search as sdf-resim.sh,
# with klt optional here).
LIBS_REF=""
if command -v klt >/dev/null 2>&1; then
    LIBS_REF="$(klt pdk find --pdk sky130A --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assets", {}).get("libs_ref", ""))' 2>/dev/null || true)"
fi
CELL_DIR=""
for c in "${LIBS_REF:+$LIBS_REF/sky130_fd_sc_hd/verilog}" \
         "${PDK_ROOT:+$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog}" \
         "$HOME/.volare/sky130A/libs.ref/sky130_fd_sc_hd/verilog"; do
    if [[ -n "$c" && -f "$c/sky130_fd_sc_hd.v" ]]; then CELL_DIR="$c"; break; fi
done
[[ -n "$CELL_DIR" ]] || { echo "error: could not resolve sky130_fd_sc_hd Verilog cell models (set PDK_ROOT)" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
echo "=== $(iverilog -V 2>&1 | head -1) ==="
echo "=== netlist: layout/experimental/logic_tile_routed.synth.v (cells: $(grep -c 'sky130_fd_sc_hd__' "$NETLIST") references) ==="

iverilog -g2012 -s "$TB_NAME" -o "$BUILD_DIR/$TB_NAME.vvp" \
    "$REPO_ROOT/sim/$TB_NAME.v" "$NETLIST" \
    "$CELL_DIR/primitives.v" "$CELL_DIR/sky130_fd_sc_hd.v" \
    2>"$BUILD_DIR/build.log" || { echo "error: compile failed (see $BUILD_DIR/build.log)" >&2; exit 1; }

vvp "$BUILD_DIR/$TB_NAME.vvp" | tee "$BUILD_DIR/$TB_NAME.log"
if ! grep -q "^PASS: ${TB_NAME}" "$BUILD_DIR/$TB_NAME.log"; then
    echo "error: ${TB_NAME} did not report PASS gate-level, zero delay" >&2
    exit 1
fi
echo "=== ${TB_NAME} PASSES gate-level, zero delay (functional-only; no timing claim) ==="
