#!/usr/bin/env bash
# flow/gate-sim-bitstream.sh   (issue #119, EXPERIMENTAL, observation-only)
#
# Zero-delay gate-level run of the UNMODIFIED sim/tb_logic_tile_bitstream.v
# with both committed baseline bitstream fixtures (sim/bitstream/top_io.bin,
# top_reg.bin) and, since issue #135, every successful routability-corpus
# fixture listed in sim/bitstream/corpus/index.txt, and, since issue #145, the
# three experimental pin-experiment fixtures of sim/bitstream/pin_experiment/
# (one compile, reused) against the committed synthesized netlist of the
# experimental composed tile (layout/experimental/logic_tile_routed.synth.v) and the sky130_fd_sc_hd
# behavioral models. The netlist replaces design/rtl/ in the DUT; the frame
# loader and boundary pads remain SIMULATION MODELS inside the testbench.
#
# Label: experimental same-index switch matrix (ADR-0004/0005 Proposed),
# zero-delay, functional observation only. No SDF/timing, no ratified-fabric
# claim, no inter-tile claim.
#
# Usage:
#   ./flow/gate-sim-bitstream.sh              # baseline + corpus fixtures, must PASS
#   GATE_SIM_CORPUS_DIR=<dir> overrides the corpus dir (scratch failure-mode tests)
#   ./flow/gate-sim-bitstream.sh --negative   # also prove wrong results FAIL
#   SIM_TIMEOUT_SECONDS=<n> / SIM_KILL_AFTER_SECONDS=<n> override the per-run
#   wall-clock budget (flow/gate_sim_verdict.sh, issue #157); a run that
#   exceeds it is an infrastructure failure, never a negative-control rejection
# Exit: nonzero on missing iverilog/vvp, missing PDK models, compile error,
# simulation error, missing PASS line, or (with --negative) a negative case
# that is wrongly accepted OR whose run did not complete with the terminal
# functional FAIL summary (crash, missing verdict, setup/loader FAIL or
# conflicting verdicts are infrastructure failures; issue #141).
# Scratch output: flow/build/gate-sim-bitstream/ (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=flow/gate_sim_verdict.sh
source "$SCRIPT_DIR/gate_sim_verdict.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/gate-sim-bitstream"
TB_NAME="tb_logic_tile_bitstream"
NETLIST="$REPO_ROOT/layout/experimental/logic_tile_routed.synth.v"
BS_DIR="$REPO_ROOT/sim/bitstream"
CORPUS_DIR="${GATE_SIM_CORPUS_DIR:-$BS_DIR/corpus}"
RECOGNISED_ORACLES=" comb reg quad4 casc2 fan4 casc_fan regcasc "
NEGATIVE=0
[[ "${1:-}" == "--negative" ]] && NEGATIVE=1

for tool in iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done
gs_budget_check || exit 1
[[ -s "$NETLIST" ]] || { echo "error: missing $NETLIST" >&2; exit 1; }

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

mkdir -p "$BUILD_DIR"
echo "=== $(iverilog -V 2>&1 | head -1) ==="
echo "=== netlist: layout/experimental/logic_tile_routed.synth.v sha256 $(sha256sum "$NETLIST" | cut -d' ' -f1) ==="
echo "=== models: $CELL_DIR sha256(sky130_fd_sc_hd.v) $(sha256sum "$CELL_DIR/sky130_fd_sc_hd.v" | cut -d' ' -f1) ==="
echo "=== simulation wall-clock budget: $(gs_budget)s per run (SIM_TIMEOUT_SECONDS), kill grace $(gs_kill_after)s ==="

build() {  # build <netlist> <out.vvp>
    iverilog -g2012 -s "$TB_NAME" -I "$REPO_ROOT/sim" -o "$2" \
        "$REPO_ROOT/sim/$TB_NAME.v" "$1" \
        "$CELL_DIR/primitives.v" "$CELL_DIR/sky130_fd_sc_hd.v" \
        2>"$BUILD_DIR/build.log" || { echo "error: compile failed (see $BUILD_DIR/build.log)" >&2; return 1; }
}

# run_vvp <vvp> <bin> <wiring> <design> <log> ; prints rc-aware verdict to stdout:
# PASS | FUNC_FAIL | INFRA (classification lives in gate_sim_verdict.sh)
run_vvp() {
    local vvp_bin="$1" bin="$2" wiring="$3" dname="$4" log="$5" rc=0
    # bounded by SIM_TIMEOUT_SECONDS (issue #157): a timeout is rc 124/137 -> INFRA
    gs_run_bounded "$(basename "$bin")[$dname]" "$log" \
        ${GATE_SIM_VVP:-vvp} "$vvp_bin" +bin="$bin" +map="$BS_DIR/logic4_configmem.map" +wiring="$wiring" \
        +design="$dname" +mutate || rc=$?
    gs_classify "$rc" "$log" "$TB_NAME" "$dname"
}

# run_one: returns 0 iff the run completed with a PASS verdict (positive checks)
run_one() {
    [[ "$(run_vvp "$@")" == PASS ]]
}

build "$NETLIST" "$BUILD_DIR/$TB_NAME.vvp" || exit 1

status=0
for entry in "comb:top_io" "reg:top_reg"; do
    dname="${entry%%:*}"; stem="${entry#*:}"
    log="$BUILD_DIR/${TB_NAME}_${dname}.log"
    echo "=== gate-level ${TB_NAME} [${dname}] bitstream sim/bitstream/$stem.bin (zero delay, +mutate) ==="
    if run_one "$BUILD_DIR/$TB_NAME.vvp" "$BS_DIR/$stem.bin" "$BS_DIR/$stem.wiring" "$dname" "$log"; then
        grep -E "^(CFG=|baseline|PASS)" "$log"
        # the loaded cfg must equal the recorded cfg (same stream read as in RTL suite)
        sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log" | cut -d= -f2)"
        rec_cfg="$(tr -d '\n' < "$BS_DIR/$stem.cfg")"
        if [[ "$sim_cfg" != "$rec_cfg" ]]; then
            echo "error: [$dname] loaded cfg $sim_cfg != recorded $rec_cfg" >&2; status=1
        fi
    else
        echo "error: [$dname] gate-level run did not PASS (see $log)" >&2
        tail -n 15 "$log" >&2 || true
        status=1
    fi
done

# ---- routability-corpus fixtures (issue #135): replay every indexed successful
# fixture against the same netlist/vvp with the same independent oracles.
# Expected routing failures have no bitstream and are not in the index.
INDEX="$CORPUS_DIR/index.txt"
n_corpus=0
corpus_pass=0
if [[ ! -s "$INDEX" ]]; then
    echo "error: corpus index missing or empty: $INDEX" >&2; status=1
else
    while read -r stem oracle extra; do
        [[ -z "$stem" ]] && continue
        n_corpus=$((n_corpus + 1))
        if [[ -n "$extra" || -z "$oracle" || "$RECOGNISED_ORACLES" != *" $oracle "* ]]; then
            echo "error: [$stem] corpus index entry invalid or oracle '${oracle:-}' unrecognised" >&2; status=1; continue
        fi
        missing=0
        for ext in bin wiring cfg; do
            [[ -s "$CORPUS_DIR/$stem.$ext" ]] || { echo "error: [$stem] missing corpus file $CORPUS_DIR/$stem.$ext" >&2; missing=1; }
        done
        [[ "$missing" -eq 0 ]] || { status=1; continue; }
        log="$BUILD_DIR/${TB_NAME}_corpus_${stem}.log"
        if run_one "$BUILD_DIR/$TB_NAME.vvp" "$CORPUS_DIR/$stem.bin" "$CORPUS_DIR/$stem.wiring" "$oracle" "$log"; then
            sim_cfg="$(grep -o '^CFG=[0-9a-f]*' "$log" | cut -d= -f2)"
            rec_cfg="$(tr -d '\n' < "$CORPUS_DIR/$stem.cfg")"
            if [[ -z "$sim_cfg" || "$sim_cfg" != "$rec_cfg" ]]; then
                echo "corpus [$oracle] $stem: FAIL (loaded cfg '$sim_cfg' != recorded '$rec_cfg')" >&2; status=1
            else
                corpus_pass=$((corpus_pass + 1))
                echo "corpus [$oracle] $stem: PASS ($(grep -m1 '^PASS' "$log" | sed 's/^PASS: //'); cfg == recorded)"
            fi
        else
            echo "corpus [$oracle] $stem: FAIL (see $log)" >&2
            tail -n 15 "$log" >&2 || true
            status=1
        fi
    done < "$INDEX"
    [[ "$n_corpus" -gt 0 ]] || { echo "error: corpus index has no entries: $INDEX" >&2; status=1; }
    echo "=== corpus fixtures replayed at gate level: ${corpus_pass}/${n_corpus} PASS ==="
fi

# ---- pin-experiment fixtures (issue #145, EXPERIMENTAL, separate from the corpus):
# the three distinct-pin fan4 streams replayed at gate level (zero delay) with the
# same netlist/vvp, fan4 oracle and +mutate perturbation checks.
echo "=== pin-experiment fixtures at gate level (sim/bitstream/pin_experiment, zero delay, +mutate) ==="
"$REPO_ROOT/sim/pin_fixture_replay.sh" "$BUILD_DIR/$TB_NAME.vvp" gate || status=1

if [[ "$NEGATIVE" -eq 1 ]]; then
    echo "=== negative checks (each MUST be reported as FAIL by the same pass criterion) ==="
    # neg_verdict <label> <verdict> <log>: prints OK line and returns 0 on FUNC_FAIL;
    # PASS = wrongly accepted, INFRA = infrastructure failure (both set status=1).
    neg_check() {
        local label="$1" verdict="$2" log="$3"
        case "$verdict" in
            FUNC_FAIL) echo "negative $label OK: completed functional rejection -> $(grep -m1 -E '^FAIL' "$log")"; return 0 ;;
            PASS) echo "error: negative $label was ACCEPTED" >&2 ;;
            *) echo "error: negative $label did not complete with a recognised functional verdict (infrastructure failure; see $log)" >&2
               tail -n 15 "$log" >&2 || true ;;
        esac
        return 1
    }
    # N1: wrong program for the oracle -- top_io bitstream judged as the registered design.
    v="$(run_vvp "$BUILD_DIR/$TB_NAME.vvp" "$BS_DIR/top_io.bin" "$BS_DIR/top_reg.wiring" reg "$BUILD_DIR/neg_wrong_bitstream.log")"
    neg_check "N1 (wrong bitstream vs oracle)" "$v" "$BUILD_DIR/neg_wrong_bitstream.log" || status=1
    # N3: wrong program for a corpus case with internal routing -- casc2_s1.bin
    # judged against the casc_fan oracle and wiring.
    v="$(run_vvp "$BUILD_DIR/$TB_NAME.vvp" "$CORPUS_DIR/casc2_s1.bin" "$CORPUS_DIR/casc_fan_s1.wiring" casc_fan "$BUILD_DIR/neg_wrong_corpus.log")"
    neg_check "N3 (wrong corpus bitstream vs oracle)" "$v" "$BUILD_DIR/neg_wrong_corpus.log" || status=1
    # N4/N5: pin-experiment fixture defects (missing file, empty index, function-changing
    # LUT INIT corruption) must fail the gate-level replay too.
    "$REPO_ROOT/sim/pin_fixture_negative.sh" "$BUILD_DIR/$TB_NAME.vvp" gate || status=1
    # N2: corrupted netlist (scratch copy; every nand2_1 -> nor2_1).
    sed 's/sky130_fd_sc_hd__nand2_1/sky130_fd_sc_hd__nor2_1/g' "$NETLIST" >"$BUILD_DIR/corrupt.synth.v"
    if cmp -s "$NETLIST" "$BUILD_DIR/corrupt.synth.v"; then
        echo "error: negative N2 could not corrupt the netlist copy" >&2; status=1
    elif build "$BUILD_DIR/corrupt.synth.v" "$BUILD_DIR/corrupt.vvp"; then
        n2_func=0; n2_bad=0
        for entry in "comb:top_io" "reg:top_reg"; do
            dname="${entry%%:*}"; stem="${entry#*:}"
            v="$(run_vvp "$BUILD_DIR/corrupt.vvp" "$BS_DIR/$stem.bin" "$BS_DIR/$stem.wiring" "$dname" "$BUILD_DIR/neg_corrupt_$dname.log")"
            echo "negative N2 [$dname]: $v $(grep -m1 -E '^(FAIL|PASS)' "$BUILD_DIR/neg_corrupt_$dname.log" || echo '(no verdict line)')"
            case "$v" in
                FUNC_FAIL) n2_func=$((n2_func + 1)) ;;
                PASS) ;;
                *) n2_bad=$((n2_bad + 1))
                   echo "error: negative N2 [$dname] did not complete with a recognised verdict (infrastructure failure; see $BUILD_DIR/neg_corrupt_$dname.log)" >&2
                   tail -n 15 "$BUILD_DIR/neg_corrupt_$dname.log" >&2 || true ;;
            esac
        done
        # both runs must complete; a corrupted netlist need only be caught by at least one fixture
        if [[ "$n2_bad" -gt 0 ]]; then status=1
        elif [[ "$n2_func" -eq 0 ]]; then
            echo "error: negative N2 (corrupted netlist) was ACCEPTED by both fixtures" >&2; status=1
        else
            echo "negative N2 OK: corrupted netlist rejected by a completed functional FAIL ($n2_func/2 fixtures)"
        fi
    else
        status=1
    fi
fi

if [[ "$status" -ne 0 ]]; then echo "=== gate-sim-bitstream FAILED ===" >&2; exit 1; fi
echo "=== ${TB_NAME} PASSES gate-level, zero delay, baseline + ${n_corpus} corpus + 3 pin-experiment fixtures (functional observation only; no timing claim) ==="
