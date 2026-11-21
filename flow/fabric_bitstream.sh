#!/usr/bin/env bash
# Regenerate, assemble and simulate the experimental 2x2 fabric (#355).
# All generated RTL, the full snapshot/map and the mutated stream stay in build/.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/flow/tool_versions.sh"
source "$REPO/flow/install_oss_cad_suite.sh"
source "$REPO/flow/gate_sim_verdict.sh"
BUILD="$REPO/flow/build"
VENV="$BUILD/fab-venv"
RUN="$BUILD/fabric-bitstream"
FIX="$REPO/sim/bitstream/fabric_2x2"
TOOL="$REPO/flow/fasm_to_bitstream.py"
install_oss_cad_suite "$BUILD"
if [[ ! -x "$VENV/bin/FABulous" ]] ||
   [[ "$("$VENV/bin/FABulous" --version)" != "FABulous CLI $RECORDED_FABULOUS_VERSION" ]]; then
    UV_CACHE_DIR="$BUILD/uv-cache" uv venv --clear --python python3 "$VENV"
    UV_CACHE_DIR="$BUILD/uv-cache" uv pip install --python "$VENV/bin/python" "fabulous-fpga==$RECORDED_FABULOUS_VERSION"
fi

rm -rf "$RUN"
mkdir -p "$RUN/utils"
cd "$RUN"
cp -R "$REPO/design/fabulous/"{.FABulous,Tile,Fabric,FABulous.tcl} .
cp "$REPO/design/fabulous/fabric_2x2.csv" fabric.csv
# FABulous probes optional CAD programs too. Expose only the suite and the
# shell utilities its launchers need, even on hosts that provide OpenROAD.
for utility in bash sh dirname readlink; do ln -s "$(command -v "$utility")" "utils/$utility"; done
FAB_USER_CONFIG_DIR="$RUN/config" FAB_OSS_CAD_SUITE="$OSS" \
    FAB_YOSYS_PATH="$OSS/bin/yosys" FAB_IVERILOG_PATH="$OSS/bin/iverilog" \
    FAB_NEXTPNR_PATH="$OSS/bin/nextpnr-generic" FAB_VVP_PATH="$OSS/bin/vvp" \
    FAB_GHDL_PATH="$OSS/bin/ghdl" FAB_OPENSTA_PATH="$OSS/bin/sta" \
    FAB_OPENROAD_PATH="$OSS/bin/openroad" FAB_KLAYOUT_PATH="$OSS/bin/klayout" \
    PATH="$OSS/bin:$RUN/utils" "$VENV/bin/FABulous" -p . script FABulous.tcl > generator.log 2>&1 ||
    { tail -30 generator.log >&2; exit 1; }

SRC="$REPO/design/fabulous/nextpnr"
yosys -Q -q -p "synth_fabulous -top top -noiopad -extra-plib \"$SRC/prims.v\" -json cross_tile.json" "$SRC/cross_tile.v"
FAB_ROOT="$RUN" nextpnr-generic --uarch fabulous --json cross_tile.json \
    --write cross_tile.post.json -o fasm=cross_tile.fasm > nextpnr.log 2>&1 ||
    { tail -30 nextpnr.log >&2; exit 1; }
"$VENV/bin/python" "$TOOL" snapshot --spec .FABulous/bitStreamSpec.bin --configmem Tile/LOGIC4/LOGIC4_ConfigMem.v \
    --pips .FABulous/pips.txt --out . --fabulous-version "$RECORDED_FABULOUS_VERSION" --source flow/fabric_bitstream.sh
python3 "$TOOL" summary cross_tile.post.json --out cross_tile.mapped.json
python3 "$TOOL" assemble --snapshot fabric_spec.json --mapped cross_tile.mapped.json --fasm cross_tile.fasm --out cross_tile
"$VENV/bin/bit_gen" genBitstream cross_tile.fasm .FABulous/bitStreamSpec.bin reference.bin
cmp cross_tile.bin reference.bin
for ext in fasm mapped.json cfg wiring bin; do cmp "cross_tile.$ext" "$FIX/cross_tile.$ext"; done
echo "PASS: pinned route reproduced, assembler equals bit_gen on unfiltered FASM ($(wc -c < reference.bin) bytes)"

# Invert INIT[0] of u2, the BEL driving the crossing. Look up its frame
# position in the generated loader map. Edit one payload byte of the stream.
python3 - <<'PY'
from pathlib import Path
rows = (map(int, line.split()) for line in Path("logic4_configmem.map").read_text().splitlines())
pos, = [pos for x, y, cb, pos in rows if (x, y) == (2, 1) and cb % 158 == 3 * 17]
frame, bit = divmod(pos, 32)
data = bytearray(Path("cross_tile.bin").read_bytes())
# 20-byte sync, then select + Y2 + Y1 words per frame, all big endian.
offset = 20 + (2 * 20 + frame) * 12 + 8 + (3 - bit // 8)
data[offset] ^= 1 << (bit % 8)
Path("perturbed.bin").write_bytes(data)
PY
python3 "$TOOL" decode perturbed.bin --snapshot fabric_spec.json > perturbed.cfg
printf '`timescale 1ps/1ps\n' > timescale.v
CONFIG_RTL="$("$VENV/bin/python" -c 'from importlib.resources import files; print(files("fabulous") / "fabric_files/FABulous_project_template_verilog/Fabric")')"
iverilog -g2012 -s tb_fabric_bitstream -o bench \
    "$CONFIG_RTL/"{eFPGA_Config,ConfigFSM,bitbang,config_UART,Frame_Data_Reg,Frame_Select}.v \
    Fabric/models_pack.v Tile/LOGIC4/lut4_ff_bel.v timescale.v \
    Tile/LOGIC4/LOGIC4{,_ConfigMem,_switch_matrix}.v Tile/CAP*/*.v Fabric/eFPGA{,_top}.v "$REPO/sim/tb_fabric_bitstream.v"
for design in cross_tile perturbed; do
    gs_run_bounded_tee "$design" "$design.sim.log" vvp bench "+bin=$design.bin" "+cfg=$design.cfg"
done
grep -Fxq 'PASS: tb_fabric_bitstream (96 checks, 0 failures)' cross_tile.sim.log
grep -Fxq 'FAIL: tb_fabric_bitstream (96 checks, 32 failures)' perturbed.sim.log
echo "PASS: one-bit perturbation detected"
