#!/usr/bin/env bash
# flow/nextpnr.sh -- run yosys + nextpnr-generic (--uarch fabulous) against the
# nextpnr model FABulous generated for the LOGIC4 tile.
#
# Spec gap G1 caveat 1 (spec/framework-gaps.md, issue #87). Steps:
#   1. flow/fabulous.sh regenerates the model into flow/build/fabulous-run/.
#   2. The pinned OSS CAD Suite (flow/tool_versions.sh) is downloaded to
#      flow/build/dl/, sha256-verified, and unpacked (tool subset only) into
#      flow/build/oss-cad-suite/. Nothing is installed host-wide.
#   3. yosys reads design/fabulous/nextpnr/top.v (+ prims.v) -> JSON, then
#      nextpnr-generic places and routes it on the generated model.
#   * writes design/fabulous/nextpnr.log (committed evidence), and
#   * checks the FASM carries the expected LUT truth table.
#
# What this does NOT claim: no bitstream is assembled or simulated (G5), no
# timing (placeholder delays). See design/README.md for the IO/const findings.
#
# Usage: flow/nextpnr.sh [--update-log]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=flow/tool_versions.sh
source "$REPO/flow/tool_versions.sh"
BUILD="$REPO/flow/build"
OSS="$BUILD/oss-cad-suite"
mkdir -p "$BUILD/dl"

"$REPO/flow/fabulous.sh" >"$BUILD/fabulous-for-nextpnr.out" 2>&1 || {
    echo "flow/fabulous.sh failed:" >&2; tail -20 "$BUILD/fabulous-for-nextpnr.out" >&2; exit 1; }

if [[ ! -x "$OSS/bin/nextpnr-generic" ]] || \
   [[ ! -f "$OSS/.pin" ]] || [[ "$(cat "$OSS/.pin")" != "$RECORDED_OSS_CAD_SHA256" ]]; then
    TGZ="$BUILD/dl/$RECORDED_OSS_CAD_TARBALL"
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
} >"$RAW" 2>&1 || { echo "yosys/nextpnr FAILED; see $RAW" >&2; tail -20 "$RAW" >&2; exit 1; }

# Expected-FAIL probe: same function with top-level ports (no IO BEL in the fabric).
{
echo "# --- probe (expected FAIL): top_ports.v, 4-input function on top-level ports ---"
yosys -q -p "synth_fabulous -top top -noiopad -extra-plib $SRC/prims.v -cells-map $SRC/cells_map.v -json $W/ports.json" "$SRC/top_ports.v"
if FAB_ROOT="$BUILD/fabulous-run" nextpnr-generic --uarch fabulous --json "$W/ports.json" \
       -o fasm="$W/ports.fasm" 2>&1 | grep -v 'iteration #' | grep -E 'ERROR|errors'; then :; fi
} >"$W/probe.log" 2>&1
grep -q "must be PAD" "$W/probe.log" || { echo "IO probe did not fail as recorded" >&2; cat "$W/probe.log" >&2; exit 1; }
cat "$W/probe.log" >>"$RAW"

grep -q "Routing complete" "$RAW"
grep -q "Program finished normally" "$RAW"
# parity LUT: INIT = 16'h6996
grep -q "A.INIT\[15:0\] = 'b0110100110010110" "$W/top.fasm"

NORM="$BUILD/nextpnr-norm.log"
sed -e "s#$BUILD/fabulous-run#<fabulous-run>#g" -e "s#$W#<run>#g" "$RAW" \
  | grep -v -E 'iteration #|time|Time|Checksum' >"$NORM"

if [[ "${1:-}" == "--update-log" ]]; then
    cp "$NORM" "$REPO/design/fabulous/nextpnr.log"
    echo "updated design/fabulous/nextpnr.log"
elif ! diff -u "$REPO/design/fabulous/nextpnr.log" "$NORM"; then
    echo "nextpnr log differs from committed design/fabulous/nextpnr.log" >&2
    exit 1
else
    echo "nextpnr log matches committed copy"
fi
