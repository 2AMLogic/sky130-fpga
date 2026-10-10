#!/usr/bin/env bash
# flow/nextpnr.sh -- run yosys + nextpnr-generic (--uarch fabulous) against the
# nextpnr model FABulous generated for the LOGIC4 tile.
#
# Spec gap G1 caveat 1 (spec/framework-gaps.md, issue #87). Steps:
#   1. flow/fabulous.sh regenerates the model into flow/build/fabulous-run/.
#   2. The pinned OSS CAD Suite (flow/tool_versions.sh) is downloaded to
#      flow/build/dl/, sha256-verified, and unpacked (tool subset only) into
#      flow/build/oss-cad-suite/. Nothing is installed host-wide.
#      On later runs the unpacked tree is reused if its .pin stamp matches the
#      pinned sha256 and, when the tarball is still in flow/build/dl/, the
#      tarball re-verifies; otherwise it is re-fetched/re-extracted. The yosys
#      and nextpnr version strings are checked against the pins on every run.
#   3. yosys reads design/fabulous/nextpnr/top.v (+ prims.v) -> JSON, then
#      nextpnr-generic places and routes it on the generated model.
#   4. Two expected-FAIL probes record the fabric's known limits:
#      top_ports.v (top-level ports; no IO BEL -> "must be PAD") and
#      top_const.v (a tied-off LUT input; no constant driver -> "Failed to
#      find a route ... $PACKER_GND").
#   5. ADR-0005 (spec/decisions/0005-*.md): top_io.v -- top-level ports on
#      harness pad BELs (flow/nextpnr_io_overlay.py, scratch copy of the model;
#      not a tile type) and constants folded into the LUT truth table -- packs,
#      places and routes; a check asserts no cell pin uses $PACKER_GND/VCC.
#   * writes design/fabulous/nextpnr.log (committed evidence), and
#   * checks the FASM carries the expected LUT truth table.
#
#   6. Issue #74: top_reg.v (a registered LUT: sync reset over clock enable, EN
#      and SR routed as real nets) on the same pad model; its FASM is the
#      input of flow/fasm_to_bitstream.py (see flow/bitstream.sh).
#
# What this does NOT claim: bitstream assembly/simulation is experimental
# harness coverage only (flow/bitstream.sh, sim/), no timing (placeholder delays). See design/README.md for the IO/const findings.
#
# Usage: flow/nextpnr.sh [--update-log]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=flow/tool_versions.sh
source "$REPO/flow/tool_versions.sh"
BUILD="$REPO/flow/build"
OSS="$BUILD/oss-cad-suite"
mkdir -p "$BUILD/dl"

# Only the regenerated model is needed here; the ~2 min integrated generated-tile
# replay (issue #140) is run by a direct flow/fabulous.sh invocation, not repeated
# for every nextpnr/bitstream/corpus run (fabulous.sh prints that it was skipped).
FABULOUS_SKIP_TILE_REPLAY=1 "$REPO/flow/fabulous.sh" >"$BUILD/fabulous-for-nextpnr.out" 2>&1 || {
    echo "flow/fabulous.sh failed:" >&2; tail -20 "$BUILD/fabulous-for-nextpnr.out" >&2; exit 1; }

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
fi
export PATH="$OSS/bin:$PATH"
YV="$(yosys -V | awk '{print $2}')"
NV="$(nextpnr-generic --version 2>&1 | grep -o 'nextpnr-[0-9][^)" ]*' | head -1)"
echo "=== yosys $YV (pinned $RECORDED_YOSYS_VERSION), $NV (pinned $RECORDED_NEXTPNR_VERSION) ==="
[[ "$YV" == "$RECORDED_YOSYS_VERSION" && "$NV" == "$RECORDED_NEXTPNR_VERSION" ]] || {
    echo "toolchain version mismatch" >&2; exit 1; }

SRC="$REPO/design/fabulous/nextpnr"
W="$BUILD/nextpnr-run"
rm -rf "$W"; mkdir -p "$W"
RAW="$W/raw.log"
{
echo "# flow/nextpnr.sh: yosys $YV / $NV"
echo "# model: flow/fabulous.sh output (.FABulous/{bel.v3,pips}.txt of the LOGIC4 fabric)"
echo "\$ yosys -p 'synth_fabulous -top top -noiopad -extra-plib prims.v -json top.json' top.v"
yosys -q -p "synth_fabulous -top top -noiopad -extra-plib $SRC/prims.v -json $W/top.json" "$SRC/top.v"
echo "\$ FAB_ROOT=<fabulous-run> nextpnr-generic --uarch fabulous --json top.json -o fasm=top.fasm"
FAB_ROOT="$BUILD/fabulous-run" nextpnr-generic --uarch fabulous --json "$W/top.json" \
    -o fasm="$W/top.fasm"
echo "# --- top.fasm ---"
cat "$W/top.fasm"
# ADR-0005 scheme: top-level ports on harness pad BELs + constants folded.
echo "# --- ADR-0005 design: top_io.v (ports + constant-folded LUTs) ---"
echo "\$ nextpnr_io_overlay.py <fabulous-run>/.FABulous <run>/io-model/.FABulous   (harness pad model)"
python3 "$REPO/flow/nextpnr_io_overlay.py" "$BUILD/fabulous-run/.FABulous" "$W/io-model/.FABulous"
echo "\$ yosys -p 'synth_fabulous -top top -extra-plib prims.v -extra-plib io_prims.v -extra-map io_map.v -cells-map cells_map.v -json top_io.json' top_io.v"
yosys -q -p "synth_fabulous -top top -extra-plib $SRC/prims.v -extra-plib $SRC/io_prims.v -extra-map $SRC/io_map.v -cells-map $SRC/cells_map.v -json $W/top_io.json" "$SRC/top_io.v"
echo "\$ FAB_ROOT=<run>/io-model nextpnr-generic --uarch fabulous --json top_io.json -o pcf=top_io.pcf -o fasm=top_io.fasm"
FAB_ROOT="$W/io-model" nextpnr-generic --uarch fabulous --json "$W/top_io.json" \
    -o pcf="$SRC/top_io.pcf" -o fasm="$W/top_io.fasm" --write "$W/top_io.post.json"
echo "# --- top_io.fasm ---"
cat "$W/top_io.fasm"
# Issue #74: registered example on the same pad model. The flop maps onto a
# second BEL (FF=1) so EN/SR are routed nets. `clk` is the BEL's implicit
# UserCLK (no fabric pin, no pad): strip the unconnected top port from the JSON.
echo "# --- issue #74 registered design: top_reg.v (EN/SR routed, clk implicit) ---"
echo "\$ yosys -p 'synth_fabulous -top top -ff \$_SDFFE_PP0P_ x -extra-plib prims.v -extra-plib io_prims.v -extra-map io_map.v -extra-map ff_map.v -cells-map cells_map.v -json top_reg.json' top_reg.v"
yosys -q -p "synth_fabulous -top top -ff \$_SDFFE_PP0P_ x -extra-plib $SRC/prims.v -extra-plib $SRC/io_prims.v -extra-map $SRC/io_map.v -extra-map $SRC/ff_map.v -cells-map $SRC/cells_map.v -json $W/top_reg.raw.json" "$SRC/top_reg.v"
python3 - "$W/top_reg.raw.json" "$W/top_reg.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = d["modules"]["top"]
bits = set(m["ports"]["clk"]["bits"])
assert not any(bits & set(b) for c in m["cells"].values() for b in c["connections"].values()), "clk is connected to a cell"
del m["ports"]["clk"]
json.dump(d, open(sys.argv[2], "w"))
print("stripped the unconnected top-level port clk (implicit UserCLK)")
PY
echo "\$ FAB_ROOT=<run>/io-model nextpnr-generic --uarch fabulous --json top_reg.json -o pcf=top_reg.pcf -o fasm=top_reg.fasm"
FAB_ROOT="$W/io-model" nextpnr-generic --uarch fabulous --json "$W/top_reg.json" \
    -o pcf="$SRC/top_reg.pcf" -o fasm="$W/top_reg.fasm" --write "$W/top_reg.post.json"
echo "# --- top_reg.fasm ---"
cat "$W/top_reg.fasm"
} >"$RAW" 2>&1 || { echo "yosys/nextpnr FAILED; see $RAW" >&2; tail -20 "$RAW" >&2; exit 1; }

# Expected-FAIL probes. Each must fail in nextpnr with the recorded message;
# yosys must still succeed (its output is shown if it does not).
probe() {  # probe <name> <src.v> <expected-regex> <description> [extra yosys args]
    local name="$1" src="$2" expect="$3" desc="$4" extra="${5:-}" plog="$W/probe-$1.log"
    echo "# --- probe (expected FAIL): $(basename "$src"), $desc ---" >"$plog"
    # shellcheck disable=SC2086
    yosys -q -p "synth_fabulous -top top -noiopad -extra-plib $SRC/prims.v $extra -json $W/$name.json" \
        "$src" >>"$plog" 2>&1 || {
        echo "yosys failed on probe $name:" >&2; cat "$plog" >&2; exit 1; }
    if FAB_ROOT="$BUILD/fabulous-run" nextpnr-generic --uarch fabulous --json "$W/$name.json" \
           -o fasm="$W/$name.fasm" >"$W/probe-$name.np.log" 2>&1; then
        echo "probe $name unexpectedly PASSED in nextpnr" >&2; exit 1
    fi
    grep -v 'iteration #' "$W/probe-$name.np.log" | grep -E 'ERROR|[0-9]+ errors?$|Failed to find a route' >>"$plog" || true
    grep -q -E "$expect" "$plog" || {
        echo "probe $name did not fail as recorded (want /$expect/)" >&2
        cat "$plog" >&2; tail -20 "$W/probe-$name.np.log" >&2; exit 1; }
    cat "$plog" >>"$RAW"
}
# No IO BEL: the same function with top-level ports cannot be packed.
probe ports "$SRC/top_ports.v" "must be PAD" \
    "4-input function on top-level ports" "-cells-map $SRC/cells_map.v"
# No constant driver: top.v with u0.I1 tied to 1'b0 packs a $PACKER_GND net
# that the router cannot reach.
probe const "$SRC/top_const.v" 'Failed to find a route .*\$PACKER_GND' \
    "top.v with one LUT input tied to 1'b0"
grep -q "Routing design failed" "$W/probe-const.log"

grep -q "Routing complete" "$RAW"
# ADR-0005 constant check: nextpnr always creates the $PACKER_GND/VCC nets and
# their driver cells; what must not survive packing is any *sink* on them.
python3 - "$W/top_io.post.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["modules"]["top"]
bits = {b for n in ("$PACKER_GND", "$PACKER_VCC") for b in d["netnames"][n]["bits"]}
users = [(c, p) for c, v in d["cells"].items() if not c.endswith("_DRV")
         for p, bs in v["connections"].items() if bits & set(bs)]
if users:
    sys.exit("constant driver needed by: %s" % users)
print("no cell pin uses $PACKER_GND/$PACKER_VCC")
PY
# Same check for the registered design: the FF BEL's EN/SR are routed nets.
python3 - "$W/top_reg.post.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["modules"]["top"]
bits = {b for n in ("$PACKER_GND", "$PACKER_VCC") for b in d["netnames"][n]["bits"]}
users = [(c, p) for c, v in d["cells"].items() if not c.endswith("_DRV")
         for p, bs in v["connections"].items() if bits & set(bs)]
if users:
    sys.exit("constant driver needed by: %s" % users)
ffs = {c: v for c, v in d["cells"].items() if v["parameters"].get("FF") == "1"}
assert len(ffs) == 1, ffs
for c, v in ffs.items():
    for p in ("EN", "SR", "I0"):
        assert v["connections"].get(p) and "x" not in map(str, v["connections"][p]), (c, p)
print("registered design: no constant sinks; FF BEL has routed EN, SR, I0")
PY
grep -q "Program finished normally" "$RAW"
# parity LUT: INIT = 16'h6996
grep -q "A.INIT\[15:0\] = 'b0110100110010110" "$W/top.fasm"

NORM="$BUILD/nextpnr-norm.log"
sed -e "s#$SRC/#<nextpnr-src>/#g" -e "s#$BUILD/fabulous-run#<fabulous-run>#g" -e "s#$W#<run>#g" "$RAW" \
  | grep -v -E 'iteration #|^Info: .*([Tt]ime|Checksum)' >"$NORM"

if [[ "${1:-}" == "--update-log" ]]; then
    cp "$NORM" "$REPO/design/fabulous/nextpnr.log"
    echo "updated design/fabulous/nextpnr.log"
elif ! diff -u "$REPO/design/fabulous/nextpnr.log" "$NORM"; then
    echo "nextpnr log differs from committed design/fabulous/nextpnr.log" >&2
    exit 1
else
    echo "nextpnr log matches committed copy"
fi
