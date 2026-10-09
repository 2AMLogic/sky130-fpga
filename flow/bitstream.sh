#!/usr/bin/env bash
# flow/bitstream.sh -- regenerate / check the committed bitstream fixtures in
# sim/bitstream/ from the pinned mapper (issue #74; EXPERIMENTAL single-LOGIC4
# harness, see sim/README.md).
#
#   1. flow/nextpnr.sh   pinned FABulous 2.2.0 + yosys/nextpnr (OSS CAD Suite,
#                        flow/tool_versions.sh): generates the fabric model and
#                        maps top_io.v (combinational) and top_reg.v
#                        (registered, EN/SR routed) to FASM + routed JSON.
#   2. fasm_to_bitstream.py snapshot   freeze bitStreamSpec / ConfigMem / pips.
#   3. fasm_to_bitstream.py summary + assemble   FASM -> frame stream,
#                        wiring manifest, decoded cfg; every FASM line is
#                        accounted for and cross-checked with the routed JSON.
#   4. FABulous's own `bit_gen genBitstream` (venv, flow/build/fab-venv) must
#      produce a byte-identical stream from the same FASM (pad pips removed).
#   5. fixtures compared with the committed sim/bitstream/ (exit 1 on drift),
#      or rewritten with --update.
#
# Nothing is installed host-wide (everything lives under flow/build/).
# Usage: flow/bitstream.sh [--update]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/flow/build"
FIX="$REPO/sim/bitstream"
OUT="$BUILD/bitstream-run"
PY="$BUILD/fab-venv/bin/python"
TOOL="$REPO/flow/fasm_to_bitstream.py"

"$REPO/flow/nextpnr.sh" | tail -3
W="$BUILD/nextpnr-run"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "=== snapshot of the generated spec / ConfigMem / pip model ==="
"$PY" "$TOOL" snapshot --spec "$BUILD/fabulous-run/.FABulous/bitStreamSpec.bin" \
    --configmem "$BUILD/fabulous-run/Tile/LOGIC4/LOGIC4_ConfigMem.v" \
    --pips "$W/io-model/.FABulous/pips.txt" --out "$OUT" --fabulous-version "$("$PY" -c 'import importlib.metadata as m; print(m.version("fabulous-fpga"))')"

for d in top_io top_reg; do
    echo "=== $d ==="
    cp "$W/$d.fasm" "$OUT/$d.fasm"
    python3 "$TOOL" summary "$W/$d.post.json" --out "$OUT/$d.mapped.json"
    python3 "$TOOL" assemble --fasm "$OUT/$d.fasm" --snapshot "$OUT/fabric_spec.json" \
        --mapped "$OUT/$d.mapped.json" --out "$OUT/$d" --filtered-fasm "$OUT/$d.logic.fasm"
    "$BUILD/fab-venv/bin/bit_gen" genBitstream "$OUT/$d.logic.fasm" \
        "$BUILD/fabulous-run/.FABulous/bitStreamSpec.bin" "$OUT/$d.fabulous.bin" >/dev/null 2>&1
    cmp "$OUT/$d.bin" "$OUT/$d.fabulous.bin"
    echo "bit_gen genBitstream (FABulous) output is byte-identical to the assembler's ($d.bin)"
    sha="$(sha256sum "$OUT/$d.bin" | cut -d' ' -f1)"
    echo "$d.bin sha256 $sha"
done

FILES="fabric_spec.json logic4_configmem.map top_io.fasm top_io.mapped.json top_io.bin top_io.wiring top_io.cfg top_reg.fasm top_reg.mapped.json top_reg.bin top_reg.wiring top_reg.cfg"
if [[ "${1:-}" == "--update" ]]; then
    mkdir -p "$FIX"
    for f in $FILES; do cp "$OUT/$f" "$FIX/$f"; done
    echo "updated sim/bitstream/"
else
    drift=0
    for f in $FILES; do
        cmp -s "$OUT/$f" "$FIX/$f" || { echo "DRIFT: sim/bitstream/$f differs from the regenerated copy" >&2; drift=1; }
    done
    [[ "$drift" -eq 0 ]] || exit 1
    echo "regenerated fixtures match the committed sim/bitstream/"
fi
python3 "$TOOL" check "$FIX"
