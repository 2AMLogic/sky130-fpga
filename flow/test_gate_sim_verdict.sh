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

# ConfigMem classifier (issue #196)
CP="PASS: configmem_fabulous_equiv -- 9000 checks, 3 baseline streams, 0 failures"
CF="FAIL: configmem_fabulous_equiv -- 4 failures / 9000 checks"
CM1="FAIL walk1: ConfigBits 0 expected 1 (N ok=1)"
cexpect() {  # cexpect <name> <want> <rc> <log content>
    printf '%s' "$4" >"$T/log"
    local got; got="$(gs_classify_configmem "$3" "$T/log")"
    if [[ "$got" == "$2" ]]; then echo "ok   cm $1 -> $got"; else echo "FAIL cm $1: want $2 got $got"; rc_all=1; fi
}
cexpect "baseline pass"                  PASS      0 "$CP"$'\n'
cexpect "completed functional FAIL"      FUNC_FAIL 0 "$CM1"$'\n'"$CM1"$'\n'"$CF"$'\n'
cexpect "FAIL summary only"              FUNC_FAIL 0 "$CF"$'\n'
cexpect "pass with mismatch line"        INFRA     0 "$CM1"$'\n'"$CP"$'\n'
cexpect "missing plusargs"               INFRA     0 $'ERROR: configmem_fabulous_equiv setup: need +map= and +vec=\n'
cexpect "bad map"                        INFRA     0 $'ERROR: configmem_fabulous_equiv setup: bad map entry 1 2\n'
cexpect "legacy zero-exit setup FAIL"    INFRA     0 $'FAIL: need +map= and +vec=\n'
cexpect "legacy bad map FAIL"            INFRA     0 $'FAIL: bad map entry 1 2\n'
cexpect "setup error then summary"       INFRA     0 $'ERROR: configmem_fabulous_equiv setup: map has 3 entries\n'"$CF"$'\n'
cexpect "legacy setup FAIL + summary"    INFRA     0 $'FAIL: map has 3 entries\n'"$CF"$'\n'
cexpect "no summary, only mismatches"    INFRA     0 "$CM1"$'\n'
cexpect "absent summary"                 INFRA     0 $'something\n'
cexpect "empty output"                   INFRA     0 ""
cexpect "duplicate FAIL summary"         INFRA     0 "$CF"$'\n'"$CF"$'\n'
cexpect "duplicate PASS summary"         INFRA     0 "$CP"$'\n'"$CP"$'\n'
cexpect "conflicting PASS and FAIL"      INFRA     0 "$CP"$'\n'"$CF"$'\n'
cexpect "FAIL then PASS"                 INFRA     0 "$CF"$'\n'"$CP"$'\n'
cexpect "zero failures in FAIL summary"  INFRA     0 "FAIL: configmem_fabulous_equiv -- 0 failures / 9000 checks"$'\n'
cexpect "zero checks in FAIL summary"    INFRA     0 "FAIL: configmem_fabulous_equiv -- 4 failures / 0 checks"$'\n'
cexpect "zero checks in PASS summary"    INFRA     0 "PASS: configmem_fabulous_equiv -- 0 checks, 3 baseline streams, 0 failures"$'\n'
cexpect "malformed summary"              INFRA     0 $'FAIL: configmem_fabulous_equiv -- many failures\n'
cexpect "wrong bench name"               INFRA     0 "${CF/configmem_fabulous_equiv/other}"$'\n'
cexpect "crash after FAIL summary"       INFRA     139 "$CF"$'\n'
cexpect "timeout (124) after FAIL summary" INFRA   124 "$CF"$'\n'
cexpect "forced kill (137) after FAIL"   INFRA     137 "$CF"$'\n'
cexpect "nonzero exit after PASS"        INFRA     1 "$CP"$'\n'
cexpect "TIMEOUT marker with FAIL"       INFRA     0 "$CF"$'\nTIMEOUT: x\n'
if [[ "$(gs_classify_configmem 0 "$T/nonexistent")" == INFRA ]]; then echo "ok   cm missing log -> INFRA"; else echo "FAIL cm missing log"; rc_all=1; fi

# stub runners through gs_run_bounded (real timeout path)
cstub() {  # cstub <name> <want> <body...>
    local n="$1" w="$2"; shift 2
    printf '#!/usr/bin/env bash\n%s\n' "$*" >"$T/cstub_$n"; chmod +x "$T/cstub_$n"
    local rc=0 got
    SIM_TIMEOUT_SECONDS=1 SIM_KILL_AFTER_SECONDS=1 gs_run_bounded "cm-$n" "$T/log" "$T/cstub_$n" 2>/dev/null || rc=$?
    got="$(gs_classify_configmem "$rc" "$T/log")"
    if [[ "$got" == "$w" ]]; then echo "ok   cm stub $n -> $got"; else echo "FAIL cm stub $n: want $w got $got"; rc_all=1; fi
}
cstub kill      FUNC_FAIL "echo '$CM1'; echo '$CF'"
cstub baseline  PASS      "echo '$CP'"
cstub setup0    INFRA     "echo 'ERROR: configmem_fabulous_equiv setup: bad map entry 1 2'"
cstub crash     INFRA     "echo '$CF'; exit 139"
cstub hang      INFRA     "echo '$CF'; sleep 30"
exit "$rc_all"
