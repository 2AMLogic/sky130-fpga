#!/usr/bin/env bash
# sim/pin_fixture_negative.sh   (issue #145, EXPERIMENTAL)
#
# Negative tests for sim/pin_fixture_replay.sh: each scratch-copy defect MUST make
# the replay fail. The committed fixtures are never modified.
#   N-a  one fixture file deleted                       -> static gate fails
#   N-b  empty index                                    -> static gate fails
#   N-c  function-changing LUT config corruption (all 16 INIT bits of BEL A
#        inverted in every .bin/.cfg, index sha256 refreshed so the sha gate is
#        satisfied): the full replay must fail (assembler reproduction), AND with
#        the static assembler check skipped (--sim-only) the SIMULATION ORACLE
#        itself must reject every corrupted stream
#
#   sim/pin_fixture_negative.sh <compiled.vvp> <label>
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VVP_BIN="${1:?usage: pin_fixture_negative.sh <compiled.vvp> <label>}"
LABEL="${2:?label required}"
GOOD="$SCRIPT_DIR/bitstream/pin_experiment"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pin_fixture_negative.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export PIN_REPLAY_LOG_DIR="$WORK/logs"
status=0

expect_fail() {  # expect_fail <name> <fixture-dir> [replay flags...]
    local name="$1" dir="$2"; shift 2
    local out
    if out="$(PIN_FIXTURE_DIR="$dir" "$SCRIPT_DIR/pin_fixture_replay.sh" "$VVP_BIN" "$LABEL" "$@" 2>&1)"; then
        echo "error: pin-experiment negative $name [$LABEL] was ACCEPTED" >&2; status=1
    else
        echo "pin-experiment negative $name [$LABEL] OK: rejected -> $(grep -m1 -E 'error:|: FAIL' <<<"$out")"
        echo "$out" | grep -E "replayed" | sed 's/^/    /'
    fi
}

cp -r "$GOOD" "$WORK/missing"; rm "$WORK/missing/fan4_distinct_s2.bin"
expect_fail "N-a missing fixture file" "$WORK/missing"

cp -r "$GOOD" "$WORK/emptyidx"; : > "$WORK/emptyidx/index.json"
expect_fail "N-b empty index" "$WORK/emptyidx"

if python3 -I "$REPO_ROOT/flow/pin_fixtures.py" corrupt "$GOOD" "$WORK/corrupt" --bel 0; then
    expect_fail "N-c corrupted LUT INIT (full replay)" "$WORK/corrupt"
    expect_fail "N-c corrupted LUT INIT (simulation oracle only)" "$WORK/corrupt" --sim-only
    # the oracle must have flagged all three streams, not merely failed elsewhere
    nfail="$(PIN_FIXTURE_DIR="$WORK/corrupt" "$SCRIPT_DIR/pin_fixture_replay.sh" "$VVP_BIN" "$LABEL" --sim-only 2>&1 | grep -c 'no terminal PASS verdict')"
    if [[ "$nfail" -eq 3 ]]; then echo "pin-experiment negative N-c [$LABEL]: simulation oracle rejected 3/3 corrupted streams"
    else echo "error: oracle rejected only $nfail/3 corrupted streams" >&2; status=1; fi
else
    echo "error: could not create corrupted scratch copy" >&2; status=1
fi
exit "$status"
