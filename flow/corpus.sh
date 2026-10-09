#!/usr/bin/env bash
# flow/corpus.sh -- bounded single-tile routability corpus (issue #115).
#
# EXPERIMENTAL decision evidence for ADR-0004 item 3 (same-index vs
# Wilton-class population): maps the small explicit corpus in
# design/fabulous/corpus/ onto the single-LOGIC4 harness (scratch pad overlay,
# current CAP cells, same-index matrix) with the pinned yosys/nextpnr for a
# recorded seed set, classifies each run (success / route_fail /
# capacity_packing; tool and synthesis problems are failures of the run, not
# measurements), and for every success assembles the real bitstream, checks it
# byte-for-byte against FABulous `bit_gen genBitstream` and simulates it
# against an independent oracle (sim/tb_logic_tile_bitstream.v).
#
# Steps: flow/bitstream.sh (prepares the pinned toolchain + model and checks
# the existing baseline fixtures), then flow/corpus_run.py. Needs the
# prerequisites of flow/nextpnr.sh plus Icarus Verilog (iverilog/vvp). Nothing
# is installed host-wide.
#
# Usage: flow/corpus.sh [--update] [--append-record FILE] [--cases a,b]
#   --update          rewrite the committed sim/bitstream/corpus/ fixtures
#   --append-record   append a dated record (see design/fabulous/corpus/results.txt)
# Exit status 0 only if every outcome matches design/fabulous/corpus/corpus.json
# and the baseline cases succeed (otherwise: evidence review required).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in iverilog vvp python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: $t not found on PATH; corpus verification NOT RUN" >&2; exit 2; }
done
# flow/nextpnr.sh diffs a log that embeds placer sub-timings ("... 0.00s"); on a
# loaded shared host one of those can read 0.01s and trip the diff. Retry the
# prerequisite step a bounded number of times before calling it a failure.
ok=0
for attempt in 1 2 3; do
    if "$REPO/flow/bitstream.sh" >"$REPO/flow/build/corpus-prereq.log" 2>&1; then ok=1; break; fi
    echo "note: flow/bitstream.sh attempt $attempt failed" >&2
done
[[ "$ok" -eq 1 ]] || {
    echo "error: flow/bitstream.sh (toolchain/baseline) failed 3 times:" >&2
    tail -15 "$REPO/flow/build/corpus-prereq.log" >&2; exit 2; }
exec python3 "$REPO/flow/corpus_run.py" "$@"
