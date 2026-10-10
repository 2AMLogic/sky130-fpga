#!/usr/bin/env bash
# flow/generated_tile_replay.sh -- integrated replay of committed bitstreams
# through the FABulous-GENERATED LOGIC4 tile (issue #140, EXPERIMENTAL G5).
#
# Called by flow/fabulous.sh after a clean generation; can be re-run by hand on
# an existing scratch run:
#   flow/generated_tile_replay.sh <fabulous-run dir> <build dir>
#
# What it checks (all in the gitignored build dir, nothing generated is committed):
#   1. The generated tile module Tile/LOGIC4/LOGIC4.v exposes exactly the boundary
#      the testbench adapter connects (4x4 track ports, UserCLK/UserCLKo,
#      FrameData/FrameStrobe in/out) and really composes the generated
#      LOGIC4_ConfigMem, LOGIC4_switch_matrix and four lut4_ff_bel instances.
#   2. sim/tb_logic_tile_bitstream.v is compiled twice: -DGEN_TILE against the
#      unmodified generated LOGIC4 (+ConfigMem, matrix, BEL, models_pack.v), and
#      against the repository composition design/rtl/logic_tile_routed.v.
#   3. Every fixture -- the two baseline designs (top_io/comb, top_reg/reg), every
#      line of sim/bitstream/corpus/index.txt and the verified pin-experiment set --
#      is replayed on BOTH with the same independent oracle and +mutate
#      perturbations. The generated tile is loaded ONLY through FrameData/
#      FrameStrobe frame writes in stream order; its internal ConfigBits read
#      back must equal the recorded .cfg. Each run must be a recognised terminal
#      PASS (flow/gate_sim_verdict.sh), and both compositions must report the
#      same check and perturbation counts.
#   3c. (issue #156) flow/check_regbel_fixtures.py proves from the fixture
#      metadata that each of BEL A, B, C, D is exercised in registered mode with
#      an explicit placement (regbel_{a,b,c,d}_s1, oracle `regbel`: capture,
#      hold, sync reset with enable low, reset priority with enable high).
#   4. Composition mutations of a scratch copy of LOGIC4.v (BEL A/B ConfigBits
#      slices swapped; EN/SR swapped on BEL A, B, C and D) must each compile and
#      then produce a completed functional FAIL from at least one oracle, with no
#      infrastructure failure on any fixture. Each EN/SR swap on BEL X must in
#      addition FAIL functionally on its matching fixture regbel_x_s1.
#   5. (issue #172) LUT basis diagnostic: flow/lut_basis.py assembles 73
#      deterministic streams (blank; per BEL A..D: all-ones, one-hot INIT for each
#      of the 16 addresses, all-zero) through the existing assembler, and
#      sim/tb_lut_basis.v loads them in sequence into one live tile (generated
#      LOGIC4 via FrameData/FrameStrobe, and the repository composition), sweeping
#      all 16 input vectors with the oracle "BEL output == (vector == selected
#      address)" taken from the case identifier. Both must PASS and report 64/64
#      one-hot (BEL, address) cases; ConfigBits readback == python decode per case.
#      Scratch mutants -- a LUT-input permutation (BEL C I0<->I1 in LOGIC4.v), a
#      generated-BEL INIT-bit swap (lut4_ff_bel.v LUT entries 5<->6) and the BEL
#      A/B ConfigBits slice swap -- must each compile and give a completed
#      functional FAIL on exactly the basis cases the defect predicts.
#
# Missing fixture/index, compile error, simulator error, a missing or
# conflicting terminal verdict, or an undetected mutation fails the script.
# Every vvp run is bounded by the SIM_TIMEOUT_SECONDS wall-clock budget
# (flow/gate_sim_verdict.sh, issue #157); a timeout is an infrastructure failure
# and never counts as a caught mutation.
# Scope: single generated tile with the harness's same-index matrix, CAP
# loopbacks and pad overlay. No serial configuration loader, no timing claim,
# no ratified-fabric claim (ADR-0004/0005 remain Proposed).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${1:?usage: generated_tile_replay.sh <fabulous-run dir> <build dir>}"
BUILD="${2:?build dir required}"
OUT="$BUILD/generated_tile_replay"
BS="$REPO/sim/bitstream"
MAP="$BS/logic4_configmem.map"
TB="$REPO/sim/tb_logic_tile_bitstream.v"
TB_NAME=tb_logic_tile_bitstream
BS_TOOL="$REPO/flow/fasm_to_bitstream.py"
# shellcheck source=flow/gate_sim_verdict.sh
source "$REPO/flow/gate_sim_verdict.sh"
rm -rf "$OUT"; mkdir -p "$OUT"
status=0
die() { echo "error: $*" >&2; echo "generated-tile replay: FAIL" >&2; exit 1; }
gs_budget_check || die "invalid simulation wall-clock budget settings"
echo "simulation wall-clock budget: $(gs_budget)s per run (SIM_TIMEOUT_SECONDS), kill grace $(gs_kill_after)s (SIM_KILL_AFTER_SECONDS)"

T="$RUN/Tile/LOGIC4"
GEN_TILE_V="$T/LOGIC4.v"
for f in "$RUN/Fabric/models_pack.v" "$T/lut4_ff_bel.v" "$T/LOGIC4_ConfigMem.v" \
         "$T/LOGIC4_switch_matrix.v" "$GEN_TILE_V" "$MAP" "$TB"; do
    [[ -s "$f" ]] || die "missing generated/input file $f"
done

# ---- 1. adapter review against the generated boundary ----------------------
python3 -I - "$GEN_TILE_V" <<'PYEOF' || die "generated LOGIC4 boundary/composition differs from what the adapter expects"
import re, sys
src = open(sys.argv[1]).read()
hdr = re.sub(r"//[^\n]*|/\*.*?\*/", "", src[:src.index(");")], flags=re.S)
decl = re.findall(r"\b(input|output|inout)\b\s*(?:wire|reg)?\s*(\[[^\]]*\])?\s*(\w+)", hdr)
ports = dict((n, (d, w)) for d, w, n in decl)
if len(ports) != len(decl):
    sys.exit("duplicate port declaration in generated LOGIC4 header")
want = {"N1END": ("input", "[3:0]"), "E1END": ("input", "[3:0]"),
        "S1END": ("input", "[3:0]"), "W1END": ("input", "[3:0]"),
        "N1BEG": ("output", "[3:0]"), "E1BEG": ("output", "[3:0]"),
        "S1BEG": ("output", "[3:0]"), "W1BEG": ("output", "[3:0]"),
        "UserCLK": ("input", ""), "UserCLKo": ("output", ""),
        "FrameData": ("input", "[FrameBitsPerRow-1:0]"),
        "FrameData_O": ("output", "[FrameBitsPerRow-1:0]"),
        "FrameStrobe": ("input", "[MaxFramesPerCol-1:0]"),
        "FrameStrobe_O": ("output", "[MaxFramesPerCol-1:0]")}
if ports != want:
    sys.exit(f"ports {sorted(ports.items())} != expected {sorted(want.items())}")
for pat, n in ((r"^LOGIC4_ConfigMem\b", 1), (r"^LOGIC4_switch_matrix\s+Inst_", 1),
               (r"^lut4_ff_bel\s+Inst_L[ABCD]_lut4_ff_bel", 4)):
    if len(re.findall(pat, src, re.M)) != n:
        sys.exit(f"expected {n} instance(s) matching {pat}")
for p, d in (("MaxFramesPerCol", 20), ("FrameBitsPerRow", 32), ("NoConfigBits", 158)):
    if not re.search(rf"parameter {p}={d}\b", src):
        sys.exit(f"parameter {p} != {d}")
print("adapter: generated LOGIC4 boundary = 4x4 tracks + UserCLK(o) + FrameData/FrameStrobe(_O); "
      "composes LOGIC4_ConfigMem + LOGIC4_switch_matrix + 4x lut4_ff_bel")
PYEOF

# ---- 2. compile both compositions ------------------------------------------
# The generated files carry no `timescale; LOGIC4_switch_matrix.v has FABulous's
# placeholder `assign #80` mux delays. Compile every generated file under an
# explicit 1ps unit (80 ps per mux; sub-ns, well inside the bench's 1 ns settle
# time). This is a simulation convention, NOT a timing model or claim.
TS="$OUT/timescale_1ps.v"
printf '`timescale 1ps/1ps\n' > "$TS"
gen_compile() {  # $1 = LOGIC4.v to use, $2 = output vvp, [$3 = bench, $4 = lut4_ff_bel.v]
    iverilog -g2012 -Wall -DGEN_TILE -I "$REPO/sim" -o "$2" \
        "$TS" "$RUN/Fabric/models_pack.v" "$TS" "${4:-$T/lut4_ff_bel.v}" \
        "$TS" "$T/LOGIC4_ConfigMem.v" "$TS" "$T/LOGIC4_switch_matrix.v" \
        "$TS" "$1" "${3:-$TB}" >"$2.compile.log" 2>&1
}
GEN_VVP="$OUT/gen.vvp"; RTL_VVP="$OUT/rtl.vvp"
gen_compile "$GEN_TILE_V" "$GEN_VVP" || { cat "$GEN_VVP.compile.log" >&2; die "compile of the generated tile bench failed"; }
iverilog -g2012 -Wall -I "$REPO/sim" -o "$RTL_VVP" "$REPO/design/rtl/lut4_slice.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v" "$REPO/design/rtl/logic_tile_routed.v" \
    "$TB" >"$RTL_VVP.compile.log" 2>&1 \
    || { cat "$RTL_VVP.compile.log" >&2; die "compile of the repository-composition bench failed"; }
echo "compiled: generated LOGIC4 (-DGEN_TILE) and design/rtl/logic_tile_routed.v benches"

# ---- 3. fixture list ---------------------------------------------------------
FIX="$OUT/fixtures.txt"   # "<dir> <stem> <oracle>"
{ echo "$BS top_io comb"; echo "$BS top_reg reg"; } > "$FIX"
[[ -s "$BS/corpus/index.txt" ]] || die "missing or empty sim/bitstream/corpus/index.txt"
n_corpus=0
while read -r stem oracle; do
    [[ -z "$stem" ]] && continue
    echo "$BS/corpus $stem $oracle" >> "$FIX"; n_corpus=$((n_corpus + 1))
done < "$BS/corpus/index.txt"
[[ "$n_corpus" -gt 0 ]] || die "corpus index lists no fixtures"
pin_cases="$(python3 -I "$REPO/flow/pin_fixtures.py" verify "$BS/pin_experiment" --snapshot-dir "$BS")" \
    || die "pin-experiment fixture verification failed"
n_pin=0
while read -r stem oracle; do
    [[ -z "$stem" ]] && continue
    echo "$BS/pin_experiment $stem $oracle" >> "$FIX"; n_pin=$((n_pin + 1))
done <<< "$pin_cases"
[[ "$n_pin" -eq 3 ]] || die "expected 3 pin-experiment fixtures, got $n_pin"
n_fix=$((2 + n_corpus + n_pin))
while read -r dir stem oracle; do
    for ext in bin wiring cfg; do
        [[ -s "$dir/$stem.$ext" ]] || die "missing fixture file $dir/$stem.$ext"
    done
done < "$FIX"
echo "fixtures: 2 baseline + $n_corpus corpus (index.txt) + $n_pin pin-experiment = $n_fix"

# run_one <vvp> <dir> <stem> <oracle> <log> [extra plusargs...]; prints verdict
run_one() {
    local vvp="$1" dir="$2" stem="$3" oracle="$4" log="$5" rc=0; shift 5
    # bounded (issue #157): a timeout returns 124/137 -> INFRA, never FUNC_FAIL
    gs_run_bounded "$(basename "$vvp" .vvp):${stem}[${oracle}]" "$log" \
        vvp "$vvp" +bin="$dir/$stem.bin" +map="$MAP" +wiring="$dir/$stem.wiring" \
        +design="$oracle" "$@" || rc=$?
    gs_classify "$rc" "$log" "$TB_NAME" "$oracle"
}
summary() { grep -m1 -o '([0-9]* checks, [0-9]* failures[^)]*)' "$1"; }

# ---- 3a. registered-BEL fixture metadata (issue #156) ------------------------
python3 -I "$REPO/flow/check_regbel_fixtures.py" "$REPO" || die "registered-BEL fixture metadata check failed"

# ---- 3b. replay on both compositions ----------------------------------------
echo "=== generated-tile replay (generated LOGIC4 vs repository composition, same oracles, +mutate) ==="
pass=0
while read -r dir stem oracle; do
    glog="$OUT/gen_${stem}.log"; rlog="$OUT/rtl_${stem}.log"
    gv="$(run_one "$GEN_VVP" "$dir" "$stem" "$oracle" "$glog" +mutate)"
    rv="$(run_one "$RTL_VVP" "$dir" "$stem" "$oracle" "$rlog" +mutate)"
    if [[ "$gv" != PASS || "$rv" != PASS ]]; then
        echo "  $stem [$oracle]: FAIL (generated=$gv repository=$rv; see $glog, $rlog)" >&2
        tail -n 5 "$glog" >&2; status=1; continue
    fi
    gcfg="$(grep -o '^CFG=[0-9a-f]*' "$glog" | cut -d= -f2)"
    rcfg="$(grep -o '^CFG=[0-9a-f]*' "$rlog" | cut -d= -f2)"
    rec="$(tr -d '\n' < "$dir/$stem.cfg")"
    py="$(python3 -I "$BS_TOOL" decode "$dir/$stem.bin" --snapshot "$BS/fabric_spec.json")"
    if [[ -z "$gcfg" || "$gcfg" != "$rec" || "$rcfg" != "$rec" || "$py" != "$rec" ]]; then
        echo "  $stem [$oracle]: FAIL (cfg: generated ConfigBits=$gcfg repo=$rcfg python=$py recorded=$rec)" >&2
        status=1; continue
    fi
    gs="$(grep -m1 '^PASS' "$glog" | sed 's/^PASS: [^ ]* //')"
    rs="$(grep -m1 '^PASS' "$rlog" | sed 's/^PASS: [^ ]* //')"
    if [[ "$gs" != "$rs" ]]; then
        echo "  $stem [$oracle]: FAIL (compositions disagree: generated $gs vs repository $rs)" >&2
        status=1; continue
    fi
    pass=$((pass + 1))
    echo "  $stem [$oracle]: PASS on both $gs; $(grep -m1 '^GEN_TILE:' "$glog" | sed 's/^GEN_TILE: //'); ConfigBits == recorded cfg"
done < "$FIX"
echo "generated-tile replay: ${pass}/${n_fix} fixtures PASS on the generated LOGIC4 and the repository composition"
[[ "$pass" -eq "$n_fix" ]] || status=1

# ---- 4. composition mutations (scratch copies; each MUST be caught) ----------
echo "--- scratch composition mutations of the generated LOGIC4.v (each must be caught) ---"
python3 -I - "$GEN_TILE_V" "$OUT" <<'PYEOF' || die "could not build composition mutants"
import re, sys
src, out = open(sys.argv[1]).read(), sys.argv[2]
def sub1(pat, rep, s):
    r, n = re.subn(pat, rep, s, count=1)
    assert n == 1 and r != s, pat
    return r
a = ".ConfigBits(ConfigBits[17-1:0])"; b = ".ConfigBits(ConfigBits[34-1:17])"
assert src.count(a) == 1 and src.count(b) == 1
muts = {
    "belcfg": src.replace(a, "@@A@@").replace(b, a).replace("@@A@@", b),
    "ensr_A": sub1(r"\.SR\(LA_SR\),(\s*)\.EN\(LA_EN\)", r".SR(LA_EN),\1.EN(LA_SR)", src),
    "ensr_B": sub1(r"\.SR\(LB_SR\),(\s*)\.EN\(LB_EN\)", r".SR(LB_EN),\1.EN(LB_SR)", src),
    "ensr_C": sub1(r"\.SR\(LC_SR\),(\s*)\.EN\(LC_EN\)", r".SR(LC_EN),\1.EN(LC_SR)", src),
    "ensr_D": sub1(r"\.SR\(LD_SR\),(\s*)\.EN\(LD_EN\)", r".SR(LD_EN),\1.EN(LD_SR)", src),
}
for k, v in muts.items():
    open(f"{out}/LOGIC4_mut_{k}.v", "w").write(v)
PYEOF
declare -A MDESC=(
    [belcfg]="BEL A <-> BEL B ConfigBits slices swapped"
    [ensr_A]="BEL A EN/SR pins swapped"
    [ensr_B]="BEL B EN/SR pins swapped"
    [ensr_C]="BEL C EN/SR pins swapped"
    [ensr_D]="BEL D EN/SR pins swapped"
)
for m in belcfg ensr_A ensr_B ensr_C ensr_D; do
    mvvp="$OUT/mut_${m}.vvp"
    if ! gen_compile "$OUT/LOGIC4_mut_${m}.v" "$mvvp"; then
        cat "$mvvp.compile.log" >&2
        echo "mutation '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    det=(); npass=0; infra=0; match=""; match_stem=""
    [[ "$m" == ensr_? ]] && match_stem="regbel_$(echo "${m#ensr_}" | tr A-D a-d)_s1"
    while read -r dir stem oracle; do
        log="$OUT/mut_${m}_${stem}.log"
        v="$(run_one "$mvvp" "$dir" "$stem" "$oracle" "$log")"
        case "$v" in
            FUNC_FAIL) det+=("${stem}[${oracle}] $(summary "$log")")
                       [[ "$stem" == "$match_stem" ]] && match=caught ;;
            PASS) npass=$((npass + 1)) ;;
            *) infra=$((infra + 1)); echo "  mutation '$m' $stem: infrastructure failure (see $log)" >&2 ;;
        esac
        # storage is untouched by a composition mutation: ConfigBits still == recorded
        c="$(grep -o '^CFG=[0-9a-f]*' "$log" | cut -d= -f2)"
        [[ "$c" == "$(tr -d '\n' < "$dir/$stem.cfg")" ]] || { echo "  mutation '$m' $stem: ConfigBits readback mismatch" >&2; infra=$((infra + 1)); }
    done < "$FIX"
    if [[ "$infra" -gt 0 || "${#det[@]}" -eq 0 ]]; then
        echo "mutation '$m' (${MDESC[$m]}): NOT caught (${#det[@]} functional FAILs, $infra infrastructure failures)" >&2
        status=1; continue
    fi
    if [[ -n "$match_stem" && "$match" != caught ]]; then
        echo "mutation '$m' (${MDESC[$m]}): NOT caught on its matching fixture $match_stem" >&2
        status=1; continue
    fi
    echo "mutation '$m' (${MDESC[$m]}) caught: compiled; functional FAIL on ${#det[@]}/$n_fix fixtures ($npass unaffected), ConfigBits == recorded on all"
    for d in "${det[@]}"; do echo "    FAIL: $d"; done
done

# ---- 5. LUT basis diagnostic (issue #172) -----------------------------------
# Diagnostic assembler-generated streams, NOT mapper output: proves address
# selection of every LUT entry on every BEL through the integrated tile, nothing
# about how yosys/nextpnr map truth tables.
echo "=== LUT basis diagnostic (issue #172): 4 BELs x 16 addresses through the integrated tile ==="
LB="$OUT/lut_basis"; LB_TB="$REPO/sim/tb_lut_basis.v"; LB_NAME=tb_lut_basis
[[ -s "$LB_TB" ]] || die "missing $LB_TB"
python3 -I "$REPO/flow/lut_basis.py" "$LB" --snapshot "$BS/fabric_spec.json" || die "LUT basis stream generation failed"
[[ "$(wc -l < "$LB/cases.txt")" -eq 73 ]] || die "expected 73 LUT basis cases"
LB_GEN="$OUT/basis_gen.vvp"; LB_RTL="$OUT/basis_rtl.vvp"
gen_compile "$GEN_TILE_V" "$LB_GEN" "$LB_TB" \
    || { cat "$LB_GEN.compile.log" >&2; die "compile of the generated-tile basis bench failed"; }
iverilog -g2012 -Wall -o "$LB_RTL" "$REPO/design/rtl/lut4_slice.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v" "$REPO/design/rtl/logic_tile_routed.v" \
    "$LB_TB" >"$LB_RTL.compile.log" 2>&1 \
    || { cat "$LB_RTL.compile.log" >&2; die "compile of the repository-composition basis bench failed"; }
# basis_run <vvp> <log>: one bounded run of all 73 cases; prints the verdict
basis_run() {
    local rc=0
    gs_run_bounded "$(basename "$1" .vvp)[basis]" "$2" vvp "$1" +dir="$LB" +list="$LB/cases.txt" \
        +wiring="$LB/basis.wiring" +map="$MAP" || rc=$?
    gs_classify "$rc" "$2" "$LB_NAME" basis
}
# basis_cfg_ok <log>: every case's ConfigBits/cfg readback == python decode of its stream
basis_cfg_ok() {
    local id got
    while read -r id _; do
        got="$(grep -m1 "^CFG $id " "$1" | cut -d' ' -f3)"
        if [[ -z "$got" || "$got" != "$(tr -d '\n' < "$LB/$id.cfg")" ]]; then
            echo "  case $id: readback '$got' != decoded $(tr -d '\n' < "$LB/$id.cfg")" >&2; return 1
        fi
    done < "$LB/cases.txt"
}
COV_RE='^COVERAGE: 4 BELs x 16 addresses = 64/64 one-hot cases; 4 all-ones, 5 all-zero cases; 73 cases loaded in sequence into one live tile$'
basis_ok=1
for comp in gen rtl; do
    vvp_f="$LB_GEN"; [[ "$comp" == rtl ]] && vvp_f="$LB_RTL"
    log="$OUT/basis_${comp}.log"
    v="$(basis_run "$vvp_f" "$log")"
    if [[ "$v" != PASS ]] || ! grep -qE "$COV_RE" "$log" \
       || [[ "$(grep -c '^COVERAGE: BEL [A-D]: 16/16 addresses' "$log")" -ne 4 ]]; then
        echo "  LUT basis [$comp]: FAIL (verdict $v or incomplete coverage; see $log)" >&2
        tail -n 8 "$log" >&2; basis_ok=0; status=1; continue
    fi
    basis_cfg_ok "$log" || { echo "  LUT basis [$comp]: readback mismatch" >&2; basis_ok=0; status=1; }
done
if [[ "$basis_ok" -eq 1 ]]; then
    gsum="$(grep -m1 '^PASS' "$OUT/basis_gen.log" | sed 's/^PASS: [^ ]* //')"
    rsum="$(grep -m1 '^PASS' "$OUT/basis_rtl.log" | sed 's/^PASS: [^ ]* //')"
    if [[ "$gsum" != "$rsum" ]]; then
        echo "  LUT basis: compositions disagree (generated $gsum vs repository $rsum)" >&2; status=1
    else
        grep '^COVERAGE' "$OUT/basis_gen.log" | sed 's/^/  generated: /'
        grep '^COVERAGE' "$OUT/basis_rtl.log" | sed 's/^/  repository: /'
        echo "  generated: $(grep -m1 '^GEN_TILE:' "$OUT/basis_gen.log")"
        echo "  LUT basis: PASS on both $gsum; readback == python decode for all 73 streams on both"
    fi
fi

echo "--- scratch mutants vs the LUT basis (each must give a completed functional FAIL on the predicted cases) ---"
python3 -I - "$GEN_TILE_V" "$T/lut4_ff_bel.v" "$OUT" <<'PYEOF' || die "could not build LUT basis mutants"
import sys
tile, bel, out = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
a = ".I({LC_I3, LC_I2, LC_I1, LC_I0})"
assert tile.count(a) == 1, a
open(f"{out}/LOGIC4_mut_lutin_C.v", "w").write(tile.replace(a, ".I({LC_I3, LC_I2, LC_I0, LC_I1})"))
b = "wire [15:0] LUT_values = ConfigBits[15:0];"
assert bel.count(b) == 1, b
open(f"{out}/lut4_ff_bel_mut_init56.v", "w").write(bel.replace(
    b, "wire [15:0] LUT_values = {ConfigBits[15:7], ConfigBits[5], ConfigBits[6], ConfigBits[4:0]};"))
PYEOF
[[ -s "$OUT/LOGIC4_mut_belcfg.v" ]] || die "missing the belcfg composition mutant from step 4"
# Predicted failing basis cases, derived from the defect (not from the DUT):
#   lutin_C : BEL C inputs I0/I1 exchanged -> C one-hot addresses with bit0 != bit1, nothing else
#   init56  : LUT entries 5/6 exchanged in the shared BEL module -> a05 and a06 on every BEL
#   belcfg  : BEL A/B config slices exchanged -> every A and B all-ones / one-hot case
declare -A LBM_DESC=(
    [lutin_C]="LUT-input permutation: BEL C I0 <-> I1 (scratch LOGIC4.v)"
    [init56]="generated-BEL INIT-bit swap: LUT entries 5 <-> 6 (scratch lut4_ff_bel.v, all four BELs)"
    [belcfg]="BEL A <-> BEL B ConfigBits slices swapped (scratch LOGIC4.v)"
)
lbm_expect() {
    local x k
    case "$1" in
        lutin_C) echo C_a01 C_a02 C_a05 C_a06 C_a09 C_a10 C_a13 C_a14 ;;
        init56)  for x in A B C D; do echo "${x}_a05 ${x}_a06"; done ;;
        belcfg)  for x in A B; do echo "${x}_ones"; for k in $(seq -w 0 15); do echo "${x}_a$k"; done; done ;;
    esac | tr ' ' '\n' | sort | xargs
}
n_lbm=0
for m in lutin_C init56 belcfg; do
    mvvp="$OUT/basis_mut_${m}.vvp"; mlog="$OUT/basis_mut_${m}.log"; crc=0
    case "$m" in
        lutin_C) gen_compile "$OUT/LOGIC4_mut_lutin_C.v" "$mvvp" "$LB_TB" || crc=$? ;;
        init56)  gen_compile "$GEN_TILE_V" "$mvvp" "$LB_TB" "$OUT/lut4_ff_bel_mut_init56.v" || crc=$? ;;
        belcfg)  gen_compile "$OUT/LOGIC4_mut_belcfg.v" "$mvvp" "$LB_TB" || crc=$? ;;
    esac
    if [[ "$crc" -ne 0 ]]; then
        cat "$mvvp.compile.log" >&2
        echo "basis mutant '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    v="$(basis_run "$mvvp" "$mlog")"
    if [[ "$v" != FUNC_FAIL ]]; then
        echo "basis mutant '$m' (${LBM_DESC[$m]}): NOT caught (verdict $v; a timeout, simulator error or missing verdict never counts; see $mlog)" >&2
        status=1; continue
    fi
    got="$(sed -n 's/^  case \([A-Za-z0-9_]*\): [0-9]* mismatches$/\1/p' "$mlog" | sort | xargs)"
    want="$(lbm_expect "$m")"
    if [[ "$got" != "$want" ]]; then
        echo "basis mutant '$m' (${LBM_DESC[$m]}): failing cases [$got] != predicted [$want]" >&2
        status=1; continue
    fi
    basis_cfg_ok "$mlog" || { echo "basis mutant '$m': readback mismatch" >&2; status=1; continue; }
    n_lbm=$((n_lbm + 1))
    echo "basis mutant '$m' (${LBM_DESC[$m]}) caught: compiled; $(grep -m1 '^FAIL' "$mlog" | sed 's/^FAIL: //'); failing cases == predicted ($(echo "$got" | wc -w)/73): $got; ConfigBits == decoded on all"
done
[[ "$n_lbm" -eq 3 ]] || status=1

if [[ "$status" -eq 0 ]]; then
    echo "generated-tile replay: PASS (${pass}/${n_fix} fixtures, 5/5 composition mutations caught; LUT basis 64/64 (BEL, address) cases on both compositions, 3/3 basis mutants caught)"
else
    echo "generated-tile replay: FAIL" >&2
fi
exit "$status"
