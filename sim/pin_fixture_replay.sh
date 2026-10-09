#!/usr/bin/env bash
# sim/pin_fixture_replay.sh   (issue #145, EXPERIMENTAL)
#
# Replay the committed pin-experiment fixture set (sim/bitstream/pin_experiment/:
# the three successful distinct-pin fan4 streams of flow/pin_experiment.py) through
# an already-compiled sim/tb_logic_tile_bitstream.v simulation, with the independent
# fan4 oracle and perturbation checks. Shared by the RTL suite (sim/run.sh) and the
# zero-delay gate suite (flow/gate-sim-bitstream.sh); needs no mapper.
#
#   sim/pin_fixture_replay.sh <compiled.vvp> <label> [--sim-only]
#
# Env: PIN_FIXTURE_DIR overrides the fixture directory (scratch negative tests only).
# Static gate (unless --sim-only, which exists solely for negative tests that need
# the simulation path to be the thing that fails): flow/pin_fixtures.py verify
# (index present/non-empty, exactly 3 cases, files present, sha256 + snapshot
# provenance, netlist relation) and flow/fasm_to_bitstream.py check (every stream
# reproduces from its FASM). Per case: vvp must exit 0 and print the recognised
# terminal PASS verdict with no FAIL line, and the loaded CFG must equal the python
# decoder and the recorded .cfg.
#
# Not a baseline-corpus expectation; no timing and no ratified-fabric claim.
# Exit: 0 iff every case passes; nonzero otherwise. Summary line:
#   pin-experiment fixtures replayed [<label>]: N/3 PASS
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VVP_BIN="${1:?usage: pin_fixture_replay.sh <compiled.vvp> <label> [--sim-only]}"
LABEL="${2:?label required}"
SIM_ONLY=0; [[ "${3:-}" == "--sim-only" ]] && SIM_ONLY=1
FIX_DIR="${PIN_FIXTURE_DIR:-$SCRIPT_DIR/bitstream/pin_experiment}"
BS_DIR="$SCRIPT_DIR/bitstream"
BS_TOOL="$REPO_ROOT/flow/fasm_to_bitstream.py"
LOG_DIR="${PIN_REPLAY_LOG_DIR:-$SCRIPT_DIR/build}/pin_experiment"
TB_NAME="tb_logic_tile_bitstream"
EXPECTED=3
mkdir -p "$LOG_DIR"
status=0

if ! cases="$(python3 -I "$REPO_ROOT/flow/pin_fixtures.py" verify "$FIX_DIR" --snapshot-dir "$BS_DIR")"; then
    echo "error: pin-experiment fixture verification failed ($FIX_DIR)" >&2
    echo "pin-experiment fixtures replayed [$LABEL]: 0/$EXPECTED PASS" >&2
    exit 1
fi
if [[ "$SIM_ONLY" -eq 0 ]]; then
    if ! python3 -I "$BS_TOOL" check "$FIX_DIR" --snapshot-dir "$BS_DIR" >"$LOG_DIR/check.log" 2>&1; then
        cat "$LOG_DIR/check.log" >&2
        echo "error: pin-experiment fixtures drifted from the assembler output" >&2
        status=1
    fi
fi

n=0; pass=0
while read -r stem oracle; do
    [[ -z "$stem" ]] && continue
    n=$((n + 1))
    log="$LOG_DIR/${stem}.log"
    if ! vvp "$VVP_BIN" +bin="$FIX_DIR/$stem.bin" +map="$BS_DIR/logic4_configmem.map" \
            +wiring="$FIX_DIR/$stem.wiring" +design="$oracle" +mutate >"$log" 2>&1; then
        echo "pin-experiment [$oracle] $stem [$LABEL]: FAIL (simulation error, see $log)" >&2
        tail -n 8 "$log" >&2; status=1; continue
    fi
    if ! grep -q "^PASS: ${TB_NAME}\[${oracle}\]" "$log" || grep -q "^FAIL" "$log"; then
        echo "pin-experiment [$oracle] $stem [$LABEL]: FAIL (no terminal PASS verdict, see $log)" >&2
        tail -n 8 "$log" >&2; status=1; continue
    fi
    sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log" | cut -d= -f2)"
    py_cfg="$(python3 -I "$BS_TOOL" decode "$FIX_DIR/$stem.bin" --snapshot "$BS_DIR/fabric_spec.json")"
    rec_cfg="$(tr -d '\n' < "$FIX_DIR/$stem.cfg")"
    if [[ -z "$sim_cfg" || "$sim_cfg" != "$py_cfg" || "$sim_cfg" != "$rec_cfg" ]]; then
        echo "pin-experiment [$oracle] $stem [$LABEL]: FAIL (cfg mismatch sim=$sim_cfg python=$py_cfg recorded=$rec_cfg)" >&2
        status=1; continue
    fi
    pass=$((pass + 1))
    echo "pin-experiment [$oracle] $stem [$LABEL]: PASS ($(grep -m1 '^PASS' "$log" | sed 's/^PASS: //'); cfg: sim == python == recorded)"
done <<< "$cases"

if [[ "$n" -ne "$EXPECTED" ]]; then
    echo "error: replayed $n cases, expected exactly $EXPECTED" >&2; status=1
fi
echo "pin-experiment fixtures replayed [$LABEL]: ${pass}/${EXPECTED} PASS"
exit "$status"
