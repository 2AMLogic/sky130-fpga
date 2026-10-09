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
