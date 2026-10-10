#!/usr/bin/env bash
# flow/test_sim_budget.sh (issue #157): regression for the per-simulation
# wall-clock budget (flow/gate_sim_verdict.sh gs_run_bounded*, flow/sim_budget.py)
# and its use by the replay drivers. Needs no iverilog/PDK: it uses stub
# simulators (a fake `vvp` on PATH for sim/pin_fixture_replay.sh and
# sim/pin_fixture_negative.sh). Runs serially; each timeout case costs ~1-2 s.
# Exit nonzero on any mismatch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
source "$HERE/gate_sim_verdict.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
TB=tb_logic_tile_bitstream; D=reg
PASSL="PASS: ${TB}[${D}] (10 checks, 0 failures; 5/5 perturbations detected)"
FUNCL="FAIL: ${TB}[${D}] (10 checks, 3 failures, 1 perturbations survived)"
rc_all=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; rc_all=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }  # check <name> <bash condition>
now_ms() { local t="${EPOCHREALTIME/[.,]/}"; echo "$((10#${t:0:${#t}-3}))"; }

fix_sha() { find "$REPO/sim/bitstream" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum; }
SHA_BEFORE="$(fix_sha)"

# ---- 1. budget validation -------------------------------------------------
for v in "" 0 00 -5 abc 1.5 10s " 7" 1234567; do
    if ( SIM_TIMEOUT_SECONDS="$v"; export SIM_TIMEOUT_SECONDS; gs_budget_check ) 2>/dev/null; then
        bad "invalid SIM_TIMEOUT_SECONDS='$v' accepted"
    else ok "invalid SIM_TIMEOUT_SECONDS='$v' rejected"; fi
    if ( SIM_KILL_AFTER_SECONDS="$v"; export SIM_KILL_AFTER_SECONDS; gs_budget_check ) 2>/dev/null; then
        bad "invalid SIM_KILL_AFTER_SECONDS='$v' accepted"
    else ok "invalid SIM_KILL_AFTER_SECONDS='$v' rejected"; fi
    if SIM_TIMEOUT_SECONDS="$v" python3 -I -c "import sys; sys.path.insert(0, '$HERE'); import sim_budget; sim_budget.budget()" 2>/dev/null; then
        bad "flow/sim_budget.py accepted SIM_TIMEOUT_SECONDS='$v'"
    else ok "flow/sim_budget.py rejected SIM_TIMEOUT_SECONDS='$v'"; fi
done
for v in 1 30 900 999999; do
    check "valid SIM_TIMEOUT_SECONDS=$v accepted" "( SIM_TIMEOUT_SECONDS=$v; export SIM_TIMEOUT_SECONDS; gs_budget_check && [[ \$(gs_budget) == $v ]] )"
done
check "default budget used when unset" "( unset SIM_TIMEOUT_SECONDS SIM_KILL_AFTER_SECONDS; [[ \$(gs_budget) == $GS_SIM_TIMEOUT_DEFAULT && \$(gs_kill_after) == $GS_SIM_KILL_AFTER_DEFAULT ]] )"
pyd="$(env -u SIM_TIMEOUT_SECONDS python3 -I -c "import sys; sys.path.insert(0, '$HERE'); import sim_budget; print(sim_budget.budget())")"
check "flow/sim_budget.py default == GS_SIM_TIMEOUT_DEFAULT ($GS_SIM_TIMEOUT_DEFAULT)" "[[ '$pyd' == '$GS_SIM_TIMEOUT_DEFAULT' ]]"
# drivers refuse to start on an invalid override
for drv in "sim/pin_fixture_replay.sh /nonexistent.vvp lbl" "sim/run.sh"; do
    out="$(SIM_TIMEOUT_SECONDS=0 "$REPO"/$drv 2>&1)"; r=$?
    check "$drv refuses SIM_TIMEOUT_SECONDS=0 (rc=$r)" "[[ $r -ne 0 && \"\$out\" == *'invalid SIM_TIMEOUT_SECONDS'* ]]"
done

# ---- 2. stub simulators -----------------------------------------------------
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/$1"; chmod +x "$T/$1"; }
mk hang_term        'echo "running"; exec sleep 1000'                       # honours TERM
mk hang_ignore_term "trap '' TERM; echo running; while :; do sleep 0.2; done" # ignores TERM
mk pass_then_hang   "echo '$PASSL'; trap '' TERM; while :; do sleep 0.2; done"
mk func_then_hang   "echo '$FUNCL'; exec sleep 1000"
mk pass_ok          "echo 'CFG=ab'; echo '$PASSL'"
mk func_ok          "echo 'CFG=ab'; echo '$FUNCL'"
mk own_rc124        "echo '$PASSL'; exit 124"                               # not a timeout

export SIM_TIMEOUT_SECONDS=1 SIM_KILL_AFTER_SECONDS=1
# bounded <stub> -> sets RC, ELAPSED_MS, ERR; log in $T/<stub>.log
bounded() {
    local t0; t0="$(now_ms)"; RC=0
    gs_run_bounded "fixture_$1" "$T/$1.log" "$T/$1" 2>"$T/$1.err" || RC=$?
    ELAPSED_MS=$(( $(now_ms) - t0 )); ERR="$(cat "$T/$1.err")"
}
bounded hang_term
check "TERM-honouring hang stopped within budget (rc=$RC, ${ELAPSED_MS}ms)" "[[ $RC -eq 124 && $ELAPSED_MS -lt 4000 ]]"
check "timeout diagnostic names fixture, budget and log" "[[ \"\$ERR\" == *fixture_hang_term*'1s wall-clock budget'*'$T/hang_term.log'* ]]"
check "timeout marker appended to log, simulator output kept" "grep -q '^running' '$T/hang_term.log' && grep -q '^TIMEOUT: .*fixture_hang_term' '$T/hang_term.log'"
check "timeout classified INFRA" "[[ \$(gs_classify $RC '$T/hang_term.log' $TB $D) == INFRA ]]"

bounded hang_ignore_term
check "TERM-ignoring hang force-killed (rc=$RC, ${ELAPSED_MS}ms)" "[[ $RC -eq 137 && $ELAPSED_MS -lt 6000 ]]"
check "forced-kill diagnostic says so" "[[ \"\$ERR\" == *'forced KILL'* ]]"
check "no stray stub process left" "! pgrep -f '$T/hang_ignore_term' >/dev/null"

bounded pass_then_hang
check "PASS printed then timeout -> INFRA (rc=$RC)" "[[ $RC -eq 137 && \$(gs_classify $RC '$T/pass_then_hang.log' $TB $D) == INFRA ]]"
bounded func_then_hang
check "functional FAIL printed then timeout -> INFRA, not FUNC_FAIL (rc=$RC)" "[[ $RC -eq 124 && \$(gs_classify $RC '$T/func_then_hang.log' $TB $D) == INFRA ]]"

bounded pass_ok
check "completed PASS unchanged (rc=$RC)" "[[ $RC -eq 0 && \$(gs_classify $RC '$T/pass_ok.log' $TB $D) == PASS && -z \"\$ERR\" ]]"
check "completed run log byte-identical to simulator output" "cmp -s '$T/pass_ok.log' <('$T/pass_ok')"
bounded func_ok
check "completed functional FAIL unchanged (rc=$RC)" "[[ $RC -eq 0 && \$(gs_classify $RC '$T/func_ok.log' $TB $D) == FUNC_FAIL ]]"
bounded own_rc124
check "simulator's own rc 124 is INFRA but not reported as a timeout" "[[ $RC -eq 124 && -z \"\$ERR\" ]] && ! grep -q '^TIMEOUT' '$T/own_rc124.log' && [[ \$(gs_classify $RC '$T/own_rc124.log' $TB $D) == INFRA ]]"

# tee variant (sim/run.sh, gate-sim-routed.sh, fabulous.sh, sdf-resim.sh)
RC=0; out="$(gs_run_bounded_tee tee_ok "$T/tee_ok.log" "$T/pass_ok" 2>/dev/null)" || RC=$?
check "tee variant: completed run streams and logs output (rc=$RC)" "[[ $RC -eq 0 && \"\$out\" == *'$PASSL'* ]] && cmp -s '$T/tee_ok.log' <('$T/pass_ok')"
t0="$(now_ms)"; RC=0; gs_run_bounded_tee tee_hang "$T/tee_hang.log" "$T/pass_then_hang" >/dev/null 2>"$T/tee.err" || RC=$?
el=$(( $(now_ms) - t0 ))
check "tee variant: PASS then TERM-ignoring hang -> rc 137 within bound (${el}ms)" "[[ $RC -eq 137 && $el -lt 6000 ]] && grep -q 'tee_hang' '$T/tee.err'"
check "tee variant under set -e returns the status instead of aborting" "( set -e; gs_run_bounded_tee x '$T/x.log' '$T/own_rc124' >/dev/null || [[ \$? -eq 124 ]] )"

# ---- 3. Python drivers: a timeout is never a kill / pass ------------------
pyout="$(cd "$T" && python3 -I - "$REPO" <<'PY' 2>&1
import importlib.util, pathlib, sys
repo = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("mutation", repo / "sim" / "mutation.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rc, txt = m.run(["sleep", "5"])
assert rc is None and "TIMEOUT" in txt, (rc, txt)
# a hanging testbench run must surface as an error, never as a killer
m.run = lambda cmd: (0, "") if cmd[0] == "iverilog" else (None, "TIMEOUT: stub")
k, err = m.killer(pathlib.Path("."))
assert k is None and err and "TIMEOUT" in err, (k, err)
print("python-ok")
PY
)"
check "sim/mutation.py: timeout -> infrastructure error, not a kill" "[[ \"\$pyout\" == *python-ok* ]]"
[[ "$pyout" == *python-ok* ]] || echo "$pyout"

# ---- 4. end to end through sim/pin_fixture_replay.sh with a fake vvp --------
mkdir -p "$T/bin"
cat >"$T/bin/vvp" <<'S'
#!/usr/bin/env bash
d=; b=
for a; do case "$a" in +design=*) d="${a#+design=}";; +bin=*) b="${a#+bin=}";; esac; done
echo "CFG=$(tr -d '\n' < "${b%.bin}.cfg")"
case "$FAKE_VVP_MODE" in
    pass)      echo "PASS: tb_logic_tile_bitstream[$d] (1 checks, 0 failures; 1/1 perturbations detected)"; exit 0 ;;
    pass_hang) echo "PASS: tb_logic_tile_bitstream[$d] (1 checks, 0 failures; 1/1 perturbations detected)" ;;
    func_hang) echo "FAIL: tb_logic_tile_bitstream[$d] (1 checks, 1 failures, 0 perturbations survived)" ;;
esac
trap '' TERM
while :; do sleep 0.2; done
S
chmod +x "$T/bin/vvp"
replay() {  # replay <mode> [flags] -> RC, OUT
    RC=0; OUT="$(PATH="$T/bin:$PATH" FAKE_VVP_MODE="$1" PIN_REPLAY_LOG_DIR="$T/replay_$1" \
        "$REPO/sim/pin_fixture_replay.sh" "$T/compiled.vvp" stub "${@:2}" 2>&1)" || RC=$?
}
replay pass
check "pin replay: completed PASS runs keep their classification (rc=$RC)" "[[ $RC -eq 0 && \"\$OUT\" == *'replayed [stub]: 3/3 PASS'* ]]"
[[ "$RC" -eq 0 ]] || echo "$OUT"
t0="$(now_ms)"; replay pass_hang --sim-only; el=$(( $(now_ms) - t0 ))
check "pin replay: PASS-then-hang fails as infrastructure (rc=$RC, ${el}ms for 3 runs)" "[[ $RC -ne 0 && \"\$OUT\" == *'infrastructure failure'*'simulation timeout'* && \"\$OUT\" == *'0/3 PASS'* && $el -lt 20000 ]]"
check "pin replay: diagnostic names the stalled fixture and its log" "[[ \"\$OUT\" == *\"fixture 'pin-experiment fan4_distinct_s1[fan4] [stub]'\"*'$T/replay_pass_hang/pin_experiment/fan4_distinct_s1.log'* ]]"
replay func_hang --sim-only
check "pin replay: FAIL-then-hang is not a completed functional rejection" "[[ $RC -ne 0 && \"\$OUT\" != *'completed functional rejection'* && \"\$OUT\" == *'infrastructure failure'* ]]"
# the negative-control script must not count a timed-out run as a rejection
RC=0; OUT="$(PATH="$T/bin:$PATH" FAKE_VVP_MODE=func_hang "$REPO/sim/pin_fixture_negative.sh" "$T/compiled.vvp" stub 2>&1)" || RC=$?
check "pin negative controls: timed-out simulation never satisfies N-c (rc=$RC)" "[[ $RC -ne 0 && \"\$OUT\" == *'only through an infrastructure failure'* && \"\$OUT\" != *'rejected 3/3 corrupted streams'* ]]"
check "pin negative controls: static N-a/N-b still pass" "[[ \"\$OUT\" == *'N-a missing fixture file [stub] OK'* && \"\$OUT\" == *'N-b empty index [stub] OK'* ]]"

check "committed fixture bytes under sim/bitstream unchanged" "[[ '$(fix_sha)' == '$SHA_BEFORE' ]]"
exit "$rc_all"
