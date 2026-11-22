#!/usr/bin/env bash
# flow/tile-functional-verification.sh
#
# The paired zero-delay vs SDF-annotated cocotb regression of the as-built
# logic_tile netlist (issue #359): the four named tile checks ported from
# sim/tb_logic_tile.v into sim/cocotb/test_logic_tile.py, run twice against
# layout/logic_tile.asbuilt.v -- once at zero delay, once with the committed
# measurements/timing-characterization/logic_tile_route.sdf back-annotated
# by `klt functional-verification` (Icarus $sdf_annotate). Both envelopes
# are committed as measurements/timing-characterization/
# logic_tile.fv-zero-delay.json / logic_tile.fv-sdf.json and are the paired
# evidence #360 consumes for the item-7 signoff decision.
#
# Why a generating harness instead of two committed request files: the
# request's `sources` include the sky130_fd_sc_hd Verilog models, whose
# absolute path is machine-local (a throwaway ciel root). The requests are
# therefore generated into flow/build/ (gitignored) with absolute paths,
# and this script is the committed, hash-pinned reproduction entry point.
#
# Model resolution follows the gate-sim.yml convention (issue #130/#269):
# the recorded PDK revision (RECORDED_PDK_VERSION in flow/tool_versions.sh)
# is not published in the ciel-releases index, so a model directory is
# accepted ONLY when its sky130_fd_sc_hd.v and primitives.v sha256 both
# equal RECORDED_PDK_MODELS_SHA256 / RECORDED_PDK_PRIMITIVES_SHA256 -- the
# same two values .github/workflows/gate-sim.yml asserts on the models it
# fetches with:
#
#   uvx --from "ciel==3.0.1" ciel enable --pdk-root <root> --pdk-family \
#       sky130 -l sky130_fd_sc_hd a492ff787163f93ce9ebc382b23c58c0de33afa3
#
# (the nearest published revision whose two model files are byte-identical
# to the recorded one's). Candidates, in order: $PDK_ROOT, then the
# `<libs_ref>/sky130_fd_sc_hd/verilog` directory `klt pdk find` resolves
# (flow/pdk_root.sh's sky130_cell_models_from_klt, issue #375 -- the
# pre-#375 inline block queried the find result's bare root, where the
# models never live, so that fallback never matched). The installed
# revision is printed alongside the two verified digests and recorded in
# the issue-#359 record.
#
# USE_POWER_PINS and FUNCTIONAL are deliberately left UNDEFINED in both
# runs: the as-built netlist carries no supply pins, and only the models'
# non-FUNCTIONAL branch keeps the specify blocks the SDF's IOPATH entries
# annotate (klt rejects options.sdf together with a FUNCTIONAL define).
# Both runs share the same engine (icarus), models, netlist, bench, seed
# and build flags; the only difference is options.sdf -- the pairing the
# comparison needs. The bench's own CLOCK_PERIOD_NS (20) and SETTLE_NS (4)
# constants are identical in both runs by construction.
#
# The verdict and every count come from klt's own envelope (itself derived
# from the run's results.xml; nothing here writes pass/fail). Only
# machine-local fields are normalised before an envelope is committed:
# environment.{results_xml,test_log,build_log} become bare file names (their
# run-to-run-volatile sha256 digests and scope are dropped -- results.xml
# and the test log embed wall-clock real_time), tests[].real_time_s becomes
# 0.0, and environment.sdf.file becomes the repo-relative path. Everything
# else -- status, counts, test names, sim_time_ns, engine/cocotb versions,
# seed, and environment.sdf's annotated/partial/renamed/dropped -- is kept
# exactly as klt wrote it.
#
# Why a second pair, the SDF settle-time probe (issue #382): the four named
# checks pass identically on both legs above, so they observe no delay -- a
# toolchain change that made the annotation a silent no-op (zero arcs
# applied, environment.sdf.annotated still true) would leave both committed
# envelopes byte-identical. The probe module
# sim/cocotb/test_logic_tile_sdf_probe.py therefore runs on the same two
# requests with only testbench.module swapped: it repeats two of the bench's
# stimuli (one registered capture, one combinational input change), reads
# `out` every 10 ps across each, and prints the first poll after the last
# one that read anything but the expected value. It asserts only functional
# correctness, so it too passes on both legs. The readings are embedded in
# the trimmed probe envelopes as `sdf_probe` (the one key here that is not
# klt's) and committed as measurements/timing-characterization/
# logic_tile.sdf-probe-zero-delay.json / logic_tile.sdf-probe-sdf.json.
# flow/tile_sdf_probe_gate.py then reads both legs' test logs and requires
# the annotated leg to settle at least PROBE_MIN_DELTA_NS later on both
# paths -- refusing a missing or malformed reading rather than reading it as
# a pass. The margin is deliberately loose (the probe observed 0.60 /
# 0.53 ns against 0.01 ns; record 20261121-183351-787c7ca): this is evidence
# that annotation took effect, not a timing measurement.
#
# Usage:
#   ./flow/tile-functional-verification.sh            # run, diff against the committed envelopes
#   ./flow/tile-functional-verification.sh --update   # run, rewrite the committed envelopes
#
# Environment:
#   PDK_ROOT      volare/ciel root holding hash-matching sky130_fd_sc_hd models
#   KLT_FV_CMD    override the pinned klt invocation (default: uvx, klt 0.9.1)
#
# Exit 0 iff all four runs pass their gates, the probe gate passes, and
# (check mode) all four envelopes are unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NETLIST="$REPO_ROOT/layout/logic_tile.asbuilt.v"
SDF="$REPO_ROOT/measurements/timing-characterization/logic_tile_route.sdf"
BENCH_DIR="$REPO_ROOT/sim/cocotb"
BUILD_DIR="$SCRIPT_DIR/build/tile-functional-verification"
COMMITTED_ZERO="$REPO_ROOT/measurements/timing-characterization/logic_tile.fv-zero-delay.json"
COMMITTED_SDF="$REPO_ROOT/measurements/timing-characterization/logic_tile.fv-sdf.json"
# The SDF settle-time probe pair (issue #382): same netlist, models, SDF and
# request options as the pair above, only the bench module differs.
PROBE_BENCH="test_logic_tile_sdf_probe"
PROBE_MIN_DELTA_NS="0.1"
COMMITTED_PROBE_ZERO="$REPO_ROOT/measurements/timing-characterization/logic_tile.sdf-probe-zero-delay.json"
COMMITTED_PROBE_SDF="$REPO_ROOT/measurements/timing-characterization/logic_tile.sdf-probe-sdf.json"

MODE="check"
case "${1:-}" in
    --update) MODE="update" ;;
    "") ;;
    *) echo "usage: $0 [--update]" >&2; exit 1 ;;
esac

KLT_FV_CMD="${KLT_FV_CMD:-uvx --from klayout-tools[functional-verification]==0.9.1 klt}"
command -v iverilog >/dev/null 2>&1 || { echo "error: iverilog not found on PATH" >&2; exit 1; }

# The pinned model digests, from the repo's single committed source.
# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"
# shellcheck source=./pdk_root.sh
source "$SCRIPT_DIR/pdk_root.sh"   # sky130_cell_models_from_klt (issue #375)

# --- resolve the sky130_fd_sc_hd Verilog models (hash-gated) -------------
MODELS_DIR=""
INSTALLED_REV=""
for c in "${PDK_ROOT:+$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog}" \
         "$(sky130_cell_models_from_klt sky130A)"; do
    d="${c%/}/"
    d="${d%/}"
    [[ -n "$c" && -f "$d/sky130_fd_sc_hd.v" && -f "$d/primitives.v" ]] || continue
    m="$(sha256sum "$d/sky130_fd_sc_hd.v" | cut -d' ' -f1)"
    p="$(sha256sum "$d/primitives.v" | cut -d' ' -f1)"
    if [[ "$m" == "$RECORDED_PDK_MODELS_SHA256" && "$p" == "$RECORDED_PDK_PRIMITIVES_SHA256" ]]; then
        MODELS_DIR="$d"
        # Report the revision the models actually came from: a ciel layout
        # resolves through .../versions/<sha>/..., so read it off the real
        # path; only fall back to `klt pdk find` when it does not carry one
        # (a hand-placed hash-matching model directory has no revision of
        # its own -- the two verified digests are then the pin).
        real="$(readlink -f "$d")"
        INSTALLED_REV="$(python3 -c '
import re, sys
m = re.search(r"/versions/([0-9a-f]{40})/", sys.argv[1])
print(f"open_pdks {m.group(1)}" if m else "")' "$real")"
        if [[ -z "$INSTALLED_REV" ]]; then
            INSTALLED_REV="$(klt pdk find --pdk sky130A --format json 2>/dev/null \
                | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","unknown"))' 2>/dev/null || echo unknown)"
        fi
        break
    fi
    echo "note: model candidate $d does not hash-match the recorded digests (sky130_fd_sc_hd.v ${m:0:8}..., primitives.v ${p:0:8}...); skipping" >&2
done
if [[ -z "$MODELS_DIR" ]]; then
    cat >&2 <<ERR
error: no sky130_fd_sc_hd Verilog model directory hash-matches flow/tool_versions.sh's
       RECORDED_PDK_MODELS_SHA256 / RECORDED_PDK_PRIMITIVES_SHA256. Fetch the published
       byte-identical revision into a throwaway root and point PDK_ROOT at it (the same
       fetch .github/workflows/gate-sim.yml performs):

         uvx --from "ciel==3.0.1" ciel enable --pdk-root <root> --pdk-family \\
             sky130 -l sky130_fd_sc_hd a492ff787163f93ce9ebc382b23c58c0de33afa3
         PDK_ROOT=<root> $0
ERR
    exit 1
fi
echo "=== models: $MODELS_DIR (installed PDK: ${INSTALLED_REV:-unknown}) ==="
echo "    sha256(sky130_fd_sc_hd.v) ${RECORDED_PDK_MODELS_SHA256} (verified)"
echo "    sha256(primitives.v)      ${RECORDED_PDK_PRIMITIVES_SHA256} (verified)"

# --- generate the two request pairs ---------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

REQUEST_ZERO="$BUILD_DIR/fv_tile_request_zero.json"
REQUEST_SDF="$BUILD_DIR/fv_tile_request_sdf.json"
REQUEST_PROBE_ZERO="$BUILD_DIR/fv_tile_probe_request_zero.json"
REQUEST_PROBE_SDF="$BUILD_DIR/fv_tile_probe_request_sdf.json"
python3 - "$NETLIST" "$MODELS_DIR" "$BENCH_DIR" "$REQUEST_ZERO" "$REQUEST_SDF" "$SDF" \
          "$PROBE_BENCH" "$REQUEST_PROBE_ZERO" "$REQUEST_PROBE_SDF" <<'PY'
import json, sys

netlist, models, bench_dir, req_zero, req_sdf, sdf = sys.argv[1:7]
probe_bench, probe_zero, probe_sdf = sys.argv[7:10]

common = {
    "schema": "klt.functional_verification.request/1",
    "engine": "icarus",
    "sources": [netlist, f"{models}/primitives.v", f"{models}/sky130_fd_sc_hd.v"],
    "hdl_toplevel": "logic_tile",
    "testbench": {"module": "test_logic_tile", "search_path": bench_dir},
    "options": {
        # Same bench timing in both runs: CLOCK_PERIOD_NS=20 / SETTLE_NS=4 live in
        # the bench itself; the seed and build flags are pinned here so the only
        # request-level difference between the pair is options.sdf. The build
        # flags mirror flow/sdf-resim.sh leg 2 (-g2012 is cocotb's own default):
        # without them the zero-delay leg would not pair the annotated leg's
        # -gspecify -ginterconnect -Ttyp elaboration.
        "timescale": ["1ns", "1ps"],
        "random_seed": 359,
        "build_args": ["-gspecify", "-ginterconnect", "-Ttyp"],
    },
}

with open(req_zero, "w") as f:
    json.dump(common, f, indent=2)
    f.write("\n")

annotated = json.loads(json.dumps(common))
annotated["options"]["sdf"] = {"file": sdf, "corner": "typ"}  # entries: "all" (default)
with open(req_sdf, "w") as f:
    json.dump(annotated, f, indent=2)
    f.write("\n")

# The probe pair (issue #382) is derived from the two documents just written,
# so it differs from them in exactly one field, testbench.module, by
# construction rather than by copy.
for src, dst in ((req_zero, probe_zero), (req_sdf, probe_sdf)):
    with open(src) as f:
        probe = json.load(f)
    probe["testbench"]["module"] = probe_bench
    with open(dst, "w") as f:
        json.dump(probe, f, indent=2)
        f.write("\n")
PY

run_klt() {
    local req="$1" outdir="$2" raw="$3"
    set +e
    # shellcheck disable=SC2086
    ( cd "$(dirname "$raw")" && $KLT_FV_CMD functional-verification "$req" -o "$outdir" --format json ) >"$raw"
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "error: klt functional-verification exited $rc for $(basename "$req") (see $raw and $outdir/)" >&2
        exit 1
    fi
}

echo "=== zero-delay run ==="
run_klt "$REQUEST_ZERO" "$BUILD_DIR/run-zero" "$BUILD_DIR/response-zero.json"
echo "=== SDF-annotated run (corner typ, entries all) ==="
run_klt "$REQUEST_SDF" "$BUILD_DIR/run-sdf" "$BUILD_DIR/response-sdf.json"
echo "=== SDF settle-time probe: zero-delay run ==="
run_klt "$REQUEST_PROBE_ZERO" "$BUILD_DIR/run-probe-zero" "$BUILD_DIR/response-probe-zero.json"
echo "=== SDF settle-time probe: SDF-annotated run (corner typ, entries all) ==="
run_klt "$REQUEST_PROBE_SDF" "$BUILD_DIR/run-probe-sdf" "$BUILD_DIR/response-probe-sdf.json"

# --- gate + trim all four envelopes -----------------------------------------
# Argument groups of five: <raw response> <trimmed output> <repo root> <leg>
# <probe run dir>. An empty fifth field is the four-check pair; a non-empty one
# is a probe leg, whose SETTLE_PROBE readings are read from that run's own test
# log (resolved the way the artifact trimming below reads the same field) and
# embedded as `sdf_probe`.
TRIMMED_ZERO="$BUILD_DIR/logic_tile.fv-zero-delay.json"
TRIMMED_SDF="$BUILD_DIR/logic_tile.fv-sdf.json"
TRIMMED_PROBE_ZERO="$BUILD_DIR/logic_tile.sdf-probe-zero-delay.json"
TRIMMED_PROBE_SDF="$BUILD_DIR/logic_tile.sdf-probe-sdf.json"
python3 - "$SCRIPT_DIR" \
         "$BUILD_DIR/response-zero.json" "$TRIMMED_ZERO" "$REPO_ROOT" zero "" \
         "$BUILD_DIR/response-sdf.json" "$TRIMMED_SDF" "$REPO_ROOT" sdf "" \
         "$BUILD_DIR/response-probe-zero.json" "$TRIMMED_PROBE_ZERO" "$REPO_ROOT" zero "$BUILD_DIR/run-probe-zero" \
         "$BUILD_DIR/response-probe-sdf.json" "$TRIMMED_PROBE_SDF" "$REPO_ROOT" sdf "$BUILD_DIR/run-probe-sdf" <<'PY'
import json, os, sys
from decimal import Decimal

FLOW_DIR = sys.argv[1]

EXPECT_TESTS = [
    "test_independent_lut_config",
    "test_reset_with_all_enables_low",
    "test_selective_capture",
    "test_reset_from_mixed_state_all_enables_high",
]
EXPECT_PROBE_TESTS = [
    "test_probe_registered_settle",
    "test_probe_combinational_settle",
]

def read_probe(env, probe_dir, repo_root, leg):
    """The SETTLE_PROBE readings of a probe leg, from its run's own test log."""
    sys.path.insert(0, FLOW_DIR)
    from _modload import load_module
    gate = load_module("tile_sdf_probe_gate", os.path.join(FLOW_DIR, "tile_sdf_probe_gate.py"))
    artifact = env["environment"].get("test_log")
    name = artifact.get("path") if isinstance(artifact, dict) else None
    if not name:
        raise SystemExit(f"error: {leg} probe envelope refused: it names no test_log "
                         "artifact to read the SETTLE_PROBE readings from")
    candidates = [name] if os.path.isabs(name) else [os.path.join(repo_root, name)]
    candidates.append(os.path.join(probe_dir, os.path.basename(name)))
    log = next((c for c in candidates if os.path.isfile(c)), None)
    if log is None:
        raise SystemExit(f"error: {leg} probe envelope refused: test log {name!r} not found "
                         f"(looked at {candidates})")
    with open(log, encoding="utf-8", errors="replace") as f:
        try:
            return gate.parse_probe(f.read(), os.path.relpath(log, repo_root))
        except gate.ProbeError as exc:
            raise SystemExit(f"error: {leg} probe envelope refused: {exc}")

def load_trim_gate(raw_path, out_path, repo_root, leg, expect_tests, probe_dir=None):
    with open(raw_path) as f:
        env = json.load(f)

    names = [t["name"] for t in env["tests"]]
    problems = []
    if env.get("status") != "pass":
        problems.append(f"status is {env.get('status')!r}, not pass")
    if env.get("skipped_count") != 0:
        problems.append(f"skipped_count is {env['skipped_count']} (baseline must have no skips)")
    if env.get("failed_count") != 0:
        problems.append(f"failed_count is {env['failed_count']}")
    if names != expect_tests:
        problems.append(f"test names {names} != the {len(expect_tests)} expected named tests {expect_tests}")
    sdf = env["environment"]["sdf"]
    if leg == "zero":
        if sdf is not None:
            problems.append("zero-delay environment.sdf must be null")
    elif not isinstance(sdf, dict):
        problems.append("annotated environment.sdf must be an object")
    else:
        if sdf.get("annotated") is not True:
            problems.append("environment.sdf.annotated is not true")
        if sdf.get("entries") != "all":
            problems.append(f"environment.sdf.entries is {sdf.get('entries')!r}, not 'all'")
        if sdf.get("corner") != "typ":
            problems.append(f"environment.sdf.corner is {sdf.get('corner')!r}, not 'typ'")
    if problems:
        raise SystemExit(f"error: {leg} envelope refused: " + "; ".join(problems))

    probe = read_probe(env, probe_dir, repo_root, leg) if probe_dir else None

    for key in ("results_xml", "test_log", "build_log"):
        artifact = env["environment"].get(key)
        if isinstance(artifact, dict) and artifact.get("path"):
            # Drop the run-to-run-volatile digest and the machine-local scope;
            # keep the bare artifact name so the run's own files stay named.
            env["environment"][key] = {"path": os.path.basename(artifact["path"])}
    if isinstance(sdf, dict) and isinstance(sdf.get("file"), str):
        f = sdf["file"]
        if f.startswith(repo_root + "/"):
            f = os.path.relpath(f, repo_root)
        sdf["file"] = f
    for t in env["tests"]:
        t["real_time_s"] = 0.0
    if probe is not None:
        # The one key of a committed envelope that is not klt's: the readings
        # the probe printed, exactly as the gate module parsed them from the
        # run's own log.
        env["sdf_probe"] = {k: float(v) if isinstance(v, Decimal) else v
                            for k, v in probe.items()}

    with open(out_path, "w") as f:
        json.dump(env, f, indent=2, sort_keys=True)
        f.write("\n")

for i in range(2, len(sys.argv), 5):
    raw, out, repo_root, leg, probe_dir = sys.argv[i:i + 5]
    load_trim_gate(raw, out, repo_root, leg,
                   EXPECT_PROBE_TESTS if probe_dir else EXPECT_TESTS, probe_dir or None)
PY

python3 -c "
import json
for leg in ('zero', 'sdf'):
    d = json.load(open('$BUILD_DIR/logic_tile.fv-%s.json' % ('zero-delay' if leg == 'zero' else 'sdf')))
    print('=== %s: %s  tests: %d passed: %d failed: %d skipped: %d ===' % (
        leg, d['status'], d['test_count'], d['passed_count'], d['failed_count'], d['skipped_count']))
    for t in d['tests']:
        print('    [%s] %s  %.0f ns' % (t['status'], t['name'], t['sim_time_ns']))
"

python3 -c "
import json
for leg, name in (('zero', 'zero-delay'), ('sdf', 'sdf')):
    d = json.load(open('$BUILD_DIR/logic_tile.sdf-probe-%s.json' % name))
    print('=== probe %s: %s  tests: %d passed: %d failed: %d skipped: %d ===' % (
        leg, d['status'], d['test_count'], d['passed_count'], d['failed_count'], d['skipped_count']))
    for t in d['tests']:
        print('    [%s] %s  %.0f ns' % (t['status'], t['name'], t['sim_time_ns']))
    p = d['sdf_probe']
    print('    out settled: registered %.2f ns, combinational %.2f ns (first poll after the last unsettled one, %d ps grid)' % (
        p['registered_ns'], p['combinational_ns'], p['poll_step_ps']))
"

# --- probe gate: the annotated leg must settle later (issue #382) ------------
# The logs are the runs' own test_log artifacts (the same field the envelope
# trimming names). flow/tile_sdf_probe_gate.py refuses a missing or malformed
# reading outright, so a probe that did not run or printed nothing can never
# read as a pass; under set -e its exit 1 ends the run before anything below
# writes or compares a committed file.
probe_log() {  # <raw response> <run dir> -> the run's test log
    python3 -c 'import json, os, sys
print(os.path.join(sys.argv[2], os.path.basename(json.load(open(sys.argv[1]))["environment"]["test_log"]["path"])))' "$1" "$2"
}
LOG_PROBE_ZERO="$(probe_log "$BUILD_DIR/response-probe-zero.json" "$BUILD_DIR/run-probe-zero")"
LOG_PROBE_SDF="$(probe_log "$BUILD_DIR/response-probe-sdf.json" "$BUILD_DIR/run-probe-sdf")"
python3 "$SCRIPT_DIR/tile_sdf_probe_gate.py" \
    --zero-log "$LOG_PROBE_ZERO" --sdf-log "$LOG_PROBE_SDF" \
    --min-delta-ns "$PROBE_MIN_DELTA_NS"

if [[ "$MODE" == "update" ]]; then
    cp "$TRIMMED_ZERO" "$COMMITTED_ZERO"
    cp "$TRIMMED_SDF" "$COMMITTED_SDF"
    cp "$TRIMMED_PROBE_ZERO" "$COMMITTED_PROBE_ZERO"
    cp "$TRIMMED_PROBE_SDF" "$COMMITTED_PROBE_SDF"
    echo "=== paired envelopes written to $COMMITTED_ZERO and $COMMITTED_SDF ==="
    echo "=== probe envelopes written to $COMMITTED_PROBE_ZERO and $COMMITTED_PROBE_SDF ==="
    exit 0
fi

rc=0
check_envelope() {  # <label> <committed> <regenerated>
    if ! diff -u "$2" "$3"; then
        echo "error: $1 envelope differs from $2; run '$0 --update'" >&2
        rc=1
    fi
}
check_envelope "zero-delay" "$COMMITTED_ZERO" "$TRIMMED_ZERO"
check_envelope "SDF" "$COMMITTED_SDF" "$TRIMMED_SDF"
check_envelope "probe zero-delay" "$COMMITTED_PROBE_ZERO" "$TRIMMED_PROBE_ZERO"
check_envelope "probe SDF" "$COMMITTED_PROBE_SDF" "$TRIMMED_PROBE_SDF"
if [[ "$rc" -eq 0 ]]; then
    echo "=== paired envelopes reproduce the committed copies ==="
fi
exit "$rc"
