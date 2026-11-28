# flow/gate_sim_verdict.sh -- sourced helper (issue #141): the ONE place that
# classifies a gate-level testbench run for flow/gate-sim-bitstream.sh, and
# (issue #401, bottom of this file) the ONE loaded-cfg cross-check, corpus
# index validation and gate-level bench compile of the replay drivers.
#
# gs_classify <rc> <log> <tb_name> <design>  prints exactly one of:
#   PASS      vvp exit 0, exactly one terminal "PASS: <tb>[<design>]" line,
#             no FAIL line at all.
#   FUNC_FAIL vvp exit 0, exactly one design-specific terminal functional
#             summary "FAIL: <tb>[<design>] (N checks, M failures, K
#             perturbations survived)" (sim/tb_logic_tile_bitstream.v), no PASS.
#   INFRA     anything else: nonzero exit/crash, missing or unreadable log,
#             empty output, no verdict, setup/loader/input-open FAIL lines
#             (any FAIL line that is not the terminal functional summary),
#             or conflicting / repeated terminal verdicts.
# Only PASS and FUNC_FAIL are completed runs. A negative control may count a
# result as "rejected" only when it is FUNC_FAIL; INFRA is an infrastructure
# failure of the whole script.
#
# Wall-clock budget (issue #157). Every simulator invocation of the replay
# drivers goes through gs_run_bounded / gs_run_bounded_tee, which run it under
# GNU coreutils `timeout`:
#   SIM_TIMEOUT_SECONDS     per-simulation budget, positive integer seconds
#                           (default GS_SIM_TIMEOUT_DEFAULT below)
#   SIM_KILL_AFTER_SECONDS  grace after TERM before a forced KILL, positive
#                           integer seconds (default GS_SIM_KILL_AFTER_DEFAULT)
# Any other value (empty, 0, negative, non-integer, unit suffix) is rejected
# by gs_budget_check before anything runs. A run that exceeds the budget
# returns 124 (stopped by TERM) or 137 (forced KILL); that nonzero status is
# passed to gs_classify unchanged, so a timed-out run is always INFRA -- even
# if it printed a PASS or FAIL verdict first -- and can never be counted as a
# completed functional rejection (caught mutation / negative control). On a
# timeout the fixture, budget and log path are reported on stderr and a
# "TIMEOUT:" line is appended to the log; the simulator's own output stays in
# the log. Default basis (sim/README.md): the slowest single runs measured on
# a shared 8-vCPU dev host are the regcasc corpus fixtures at ~22-25 s (RTL,
# gate-level and generated-tile benches alike); 300 s is a >10x margin and stays
# inside the 15/20-minute CI job limits, so a stall still yields a per-fixture
# verdict in CI.
GS_SIM_TIMEOUT_DEFAULT=300
GS_SIM_KILL_AFTER_DEFAULT=10

# gs_budget_check: validate the budget settings; prints an error and returns
# 2 if invalid. Callers run it once at startup so a bad override fails fast.
gs_budget_check() {
    local v name
    for name in SIM_TIMEOUT_SECONDS SIM_KILL_AFTER_SECONDS; do
        [[ -z "${!name+x}" ]] && continue
        v="${!name}"
        if [[ ! "$v" =~ ^[1-9][0-9]{0,5}$ ]]; then
            echo "error: invalid $name='$v' (must be a positive integer number of seconds, 1..999999)" >&2
            return 2
        fi
    done
    command -v timeout >/dev/null 2>&1 || { echo "error: timeout (GNU coreutils) not found on PATH" >&2; return 2; }
}
gs_budget() { echo "${SIM_TIMEOUT_SECONDS:-$GS_SIM_TIMEOUT_DEFAULT}"; }
gs_kill_after() { echo "${SIM_KILL_AFTER_SECONDS:-$GS_SIM_KILL_AFTER_DEFAULT}"; }

# _gs_now_ms: wall-clock milliseconds (bash 5 EPOCHREALTIME).
_gs_now_ms() { local t="${EPOCHREALTIME/[.,]/}"; echo "$((10#${t:0:${#t}-3}))"; }

# _gs_after_run <fixture> <log> <rc> <start_ms>: on a budget overrun, report it.
_gs_after_run() {
    local fixture="$1" log="$2" rc="$3" t0="$4" el b k how
    b="$(gs_budget)"; k="$(gs_kill_after)"
    el=$(( $(_gs_now_ms) - t0 ))
    if [[ ( "$rc" == 124 || "$rc" == 137 ) && "$el" -ge $(( b * 1000 )) ]]; then
        if [[ "$rc" == 137 ]]; then how="ignored TERM; forced KILL after ${k}s grace"
        else how="stopped by TERM"; fi
        echo "TIMEOUT: simulation of fixture '$fixture' exceeded the ${b}s wall-clock budget (SIM_TIMEOUT_SECONDS; $how; rc=$rc) -- infrastructure failure, not a verdict" >>"$log"
        echo "error: simulation TIMEOUT (infrastructure failure): fixture '$fixture' exceeded the ${b}s wall-clock budget ($how, rc=$rc); log: $log" >&2
    fi
}

# gs_run_bounded <fixture> <log> <cmd...>: run cmd with stdout+stderr to log
# under the budget; returns cmd's exit status (124/137 on timeout, 125 if the
# budget settings are invalid).
gs_run_bounded() {
    local fixture="$1" log="$2" rc=0 t0; shift 2
    gs_budget_check || { echo "INFRA: invalid simulation budget settings; '$fixture' not run" >"$log"; return 125; }
    t0="$(_gs_now_ms)"
    timeout --foreground -k "$(gs_kill_after)" "$(gs_budget)" "$@" >"$log" 2>&1 || rc=$?
    _gs_after_run "$fixture" "$log" "$rc" "$t0"
    return "$rc"
}

# gs_run_bounded_tee <fixture> <log> <cmd...>: like `cmd | tee log` (stdout to
# both, stderr to the terminal) under the budget; returns cmd's exit status.
# Self-contained: the status is read from PIPESTATUS in both branches, so a
# timeout (124/137) is returned whether or not the caller set pipefail.
gs_run_bounded_tee() {
    local fixture="$1" log="$2" rc=0 t0 ps; shift 2
    gs_budget_check || { echo "INFRA: invalid simulation budget settings; '$fixture' not run" >"$log"; return 125; }
    t0="$(_gs_now_ms)"
    if timeout --foreground -k "$(gs_kill_after)" "$(gs_budget)" "$@" | tee "$log"; then ps="${PIPESTATUS[*]}"
    else ps="${PIPESTATUS[*]}"; fi
    rc="${ps%% *}"
    [[ "$rc" != 0 || "${ps##* }" == 0 ]] || rc=1  # rc=1: tee itself failed
    _gs_after_run "$fixture" "$log" "$rc" "$t0"
    return "$rc"
}

gs_classify() {
    local rc="$1" log="$2" tb="$3" design="$4"
    local pass_re="^PASS: ${tb}\[${design}\]"
    local func_re="^FAIL: ${tb}\[${design}\] \([0-9]+ checks, [0-9]+ failures, [0-9]+ perturbations survived\)\$"
    local n_pass n_func n_fail
    if [[ "$rc" != 0 || ! -s "$log" ]]; then echo INFRA; return 0; fi
    n_pass="$(grep -c -E "$pass_re" "$log" || true)"
    n_func="$(grep -c -E "$func_re" "$log" || true)"
    n_fail="$(grep -c -E '^FAIL' "$log" || true)"
    if [[ "$n_pass" -eq 1 && "$n_fail" -eq 0 && "$n_func" -eq 0 ]]; then echo PASS
    elif [[ "$n_func" -eq 1 && "$n_fail" -eq 1 && "$n_pass" -eq 0 ]]; then echo FUNC_FAIL
    else echo INFRA; fi
}

# gs_classify_configmem <rc> <log>   (issue #196)
# Verdict for design/fabulous/tb_configmem_equiv.v, which ends setup errors
# with $finish (exit 0). Prints PASS, FUNC_FAIL or INFRA.
#   PASS      rc 0, exactly one "PASS: configmem_fabulous_equiv -- N checks,
#             S baseline streams, 0 failures[; transparent-open: ...]" (N>0), no
#             FAIL/ERROR line at all.
#   FUNC_FAIL rc 0, exactly one "FAIL: configmem_fabulous_equiv -- M failures /
#             N checks[ (T transparent-open failures / C checks)]" with M>0 and
#             N>0, no PASS line, no ERROR line, and no
#             FAIL line other than ordinary per-check mismatch lines
#             ("FAIL <what>: ...", no colon directly after FAIL).
#   INFRA     everything else: nonzero exit / crash / timeout (even after a
#             verdict), empty or missing log, setup ERROR or legacy "FAIL:"
#             setup lines, missing / duplicate / conflicting summaries, zero
#             counts, TIMEOUT/INFRA markers. Only FUNC_FAIL counts as a kill.
gs_classify_configmem() {
    local rc="$1" log="$2"
    # optional suffixes: issue #195 transparent-open phase report
    local pass_re='^PASS: configmem_fabulous_equiv -- ([0-9]+) checks, ([0-9]+) baseline streams, 0 failures(; transparent-open: [0-9]+ frames, [0-9]+/[0-9]+ mapped bits changed under asserted strobe, [0-9]+ settled changes, [0-9]+ checks, 0 failures)?$'
    local func_re='^FAIL: configmem_fabulous_equiv -- ([0-9]+) failures / ([0-9]+) checks( \([0-9]+ transparent-open failures / [0-9]+ checks\))?$'
    local n_pass_any n_pass n_func n_colon n_err line
    if [[ "$rc" != 0 || ! -s "$log" ]]; then echo INFRA; return 0; fi
    n_pass_any="$(grep -c -E '^PASS' "$log" || true)"
    n_pass="$(grep -c -E "$pass_re" "$log" || true)"
    n_func="$(grep -c -E "$func_re" "$log" || true)"
    n_colon="$(grep -c -E '^FAIL:' "$log" || true)"
    n_err="$(grep -c -E '^(ERROR|TIMEOUT|INFRA)' "$log" || true)"
    if [[ "$n_err" -ne 0 ]]; then echo INFRA; return 0; fi
    if [[ "$n_pass" -eq 1 && "$n_pass_any" -eq 1 && "$n_func" -eq 0 \
          && "$(grep -c -E '^FAIL' "$log" || true)" -eq 0 ]]; then
        line="$(grep -E "$pass_re" "$log")"
        [[ "$line" =~ $pass_re && "${BASH_REMATCH[1]}" -gt 0 ]] && echo PASS || echo INFRA
    elif [[ "$n_func" -eq 1 && "$n_colon" -eq 1 && "$n_pass_any" -eq 0 ]]; then
        line="$(grep -E "$func_re" "$log")"
        [[ "$line" =~ $func_re && "${BASH_REMATCH[1]}" -gt 0 && "${BASH_REMATCH[2]}" -gt 0 ]] \
            && echo FUNC_FAIL || echo INFRA
    else echo INFRA; fi
}

# gs_configmem_is_setup_error <rc> <log>   (issue #200)
# True (exit 0) only when a tb_configmem_equiv.v run on broken INPUT ended the
# way the bench's input contract requires: the simulator terminated on its own
# (rc 0, so within the wall-clock budget -- not a timeout/kill), printed a
# "ERROR: configmem_fabulous_equiv setup:" line, printed NO terminal summary
# (no "PASS:"/"FAIL:" line at all), and gs_classify_configmem says INFRA.
gs_configmem_is_setup_error() {
    local rc="$1" log="$2"
    [[ "$rc" == 0 && -s "$log" ]] || return 1
    [[ "$(gs_classify_configmem "$rc" "$log")" == INFRA ]] || return 1
    grep -q '^ERROR: configmem_fabulous_equiv setup:' "$log" || return 1
    ! grep -q -E '^(PASS|FAIL):' "$log"
}

# ---------------------------------------------------------------------------
# Shared replay checks of the tb_logic_tile_bitstream drivers (issue #401):
# sim/run.sh, flow/gate-sim-bitstream.sh (+ flow/gate_route_diag.sh),
# sim/pin_fixture_replay.sh and flow/blinky.sh. Each carried its own copy of
# the loaded-cfg cross-check, the corpus-index validation and the gate-level
# bench compile, and the copies had drifted: a log without a CFG= line killed
# five of them inside `grep | cut` under `set -euo pipefail` before their own
# error branch, none rejected a duplicated CFG= line, and the gate-level ones
# skipped the python decode. The functions below are the only implementations.

# This file's directory: reaches flow/fasm_to_bitstream.py whatever the
# caller names its repo root (REPO_ROOT, REPO, HERE).
_GS_FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# gs_cfg_ok <label> <log> <bin> <cfg> <snapshot>
#   <label>     names the fixture in the diagnostic
#   <log>       simulator output holding the loader's "CFG=<hex>" readback
#   <bin>       the frame stream that was loaded, decoded by
#               flow/fasm_to_bitstream.py under <snapshot> (fabric_spec.json)
#   <cfg>       the assembler's recorded cfg of the same stream
# True (exit 0) iff <log> holds exactly one well-formed CFG= line whose value
# equals both the python decode and the recorded cfg; then GS_SIM_CFG holds
# that value. Otherwise prints "error: <label>: ..." on stderr and returns 1
# -- including for a log with no CFG= line, which must reach the caller's
# error branch instead of aborting it. The message never says "infrastructure
# failure": sim/pin_fixture_negative.sh reads that phrase as a crash/timeout,
# i.e. as not a rejection by the replay's checks.
# shellcheck disable=SC2034  # GS_SIM_CFG is read by the scripts that source this file
gs_cfg_ok() {
    local label="$1" log="$2" bin="$3" cfg="$4" snapshot="$5" f n sim_cfg py_cfg rec_cfg
    for f in "$log" "$bin" "$cfg" "$snapshot"; do
        [[ -s "$f" ]] || { echo "error: $label: missing or empty input $f" >&2; return 1; }
    done
    n="$(grep -c -E '^CFG=[0-9a-f]+$' "$log" || true)"
    if [[ "$n" -ne 1 ]]; then
        echo "error: $label: expected exactly one CFG=<hex> readback in $log, found ${n:-0}" >&2; return 1
    fi
    sim_cfg="$(grep -m1 -E '^CFG=[0-9a-f]+$' "$log" | cut -d= -f2)"
    py_cfg="$(python3 -I "$_GS_FLOW_DIR/fasm_to_bitstream.py" decode "$bin" --snapshot "$snapshot" 2>&1)" \
        || { echo "error: $label: python decode of $bin failed: $py_cfg" >&2; return 1; }
    rec_cfg="$(tr -d '\n' < "$cfg")"
    if [[ "$sim_cfg" == "$py_cfg" && "$sim_cfg" == "$rec_cfg" ]]; then
        GS_SIM_CFG="$sim_cfg"
        return 0
    fi
    echo "error: $label: loaded cfg mismatch: sim=$sim_cfg python=$py_cfg recorded=$rec_cfg" >&2
    return 1
}

# GS_RECOGNISED_ORACLES: the oracles a routability-corpus fixture may name
# (matched as *" $oracle "*).
GS_RECOGNISED_ORACLES=" comb reg quad4 casc2 fan4 casc_fan regcasc regbel "

# gs_corpus_index_ok <index>: the routability-corpus index ("<stem> <oracle>"
# per line, sim/bitstream/corpus/index.txt) exists and has at least one
# non-blank line, so a blank index cannot pass as "0 fixtures simulated".
gs_corpus_index_ok() {
    local n
    [[ -s "$1" ]] || { echo "error: corpus index missing or empty: $1" >&2; return 1; }
    n="$(grep -c -E '[^[:space:]]' "$1" || true)"
    [[ "$n" -gt 0 ]] || { echo "error: corpus index has no entries: $1" >&2; return 1; }
}

# gs_corpus_entry_ok <corpus_dir> <stem> <oracle> <extra>: one index line as
# read by `read -r stem oracle extra` is well formed (no extra field, a
# recognised oracle) and its .bin/.wiring/.cfg are present and non-empty.
# Reports every defect of the line; returns 1 if any.
gs_corpus_entry_ok() {
    local dir="$1" stem="$2" oracle="$3" extra="$4" ext bad=0
    if [[ -n "$extra" || -z "$oracle" || "$GS_RECOGNISED_ORACLES" != *" $oracle "* ]]; then
        echo "error: [$stem] corpus index entry invalid or oracle '${oracle:-}' unrecognised" >&2
        return 1
    fi
    for ext in bin wiring cfg; do
        [[ -s "$dir/$stem.$ext" ]] || { echo "error: [$stem] missing corpus file $dir/$stem.$ext" >&2; bad=1; }
    done
    return "$bad"
}

# gs_gate_compile <bench> <netlist> <out.vvp> <log> <sim_dir> <cell_dir>: the
# ONE gate-level bench compile behind `build` in flow/gate-sim-bitstream.sh
# (bitstream, LUT-basis and corrupted-netlist images) and rd_compile in
# flow/gate_route_diag.sh: <sim_dir>/<bench>.v as top, <netlist> in place of
# the RTL, the sky130_fd_sc_hd behavioral models of <cell_dir>. Returns
# iverilog's status and prints nothing -- output and diagnostics go to <log>;
# the caller names the bench and the log in its own error.
gs_gate_compile() {
    iverilog -g2012 -s "$1" -I "$5" -o "$3" "$5/$1.v" "$2" "$6/primitives.v" "$6/sky130_fd_sc_hd.v" >"$4" 2>&1
}
