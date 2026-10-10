#!/usr/bin/env bash
# flow/pin_experiment.sh -- opt-in LUT pin-index experiment (issue #137).
#
# Compares the unchanged synthesized `fan4` netlist with a deterministic
# LUT-input-pin-aligned variant (INIT permuted identically, equivalence proven
# exhaustively before routing) under the same pcf/seeds/budget/router. Separate
# from flow/corpus.sh: it changes no corpus expectation and no committed fixture.
# `--case regcasc` (issue #160) runs the registered case through the bounded
# one-register transition-equivalence gate before routing; unsupported
# sequential shapes stop before routing.
# See design/fabulous/corpus/pin_experiment.md. Prerequisites as flow/corpus.sh.
#
# Usage: flow/pin_experiment.sh [--append-record FILE] [--case fan4|regcasc] [--export-fixtures [DIR]]  (issue #145: opt-in fixture export, fan4 only)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in iverilog vvp python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: $t not found on PATH; experiment NOT RUN" >&2; exit 2; }
done
ok=0
for attempt in 1 2 3; do
    if "$REPO/flow/bitstream.sh" >"$REPO/flow/build/pin-experiment-prereq.log" 2>&1; then ok=1; break; fi
    echo "note: flow/bitstream.sh attempt $attempt failed" >&2
done
[[ "$ok" -eq 1 ]] || { echo "error: flow/bitstream.sh failed 3 times" >&2
    tail -15 "$REPO/flow/build/pin-experiment-prereq.log" >&2; exit 2; }
exec python3 "$REPO/flow/pin_experiment.py" "$@"
