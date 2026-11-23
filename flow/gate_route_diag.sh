# flow/gate_route_diag.sh -- sourced helper (issue #189, EXPERIMENTAL, observation-only):
# replay of the three existing route diagnostic suites against the committed synthesized
# netlist of the experimental composed tile, for flow/gate-sim-bitstream.sh.
#
#   route    flow/route_diag.py   -> sim/tb_route_diag.v   LUT-input directional routes (#176)
#   ctrl     flow/ctrl_route.py   -> sim/tb_ctrl_route.v   control-jump enable/reset routes (#181)
#   outroute flow/output_route.py -> sim/tb_output_route.v boundary output-track sources (#180)
#
# Generators and benches are reused UNMODIFIED, with their independent oracles (expected
# values from the case identifier and the applied stimulus only). Each suite is loaded in
# sequence into ONE live instance of the netlist through its flat cfg port, i.e. by the
# benches' simulation-only stream-to-cfg loader; the generated ConfigMem is not in this
# netlist. The case manifest must cover the suite's required set exactly once, and the
# coverage report must be that full set at the suite's absolute size -- never a set
# re-derived from the manifest, which a shortened manifest and a matching report would
# satisfy. The run, readback and coverage checks are the ones of flow/
# route_diag_helpers.sh, shared with the generated-tile replay (#260); only the
# generation, compilation and gate-level orchestration live here.
# Zero delay (the benches' `#1` settle steps are a simulation convention).
# Functional only: no SDF/timing, inter-tile or ratified-fabric claim (ADR-0004/0005
# Proposed, experimental same-index matrix).
#
# The caller must set: REPO_ROOT, SCRIPT_DIR, BUILD_DIR, BS_DIR, NETLIST, CELL_DIR, and
# source flow/gate_sim_verdict.sh and flow/route_diag_helpers.sh. GATE_SIM_VVP overrides
# the simulator (stub tests).
#
# rd_positive <suite>   generate, check the manifest, compile, run; 0 iff a completed
#                       PASS with exact coverage and per-case cfg readback == decode.
# rd_negative <suite>   (after rd_positive) re-point ONE case's route under test to a
#                       different LEGAL source of the same sink (flow/route_diag_negative.py)
#                       with the case list / oracle unchanged; 0 iff the run completes with
#                       a functional FAIL on exactly that case, coverage intact and cfg ==
#                       decode of the altered streams. PASS (accepted), a setup/assembly
#                       error, a timeout or any INFRA verdict is a failure.
# Every failure prints the reason on stderr; logs land directly in $BUILD_DIR/*.log.

# The shared replay checks must be sourced first: without RD_SUITES the caller's
# suite loops would skip every suite and still report success.
if ! declare -F rd_run >/dev/null || [[ -z "${RD_SUITES:-}" ]]; then
    echo "error: source flow/route_diag_helpers.sh before flow/gate_route_diag.sh" >&2; return 1
fi

declare -A RD_GEN=([route]=route_diag.py [ctrl]=ctrl_route.py [outroute]=output_route.py)
declare -A RD_DESC=([route]="LUT-input directional routes (BEL, pin, edge)"
                    [ctrl]="control-jump routes (16 enable + 4 shared reset)"
                    [outroute]="boundary output-track sources (edge, track, source)")
# negative controls: "<case> <route-under-test FASM pip> <different legal source, same sink>"
declare -A RD_NEG_ID=([route]=N7 [ctrl]=N8 [outroute]=N9)
declare -A RD_NEG=(
    [route]="R_C_I2_E X1Y1.E1END2.LC_I2 X1Y1.S1END2.LC_I2"
    [ctrl]="C_EN_B_E X1Y1.E1END1.J_EN_BEG1 X1Y1.S1END1.J_EN_BEG1"
    [outroute]="O_W3_D X1Y1.LD_O.W1BEG3 X1Y1.S1END3.W1BEG3"
)
declare -A RD_OK=([route]=0 [ctrl]=0 [outroute]=0)
declare -A RD_N=([route]=0 [ctrl]=0 [outroute]=0)

rd_dir() { echo "$BUILD_DIR/rd_$1"; }
rd_vvp() { echo "$BUILD_DIR/${RD_BENCH[$1]}.vvp"; }

# rd_manifest_ok <suite> <dir>: the case manifest covers the required set exactly once,
# case ids are unique and every case has its stream and decoded cfg. Sets RD_N[suite].
rd_manifest_ok() {
    local s="$1" d="$2" id
    [[ -s "$d/cases.txt" && -s "$d/required.txt" && -s "$d/${RD_WIRE[$s]}" ]] \
        || { echo "error: [$s] missing case list, required set or wiring manifest in $d" >&2; return 1; }
    [[ "$(sort "$d/required.txt" | uniq -d | wc -l)" -eq 0 ]] \
        || { echo "error: [$s] duplicate entries in the required route set" >&2; return 1; }
    [[ "$(awk '{print $1}' "$d/cases.txt" | sort | uniq -d | wc -l)" -eq 0 ]] \
        || { echo "error: [$s] duplicate case ids in the case list" >&2; return 1; }
    [[ "$(awk '{print $2, $3, $4}' "$d/cases.txt" | sort)" == "$(sort "$d/required.txt")" ]] \
        || { echo "error: [$s] case list does not cover the required route set exactly once (missing or duplicate route)" >&2; return 1; }
    while read -r id _; do
        [[ -s "$d/$id.bin" && -s "$d/$id.cfg" ]] || { echo "error: [$s] case $id: missing .bin/.cfg" >&2; return 1; }
    done < "$d/cases.txt"
    RD_N[$s]="$(wc -l < "$d/required.txt")"
}

# rd_compile <suite> <netlist> <out.vvp>
rd_compile() {
    local s="$1" log="$BUILD_DIR/${RD_BENCH[$1]}_build.log"
    iverilog -g2012 -s "${RD_BENCH[$s]}" -I "$REPO_ROOT/sim" -o "$3" \
        "$REPO_ROOT/sim/${RD_BENCH[$s]}.v" "$2" "$CELL_DIR/primitives.v" "$CELL_DIR/sky130_fd_sc_hd.v" \
        >"$log" 2>&1 || { echo "error: [$s] compile of the gate-level ${RD_BENCH[$s]} bench failed (see $log)" >&2; return 1; }
}

rd_failing_cases() {  # <log>: sorted ids of the cases the bench reported as failing
    sed -n 's/^  case \([A-Za-z0-9_]*\): [0-9]* mismatches$/\1/p' "$1" | sort | xargs
}

# rd_check <suite> <dir> <log>: run and require a completed PASS, exact coverage and readback
rd_check() {
    local s="$1" d="$2" log="$3" v
    v="$(rd_run "$s" "${RD_BENCH[$s]}" "$BS_DIR/logic4_configmem.map" "$d" "$d/cases.txt" \
        "$d/${RD_WIRE[$s]}" "$log" "${GATE_SIM_VVP:-vvp}" "$(rd_vvp "$s")")"
    if [[ "$v" != PASS ]]; then
        echo "error: [$s] gate-level ${RD_BENCH[$s]} did not complete with PASS (verdict $v; see $log)" >&2
        tail -n 8 "$log" >&2 || true; return 1
    fi
    rd_cov_ok "$s" "$d" "$log" || { echo "error: [$s] gate-level coverage incomplete (see $log)" >&2; return 1; }
    rd_cfg_ok "[$s] case" "$d" "$d/cases.txt" "$log" || { echo "error: [$s] gate-level loaded cfg != python decode" >&2; return 1; }
}

rd_positive() {
    local s="$1" d log
    d="$(rd_dir "$s")"; log="$BUILD_DIR/${RD_BENCH[$s]}_gate.log"
    RD_OK[$s]=0
    rm -rf "$d" "${d}_neg"
    python3 -I "$SCRIPT_DIR/${RD_GEN[$s]}" "$d" --snapshot "$BS_DIR/fabric_spec.json" >"$BUILD_DIR/${RD_BENCH[$s]}_gen.log" 2>&1 \
        || { echo "error: [$s] stream generation failed (see $BUILD_DIR/${RD_BENCH[$s]}_gen.log)" >&2; return 1; }
    rd_manifest_ok "$s" "$d" || return 1
    rd_compile "$s" "$NETLIST" "$(rd_vvp "$s")" || return 1
    rd_check "$s" "$d" "$log" || return 1
    RD_OK[$s]=1
    echo "  [$s] $(grep -m1 -E '^COVERAGE: [0-9]+/' "$log")"
    echo "  [$s] $(grep -m1 '^PASS' "$log")"
    echo "=== route diagnostic [$s] at gate level: PASS, ${RD_N[$s]}/${RD_N[$s]} ${RD_DESC[$s]} (exact required set), cfg == decode for all ${RD_N[$s]} streams ==="
}

rd_negative() {
    local s="$1" nid="${RD_NEG_ID[$1]}" ncase nold nnew nd nlog v got
    if [[ "${RD_OK[$s]}" -ne 1 ]]; then
        echo "error: negative $nid [$s] skipped: the positive gate-level leg did not pass" >&2; return 1
    fi
    read -r ncase nold nnew <<<"${RD_NEG[$s]}"
    nd="$(rd_dir "$s")_neg"; nlog="$BUILD_DIR/neg_${RD_BENCH[$s]}_other_source.log"
    rm -rf "$nd"
    python3 -I "$SCRIPT_DIR/route_diag_negative.py" "$(rd_dir "$s")" "$nd" "$ncase" "$nold" "$nnew" \
            --snapshot "$BS_DIR/fabric_spec.json" >"$BUILD_DIR/neg_${RD_BENCH[$s]}_gen.log" 2>&1 \
        || { echo "error: negative $nid [$s] could not build the altered stream (setup failure, not a detection; see $BUILD_DIR/neg_${RD_BENCH[$s]}_gen.log)" >&2; return 1; }
    v="$(rd_run "$s" "${RD_BENCH[$s]}" "$BS_DIR/logic4_configmem.map" "$nd" "$nd/cases.txt" \
        "$nd/${RD_WIRE[$s]}" "$nlog" "${GATE_SIM_VVP:-vvp}" "$(rd_vvp "$s")")"
    case "$v" in
        FUNC_FAIL) ;;
        PASS) echo "error: negative $nid [$s] (case $ncase: $nold -> $nnew) was ACCEPTED" >&2; return 1 ;;
        *) echo "error: negative $nid [$s] did not complete with a recognised functional verdict (infrastructure failure; see $nlog)" >&2
           tail -n 8 "$nlog" >&2 || true; return 1 ;;
    esac
    got="$(rd_failing_cases "$nlog")"
    if [[ "$got" != "$ncase" ]]; then
        echo "error: negative $nid [$s] failing cases [$got] != predicted [$ncase]" >&2; return 1
    fi
    if ! rd_cov_ok "$s" "$nd" "$nlog" || ! rd_cfg_ok "[$s] case" "$nd" "$nd/cases.txt" "$nlog"; then
        echo "error: negative $nid [$s] coverage/readback not intact on the altered streams" >&2; return 1
    fi
    echo "negative $nid ($s case $ncase: $nold -> $nnew) OK: completed functional rejection -> $(grep -m1 -E '^FAIL' "$nlog")"
    echo "negative $nid [$s] failing cases == predicted ($ncase only, 1/${RD_N[$s]}); cfg == decode of the altered streams"
}
