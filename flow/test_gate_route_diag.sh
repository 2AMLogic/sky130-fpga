#!/usr/bin/env bash
# flow/test_gate_route_diag.sh (issue #189): failure-mode regression for the gate-level
# route diagnostic replay (flow/gate_route_diag.sh, used by flow/gate-sim-bitstream.sh).
#
# Uses the real LUT-input route suite (flow/route_diag.py + sim/tb_route_diag.v) against
# the committed synthesized netlist for the positive and negative legs and for manifest,
# readback and compile defects, and stub simulators with a canned log for simulator
# errors, timeouts, missing/conflicting verdicts and coverage-report defects. Every
# defect must make the replay fail; the unmodified suite must pass and its legal-other-
# source negative control must be a completed functional FAIL on exactly one case.
# Needs iverilog/vvp and the sky130_fd_sc_hd Verilog models (PDK_ROOT, klt or ~/.volare),
# like flow/gate-sim-bitstream.sh. Exit nonzero on any mismatch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BS_DIR="$REPO_ROOT/sim/bitstream"
NETLIST="$REPO_ROOT/layout/experimental/logic_tile_routed.synth.v"
# shellcheck source=flow/gate_sim_verdict.sh
source "$SCRIPT_DIR/gate_sim_verdict.sh"
for tool in iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done
LIBS_REF=""
if command -v klt >/dev/null 2>&1; then
    LIBS_REF="$(klt pdk find --pdk sky130A --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assets", {}).get("libs_ref", ""))' 2>/dev/null || true)"
fi
CELL_DIR=""
for c in "${LIBS_REF:+$LIBS_REF/sky130_fd_sc_hd/verilog}" \
         "${PDK_ROOT:+$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog}" \
         "$HOME/.volare/sky130A/libs.ref/sky130_fd_sc_hd/verilog"; do
    if [[ -n "$c" && -f "$c/sky130_fd_sc_hd.v" && -f "$c/primitives.v" ]]; then CELL_DIR="$c"; break; fi
done
[[ -n "$CELL_DIR" ]] || { echo "error: could not resolve sky130_fd_sc_hd Verilog cell models (set PDK_ROOT)" >&2; exit 1; }

BUILD_DIR="$(mktemp -d)"; trap 'rm -rf "$BUILD_DIR"' EXIT
# shellcheck source=flow/gate_route_diag.sh
source "$SCRIPT_DIR/gate_route_diag.sh"
S=route
rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }
# must_fail <name> <cmd...>: the command must return nonzero (its stderr goes to a per-test log)
must_fail() {
    local name="$1"; shift
    if "$@" >"$BUILD_DIR/t.out" 2>"$BUILD_DIR/t.err"; then bad "$name: was ACCEPTED"; else ok "$name -> rejected ($(grep -m1 . "$BUILD_DIR/t.err" | cut -c1-110))"; fi
}
scratch() {  # scratch <name>: fresh copy of the generated suite directory
    rm -rf "$BUILD_DIR/x_$1"; cp -r "$(rd_dir "$S")" "$BUILD_DIR/x_$1"; echo "$BUILD_DIR/x_$1"
}

# ---- positive leg and its negative control (real simulator) ----
if rd_positive "$S" >"$BUILD_DIR/pos.out" 2>&1; then ok "unmodified route suite passes (${RD_N[$S]}/${RD_N[$S]} routes)"
else bad "unmodified route suite"; cat "$BUILD_DIR/pos.out"; echo "cannot continue"; exit 1; fi
# canned copies: later runs (real and stub) overwrite the original log paths
GOOD_LOG="$BUILD_DIR/canned_pass.log"; cp "$BUILD_DIR/${RD_TB[$S]}_gate.log" "$GOOD_LOG"
if rd_negative "$S" >"$BUILD_DIR/neg.out" 2>&1 && grep -q '^negative N7 \[route\] failing cases == predicted' "$BUILD_DIR/neg.out"; then
    ok "legal-other-source negative control: completed functional FAIL on exactly the altered case"
else bad "negative control"; cat "$BUILD_DIR/neg.out"; fi
NEG_LOG="$BUILD_DIR/canned_neg.log"; cp "$BUILD_DIR/neg_${RD_TB[$S]}_other_source.log" "$NEG_LOG"
grep -q '^  case R_C_I2_E: [0-9]* mismatches$' "$NEG_LOG" || bad "canned negative log lacks the R_C_I2_E failure line"

# ---- manifest defects ----
d="$(scratch miss)"; sed -i '5d' "$d/cases.txt"
must_fail "missing case (manifest)" rd_manifest_ok "$S" "$d"
must_fail "missing case (simulated anyway)" rd_check "$S" "$d" "$BUILD_DIR/miss.log"
d="$(scratch dup)"; head -n1 "$d/cases.txt" >>"$d/cases.txt"
must_fail "duplicate case (manifest)" rd_manifest_ok "$S" "$d"
must_fail "duplicate case (simulated anyway)" rd_check "$S" "$d" "$BUILD_DIR/dup.log"
d="$(scratch dupid)"; sed -i '2s/^[^ ]*/R_A_I0_N/' "$d/cases.txt"
must_fail "duplicate case id with another route" rd_manifest_ok "$S" "$d"
d="$(scratch req)"; sed -i '3d' "$d/required.txt"
must_fail "case list != required set" rd_manifest_ok "$S" "$d"
d="$(scratch bin)"; rm "$d/$(awk 'NR==7{print $1}' "$d/cases.txt").bin"
must_fail "missing stream file" rd_manifest_ok "$S" "$d"
must_fail "missing stream file (simulated anyway: loader setup failure)" rd_check "$S" "$d" "$BUILD_DIR/bin.log"

# ---- readback mismatch (stream and oracle intact, recorded decode differs) ----
d="$(scratch cfg)"; id="$(awk 'NR==9{print $1}' "$d/cases.txt")"
python3 -I -c 'import sys; p=sys.argv[1]; v=int(open(p).read(),16)^1; open(p,"w").write(f"{v:040x}\n")' "$d/$id.cfg"
must_fail "readback != decode" rd_check "$S" "$d" "$BUILD_DIR/cfg.log"
grep -q "readback" "$BUILD_DIR/t.err" || bad "readback mismatch was not reported as a readback mismatch"
# a valid stream substituted under another case's name: loaded cfg != that case's decode
d="$(scratch swap)"; a="$(awk 'NR==10{print $1}' "$d/cases.txt")"; b="$(awk 'NR==11{print $1}' "$d/cases.txt")"
cp "$d/$b.bin" "$d/$a.bin"
must_fail "stream swapped without its decode" rd_check "$S" "$d" "$BUILD_DIR/swap.log"

# ---- compile error ----
head -n 40 "$NETLIST" >"$BUILD_DIR/broken.synth.v"
must_fail "compile error" rd_compile "$S" "$BUILD_DIR/broken.synth.v" "$BUILD_DIR/broken.vvp"

# ---- stub simulators: errors, timeouts, verdict and coverage-report defects ----
STUB="$BUILD_DIR/stub_vvp"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_SRC"
case "$STUB_MODE" in
    exit) exit 3 ;;
    sleep) sleep 30 ;;
esac
exit 0
EOF
chmod +x "$STUB"
D="$(rd_dir "$S")"
stub() {  # stub <name> <mode> <canned log> <fn> : fn must fail with the stub simulator
    local name="$1" mode="$2" src="$3" fn="$4"
    STUB_MODE="$mode" STUB_SRC="$src" GATE_SIM_VVP="$STUB" must_fail "$name" "$fn"
}
pos_check() { rd_check "$S" "$D" "$BUILD_DIR/stub.log"; }
neg_leg()   { rd_negative "$S"; }
export STUB_MODE STUB_SRC
if STUB_MODE=cat STUB_SRC="$GOOD_LOG" GATE_SIM_VVP="$STUB" pos_check >/dev/null 2>&1; then ok "stub replaying the good log passes (harness sanity)"
else bad "stub harness sanity"; fi
if STUB_MODE=cat STUB_SRC="$NEG_LOG" GATE_SIM_VVP="$STUB" neg_leg >/dev/null 2>&1; then ok "stub replaying the negative log is a detection (harness sanity)"
else bad "stub negative harness sanity"; fi
stub "simulator error (nonzero exit after PASS)" exit "$GOOD_LOG" pos_check
SIM_TIMEOUT_SECONDS=1 SIM_KILL_AFTER_SECONDS=1 stub "timeout after PASS" sleep "$GOOD_LOG" pos_check
grep -v '^PASS' "$GOOD_LOG" >"$BUILD_DIR/noverdict.log"
stub "missing verdict" cat "$BUILD_DIR/noverdict.log" pos_check
{ cat "$GOOD_LOG"; grep '^FAIL' "$NEG_LOG"; } >"$BUILD_DIR/conflict.log"
stub "conflicting verdicts" cat "$BUILD_DIR/conflict.log" pos_check
{ cat "$GOOD_LOG"; grep '^PASS' "$GOOD_LOG"; } >"$BUILD_DIR/twopass.log"
stub "repeated verdict" cat "$BUILD_DIR/twopass.log" pos_check
grep -v '^COVERAGE: ROUTE C 2 E:' "$GOOD_LOG" >"$BUILD_DIR/covmiss.log"
stub "coverage report misses a route" cat "$BUILD_DIR/covmiss.log" pos_check
awk '{print} /^COVERAGE: ROUTE C 2 E:/{print}' "$GOOD_LOG" >"$BUILD_DIR/covdup.log"
stub "coverage report duplicates a route" cat "$BUILD_DIR/covdup.log" pos_check
grep -v '^CFG R_B_I1_S ' "$GOOD_LOG" >"$BUILD_DIR/cfgmiss.log"
stub "missing cfg readback" cat "$BUILD_DIR/cfgmiss.log" pos_check
awk '{print} /^CFG R_B_I1_S /{print}' "$GOOD_LOG" >"$BUILD_DIR/cfgdup.log"
stub "duplicate cfg readback" cat "$BUILD_DIR/cfgdup.log" pos_check
stub "negative control accepted (PASS)" cat "$GOOD_LOG" neg_leg
SIM_TIMEOUT_SECONDS=1 SIM_KILL_AFTER_SECONDS=1 stub "negative control timeout after FAIL" sleep "$NEG_LOG" neg_leg
stub "negative control simulator error after FAIL" exit "$NEG_LOG" neg_leg
sed 's/^  case R_C_I2_E: \([0-9]*\) mismatches$/  case R_C_I2_N: \1 mismatches/' "$NEG_LOG" >"$BUILD_DIR/negwrong.log"
stub "negative control fails on the wrong case" cat "$BUILD_DIR/negwrong.log" neg_leg
{ cat "$NEG_LOG"; echo "  case R_A_I0_N: 3 mismatches"; } >"$BUILD_DIR/negextra.log"
stub "negative control fails on an extra case" cat "$BUILD_DIR/negextra.log" neg_leg
{ echo "FAIL: tb_route_diag: loader rejected case R_C_I2_E: bad sync header"; } >"$BUILD_DIR/negsetup.log"
stub "negative control setup/loader FAIL" cat "$BUILD_DIR/negsetup.log" neg_leg

# ---- negative-control setup failure: an illegal replacement source is never a detection ----
RD_NEG[$S]="R_C_I2_E X1Y1.E1END2.LC_I2 X1Y1.N1END1.LC_I2"
must_fail "negative control with an illegal source (setup failure)" rd_negative "$S"
grep -q 'setup failure' "$BUILD_DIR/t.err" || bad "illegal-source negative not reported as a setup failure"

if [[ "$rc_all" -ne 0 ]]; then echo "test_gate_route_diag: FAIL"; exit 1; fi
echo "test_gate_route_diag: PASS"
