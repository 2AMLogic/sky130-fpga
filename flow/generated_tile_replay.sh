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
#   4. Composition mutations of a scratch copy of LOGIC4.v (BEL A/B ConfigBits
#      slices swapped; EN/SR swapped on BEL A; EN/SR swapped on BEL B) must each
#      compile and then produce a completed functional FAIL from at least one
#      oracle, with no infrastructure failure on any fixture.
#
# Missing fixture/index, compile error, simulator error, a missing or
# conflicting terminal verdict, or an undetected mutation fails the script.
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
gen_compile() {  # $1 = LOGIC4.v to use, $2 = output vvp
    iverilog -g2012 -Wall -DGEN_TILE -I "$REPO/sim" -o "$2" \
        "$TS" "$RUN/Fabric/models_pack.v" "$TS" "$T/lut4_ff_bel.v" \
        "$TS" "$T/LOGIC4_ConfigMem.v" "$TS" "$T/LOGIC4_switch_matrix.v" \
        "$TS" "$1" "$TB" >"$2.compile.log" 2>&1
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
    vvp "$vvp" +bin="$dir/$stem.bin" +map="$MAP" +wiring="$dir/$stem.wiring" \
        +design="$oracle" "$@" >"$log" 2>&1 || rc=$?
    gs_classify "$rc" "$log" "$TB_NAME" "$oracle"
}
summary() { grep -m1 -o '([0-9]* checks, [0-9]* failures[^)]*)' "$1"; }

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
}
for k, v in muts.items():
    open(f"{out}/LOGIC4_mut_{k}.v", "w").write(v)
PYEOF
declare -A MDESC=(
    [belcfg]="BEL A <-> BEL B ConfigBits slices swapped"
    [ensr_A]="BEL A EN/SR pins swapped"
    [ensr_B]="BEL B EN/SR pins swapped"
)
for m in belcfg ensr_A ensr_B; do
    mvvp="$OUT/mut_${m}.vvp"
    if ! gen_compile "$OUT/LOGIC4_mut_${m}.v" "$mvvp"; then
        cat "$mvvp.compile.log" >&2
        echo "mutation '$m': FAIL (did not compile; a mutation must compile and fail functionally)" >&2
        status=1; continue
    fi
    det=(); npass=0; infra=0
    while read -r dir stem oracle; do
        log="$OUT/mut_${m}_${stem}.log"
        v="$(run_one "$mvvp" "$dir" "$stem" "$oracle" "$log")"
        case "$v" in
            FUNC_FAIL) det+=("${stem}[${oracle}] $(summary "$log")") ;;
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
    echo "mutation '$m' (${MDESC[$m]}) caught: compiled; functional FAIL on ${#det[@]}/$n_fix fixtures ($npass unaffected), ConfigBits == recorded on all"
    for d in "${det[@]}"; do echo "    FAIL: $d"; done
done

if [[ "$status" -eq 0 ]]; then
    echo "generated-tile replay: PASS (${pass}/${n_fix} fixtures, 3/3 composition mutations caught)"
else
    echo "generated-tile replay: FAIL" >&2
fi
exit "$status"
