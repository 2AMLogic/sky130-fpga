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
# issue #195 summary suffixes (transparent-open phase report)
CP2="PASS: configmem_fabulous_equiv -- 7712 checks, 17 baseline streams, 0 failures; transparent-open: 5 frames, 158/158 mapped bits changed under asserted strobe, 385 settled changes, 430 checks, 0 failures"
CF2="FAIL: configmem_fabulous_equiv -- 458 failures / 7712 checks (428 transparent-open failures / 430 checks)"
CCOV="FAIL transparent-open-coverage: 0/158 mapped bits, 5 frames"
cexpect "#195 pass summary"              PASS      0 "$CP2"$'\n'
cexpect "#195 FAIL summary"              FUNC_FAIL 0 "$CM1"$'\n'"$CF2"$'\n'
cexpect "#195 coverage shortfall + FAIL" FUNC_FAIL 0 "$CM1"$'\n'"$CCOV"$'\n'"$CF2"$'\n'
cexpect "#195 coverage line with PASS"   INFRA     0 "$CCOV"$'\n'"$CP2"$'\n'
cexpect "#195 malformed suffix"          INFRA     0 "${CF2% checks)} cheks)"$'\n'
cexpect "#195 PASS with nonzero tfails"  INFRA     0 "${CP2%0 failures}3 failures"$'\n'
cexpect "pre-#196 colon coverage form"   INFRA     0 "FAIL: transparent-open coverage 0/158 mapped bits, 5 frames"$'\n'"$CF2"$'\n'
# setup errors from the bench's input checks (PR #198 review): missing / empty /
# truncated vector file is INFRA even when mismatch lines were printed first
CE0="ERROR: configmem_fabulous_equiv setup: only 0 baseline streams in vector file /x"
CE1="ERROR: configmem_fabulous_equiv setup: only 1 baseline streams in vector file /x"
cexpect "cannot open vector file"        INFRA     0 $'ERROR: configmem_fabulous_equiv setup: cannot open vector file /nonexistent\n'
cexpect "cannot open map file"           INFRA     0 $'ERROR: configmem_fabulous_equiv setup: cannot open map file /nonexistent\n'
cexpect "zero baseline streams"          INFRA     0 "$CE0"$'\n'
cexpect "one baseline stream"            INFRA     0 "$CE1"$'\n'
cexpect "zero streams after mismatches"  INFRA     0 "$CM1"$'\n'"$CM1"$'\n'"$CE0"$'\n'
cexpect "one stream after baseline mismatch" INFRA 0 "FAIL baseline s0: ConfigBits 0 recorded 1"$'\n'"$CE1"$'\n'
cexpect "zero streams + stray FAIL summary" INFRA  0 "$CM1"$'\n'"$CE0"$'\n'"$CF"$'\n'
cexpect "pre-fix baseline-streams FAIL form" INFRA 0 $'FAIL: only 0 baseline streams replayed\n'"$CF"$'\n'
# issue #200: malformed transaction / map input is a setup ERROR -> INFRA, also
# when it follows mismatch lines; the input predicate also requires rc 0 and no summary
CET="ERROR: configmem_fabulous_equiv setup: vector file /x: last stream s2 incomplete at EOF: 2 of 20 frames"
CEM="ERROR: configmem_fabulous_equiv setup: bad map entry 0 131 (map file /m line 2: duplicate ConfigBits index)"
cexpect "truncated 2nd stream"           INFRA     0 "$CET"$'\n'
cexpect "truncated stream after mismatch" INFRA    0 "$CM1"$'\n'"$CET"$'\n'
cexpect "duplicate ConfigBits index"     INFRA     0 "$CEM"$'\n'
cexpect "bad record line"                INFRA     0 $'ERROR: configmem_fabulous_equiv setup: vector file /x line 23: wrong field count (want 3)\n'
sexpect() {  # sexpect <name> <want yes|no> <rc> <log content>
    printf '%s' "$4" >"$T/log"
    local got=no; gs_configmem_is_setup_error "$3" "$T/log" && got=yes
    if [[ "$got" == "$2" ]]; then echo "ok   cm setup-error $1 -> $got"; else echo "FAIL cm setup-error $1: want $2 got $got"; rc_all=1; fi
}
sexpect "plain setup ERROR"              yes 0   "$CET"$'\n'
sexpect "setup ERROR after mismatches"   yes 0   "$CM1"$'\n'"$CET"$'\n'
sexpect "setup ERROR + FAIL summary"     no  0   "$CET"$'\n'"$CF"$'\n'
sexpect "setup ERROR + PASS summary"     no  0   "$CEM"$'\n'"$CP"$'\n'
sexpect "setup ERROR, nonzero exit"      no  1   "$CET"$'\n'
sexpect "setup ERROR, then timeout"      no  124 "$CET"$'\n'
sexpect "completed functional FAIL"      no  0   "$CM1"$'\n'"$CF"$'\n'
sexpect "baseline PASS"                  no  0   "$CP"$'\n'
sexpect "other ERROR (not setup)"        no  0   $'ERROR: something else\n'
sexpect "empty log"                      no  0   ""

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
cstub novec     INFRA     "echo '$CE0'"

# ---- issue #401: the shared cfg cross-check (gs_cfg_ok), corpus-index validators
# (gs_corpus_index_ok / gs_corpus_entry_ok) and gate-level bench compile
# (gs_gate_compile) of the tb_logic_tile_bitstream replay drivers --------------
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1${2:+: $2}"; rc_all=1; }
# agree <tag> <name> <ok | diagnostic substring> <got>: "ok" must be a silent
# success; anything else must be a failure explained by an "error:" line that
# contains the substring (never an abort of the caller)
agree() {
    if [[ "$3" == ok && "$4" == ok ]] || { [[ "$3" != ok && "$4" != ok && "$4" != aborted* && "$4" == error:*"$3"* ]]; }; then pass "$1 $2"
    else fail "$1 $2" "want '$3', got '$4'"; fi
}
FX="$HERE/../sim/bitstream"
GOOD_CFG="$(tr -d '\n' < "$FX/top_io.cfg")"
case "${GOOD_CFG: -1}" in 0) BAD_CFG="${GOOD_CFG%?}1" ;; *) BAD_CFG="${GOOD_CFG%?}0" ;; esac
printf '%s\n' "$BAD_CFG" >"$T/bad.cfg"
head -c 20 "$FX/top_io.bin" >"$T/truncated.bin"

# cfg_case <name> <ok | diagnostic substring> <log content> [bin] [cfg] [snapshot]
# gs_cfg_ok exactly as every caller uses it: under `set -euo pipefail`, in an
# `if` (so a rejection must reach the caller's error branch, not abort it).
cfg_case() {
    local got
    printf '%s' "$3" >"$T/cfg.log"
    got="$( set -euo pipefail; if gs_cfg_ok lbl "$T/cfg.log" "${4:-$FX/top_io.bin}" "${5:-$FX/top_io.cfg}" "${6:-$FX/fabric_spec.json}"; then echo ok; fi 2>&1 )" || got="aborted rc=$?: $got"
    agree cfg "$1" "$2" "$got"
}
cfg_case "clean three-way match"                    ok   "CFG=$GOOD_CFG"$'\n'"$PASSL"$'\n'
cfg_case "no CFG= line"               "CFG=<hex> readback in $T/cfg.log, found 0" "$PASSL"$'\n'
cfg_case "duplicated CFG= line"       "found 2" "CFG=$GOOD_CFG"$'\n'"CFG=$GOOD_CFG"$'\n'"$PASSL"$'\n'
cfg_case "empty CFG= line"            "found 0" $'CFG=\n'"$PASSL"$'\n'
cfg_case "non-hex CFG= line"          "found 0" $'CFG=zzzz\n'"$PASSL"$'\n'
cfg_case "CFG= line with trailing text" "found 0" "CFG=$GOOD_CFG extra"$'\n'"$PASSL"$'\n'
cfg_case "loader readback != decode and record" "loaded cfg mismatch: sim=$BAD_CFG python=$GOOD_CFG recorded=$GOOD_CFG" "CFG=$BAD_CFG"$'\n'
cfg_case "recorded cfg != loader and decode" "loaded cfg mismatch: sim=$GOOD_CFG python=$GOOD_CFG recorded=$BAD_CFG" "CFG=$GOOD_CFG"$'\n' "$FX/top_io.bin" "$T/bad.cfg"
cfg_case "corrupt .bin: python decode fails" "python decode of $T/truncated.bin failed" "CFG=$GOOD_CFG"$'\n' "$T/truncated.bin"
cfg_case "empty simulator log"        "missing or empty input $T/cfg.log" ""
cfg_case "missing recorded cfg"       "missing or empty input $T/nonexistent.cfg" "CFG=$GOOD_CFG"$'\n' "$FX/top_io.bin" "$T/nonexistent.cfg"
cfg_case "missing bitstream"          "missing or empty input $T/nonexistent.bin" "CFG=$GOOD_CFG"$'\n' "$T/nonexistent.bin"
cfg_case "missing snapshot"           "missing or empty input $T/nonexistent.json" "CFG=$GOOD_CFG"$'\n' "$FX/top_io.bin" "$FX/top_io.cfg" "$T/nonexistent.json"
# a diagnostic is never an "infrastructure failure" (sim/pin_fixture_negative.sh
# reads that phrase as a crash/timeout, not as a rejection by the replay's checks)
printf 'no verdict\n' >"$T/cfg.log"
err="$(gs_cfg_ok lbl "$T/cfg.log" "$FX/top_io.bin" "$FX/top_io.cfg" "$FX/fabric_spec.json" 2>&1)"
if [[ -n "$err" && "$err" != *'infrastructure failure'* ]]; then pass "cfg diagnostic never says 'infrastructure failure'"
else fail "cfg diagnostic never says 'infrastructure failure'" "'$err'"; fi
# as a plain statement under `set -euo pipefail` the missing CFG= line is reported,
# not a silent exit from a `grep | cut` pipeline (the pre-#401 copies: rc 1, no output)
rc=0
err="$( set -euo pipefail; gs_cfg_ok lbl "$T/cfg.log" "$FX/top_io.bin" "$FX/top_io.cfg" "$FX/fabric_spec.json" 2>&1 )" || rc=$?
if [[ $rc -eq 1 && "$err" == "error: lbl:"* ]]; then pass "cfg plain call under set -euo pipefail: exit 1 with a diagnostic"
else fail "cfg plain call under set -euo pipefail: exit 1 with a diagnostic" "rc=$rc, '$err'"; fi
# the matched value is handed to the caller; no caller root variable is needed
printf 'CFG=%s\n' "$GOOD_CFG" >"$T/cfg.log"
if ( unset REPO_ROOT REPO HERE; gs_cfg_ok lbl "$T/cfg.log" "$FX/top_io.bin" "$FX/top_io.cfg" "$FX/fabric_spec.json" 2>/dev/null ); then pass "cfg needs no caller root variable"
else fail "cfg needs no caller root variable"; fi
GS_SIM_CFG=""
if gs_cfg_ok lbl "$T/cfg.log" "$FX/top_io.bin" "$FX/top_io.cfg" "$FX/fabric_spec.json" 2>/dev/null && [[ "$GS_SIM_CFG" == "$GOOD_CFG" ]]; then pass "cfg GS_SIM_CFG holds the matched readback"
else fail "cfg GS_SIM_CFG holds the matched readback" "'$GS_SIM_CFG'"; fi

# cmd_case <tag> <name> <ok | diagnostic substring> <cmd...>
cmd_case() {
    local got
    got="$("$4" "${@:5}" 2>&1)" && got=ok
    agree "$1" "$2" "$3" "$got"
}
# gs_corpus_index_ok <index>
CIX="$T/corpus/index.txt"
mkdir -p "$T/corpus"
printf 'casc2_s1 casc2\nregbel_a_s1 regbel\n' >"$CIX"
cmd_case index "valid index"                  ok                            gs_corpus_index_ok "$CIX"
printf '\ncasc2_s1 casc2\n\n' >"$CIX"
cmd_case index "valid index with blank lines" ok                            gs_corpus_index_ok "$CIX"
rm -f "$CIX"
cmd_case index "missing index"                "corpus index missing or empty: $CIX" gs_corpus_index_ok "$CIX"
: >"$CIX"
cmd_case index "empty index"                  "corpus index missing or empty: $CIX" gs_corpus_index_ok "$CIX"
printf ' \t\n\n' >"$CIX"
cmd_case index "whitespace-only index"        "corpus index has no entries: $CIX"    gs_corpus_index_ok "$CIX"
# gs_corpus_entry_ok <corpus_dir> <stem> <oracle> <extra>
cmd_case entry "valid entry"                  ok                                gs_corpus_entry_ok "$FX/corpus" casc2_s1 casc2 ""
cmd_case entry "extra field"                  "entry invalid"                    gs_corpus_entry_ok "$FX/corpus" casc2_s1 casc2 "more fields"
cmd_case entry "missing oracle"               "oracle '' unrecognised"           gs_corpus_entry_ok "$FX/corpus" casc2_s1 "" ""
cmd_case entry "unrecognised oracle"          "oracle 'bogus' unrecognised"      gs_corpus_entry_ok "$FX/corpus" casc2_s1 bogus ""
for ext in bin wiring cfg; do
    rm -rf "$T/one"; mkdir -p "$T/one"; cp "$FX/corpus/casc2_s1".{bin,wiring,cfg} "$T/one/"; rm "$T/one/casc2_s1.$ext"
    cmd_case entry "missing .$ext"            "missing corpus file $T/one/casc2_s1.$ext" gs_corpus_entry_ok "$T/one" casc2_s1 casc2 ""
done
: >"$T/one/casc2_s1.cfg"
cmd_case entry "empty .cfg is missing"        "missing corpus file $T/one/casc2_s1.cfg" gs_corpus_entry_ok "$T/one" casc2_s1 casc2 ""

# gs_gate_compile with stub model files, a trivial bench and netlist (needs only iverilog)
if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then
    mkdir -p "$T/gsc/sim" "$T/gsc/cells"
    : >"$T/gsc/cells/primitives.v"; : >"$T/gsc/cells/sky130_fd_sc_hd.v"
    echo 'module tiny_net(); wire w; endmodule' >"$T/gsc/tiny_net.v"
    cat >"$T/gsc/sim/tiny_tb.v" <<'V'
module tiny_tb(); initial begin $display("PASS: tiny_tb"); $finish; end endmodule
V
    cat >"$T/gsc/sim/tiny_bad_tb.v" <<'V'
module tiny_bad_tb(); no_such_cell u(); endmodule
V
    gsc_out="$(gs_gate_compile tiny_tb "$T/gsc/tiny_net.v" "$T/gsc/tiny.vvp" "$T/gsc/tiny_build.log" "$T/gsc/sim" "$T/gsc/cells" 2>&1)"; rc=$?
    gsc_run="$(vvp "$T/gsc/tiny.vvp" 2>&1 | head -n 1)"
    if [[ $rc -eq 0 && -z "$gsc_out" && "$gsc_run" == "PASS: tiny_tb" ]]; then pass "gate compile: bench + netlist + stub models -> runnable image, nothing printed"
    else fail "gate compile: bench + netlist + stub models -> runnable image, nothing printed" "rc=$rc, vvp said '$gsc_run', helper printed '$gsc_out'"; fi
    gsc_out="$(gs_gate_compile tiny_bad_tb "$T/gsc/tiny_net.v" "$T/gsc/bad.vvp" "$T/gsc/bad_build.log" "$T/gsc/sim" "$T/gsc/cells" 2>&1)"; rc=$?
    if [[ $rc -ne 0 && -z "$gsc_out" ]] && grep -q no_such_cell "$T/gsc/bad_build.log"; then pass "gate compile: undefined module -> nonzero, diagnostics in the log, nothing printed"
    else fail "gate compile: undefined module -> nonzero, diagnostics in the log, nothing printed" "rc=$rc, helper printed '$gsc_out'"; fi
else echo "skip gate compile: needs iverilog/vvp"; fi

# Real bench (PR #198 review): unmodified generated ConfigMem, broken inputs.
# Needs iverilog/vvp and the scratch FABulous output of flow/fabulous.sh
# (CM_RUN_DIR, default flow/build/fabulous-run); skipped (and said so) otherwise.
# flow/fabulous.sh runs the same checks unconditionally after its generator run.
CM_RUN_DIR="${CM_RUN_DIR:-$HERE/build/fabulous-run}"
CM_VEC_FILE="${CM_VEC_FILE:-$HERE/build/configmem_vectors.txt}"
if command -v iverilog >/dev/null && command -v vvp >/dev/null \
   && [[ -f "$CM_RUN_DIR/Tile/LOGIC4/LOGIC4_ConfigMem.v" && -f "$CM_RUN_DIR/Fabric/models_pack.v" ]]; then
    if iverilog -g2005 -o "$T/cm_tb" "$HERE/../design/fabulous/tb_configmem_equiv.v" \
            "$CM_RUN_DIR/Tile/LOGIC4/LOGIC4_ConfigMem.v" "$CM_RUN_DIR/Fabric/models_pack.v"; then
        : >"$T/vec_empty"
        cases=("missing-vec:/nonexistent/configmem_vectors.txt" "empty-vec:$T/vec_empty")
        if [[ -s "$CM_VEC_FILE" ]]; then
            awk '/^S/{n++} n<2' "$CM_VEC_FILE" >"$T/vec_one"
            cases+=("one-stream-vec:$T/vec_one")
        fi
        for c in "${cases[@]}"; do
            rc=0
            SIM_TIMEOUT_SECONDS=120 SIM_KILL_AFTER_SECONDS=5 gs_run_bounded "cm-real-${c%%:*}" "$T/log" \
                vvp "$T/cm_tb" +map="$HERE/../sim/bitstream/logic4_configmem.map" +vec="${c#*:}" 2>/dev/null || rc=$?
            got="$(gs_classify_configmem "$rc" "$T/log")"
            if gs_configmem_is_setup_error "$rc" "$T/log"; then
                echo "ok   cm real bench ${c%%:*} -> $got (setup ERROR, no summary)"
            else echo "FAIL cm real bench ${c%%:*}: got $got"; sed 's/^/     | /' "$T/log"; rc_all=1; fi
        done
        # issue #200: malformed transaction records / maps and valid controls
        # (flow/configmem_bad_inputs.py), driven through the real bench
        if [[ -s "$CM_VEC_FILE" ]] && python3 "$HERE/configmem_bad_inputs.py" "$CM_VEC_FILE" \
                "$HERE/../sim/bitstream/logic4_configmem.map" "$T/bad" >"$T/bad.lst"; then
            while read -r expect kind name vecf mapf; do
                rc=0
                SIM_TIMEOUT_SECONDS=120 SIM_KILL_AFTER_SECONDS=5 gs_run_bounded "cm-real-$kind-$name" "$T/log" \
                    vvp "$T/cm_tb" +map="$mapf" +vec="$vecf" 2>/dev/null || rc=$?
                got="$(gs_classify_configmem "$rc" "$T/log")"
                if [[ "$expect" == bad ]] && gs_configmem_is_setup_error "$rc" "$T/log"; then
                    echo "ok   cm real bench bad $kind $name -> $got (setup ERROR, no summary)"
                elif [[ "$expect" == good && "$got" == PASS ]]; then
                    echo "ok   cm real bench valid $kind control $name -> $got"
                else echo "FAIL cm real bench $expect $kind $name: got $got (rc=$rc)"; sed 's/^/     | /' "$T/log"; rc_all=1; fi
            done <"$T/bad.lst"
        elif [[ -s "$CM_VEC_FILE" ]]; then echo "FAIL cm real bench: configmem_bad_inputs.py failed"; rc_all=1
        else echo "skip cm real bench malformed inputs: needs $CM_VEC_FILE (run flow/fabulous.sh first)"; fi
    else echo "FAIL cm real bench: iverilog compile failed"; rc_all=1; fi
else
    echo "skip cm real bench: needs iverilog/vvp and $CM_RUN_DIR (run flow/fabulous.sh first)"
fi
exit "$rc_all"
