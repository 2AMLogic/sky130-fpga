#!/usr/bin/env bash
# flow/functional-verification.sh
#
# Produce the `klt functional-verification` envelope T1 item 5 (digital)
# cites next to the multi-corner STA envelope: a cocotb regression
# (sim/cocotb/test_bitstream_fabric.py) that loads the committed FABulous
# frame streams (sim/bitstream/*.bin) into design/rtl/logic_tile_routed.v and
# checks the mapped designs' function against independent oracles -- see that
# file's header for scope. Issue #228.
#
# The verdict and every count come from the run's own results.xml (klt derives
# them; nothing here writes pass/fail). Only the machine-local fields are
# normalised before the envelope is committed: `environment.{results_xml,
# test_log,build_log}` become bare file names and each test's `real_time_s`
# (wall clock) becomes 0.0. Everything else -- status, counts, test names,
# `sim_time_ns`, engine/cocotb versions, seed -- is kept as klt wrote it.
#
# klt needs cocotb, which the host/CI klt does not carry, so this runs klt in
# a throwaway env (never installs into the host): set KLT_FV_CMD to override.
#
# Usage:
#   ./flow/functional-verification.sh            # run, diff against the committed envelope
#   ./flow/functional-verification.sh --update   # run, rewrite signoff/item-5-functional-verification.json
#
# Exit 0 iff the regression passes and (check mode) the envelope is unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUEST="$REPO_ROOT/sim/cocotb/fv_request.json"
COMMITTED="$REPO_ROOT/signoff/item-5-functional-verification.json"
BUILD_DIR="$SCRIPT_DIR/build/functional-verification"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    "") ;;
    *) echo "usage: $0 [--update]" >&2; exit 1 ;;
esac

KLT_FV_CMD="${KLT_FV_CMD:-uvx --from klayout-tools[functional-verification]==0.8.0 klt}"
command -v iverilog >/dev/null 2>&1 || { echo "error: iverilog not found on PATH" >&2; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
RAW="$BUILD_DIR/response.json"

set +e
# shellcheck disable=SC2086
$KLT_FV_CMD functional-verification "$REQUEST" -o "$BUILD_DIR/run" --format json >"$RAW"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
    echo "error: klt functional-verification exited $rc (see $RAW)" >&2
    exit 1
fi

TRIMMED="$BUILD_DIR/item-5-functional-verification.json"
python3 - "$RAW" "$TRIMMED" <<'PY'
import json, os, sys

env = json.load(open(sys.argv[1]))
if env.get("status") != "pass" or env.get("failed_count") != 0:
    sys.exit("error: regression did not pass; refusing to record it")
for key in ("results_xml", "test_log", "build_log"):
    if env["environment"].get(key):
        env["environment"][key] = os.path.basename(env["environment"][key])
for t in env["tests"]:
    t["real_time_s"] = 0.0
with open(sys.argv[2], "w") as f:
    json.dump(env, f, indent=2, sort_keys=True)
    f.write("\n")
PY

if [[ "$MODE" == "update" ]]; then
    cp "$TRIMMED" "$COMMITTED"
    echo "=== functional-verification envelope written to $COMMITTED ==="
    exit 0
fi
if ! diff -u "$COMMITTED" "$TRIMMED"; then
    echo "error: regenerated envelope differs from $COMMITTED; run '$0 --update'" >&2
    exit 1
fi
echo "=== functional-verification envelope reproduces the committed copy ==="
