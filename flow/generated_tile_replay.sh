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
#   6. (issue #176) LUT-input directional route diagnostic: flow/route_diag.py
#      assembles one stream per (BEL, input pin, edge) matrix source into a LUT
#      input -- 4 x 4 x 4 = 64, the required set read from the frozen pip model --
#      and sim/tb_route_diag.v loads them in sequence into one live tile (generated
#      LOGIC4 via FrameData/FrameStrobe, and the repository composition), driving
#      the selected boundary track against every combination of the three
#      unselected directional tracks. The coverage report must list exactly the
#      required routes, each once; a missing or duplicate route fails. Scratch
#      generated-matrix source-selection permutations must each compile and give a
#      completed functional FAIL on exactly the predicted route cases.
#
#   7. (issue #181) control-jump directional route diagnostic (flow/ctrl_route.py,
#      sim/tb_ctrl_route.v): 20 routes (16 enable + 4 shared reset), own mutants.
#
#   8. (issue #180) boundary output-track source diagnostic: flow/output_route.py
#      assembles one stream per legal (output edge, track, source) tuple -- 16
#      tracks x 7 sources = 112, the required set read from the frozen pip model --
#      and sim/tb_output_route.v loads them in sequence into one live tile
#      (generated LOGIC4 via FrameData/FrameStrobe, and the repository composition).
#      The tile boundary is observed directly (no CAP loopbacks): every stream
#      routes all 16 output tracks, the selected source is toggled against every
#      combination of the unselected candidates and the four BELs (distinguishable
#      functions, both polarities), and all 16 outputs are checked each pattern.
#      The coverage report must list exactly the required tuples, each once; a
#      missing or duplicate tuple fails. Scratch generated-matrix source
#      permutations and output-sink select-field aliases must each compile and give
#      a completed functional FAIL on exactly the cases an independent model
#      (flow/output_route.py predict) derives from the case list.
#
#   9. (issue #188) tile clock and frame forwarding diagnostic (sim/tb_boundary_fwd.v,
#      generated tile only): UserCLKo = UserCLK, FrameData_O = FrameData (32 bits),
#      FrameStrobe_O = FrameStrobe (20 bits) as pure logical copies, per the pinned
#      generated assignments (checked by this script). Both clock levels and repeated
#      edges, walking one/zero over all data and strobe bits, idle strobes with
#      changing data, legal frame writes; four-state compares, independent of
#      ConfigBits. Scratch mutants (clock open, clock inverted, data bit alias,
#      strobe bit dropped) must each compile and give a completed functional FAIL
#      naming only the mutated port. Logical forwarding only: no timing claim.
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

# ---- 6. LUT-input directional route diagnostic (issue #176) -----------------
# Diagnostic assembler-generated streams, NOT mapper output: proves that every
# existing directional source of every LUT input is selected through frame
# programming. Not a component select sweep (tb_switch_matrix_equiv.v drives cfg
# directly) and not LUT address coverage (step 5 uses the S edge only).
echo "=== LUT-input route diagnostic (issue #176): 4 BELs x 4 pins x 4 edges through the integrated tile ==="
RD="$OUT/route_diag"; RD_TB="$REPO/sim/tb_route_diag.v"; RD_NAME=tb_route_diag
[[ -s "$RD_TB" ]] || die "missing $RD_TB"
python3 -I "$REPO/flow/route_diag.py" "$RD" --snapshot "$BS/fabric_spec.json" || die "route diagnostic stream generation failed"
[[ "$(wc -l < "$RD/cases.txt")" -eq 64 && "$(wc -l < "$RD/required.txt")" -eq 64 ]] || die "expected 64 route cases and 64 required routes"
RD_GEN="$OUT/route_gen.vvp"; RD_RTL="$OUT/route_rtl.vvp"
gen_compile "$GEN_TILE_V" "$RD_GEN" "$RD_TB" \
    || { cat "$RD_GEN.compile.log" >&2; die "compile of the generated-tile route bench failed"; }
iverilog -g2012 -Wall -o "$RD_RTL" "$REPO/design/rtl/lut4_slice.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v" "$REPO/design/rtl/logic_tile_routed.v" \
    "$RD_TB" >"$RD_RTL.compile.log" 2>&1 \
    || { cat "$RD_RTL.compile.log" >&2; die "compile of the repository-composition route bench failed"; }
route_run() {   # <vvp> <log>; prints the verdict
    local rc=0
    gs_run_bounded "$(basename "$1" .vvp)[route]" "$2" vvp "$1" +dir="$RD" +list="$RD/cases.txt" \
        +wiring="$RD/route.wiring" +map="$MAP" || rc=$?
    gs_classify "$rc" "$2" "$RD_NAME" route
}
route_cfg_ok() {   # <log>: per-case ConfigBits/cfg readback == python decode of the stream
    local id got
    while read -r id _; do
        got="$(grep -m1 "^CFG $id " "$1" | cut -d' ' -f3)"
        if [[ -z "$got" || "$got" != "$(tr -d '\n' < "$RD/$id.cfg")" ]]; then
            echo "  route case $id: readback '$got' != decoded $(tr -d '\n' < "$RD/$id.cfg")" >&2; return 1
        fi
    done < "$RD/cases.txt"
}
route_cov_ok() {   # <log>: the coverage report must equal the required set, each route exactly once
    local got
    got="$(sed -n 's/^COVERAGE: ROUTE \([A-D]\) \([0-3]\) \([NESW]\): selected track toggled.*$/\1 \2 \3/p' "$1" | sort)"
    [[ "$got" == "$(sort "$RD/required.txt")" ]] \
        && [[ "$(echo "$got" | wc -l)" -eq 64 && "$(echo "$got" | uniq -d | wc -l)" -eq 0 ]] \
        && grep -qE '^COVERAGE: 64/64 routes \(4 BELs x 4 pins x 4 edges\); 64 cases loaded in sequence into one live tile; [0-9]+ adversarial .* 0 duplicate case ids$' "$1"
}
route_ok=1
for comp in gen rtl; do
    vvp_f="$RD_GEN"; [[ "$comp" == rtl ]] && vvp_f="$RD_RTL"
    log="$OUT/route_${comp}.log"
    v="$(route_run "$vvp_f" "$log")"
    if [[ "$v" != PASS ]] || ! route_cov_ok "$log"; then
        echo "  route diagnostic [$comp]: FAIL (verdict $v or coverage differs from the required route set; see $log)" >&2
        tail -n 8 "$log" >&2; route_ok=0; status=1; continue
    fi
    route_cfg_ok "$log" || { echo "  route diagnostic [$comp]: readback mismatch" >&2; route_ok=0; status=1; }
done
if [[ "$route_ok" -eq 1 ]]; then
    gsum="$(grep -m1 '^PASS' "$OUT/route_gen.log" | sed 's/^PASS: [^ ]* //')"
    rsum="$(grep -m1 '^PASS' "$OUT/route_rtl.log" | sed 's/^PASS: [^ ]* //')"
    if [[ "$gsum" != "$rsum" ]]; then
        echo "  route diagnostic: compositions disagree (generated $gsum vs repository $rsum)" >&2; status=1
    else
        grep -m1 '^COVERAGE: 64/64' "$OUT/route_gen.log" | sed 's/^/  generated: /'
        grep -m1 '^COVERAGE: 64/64' "$OUT/route_rtl.log" | sed 's/^/  repository: /'
        echo "  generated: $(grep -m1 '^GEN_TILE:' "$OUT/route_gen.log")"
        echo "  route diagnostic: PASS on both $gsum; 64/64 routes, readback == python decode for all 64 streams on both"
    fi
fi

echo "--- scratch generated-matrix source-selection permutations vs the route diagnostic (each must give a completed functional FAIL on the predicted routes) ---"
python3 -I - "$T/LOGIC4_switch_matrix.v" "$OUT" <<'PYEOF' || die "could not build route mutants"
import sys
sm, out = open(sys.argv[1]).read(), sys.argv[2]
def swap(sink, i, j):   # exchange two sources of one sink mux (mux input list is {W,S,E,N})
    pat = "assign %s_input = {W1END%s,S1END%s,E1END%s,N1END%s};" % ((sink,) + (sink[-1],) * 4)
    assert sm.count(pat) == 1, pat
    order = ["N", "E", "S", "W"]
    order[i], order[j] = order[j], order[i]
    new = "assign %s_input = {%s};" % (sink, ",".join(f"{order[k]}1END{sink[-1]}" for k in (3, 2, 1, 0)))
    return sm.replace(pat, new)
open(f"{out}/matrix_mut_C2_ES.v", "w").write(swap("LC_I2", 1, 2))
open(f"{out}/matrix_mut_A0_NW.v", "w").write(swap("LA_I0", 0, 3))
open(f"{out}/matrix_mut_D3_NE.v", "w").write(swap("LD_I3", 0, 1))
PYEOF
# Predicted failing route cases, derived from the defect: the two exchanged sources of that one sink
# on that one BEL, nothing else (every other sink, pin and BEL is untouched).
declare -A RDM_DESC=(
    [C2_ES]="BEL C pin I2: E and S sources exchanged in a scratch LOGIC4_switch_matrix.v"
    [A0_NW]="BEL A pin I0: N and W sources exchanged (the default select 0 moves to W)"
    [D3_NE]="BEL D pin I3: N and E sources exchanged"
)
declare -A RDM_WANT=(
    [C2_ES]="R_C_I2_E R_C_I2_S"
    [A0_NW]="R_A_I0_N R_A_I0_W"
    [D3_NE]="R_D_I3_E R_D_I3_N"
)
n_rdm=0
for m in C2_ES A0_NW D3_NE; do
    mvvp="$OUT/route_mut_${m}.vvp"; mlog="$OUT/route_mut_${m}.log"
    mt="$OUT/matrix_mut_${m}.v"; crc=0
    [[ -s "$mt" && "$(diff <(cat "$T/LOGIC4_switch_matrix.v") "$mt" | grep -c '^>')" -eq 1 ]] \
        || { echo "route mutant '$m': scratch matrix is not a one-line mutation" >&2; status=1; continue; }
    iverilog -g2012 -Wall -DGEN_TILE -I "$REPO/sim" -o "$mvvp" \
        "$TS" "$RUN/Fabric/models_pack.v" "$TS" "$T/lut4_ff_bel.v" "$TS" "$T/LOGIC4_ConfigMem.v" \
        "$TS" "$mt" "$TS" "$GEN_TILE_V" "$RD_TB" >"$mvvp.compile.log" 2>&1 || crc=$?
    if [[ "$crc" -ne 0 ]]; then
        cat "$mvvp.compile.log" >&2
        echo "route mutant '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    v="$(route_run "$mvvp" "$mlog")"
    if [[ "$v" != FUNC_FAIL ]]; then
        echo "route mutant '$m' (${RDM_DESC[$m]}): NOT caught (verdict $v; a timeout, simulator error or missing verdict never counts; see $mlog)" >&2
        status=1; continue
    fi
    got="$(sed -n 's/^  case \(R_[A-Z0-9_]*\): [0-9]* mismatches$/\1/p' "$mlog" | sort | xargs)"
    want="$(echo "${RDM_WANT[$m]}" | tr ' ' '\n' | sort | xargs)"
    if [[ "$got" != "$want" ]]; then
        echo "route mutant '$m' (${RDM_DESC[$m]}): failing cases [$got] != predicted [$want]" >&2
        status=1; continue
    fi
    route_cov_ok "$mlog" && route_cfg_ok "$mlog" || { echo "route mutant '$m': coverage/readback not intact" >&2; status=1; continue; }
    n_rdm=$((n_rdm + 1))
    echo "route mutant '$m' (${RDM_DESC[$m]}) caught: compiled; $(grep -m1 '^FAIL' "$mlog" | sed 's/^FAIL: //'); failing cases == predicted ($got); ConfigBits == decoded on all"
done
[[ "$n_rdm" -eq 3 ]] || status=1

# ---- 7. control-jump directional route diagnostic (issue #181) ---------------
# Diagnostic assembler-generated streams, NOT mapper output: proves that every
# existing directional source of every control-jump mux (4 enables x 4 edges, the
# shared reset x 4 edges = 20) is selected through frame programming and reaches
# its destination register(s). The oracle is a register reference model fed by
# the applied stimulus (sim/tb_ctrl_route.v). Not the LUT-input routes of step 6,
# not a component select sweep, no timing or ratified-fabric claim.
echo "=== control-jump route diagnostic (issue #181): 4 enables x 4 edges + shared reset x 4 edges through the integrated tile ==="
CR="$OUT/ctrl_route"; CR_TB="$REPO/sim/tb_ctrl_route.v"; CR_NAME=tb_ctrl_route
[[ -s "$CR_TB" ]] || die "missing $CR_TB"
python3 -I "$REPO/flow/ctrl_route.py" "$CR" --snapshot "$BS/fabric_spec.json" || die "control-route stream generation failed"
[[ "$(wc -l < "$CR/cases.txt")" -eq 20 && "$(wc -l < "$CR/required.txt")" -eq 20 ]] || die "expected 20 control-route cases and 20 required routes"
CR_GEN="$OUT/ctrl_gen.vvp"; CR_RTL="$OUT/ctrl_rtl.vvp"
gen_compile "$GEN_TILE_V" "$CR_GEN" "$CR_TB" \
    || { cat "$CR_GEN.compile.log" >&2; die "compile of the generated-tile control-route bench failed"; }
iverilog -g2012 -Wall -o "$CR_RTL" "$REPO/design/rtl/lut4_slice.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v" "$REPO/design/rtl/logic_tile_routed.v" \
    "$CR_TB" >"$CR_RTL.compile.log" 2>&1 \
    || { cat "$CR_RTL.compile.log" >&2; die "compile of the repository-composition control-route bench failed"; }
ctrl_run() {   # <vvp> <log>; prints the verdict
    local rc=0
    gs_run_bounded "$(basename "$1" .vvp)[ctrl]" "$2" vvp "$1" +dir="$CR" +list="$CR/cases.txt" \
        +wiring="$CR/ctrl.wiring" +map="$MAP" || rc=$?
    gs_classify "$rc" "$2" "$CR_NAME" ctrl
}
ctrl_cfg_ok() {   # <log>: per-case ConfigBits/cfg readback == python decode of the stream
    local id got
    while read -r id _; do
        got="$(grep -m1 "^CFG $id " "$1" | cut -d' ' -f3)"
        if [[ -z "$got" || "$got" != "$(tr -d '\n' < "$CR/$id.cfg")" ]]; then
            echo "  control case $id: readback '$got' != decoded $(tr -d '\n' < "$CR/$id.cfg")" >&2; return 1
        fi
    done < "$CR/cases.txt"
}
ctrl_cov_ok() {   # <log>: the coverage report must equal the required set, each route exactly once
    local got
    got="$(sed -n 's/^COVERAGE: ROUTE \(EN\|SR\) \([A-D-]\) \([NESW]\): .*checked on .*$/\1 \2 \3/p' "$1" | sort)"
    [[ "$got" == "$(sort "$CR/required.txt")" ]] \
        && [[ "$(echo "$got" | wc -l)" -eq 20 && "$(echo "$got" | uniq -d | wc -l)" -eq 0 ]] \
        && grep -qE '^COVERAGE: 20/20 routes \(16 enable = 4 BELs x 4 edges, 4 shared-reset edges\); 20 cases loaded in sequence into one live tile; [0-9]+ phases; [0-9]+ full-disagreement phases .*; 0 duplicate case ids$' "$1"
}
ctrl_ok=1
for comp in gen rtl; do
    vvp_f="$CR_GEN"; [[ "$comp" == rtl ]] && vvp_f="$CR_RTL"
    log="$OUT/ctrl_${comp}.log"
    v="$(ctrl_run "$vvp_f" "$log")"
    if [[ "$v" != PASS ]] || ! ctrl_cov_ok "$log"; then
        echo "  control-route diagnostic [$comp]: FAIL (verdict $v or coverage differs from the required route set; see $log)" >&2
        tail -n 8 "$log" >&2; ctrl_ok=0; status=1; continue
    fi
    ctrl_cfg_ok "$log" || { echo "  control-route diagnostic [$comp]: readback mismatch" >&2; ctrl_ok=0; status=1; }
done
if [[ "$ctrl_ok" -eq 1 ]]; then
    gsum="$(grep -m1 '^PASS' "$OUT/ctrl_gen.log" | sed 's/^PASS: [^ ]* //')"
    rsum="$(grep -m1 '^PASS' "$OUT/ctrl_rtl.log" | sed 's/^PASS: [^ ]* //')"
    if [[ "$gsum" != "$rsum" ]]; then
        echo "  control-route diagnostic: compositions disagree (generated $gsum vs repository $rsum)" >&2; status=1
    else
        grep -m1 '^COVERAGE: 20/20' "$OUT/ctrl_gen.log" | sed 's/^/  generated: /'
        grep -m1 '^COVERAGE: 20/20' "$OUT/ctrl_rtl.log" | sed 's/^/  repository: /'
        echo "  generated: $(grep -m1 '^GEN_TILE:' "$OUT/ctrl_gen.log")"
        echo "  control-route diagnostic: PASS on both $gsum; 20/20 routes, readback == python decode for all 20 streams on both"
    fi
fi

echo "--- scratch generated-matrix control-source permutations and enable-destination aliases vs the control-route diagnostic (each must give a completed functional FAIL on the predicted cases) ---"
python3 -I - "$T/LOGIC4_switch_matrix.v" "$OUT" <<'PYEOF' || die "could not build control-route mutants"
import sys
sm, out = open(sys.argv[1]).read(), sys.argv[2]
def swap(sink, i, j):   # exchange two sources of one control-jump mux (mux input list is {W,S,E,N})
    n = sink[-1]
    pat = "assign %s_input = {W1END%s,S1END%s,E1END%s,N1END%s};" % ((sink,) + (n,) * 4)
    assert sm.count(pat) == 1, pat
    order = ["N", "E", "S", "W"]
    order[i], order[j] = order[j], order[i]
    return sm.replace(pat, "assign %s_input = {%s};" % (sink, ",".join(f"{order[k]}1END{n}" for k in (3, 2, 1, 0))))
def alias(dst, src):    # the destination BEL's enable takes another BEL's enable jump wire
    pat = f"assign {dst} = {src[0]};"
    assert sm.count(pat) == 1, pat
    return sm.replace(pat, f"assign {dst} = {src[1]};")
open(f"{out}/matrix_mut_ctrl_EN1_ES.v", "w").write(swap("J_EN_BEG1", 1, 2))
open(f"{out}/matrix_mut_ctrl_EN3_NW.v", "w").write(swap("J_EN_BEG3", 0, 3))
open(f"{out}/matrix_mut_ctrl_SR_ES.v", "w").write(swap("J_SR_BEG0", 1, 2))
open(f"{out}/matrix_mut_ctrl_ALIAS_BA.v", "w").write(alias("LB_EN", ("J_EN_END1", "J_EN_END0")))
open(f"{out}/matrix_mut_ctrl_ALIAS_DC.v", "w").write(alias("LD_EN", ("J_EN_END3", "J_EN_END2")))
PYEOF
# Predicted failing control cases, derived from the defect and the case roles (not from the DUT):
#   EN1_ES / EN3_NW : only the tested enable of that BEL on the two exchanged edges (every other route
#                     reads a track that equals its selected one while its enable is not under test)
#   SR_ES           : every case whose reset is routed from E or S (the reset edge is column 5 of the case list)
#   ALIAS_BA        : BEL B's enable becomes BEL A's: every case where enable A and enable B differ at some
#                     phase = the four enable-A cases, the four enable-B cases and the four reset cases
#   ALIAS_DC        : likewise for BEL D taking BEL C's enable: enable-C, enable-D and reset cases
declare -A CRM_DESC=(
    [EN1_ES]="BEL B enable: E and S sources exchanged in a scratch LOGIC4_switch_matrix.v"
    [EN3_NW]="BEL D enable: N and W sources exchanged"
    [SR_ES]="shared reset: E and S sources exchanged"
    [ALIAS_BA]="enable-destination alias: LB_EN driven by J_EN_END0 (BEL A's enable)"
    [ALIAS_DC]="enable-destination alias: LD_EN driven by J_EN_END2 (BEL C's enable)"
)
crm_expect() {
    case "$1" in
        EN1_ES) echo C_EN_B_E C_EN_B_S ;;
        EN3_NW) echo C_EN_D_N C_EN_D_W ;;
        SR_ES)  awk '$5 == "E" || $5 == "S" { print $1 }' "$CR/cases.txt" ;;
        ALIAS_BA) echo C_EN_A_N C_EN_A_E C_EN_A_S C_EN_A_W C_EN_B_N C_EN_B_E C_EN_B_S C_EN_B_W C_SR_N C_SR_E C_SR_S C_SR_W ;;
        ALIAS_DC) echo C_EN_C_N C_EN_C_E C_EN_C_S C_EN_C_W C_EN_D_N C_EN_D_E C_EN_D_S C_EN_D_W C_SR_N C_SR_E C_SR_S C_SR_W ;;
    esac | tr ' ' '\n' | sort | xargs
}
n_crm=0
for m in EN1_ES EN3_NW SR_ES ALIAS_BA ALIAS_DC; do
    mvvp="$OUT/ctrl_mut_${m}.vvp"; mlog="$OUT/ctrl_mut_${m}.log"
    mt="$OUT/matrix_mut_ctrl_${m}.v"; crc=0
    [[ -s "$mt" && "$(diff <(cat "$T/LOGIC4_switch_matrix.v") "$mt" | grep -c '^>')" -eq 1 ]] \
        || { echo "control-route mutant '$m': scratch matrix is not a one-line mutation" >&2; status=1; continue; }
    iverilog -g2012 -Wall -DGEN_TILE -I "$REPO/sim" -o "$mvvp" \
        "$TS" "$RUN/Fabric/models_pack.v" "$TS" "$T/lut4_ff_bel.v" "$TS" "$T/LOGIC4_ConfigMem.v" \
        "$TS" "$mt" "$TS" "$GEN_TILE_V" "$CR_TB" >"$mvvp.compile.log" 2>&1 || crc=$?
    if [[ "$crc" -ne 0 ]]; then
        cat "$mvvp.compile.log" >&2
        echo "control-route mutant '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    v="$(ctrl_run "$mvvp" "$mlog")"
    if [[ "$v" != FUNC_FAIL ]]; then
        echo "control-route mutant '$m' (${CRM_DESC[$m]}): NOT caught (verdict $v; a timeout, simulator error or missing verdict never counts; see $mlog)" >&2
        status=1; continue
    fi
    got="$(sed -n 's/^  case \(C_[A-Z0-9_]*\): [0-9]* mismatches$/\1/p' "$mlog" | sort | xargs)"
    want="$(crm_expect "$m")"
    if [[ "$got" != "$want" ]]; then
        echo "control-route mutant '$m' (${CRM_DESC[$m]}): failing cases [$got] != predicted [$want]" >&2
        status=1; continue
    fi
    ctrl_cov_ok "$mlog" && ctrl_cfg_ok "$mlog" || { echo "control-route mutant '$m': coverage/readback not intact" >&2; status=1; continue; }
    n_crm=$((n_crm + 1))
    echo "control-route mutant '$m' (${CRM_DESC[$m]}) caught: compiled; $(grep -m1 '^FAIL' "$mlog" | sed 's/^FAIL: //'); failing cases == predicted ($(echo "$got" | wc -w)/20): $got; ConfigBits == decoded on all"
done
[[ "$n_crm" -eq 5 ]] || status=1

# ---- 8. boundary output-track source diagnostic (issue #180) ----------------
# Diagnostic assembler-generated streams, NOT mapper output: proves that every
# existing source of every boundary output track (4 BEL outputs + 3 incoming
# same-index tracks, 16 tracks) is selected through frame programming and
# reaches the tile boundary, observed directly. Not the fixed output routes of
# step 5, not the routes into the BELs of steps 6/7, not a component select
# sweep; no inter-tile, timing or ratified-fabric claim.
echo "=== boundary output-route diagnostic (issue #180): 16 output tracks x 7 sources through the integrated tile ==="
OR="$OUT/output_route"; OR_TB="$REPO/sim/tb_output_route.v"; OR_NAME=tb_output_route
[[ -s "$OR_TB" ]] || die "missing $OR_TB"
python3 -I "$REPO/flow/output_route.py" "$OR" --snapshot "$BS/fabric_spec.json" || die "output-route stream generation failed"
[[ "$(wc -l < "$OR/cases.txt")" -eq 112 && "$(wc -l < "$OR/required.txt")" -eq 112 ]] || die "expected 112 output-route cases and 112 required routes"
OR_GEN="$OUT/outroute_gen.vvp"; OR_RTL="$OUT/outroute_rtl.vvp"
gen_compile "$GEN_TILE_V" "$OR_GEN" "$OR_TB" \
    || { cat "$OR_GEN.compile.log" >&2; die "compile of the generated-tile output-route bench failed"; }
iverilog -g2012 -Wall -o "$OR_RTL" "$REPO/design/rtl/lut4_slice.v" \
    "$REPO/design/rtl/logic_tile_switch_matrix.v" "$REPO/design/rtl/logic_tile_routed.v" \
    "$OR_TB" >"$OR_RTL.compile.log" 2>&1 \
    || { cat "$OR_RTL.compile.log" >&2; die "compile of the repository-composition output-route bench failed"; }
outroute_run() {   # <vvp> <log>; prints the verdict
    local rc=0
    gs_run_bounded "$(basename "$1" .vvp)[outroute]" "$2" vvp "$1" +dir="$OR" +list="$OR/cases.txt" \
        +wiring="$OR/out.wiring" +map="$MAP" || rc=$?
    gs_classify "$rc" "$2" "$OR_NAME" outroute
}
outroute_cfg_ok() {   # <log>: per-case ConfigBits/cfg readback == python decode of the stream
    local id got
    while read -r id _; do
        got="$(grep -m1 "^CFG $id " "$1" | cut -d' ' -f3)"
        if [[ -z "$got" || "$got" != "$(tr -d '\n' < "$OR/$id.cfg")" ]]; then
            echo "  output-route case $id: readback '$got' != decoded $(tr -d '\n' < "$OR/$id.cfg")" >&2; return 1
        fi
    done < "$OR/cases.txt"
}
outroute_cov_ok() {   # <log>: the coverage report must equal the required set, each tuple exactly once
    local got
    got="$(sed -n 's/^COVERAGE: ROUTE \([NESW]\) \([0-3]\) \([NESWA-D]\): selected source toggled.*$/\1 \2 \3/p' "$1" | sort)"
    [[ "$got" == "$(sort "$OR/required.txt")" ]] \
        && [[ "$(echo "$got" | wc -l)" -eq 112 && "$(echo "$got" | uniq -d | wc -l)" -eq 0 ]] \
        && grep -qE '^COVERAGE: 112/112 routes \(4 edges x 4 tracks x 7 sources\); 112 cases loaded in sequence into one live tile; [0-9]+ adversarial .* 0 duplicate case ids$' "$1"
}
outroute_ok=1
for comp in gen rtl; do
    vvp_f="$OR_GEN"; [[ "$comp" == rtl ]] && vvp_f="$OR_RTL"
    log="$OUT/outroute_${comp}.log"
    v="$(outroute_run "$vvp_f" "$log")"
    if [[ "$v" != PASS ]] || ! outroute_cov_ok "$log"; then
        echo "  output-route diagnostic [$comp]: FAIL (verdict $v or coverage differs from the required route set; see $log)" >&2
        tail -n 8 "$log" >&2; outroute_ok=0; status=1; continue
    fi
    outroute_cfg_ok "$log" || { echo "  output-route diagnostic [$comp]: readback mismatch" >&2; outroute_ok=0; status=1; }
done
if [[ "$outroute_ok" -eq 1 ]]; then
    gsum="$(grep -m1 '^PASS' "$OUT/outroute_gen.log" | sed 's/^PASS: [^ ]* //')"
    rsum="$(grep -m1 '^PASS' "$OUT/outroute_rtl.log" | sed 's/^PASS: [^ ]* //')"
    if [[ "$gsum" != "$rsum" ]]; then
        echo "  output-route diagnostic: compositions disagree (generated $gsum vs repository $rsum)" >&2; status=1
    else
        grep -m1 '^COVERAGE: 112/112' "$OUT/outroute_gen.log" | sed 's/^/  generated: /'
        grep -m1 '^COVERAGE: 112/112' "$OUT/outroute_rtl.log" | sed 's/^/  repository: /'
        echo "  generated: $(grep -m1 '^GEN_TILE:' "$OUT/outroute_gen.log")"
        echo "  output-route diagnostic: PASS on both $gsum; 112/112 routes, readback == python decode for all 112 streams on both"
    fi
fi

echo "--- scratch generated-matrix output-source permutations and output-sink select aliases vs the output-route diagnostic (each must give a completed functional FAIL on the predicted cases) ---"
python3 -I - "$T/LOGIC4_switch_matrix.v" "$OUT" <<'PYEOF' || die "could not build output-route mutants"
import re, sys
sm, out = open(sys.argv[1]).read(), sys.argv[2]
def swap(sink, i, j):   # exchange the sources at mux positions i, j of one output-track mux (position 0 = rightmost)
    m = re.findall(r"^assign %s_input = \{([^}]*)\};$" % sink, sm, re.M)
    assert len(m) == 1, sink
    mem = m[0].split(",")[::-1]
    mem[i], mem[j] = mem[j], mem[i]
    new = "assign %s_input = {%s};" % (sink, ",".join(mem[::-1]))
    return sm.replace("assign %s_input = {%s};" % (sink, m[0]), new)
def alias(sink, other):  # `sink` selects with the select field of `other`
    pat = re.compile(r"^(assign #80 %s = %s_input\[)(ConfigBits\[[0-9:]+\])(\];)$" % (sink, sink), re.M)
    pat_o = re.compile(r"^assign #80 %s = %s_input\[(ConfigBits\[[0-9:]+\])\];$" % (other, other), re.M)
    mo = pat_o.search(sm)
    assert len(pat.findall(sm)) == 1 and mo, (sink, other)
    return pat.sub(lambda m: m.group(1) + mo.group(1) + m.group(3), sm)
open(f"{out}/matrix_mut_out_N0_AB.v", "w").write(swap("N1BEG0", 3, 4))
open(f"{out}/matrix_mut_out_W3_SD.v", "w").write(swap("W1BEG3", 2, 6))
open(f"{out}/matrix_mut_out_ALIAS_S2S1.v", "w").write(alias("S1BEG2", "S1BEG1"))
open(f"{out}/matrix_mut_out_ALIAS_N3E3.v", "w").write(alias("N1BEG3", "E1BEG3"))
PYEOF
# Predicted failing cases: derived by flow/output_route.py predict from the case list, the stimulus
# set and the source order of the committed switch-matrix .list (never from the generated RTL or the DUT).
declare -A ORM_DESC=(
    [N0_AB]="output N1BEG0: BEL A and BEL B sources exchanged in a scratch LOGIC4_switch_matrix.v"
    [W3_SD]="output W1BEG3: S and BEL D sources exchanged"
    [ALIAS_S2S1]="sink alias: S1BEG2 uses S1BEG1's select field"
    [ALIAS_N3E3]="sink alias: N1BEG3 uses E1BEG3's select field (cross-edge)"
)
declare -A ORM_ARGS=(
    [N0_AB]="swap N1BEG0 3 4"
    [W3_SD]="swap W1BEG3 2 6"
    [ALIAS_S2S1]="alias S1BEG2 S1BEG1"
    [ALIAS_N3E3]="alias N1BEG3 E1BEG3"
)
n_orm=0
for m in N0_AB W3_SD ALIAS_S2S1 ALIAS_N3E3; do
    mvvp="$OUT/outroute_mut_${m}.vvp"; mlog="$OUT/outroute_mut_${m}.log"
    mt="$OUT/matrix_mut_out_${m}.v"; crc=0
    [[ -s "$mt" && "$(diff <(cat "$T/LOGIC4_switch_matrix.v") "$mt" | grep -c '^>')" -eq 1 ]] \
        || { echo "output-route mutant '$m': scratch matrix is not a one-line mutation" >&2; status=1; continue; }
    iverilog -g2012 -Wall -DGEN_TILE -I "$REPO/sim" -o "$mvvp" \
        "$TS" "$RUN/Fabric/models_pack.v" "$TS" "$T/lut4_ff_bel.v" "$TS" "$T/LOGIC4_ConfigMem.v" \
        "$TS" "$mt" "$TS" "$GEN_TILE_V" "$OR_TB" >"$mvvp.compile.log" 2>&1 || crc=$?
    if [[ "$crc" -ne 0 ]]; then
        cat "$mvvp.compile.log" >&2
        echo "output-route mutant '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    # shellcheck disable=SC2086
    want="$(python3 -I "$REPO/flow/output_route.py" predict "$OR" ${ORM_ARGS[$m]})" || { echo "output-route mutant '$m': prediction failed" >&2; status=1; continue; }
    want="$(echo "$want" | tr ' ' '\n' | sort | xargs)"
    [[ -n "$want" ]] || { echo "output-route mutant '$m': empty prediction (the mutant would be invisible to the diagnostic)" >&2; status=1; continue; }
    v="$(outroute_run "$mvvp" "$mlog")"
    if [[ "$v" != FUNC_FAIL ]]; then
        echo "output-route mutant '$m' (${ORM_DESC[$m]}): NOT caught (verdict $v; a timeout, simulator error or missing verdict never counts; see $mlog)" >&2
        status=1; continue
    fi
    got="$(sed -n 's/^  case \(O_[A-Z0-9_]*\): [0-9]* mismatches$/\1/p' "$mlog" | sort | xargs)"
    if [[ "$got" != "$want" ]]; then
        echo "output-route mutant '$m' (${ORM_DESC[$m]}): failing cases [$got] != predicted [$want]" >&2
        status=1; continue
    fi
    outroute_cov_ok "$mlog" && outroute_cfg_ok "$mlog" || { echo "output-route mutant '$m': coverage/readback not intact" >&2; status=1; continue; }
    n_orm=$((n_orm + 1))
    echo "output-route mutant '$m' (${ORM_DESC[$m]}) caught: compiled; $(grep -m1 '^FAIL' "$mlog" | sed 's/^FAIL: //'); failing cases == predicted ($(echo "$got" | wc -w)/112): $got; ConfigBits == decoded on all"
done
[[ "$n_orm" -eq 4 ]] || status=1

# ---- 9. tile clock and frame forwarding diagnostic (issue #188) ---------------
# Generated-tile-only companion bench (sim/tb_boundary_fwd.v): the repository
# composition has no pass-through ports. Contract read from the pinned LOGIC4.v:
# UserCLKo = UserCLK, FrameData_O = FrameData, FrameStrobe_O = FrameStrobe, each
# a pure logical copy (generator buffers; no timing is modelled or claimed). The
# expected values are the bench's own driven inputs, compared four-state, never
# ConfigBits. Single tile: no inter-tile chaining, timing or ratified-fabric claim.
echo "=== generated-tile forwarding diagnostic (issue #188): UserCLKo, FrameData_O[31:0], FrameStrobe_O[19:0] ==="
FW_TB="$REPO/sim/tb_boundary_fwd.v"; FW_NAME=tb_boundary_fwd
[[ -s "$FW_TB" ]] || die "missing $FW_TB"
python3 -I - "$GEN_TILE_V" <<'PYEOF' || die "generated LOGIC4 forwarding assignments differ from the contract the diagnostic checks"
import re, sys
src = open(sys.argv[1]).read()
def need(pat, n, what):
    if len(re.findall(pat, src, re.M)) != n:
        sys.exit(f"expected {n} x {what} ({pat})")
need(r"^assign FrameData_O_i = FrameData_i;$", 1, "FrameData_O_i = FrameData_i")
need(r"^assign FrameStrobe_O_i = FrameStrobe_i;$", 1, "FrameStrobe_O_i = FrameStrobe_i")
need(r"^clk_buf inst_clk_buf \(\s*\.A\(UserCLK\),\s*\.X\(UserCLKo\)\s*\);$", 1, "UserCLK -> UserCLKo clk_buf")
for i in range(32):
    need(rf"^my_buf data_inbuf_{i} \(\s*\.A\(FrameData\[{i}\]\),\s*\.X\(FrameData_i\[{i}\]\)\s*\);$", 1, f"data in {i}")
    need(rf"^my_buf data_outbuf_{i} \(\s*\.A\(FrameData_O_i\[{i}\]\),\s*\.X\(FrameData_O\[{i}\]\)\s*\);$", 1, f"data out {i}")
for i in range(20):
    need(rf"^my_buf strobe_inbuf_{i} \(\s*\.A\(FrameStrobe\[{i}\]\),\s*\.X\(FrameStrobe_i\[{i}\]\)\s*\);$", 1, f"strobe in {i}")
    need(rf"^my_buf strobe_outbuf_{i} \(\s*\.A\(FrameStrobe_O_i\[{i}\]\),\s*\.X\(FrameStrobe_O\[{i}\]\)\s*\);$", 1, f"strobe out {i}")
print("forwarding contract: UserCLKo=UserCLK (clk_buf); FrameData_O[i]=FrameData[i] x32, FrameStrobe_O[i]=FrameStrobe[i] x20 (my_buf chains)")
PYEOF
FW_GEN="$OUT/fwd_gen.vvp"
gen_compile "$GEN_TILE_V" "$FW_GEN" "$FW_TB" \
    || { cat "$FW_GEN.compile.log" >&2; die "compile of the generated-tile forwarding bench failed"; }
fwd_run() {   # <vvp> <log>; prints the verdict
    local rc=0
    gs_run_bounded "$(basename "$1" .vvp)[fwd]" "$2" vvp "$1" || rc=$?
    gs_classify "$rc" "$2" "$FW_NAME" fwd
}
fwd_cov_ok() {   # <log>: every forwarded port and bit exercised at both levels
    grep -qE '^COVERAGE: UserCLKo ([1-9][0-9]+) rising and ([1-9][0-9]+) falling edges followed$' "$1" \
        && [[ "$(sed -n 's/^COVERAGE: UserCLKo \([0-9]*\) rising and \([0-9]*\) falling.*$/\1 \2/p' "$1" | awk '$1>=16 && $2>=16' | wc -l)" -eq 1 ]] \
        && [[ "$(grep -c '^COVERAGE: FrameData_O 32/32 bits forwarded at both levels$' "$1")" -eq 1 ]] \
        && [[ "$(grep -c '^COVERAGE: FrameStrobe_O 20/20 bits forwarded at both levels$' "$1")" -eq 1 ]]
}
log="$OUT/fwd_gen.log"
v="$(fwd_run "$FW_GEN" "$log")"
if [[ "$v" != PASS ]] || ! fwd_cov_ok "$log"; then
    echo "  forwarding diagnostic: FAIL (verdict $v or incomplete coverage; see $log)" >&2
    tail -n 8 "$log" >&2; status=1
else
    sed -n 's/^COVERAGE: /  generated: /p' "$log"
    echo "  forwarding diagnostic: PASS - $(grep -m1 '^PASS' "$log" | sed 's/^PASS: [^ ]* //'); UserCLKo, FrameData_O 32/32, FrameStrobe_O 20/20"
fi

echo "--- scratch generated-tile forwarding mutants (each must give a completed functional FAIL on its own port only) ---"
python3 -I - "$GEN_TILE_V" "$OUT" <<'PYEOF' || die "could not build forwarding mutants"
import re, sys
src, out = open(sys.argv[1]).read(), sys.argv[2]
def sub1(a, b):
    assert src.count(a) == 1, a
    return src.replace(a, b)
muts = {
    "clk_open":   sub1(".A(UserCLK),\n    .X(UserCLKo)", ".A(UserCLK),\n    .X()"),
    "clk_inv":    sub1(".A(UserCLK),\n    .X(UserCLKo)", ".A(~UserCLK),\n    .X(UserCLKo)"),
    "data_alias": sub1(".A(FrameData_O_i[9]),\n    .X(FrameData_O[9])", ".A(FrameData_O_i[8]),\n    .X(FrameData_O[9])"),
    "strobe_drop": sub1(".A(FrameStrobe_O_i[13]),\n    .X(FrameStrobe_O[13])", ".A(1'b0),\n    .X(FrameStrobe_O[13])"),
}
for k, v in muts.items():
    open(f"{out}/LOGIC4_mut_fwd_{k}.v", "w").write(v)
PYEOF
declare -A FWM_DESC=(
    [clk_open]="UserCLKo output left unconnected (clk_buf X open)"
    [clk_inv]="UserCLKo driven from the inverted clock"
    [data_alias]="FrameData_O[9] aliased to FrameData_O[8]"
    [strobe_drop]="FrameStrobe_O[13] dropped (tied low)"
)
declare -A FWM_PORT=([clk_open]="UserCLKo" [clk_inv]="UserCLKo" [data_alias]="FrameData_O" [strobe_drop]="FrameStrobe_O")
n_fwm=0
for m in clk_open clk_inv data_alias strobe_drop; do
    mt="$OUT/LOGIC4_mut_fwd_${m}.v"; mvvp="$OUT/fwd_mut_${m}.vvp"; mlog="$OUT/fwd_mut_${m}.log"
    [[ -s "$mt" && "$(diff "$GEN_TILE_V" "$mt" | grep -c '^>')" -ge 1 && "$(diff "$GEN_TILE_V" "$mt" | grep -c '^>')" -le 2 ]] \
        || { echo "forwarding mutant '$m': scratch tile is not a minimal mutation" >&2; status=1; continue; }
    if ! gen_compile "$mt" "$mvvp" "$FW_TB"; then
        cat "$mvvp.compile.log" >&2
        echo "forwarding mutant '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    v="$(fwd_run "$mvvp" "$mlog")"
    if [[ "$v" != FUNC_FAIL ]]; then
        echo "forwarding mutant '$m' (${FWM_DESC[$m]}): NOT caught (verdict $v; a timeout, simulator error or missing verdict never counts; see $mlog)" >&2
        status=1; continue
    fi
    # the mismatch lines must name the mutated port and no other forwarded port
    bad=0
    for port in UserCLKo FrameData_O FrameStrobe_O; do
        c="$(grep -c "^  mismatch .*: $port=" "$mlog" || true)"
        if [[ "$port" == "${FWM_PORT[$m]}" ]]; then [[ "$c" -ge 1 ]] || bad=1; else [[ "$c" -eq 0 ]] || bad=1; fi
    done
    if [[ "$bad" -ne 0 ]]; then
        echo "forwarding mutant '$m' (${FWM_DESC[$m]}): failing port(s) differ from the predicted ${FWM_PORT[$m]} (see $mlog)" >&2
        status=1; continue
    fi
    n_fwm=$((n_fwm + 1))
    echo "forwarding mutant '$m' (${FWM_DESC[$m]}) caught: compiled; $(grep -m1 '^FAIL' "$mlog" | sed 's/^FAIL: //'); only ${FWM_PORT[$m]} mismatched"
done
[[ "$n_fwm" -eq 4 ]] || status=1

if [[ "$status" -eq 0 ]]; then
    echo "generated-tile replay: PASS (${pass}/${n_fix} fixtures, 5/5 composition mutations caught; LUT basis 64/64 (BEL, address) cases on both compositions, 3/3 basis mutants caught; LUT-input routes 64/64 (BEL, pin, edge) cases on both compositions, 3/3 route mutants caught; control-jump routes 20/20 (16 enable + 4 reset) cases on both compositions, 5/5 control mutants caught; output-track sources 112/112 (edge, track, source) cases on both compositions, 4/4 output mutants caught; tile forwarding UserCLKo + FrameData_O 32/32 + FrameStrobe_O 20/20 on the generated tile, 4/4 forwarding mutants caught)"
else
    echo "generated-tile replay: FAIL" >&2
fi
exit "$status"
