#!/usr/bin/env bash
# flow/test_gate_sim_verdict.sh (issue #141): regression for the verdict
# classifier used by flow/gate-sim-bitstream.sh. Needs no iverilog/PDK: it uses
# stub simulators and canned logs. Exit nonzero on any mismatch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/gate_sim_verdict.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
TB=tb_logic_tile_bitstream; D=reg
PASSL="PASS: $TB[$D] (10 checks, 0 failures; 5/5 perturbations detected)"
FUNCL="FAIL: $TB[$D] (10 checks, 3 failures, 1 perturbations survived)"
rc_all=0
expect() {  # expect <name> <want> <rc> <log content>
    printf '%s' "$4" >"$T/log"
    local got; got="$(gs_classify "$3" "$T/log" "$TB" "$D")"
    if [[ "$got" == "$2" ]]; then echo "ok   $1 -> $got"; else echo "FAIL $1: want $2 got $got"; rc_all=1; fi
}
expect "valid completed pass"            PASS      0 $'CFG=ab\nbaseline: 10 checks, 0 failures\n'"$PASSL"$'\n'
expect "valid completed functional FAIL" FUNC_FAIL 0 $'CFG=ab\n  SURVIVED: flip\n'"$FUNCL"$'\n'
expect "functional FAIL but nonzero exit" INFRA    1 "$FUNCL"$'\n'
expect "pass but nonzero exit"           INFRA     2 "$PASSL"$'\n'
expect "nonzero exit crash"              INFRA     1 $'simulator crashed\n'
expect "empty output"                    INFRA     0 ""
expect "no verdict"                      INFRA     0 $'CFG=ab\nbaseline: 1 checks, 0 failures\n'
expect "setup-only FAIL (cannot open map)" INFRA   0 $'FAIL: tb_logic_tile_bitstream: cannot open map\n'
expect "loader rejection FAIL"           INFRA     0 "FAIL: $TB[$D]: loader rejected a stream that must load: x"$'\n'
expect "setup FAIL then functional FAIL" INFRA     0 $'FAIL: tb_logic_tile_bitstream: bad wiring manifest\n'"$FUNCL"$'\n'
expect "mixed PASS and FAIL"             INFRA     0 "$PASSL"$'\n'"$FUNCL"$'\n'
expect "wrong design name in verdict"    INFRA     0 "${FUNCL/\[$D\]/[comb]}"$'\n'
expect "duplicated terminal verdict"     INFRA     0 "$FUNCL"$'\n'"$FUNCL"$'\n'
# missing log
if [[ "$(gs_classify 0 "$T/nonexistent" "$TB" "$D")" == INFRA ]]; then echo "ok   missing log -> INFRA"; else echo "FAIL missing log"; rc_all=1; fi

# stub simulator end-to-end through the script's run_vvp-equivalent contract
cat >"$T/stub_crash" <<'S'
#!/usr/bin/env bash
echo "simulator crashed"; exit 1
S
cat >"$T/stub_func" <<S
#!/usr/bin/env bash
echo "$FUNCL"; exit 0
S
chmod +x "$T/stub_crash" "$T/stub_func"
for s in crash:INFRA func:FUNC_FAIL; do
    stub="$T/stub_${s%%:*}"; rc=0
    "$stub" >"$T/log" 2>&1 || rc=$?
    got="$(gs_classify "$rc" "$T/log" "$TB" "$D")"
    if [[ "$got" == "${s##*:}" ]]; then echo "ok   stub ${s%%:*} -> $got"; else echo "FAIL stub ${s%%:*}: got $got"; rc_all=1; fi
done
exit "$rc_all"
