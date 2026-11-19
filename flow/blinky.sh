#!/usr/bin/env bash
# flow/blinky.sh -- the one-command blinky demo (issue #324): a newcomer's
# Verilog -> bitstream -> simulated blinking output, open tools only, on the
# EXPERIMENTAL single-LOGIC4 harness (sim/README.md; not the ratified fabric,
# no timing claim).
#
#   1. The pinned OSS CAD Suite (flow/tool_versions.sh) is downloaded to
#      flow/build/dl/, sha256-verified and unpacked (tool subset only) into
#      flow/build/oss-cad-suite/ BEFORE anything else: FABulous shells out to
#      yosys (BEL Verilog -> JSON), and this order -- the CI workflow's order,
#      unlike flow/nextpnr.sh's -- is what makes the command work from a clean
#      checkout with an empty flow/build/. On later runs the unpacked tree is
#      reused if its .pin stamp matches the pinned sha256 and, when the tarball
#      is still in flow/build/dl/, the tarball re-verifies; otherwise it is
#      re-fetched/re-extracted. The yosys and nextpnr version strings are
#      checked against the pins on every run. Nothing is installed host-wide.
#   2. flow/fabulous.sh regenerates the fabric model (FABULOUS_SKIP_TILE_REPLAY=1,
#      throwaway venv flow/build/fab-venv, pinned FABulous), and
#      flow/nextpnr_io_overlay.py adds the harness pad model (ADR-0005, scratch
#      copy) used for placement.
#   3. yosys maps design/fabulous/nextpnr/blinky.v (a one-bit divider: after a
#      synchronous reset the output toggles on every rising edge with en held
#      high, so the blink period is two input clocks). The flop maps onto a
#      second BEL with FF=1 (ff_map.v) so rst/en are real routed nets -- the
#      same registered path as flow/nextpnr.sh's top_reg.v -- and `clk` is
#      stripped from the nextpnr JSON (the BEL's implicit UserCLK, a runtime
#      harness input). nextpnr-generic (--uarch fabulous, fixed seed) places
#      and routes it; a route failure exits nonzero.
#   4. flow/fasm_to_bitstream.py freezes the bitstream spec / ConfigMem map /
#      pip model (byte-checked against the committed sim/bitstream/ copies, so
#      a regenerated model that drifted fails here), turns the FASM into a
#      frame stream and requires FABulous's own `bit_gen genBitstream` to
#      produce a byte-identical stream.
#   5. sim/tb_logic_tile_bitstream.v (+design=blinky) loads the stream through
#      the frame-loader model into design/rtl/logic_tile_routed.v and checks
#      the output pad against an independent expected sequence: reset to 0,
#      then toggle on every clock edge. An unknown (X) value, a wrong phase or
#      a stuck output all FAIL; every used routing-select / BEL bit of the
#      loaded stream is also flipped (+mutate) and every flip must be detected,
#      so a green run means the bitstream itself is what blinks.
#
# Exit status: 0 iff the simulation reports the terminal
# PASS: tb_logic_tile_bitstream[blinky] line (classified by the
# flow/gate_sim_verdict.sh PASS/FUNC_FAIL/INFRA rules under the
# SIM_TIMEOUT_SECONDS wall-clock budget; a timed-out run is always INFRA) and
# the cfg cross-check (sim loader == python decoder == recorded cfg) holds.
#
# Prerequisites (host; see README "Quick start"): bash, python3, uv (FABulous
# venv), Icarus Verilog (iverilog + vvp), curl/tar/sha256sum for the first
# fetch (~750 MB download). Everything else lives under flow/build/.
# Usage: ./flow/blinky.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=flow/tool_versions.sh
source "$REPO/flow/tool_versions.sh"
# shellcheck source=flow/gate_sim_verdict.sh
source "$REPO/flow/gate_sim_verdict.sh"
gs_budget_check || exit 1

for t in python3 uv curl tar sha256sum iverilog vvp timeout; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "error: $t not found on PATH; blinky NOT RUN (see README 'Quick start' for the prerequisites)" >&2
        exit 2
    }
done

SRC="$REPO/design/fabulous/nextpnr"
TOOL="$REPO/flow/fasm_to_bitstream.py"
BUILD="$REPO/flow/build"
OSS="$BUILD/oss-cad-suite"
W="$BUILD/blinky-run"
mkdir -p "$BUILD/dl"
SECONDS=0
FETCHED=0

# 1. pinned OSS CAD Suite first: FABulous (step 2) shells out to yosys
TGZ="$BUILD/dl/$RECORDED_OSS_CAD_TARBALL"
if [[ ! -x "$OSS/bin/nextpnr-generic" ]] || \
   [[ ! -f "$OSS/.pin" ]] || [[ "$(cat "$OSS/.pin")" != "$RECORDED_OSS_CAD_SHA256" ]] || \
   { [[ -f "$TGZ" ]] && ! echo "$RECORDED_OSS_CAD_SHA256  $TGZ" | sha256sum -c --quiet - >/dev/null 2>&1; }; then
    if [[ ! -f "$TGZ" ]] || ! echo "$RECORDED_OSS_CAD_SHA256  $TGZ" | sha256sum -c --quiet -; then
        curl -fsSL -o "$TGZ" \
          "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${RECORDED_OSS_CAD_TAG}/${RECORDED_OSS_CAD_TARBALL}"
        echo "$RECORDED_OSS_CAD_SHA256  $TGZ" | sha256sum -c --quiet -
    fi
    rm -rf "$OSS"; mkdir -p "$OSS"
    tar -xzf "$TGZ" -C "$OSS" --strip-components=1 \
        oss-cad-suite/bin oss-cad-suite/lib oss-cad-suite/libexec \
        oss-cad-suite/share/yosys oss-cad-suite/share/nextpnr oss-cad-suite/etc
    echo "$RECORDED_OSS_CAD_SHA256" >"$OSS/.pin"
    FETCHED=1
fi
export PATH="$OSS/bin:$PATH"
YV="$(yosys -V | awk '{print $2}')"
NV="$(nextpnr-generic --version 2>&1 | grep -o 'nextpnr-[0-9][^)" ]*' | head -1)"
echo "=== yosys $YV (pinned $RECORDED_YOSYS_VERSION), $NV (pinned $RECORDED_NEXTPNR_VERSION) ==="
[[ "$YV" == "$RECORDED_YOSYS_VERSION" && "$NV" == "$RECORDED_NEXTPNR_VERSION" ]] || {
    echo "toolchain version mismatch" >&2; exit 1; }

# 2. fabric model (pinned FABulous, throwaway venv) + harness pad overlay
FABULOUS_SKIP_TILE_REPLAY=1 "$REPO/flow/fabulous.sh" >"$BUILD/fabulous-for-blinky.out" 2>&1 || {
    echo "flow/fabulous.sh failed:" >&2; tail -20 "$BUILD/fabulous-for-blinky.out" >&2; exit 1; }

rm -rf "$W"; mkdir -p "$W"
python3 "$REPO/flow/nextpnr_io_overlay.py" "$BUILD/fabulous-run/.FABulous" "$W/io-model/.FABulous"

# 3. synth + place + route (registered path as flow/nextpnr.sh's top_reg.v;
#    fixed seed so the recorded result is reproducible. Seed 2 is recorded
#    because the seed-0 placement routes the feedback net onto two branches
#    whose loopback twin makes one S1BEG0 mux select redundant (a flip of it
#    survives the bench's perturbation sweep); at seed 2 every flip of every
#    used bit is detected.)
{
echo "\$ yosys -p 'synth_fabulous -top top -ff \$_SDFFE_PP0P_ x -extra-plib prims.v -extra-plib io_prims.v -extra-map io_map.v -extra-map ff_map.v -cells-map cells_map.v -json blinky.json' blinky.v"
yosys -q -p "synth_fabulous -top top -ff \$_SDFFE_PP0P_ x -extra-plib $SRC/prims.v -extra-plib $SRC/io_prims.v -extra-map $SRC/io_map.v -extra-map $SRC/ff_map.v -cells-map $SRC/cells_map.v -json $W/blinky.raw.json" "$SRC/blinky.v"
python3 - "$W/blinky.raw.json" "$W/blinky.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["modules"]["top"]
bits = set(m["ports"]["clk"]["bits"])
assert not any(bits & set(b) for c in m["cells"].values() for b in c["connections"].values()), "clk is connected to a cell"
del m["ports"]["clk"]
json.dump(d, open(sys.argv[2], "w"))
print("stripped the unconnected top-level port clk (implicit UserCLK)")
PY
echo "\$ FAB_ROOT=<blinky-run>/io-model nextpnr-generic --uarch fabulous --json blinky.json -o pcf=blinky.pcf -o fasm=blinky.fasm --seed 2"
FAB_ROOT="$W/io-model" nextpnr-generic --uarch fabulous --json "$W/blinky.json" \
    -o pcf="$SRC/blinky.pcf" -o fasm="$W/blinky.fasm" --write "$W/blinky.post.json" --seed 2
} >"$W/run.log" 2>&1 || { echo "yosys/nextpnr FAILED on blinky.v; see $W/run.log" >&2; tail -20 "$W/run.log" >&2; exit 1; }
grep -q "Routing complete" "$W/run.log" || { echo "blinky did not route; see $W/run.log" >&2; tail -20 "$W/run.log" >&2; exit 1; }
grep -q "Program finished normally" "$W/run.log" || { echo "nextpnr did not finish normally; see $W/run.log" >&2; tail -20 "$W/run.log" >&2; exit 1; }
grep -E "^(Info: Device utilisation|^Info: Max frequency|Info: Critical path)" "$W/run.log" || true

# 4. spec snapshot + FASM -> frame stream (== FABulous bit_gen, byte-identical)
PYV="$BUILD/fab-venv/bin/python"
"$PYV" "$TOOL" snapshot --spec "$BUILD/fabulous-run/.FABulous/bitStreamSpec.bin" \
    --configmem "$BUILD/fabulous-run/Tile/LOGIC4/LOGIC4_ConfigMem.v" \
    --pips "$W/io-model/.FABulous/pips.txt" --out "$W" \
    --fabulous-version "$("$PYV" -c 'import importlib.metadata as m; print(m.version("fabulous-fpga"))')"
cmp "$W/logic4_configmem.map" "$REPO/sim/bitstream/logic4_configmem.map" || {
    echo "error: regenerated ConfigMem map differs from committed sim/bitstream/logic4_configmem.map (model drift)" >&2; exit 1; }
cmp "$W/fabric_spec.json" "$REPO/sim/bitstream/fabric_spec.json" || {
    echo "error: regenerated bitstream spec differs from committed sim/bitstream/fabric_spec.json (model drift)" >&2; exit 1; }
python3 "$TOOL" summary "$W/blinky.post.json" --out "$W/blinky.mapped.json"
python3 "$TOOL" assemble --fasm "$W/blinky.fasm" --snapshot "$W/fabric_spec.json" \
    --mapped "$W/blinky.mapped.json" --out "$W/blinky" --filtered-fasm "$W/blinky.logic.fasm"
"$BUILD/fab-venv/bin/bit_gen" genBitstream "$W/blinky.logic.fasm" \
    "$BUILD/fabulous-run/.FABulous/bitStreamSpec.bin" "$W/blinky.fabulous.bin" >/dev/null 2>&1
cmp "$W/blinky.bin" "$W/blinky.fabulous.bin"
echo "bit_gen genBitstream (FABulous) output is byte-identical to the assembler's (blinky.bin)"
echo "blinky.bin sha256 $(sha256sum "$W/blinky.bin" | cut -d' ' -f1)"

# 5. load into the simulated tile; the bench is self-checking (+mutate)
TB="$W/tb_logic_tile_bitstream.vvp"
iverilog -g2012 -Wall -I "$REPO/sim" -o "$TB" \
    "$REPO/design/rtl/lut4_slice.v" "$REPO/design/rtl/logic_tile_switch_matrix.v" \
    "$REPO/design/rtl/logic_tile_routed.v" "$REPO/sim/tb_logic_tile_bitstream.v"
rc=0
gs_run_bounded "blinky.bin[blinky]" "$W/blinky-sim.log" \
    vvp "$TB" +bin="$W/blinky.bin" +map="$W/logic4_configmem.map" \
    +wiring="$W/blinky.wiring" +design=blinky +mutate || rc=$?
v="$(gs_classify "$rc" "$W/blinky-sim.log" tb_logic_tile_bitstream blinky)"
if [[ "$v" != "PASS" ]]; then
    if [[ "$v" == "FUNC_FAIL" ]]; then
        echo "error: blinky FAILED its self-checks (see $W/blinky-sim.log):" >&2
    else
        echo "error: blinky simulation did not complete (INFRA; see $W/blinky-sim.log):" >&2
    fi
    grep -E '^(FAIL|TIMEOUT|  mismatch|  SURVIVED)' "$W/blinky-sim.log" | head -15 >&2 || true
    exit 1
fi
# three-way cfg cross-check: simulation loader == python decoder == recorded cfg
sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$W/blinky-sim.log" | cut -d= -f2)"
py_cfg="$(python3 "$TOOL" decode "$W/blinky.bin" --snapshot "$W/fabric_spec.json")"
rec_cfg="$(tr -d '\n' < "$W/blinky.cfg")"
if [[ -z "$sim_cfg" || "$sim_cfg" != "$py_cfg" || "$sim_cfg" != "$rec_cfg" ]]; then
    echo "error: cfg cross-check mismatch (sim loader '$sim_cfg' / python decoder '$py_cfg' / recorded '$rec_cfg')" >&2
    exit 1
fi
grep -E "^(PASS|baseline)" "$W/blinky-sim.log"
echo "=== blinky PASS: RTL -> FASM -> frame stream -> simulated blink ($SECONDS s wall clock, tools $([[ "$FETCHED" -eq 1 ]] && echo fetched-this-run || echo cached)) ==="
