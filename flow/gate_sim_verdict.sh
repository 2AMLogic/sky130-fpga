# flow/gate_sim_verdict.sh -- sourced helper (issue #141): the ONE place that
# classifies a gate-level testbench run for flow/gate-sim-bitstream.sh.
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
