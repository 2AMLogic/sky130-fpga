# flow/route_diag_helpers.sh -- sourced helper (issue #260): the ONE run,
# readback and coverage implementation of the per-case diagnostic replays, shared
# by flow/generated_tile_replay.sh (generated LOGIC4 and repository composition,
# including per-mutant images), flow/gate-sim-bitstream.sh (synthesized netlist,
# LUT basis incl. the N6 negative control) and flow/gate_route_diag.sh
# (synthesized netlist, the three route suites incl. the N7/N8/N9 negative
# controls).
#
# Every diagnostic loads its cases in sequence into one live tile by the bench's
# simulation-only stream-to-cfg loader and reports a cfg readback per case and a
# coverage line per route. Before #260 the generated and the gate-level replays
# judged those reports by their own copies and could disagree on the same log:
# the gate copy took the required-route count from the manifest itself (a
# shortened manifest and a matching report passed n/n) and wildcarded the suite
# summary line, while the generated copy took the first matching readback of a
# case (a duplicate passed). The checks below keep each side's stronger half.
#
#   rd_run    <tag> <bench> <map> <dir> <list> <wiring> <log> <simulator> <image>
#   rd_cfg_ok <noun> <dir> <list> <log>
#   rd_cov_ok <suite> <dir> <log>          route suites only; the LUT basis
#                                           keeps its own address-coverage check
#
# The caller must source flow/gate_sim_verdict.sh first (bounded runs, verdict
# classification). Nothing here reads a caller's global: every argument is
# explicit. Conversely the globals defined here -- RD_SUITES, RD_BENCH, RD_WIRE,
# RD_COV_SED, RD_COUNT, RD_SUMMARY and the rd_* functions -- must stay free in
# the sourcing script: assigning a scalar to a sourced associative array
# silently writes element 0 instead of failing, which is why the bench table is
# RD_BENCH and not the RD_TB scalar of flow/generated_tile_replay.sh.

# The RD_* tables are read by the scripts that source this file.
# shellcheck disable=SC2034

RD_SUITES="route ctrl outroute"
# bench module of each route suite (sim/<module>.v)
declare -A RD_BENCH=([route]=tb_route_diag [ctrl]=tb_ctrl_route [outroute]=tb_output_route)
# wiring manifest of each route suite, inside its case directory
declare -A RD_WIRE=([route]=route.wiring [ctrl]=ctrl.wiring [outroute]=out.wiring)
# per-route coverage line of each bench -> "<k1> <k2> <k3>" (the required.txt key format)
declare -A RD_COV_SED=(
    [route]='s/^COVERAGE: ROUTE \([A-D]\) \([0-3]\) \([NESW]\): selected track toggled.*$/\1 \2 \3/p'
    [ctrl]='s/^COVERAGE: ROUTE \(EN\|SR\) \([A-D-]\) \([NESW]\): .*checked on .*$/\1 \2 \3/p'
    [outroute]='s/^COVERAGE: ROUTE \([NESW]\) \([0-3]\) \([NESWA-D]\): selected source toggled.*$/\1 \2 \3/p'
)
# the required routes of each suite, as fixed by the frozen pip model (4 BELs x
# 4 pins x 4 edges; 16 enables + 4 shared-reset edges; 4 edges x 4 tracks x 7
# sources). Asserted as an absolute number, never re-derived from the manifest.
declare -A RD_COUNT=([route]=64 [ctrl]=20 [outroute]=112)
# each bench's full coverage summary line, `@` standing for the suite's
# RD_COUNT: the literal suite shape, the case count, the suite-specific checks
# and the duplicate count -- none of which a wildcard lets drift.
declare -A RD_SUMMARY=(
    [route]='^COVERAGE: @/@ routes \(4 BELs x 4 pins x 4 edges\); @ cases loaded in sequence into one live tile; [0-9]+ adversarial .* 0 duplicate case ids$'
    [ctrl]='^COVERAGE: @/@ routes \(16 enable = 4 BELs x 4 edges, 4 shared-reset edges\); @ cases loaded in sequence into one live tile; [0-9]+ phases; [0-9]+ full-disagreement phases .*; 0 duplicate case ids$'
    [outroute]='^COVERAGE: @/@ routes \(4 edges x 4 tracks x 7 sources\); @ cases loaded in sequence into one live tile; [0-9]+ adversarial .* 0 duplicate case ids$'
)

# rd_run <tag> <bench> <map> <dir> <list> <wiring> <log> <simulator> <image>:
# one bounded run of every case in <list>; prints PASS | FUNC_FAIL | INFRA.
#   <tag>        the bench's design label, as in its "PASS: <bench>[<tag>]" line
#   <bench>      testbench module name
#   <map>        ConfigMem map the bench decodes its streams with
#   <dir>        directory of <case>.bin and <case>.cfg
#   <list>       case list; may sit outside <dir> (a negative control that keeps
#                the original case list over substituted streams)
#   <wiring>     wiring manifest
#   <log>        simulator output (stdout and stderr)
#   <simulator>  the simulator command, explicit: the gate-level pass passes
#                ${GATE_SIM_VVP:-vvp} (its stub tests), the generated pass vvp
#   <image>      the compiled simulation image, explicit: a driver runs several
#                per diagnostic (each composition, each mutant), so it is never
#                derived from a global here
# Bounded (issue #157): a timeout returns 124/137 -> INFRA, never FUNC_FAIL.
rd_run() {
    local tag="$1" bench="$2" map="$3" dir="$4" list="$5" wiring="$6" log="$7" rc=0
    gs_run_bounded "$(basename "$9" .vvp)[$tag]" "$log" "$8" "$9" \
        +dir="$dir" +list="$list" +wiring="$wiring" +map="$map" || rc=$?
    gs_classify "$rc" "$log" "$bench" "$tag"
}

# rd_cfg_ok <noun> <dir> <list> <log>: exactly one "CFG <case> <readback>" line
# per case of <list>, equal to the python decode <case>.cfg in <dir>, and no
# other readback: the total equals the case count, so a duplicated readback is
# caught even when every case still has one of its own. <dir> and <list> may
# differ (a negative control keeping the original case list over substituted
# streams and decodes). <noun> only names the case in the message.
rd_cfg_ok() {
    local noun="$1" dir="$2" list="$3" log="$4" id got n ncfg
    n="$(wc -l < "$list")"; ncfg="$(grep -c '^CFG ' "$log" || true)"
    [[ "$ncfg" -eq "$n" ]] || { echo "  $noun: $ncfg cfg readbacks for $n cases" >&2; return 1; }
    while read -r id _; do
        [[ "$(grep -c "^CFG $id " "$log")" -eq 1 ]] || { echo "  $noun $id: not exactly one cfg readback" >&2; return 1; }
        got="$(grep -m1 "^CFG $id " "$log" | cut -d' ' -f3)"
        if [[ -z "$got" || "$got" != "$(tr -d '\n' < "$dir/$id.cfg")" ]]; then
            echo "  $noun $id: readback '$got' != decoded $(tr -d '\n' < "$dir/$id.cfg")" >&2; return 1
        fi
    done < "$list"
}

# rd_cov_ok <suite> <dir> <log>: the coverage report of route suite <suite>
# (route | ctrl | outroute) is exactly the manifest's required set (<dir>/
# required.txt), each route once, at the suite's absolute size (RD_COUNT), with
# the bench's full summary line and no INCOMPLETE route.
rd_cov_ok() {
    local s="$1" d="$2" log="$3" n="${RD_COUNT[$1]}" got ngot
    got="$(sed -n "${RD_COV_SED[$s]}" "$log" | sort)"
    ngot="$(printf '%s\n' "$got" | grep -c . || true)"
    if [[ "$got" != "$(sort "$d/required.txt")" || "$(printf '%s\n' "$got" | uniq -d | wc -l)" -ne 0 ]]; then
        echo "  [$s] coverage report differs from the required route set ($ngot/$n reported)" >&2; return 1
    fi
    [[ "$ngot" -eq "$n" ]] || { echo "  [$s] coverage report lists $ngot routes, not the suite's full $n (manifest and report shortened together)" >&2; return 1; }
    if grep -q 'INCOMPLETE' "$log"; then echo "  [$s] coverage report lists INCOMPLETE routes" >&2; return 1; fi
    grep -qE "${RD_SUMMARY[$s]//@/$n}" "$log" \
        || { echo "  [$s] coverage summary is not the suite's full $n/$n-route line" >&2; return 1; }
}
