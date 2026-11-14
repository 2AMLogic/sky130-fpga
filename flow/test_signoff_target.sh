#!/usr/bin/env bash
# flow/test_signoff_target.sh (issue #259): regression for the read-only
# `--target <dir>` flag on the four signoff harnesses (flow/drc.sh,
# flow/erc.sh, flow/lvs.sh, flow/sta-sweep.sh).
#
# What it pins down, per the issue's acceptance criteria:
#   (a) default-mode `klt` argv and cwd are byte-identical to what the
#       harnesses constructed before `--target` existed (the expected argv
#       is inlined below as the committed fixture);
#   (b) `--target <dir>` argv names the target directory's artifacts and
#       consults nothing under layout/ for the measured artifact;
#   (c) `--target` combined with `--update` / `--update-report` exits
#       non-zero before any `klt` invocation and writes nothing anywhere;
#   (d) `sta-sweep.sh --routed` still resolves to layout/experimental, and
#       `--target <repo>/layout/experimental` is its exact alias, so every
#       record citation of `--routed` keeps its meaning;
#   (e) `--target` skips the committed-copy comparisons and a clean
#       measurement exits 0 with the trimmed report's location printed;
#       edge cases (missing dir, missing GDS, `--target` twice, trailing
#       slash, `--target <repo>/layout`) fail loudly or behave as the
#       default, never silently falling back.
#
# Needs no klt, no PDK, no network: a fake `klt` on PATH records every
# invocation's cwd + argv as JSON lines and answers each verb with the
# minimal deterministic response the harness proceeds on. The stub DRC
# response embeds the committed report plus two version fields, so
# drc_report_trim's output byte-matches the committed copy and the default
# drc leg exercises the full path through `klt drc --check`. The
# default-mode erc/lvs/sta legs still fail at their committed-copy diffs
# (the stub responses are not the committed bytes) -- expected; those legs
# assert argv, not exit status. Same fake-binary-on-PATH shape as
# flow/test_sim_budget.sh. Runs serially; the sta legs dominate (~1 min).
# Exit nonzero on any mismatch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }
# assert <name> <command...>: the command must exit 0
assert() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
# out_has <name> <glob-pattern>: the last run_h's output matches the pattern
out_has() {
    local name="$1" pat="$2"
    if [[ "$OUT" == $pat ]]; then ok "$name"; else bad "$name"; fi
}

KLT_LOG="$T/klt-stub.log"
: > "$KLT_LOG"
export KLT_STUB_LOG="$KLT_LOG"
export KLT_STUB_REPO="$REPO"
export KLT_STUB_T="$T"

# ---- 0. stub environment ------------------------------------------------
# 18-corner stub liberty tree, exactly sta-sweep.sh's ALL_CORNERS (the
# sweep asserts its own list against this directory's listing).
PDK_LIBS="$T/pdk/libref/sky130_fd_sc_hd/lib"
mkdir -p "$PDK_LIBS" "$T/bin" "$T/target"
for c in ff_100C_1v65 ff_100C_1v95 ff_n40C_1v56 ff_n40C_1v65 ff_n40C_1v76 \
         ff_n40C_1v95 ff_n40C_1v95_ccsnoise tt_025C_1v80 tt_100C_1v80 \
         ss_100C_1v40 ss_100C_1v60 ss_n40C_1v28 ss_n40C_1v35 ss_n40C_1v40 \
         ss_n40C_1v44 ss_n40C_1v60 ss_n40C_1v60_ccsnoise ss_n40C_1v76; do
    : > "$PDK_LIBS/sky130_fd_sc_hd__${c}.lib"
done

cat > "$T/bin/klt" <<'STUB'
#!/usr/bin/env python3
"""Stub `klt` for flow/test_signoff_target.sh (issue #259).

Logs every invocation's cwd + argv as one JSON line to $KLT_STUB_LOG and
answers each verb with the minimal deterministic response the signoff
harnesses proceed on. Unknown verbs exit 2 loudly."""
import json
import os
import sys

LOG = os.environ["KLT_STUB_LOG"]
REPO = os.environ["KLT_STUB_REPO"]
T = os.environ["KLT_STUB_T"]
SHA = "sha256:" + "0" * 64  # deterministic stand-in content hash


def log_invocation():
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps({"cwd": os.getcwd(), "argv": sys.argv[1:]}) + "\n")


def write_json(obj):
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")


def corner_entry(corner, has_spef):
    entry = {
        "corner": corner,
        "deck": {"name": f"sky130_fd_sc_hd__{corner}", "content_hash": SHA},
        "timing_status": "constrained",
        "worst_slack_ns": 1.0,
        "total_negative_slack_ns": 0,
        "worst_hold_slack_ns": 0.5,
        "total_negative_hold_slack_ns": 0,
        "setup_violation_count": 0,
        "hold_violation_count": 0,
        "fmax_mhz": 1000.0 / 19.0,  # 1/(20 ns - 1.0 ns WNS), consistent
        "clock_skew_ns": 0.01,
        "estimated_power_mw": 1.23,
    }
    if has_spef:
        entry["spef_annotation"] = {
            "annotation_complete": True,
            "partially_unannotated_driver_count": 0,
        }
    return entry


def drc_response():
    # The committed report plus the two fields drc_report_trim strips, so
    # the trimmed output byte-matches the committed copy and the default
    # drc leg runs through the report diff AND `klt drc --check`.
    with open(os.path.join(REPO, "layout", "logic_tile.drc.json"), encoding="utf-8") as f:
        report = json.load(f)
    prov = dict(report.get("provenance") or {})
    prov["klt_version"] = "stub"
    prov["klayout_version"] = "stub"
    report["provenance"] = prov
    return report


argv = sys.argv[1:]
log_invocation()
if not argv:
    sys.exit(2)
sub = argv[0]

if sub == "--version":
    print("klt 0.0.0-stub")
    sys.exit(0)

if sub == "pdk" and argv[1:2] == ["find"]:
    if "json" in argv:
        write_json({
            "root": os.path.join(T, "pdk"),
            "version": "open_pdks stub",
            "assets": {"libs_ref": os.path.join(T, "pdk", "libref")},
        })
    else:
        print(f"root: {T}/pdk")
        print("variant: sky130A")
        print("version: open_pdks stub")
    sys.exit(0)

if sub == "drc":
    if argv[1:2] == ["--check"]:
        sys.exit(0)
    write_json(drc_response())
    sys.exit(0)

if sub == "erc":
    write_json({
        "status": "ok",
        "erc_finding_count": 0,
        "erc_findings": [],
        "gates": [],
        "gate_count": 0,
    })
    sys.exit(0)

if sub == "extract":
    if "--spef" in argv:
        with open(argv[argv.index("--spef") + 1], "w", encoding="utf-8") as f:
            f.write("*DATE stub\n*VERSION stub\n")
    if "-o" in argv:
        with open(argv[argv.index("-o") + 1], "w", encoding="utf-8") as f:
            f.write("* stub spice\n")
    write_json({
        "status": "extracted",
        "provenance": {"input": {"content_hash": SHA, "role": "gds"},
                        "klt_version": "0.0.0-stub"},
    })
    sys.exit(0)

if sub == "lvs":
    write_json({
        "status": "match",
        "power_connectivity": {"status": "match"},
        "provenance": {"input": {"content_hash": SHA},
                        "klt_version": "0.0.0-stub"},
    })
    sys.exit(0)

if sub == "sta":
    with open(argv[1], encoding="utf-8") as f:
        req = json.load(f)
    has_spef = bool(req.get("spef"))
    prov = {"input": {"content_hash": SHA, "role": "def"},
            "deck": {"content_hash": SHA},
            "klt_version": "0.0.0-stub"}
    corners = (req.get("pdk") or {}).get("corners")
    if corners:
        write_json({
            "status": "ok",
            "geometry_source": "routed",
            "provenance": prov,
            "corners": [corner_entry(c, True) for c in corners],
        })
    else:
        resp = {"status": "ok", "geometry_source": "routed", "provenance": prov}
        resp.update(corner_entry((req.get("pdk") or {}).get("corner"), has_spef))
        write_json(resp)
    sys.exit(0)

if sub == "synthesize":
    # flow/lvs.sh runs flow/layout.sh in check mode first; make that fail
    # after the request exists (layout.sh exits nonzero, which lvs.sh's
    # check mode tolerates), with a parseable response carrying the
    # provenance.input.content_hash lvs_report_trim later reads.
    write_json({"status": "failed", "error": "stub synthesize",
                "provenance": {"input": {"content_hash": SHA}}})
    sys.exit(1)

print(f"stub klt: unknown verb {sub!r}", file=sys.stderr)
sys.exit(2)
STUB
chmod +x "$T/bin/klt"

printf '#!/usr/bin/env bash\necho "stub-openroad 1.0"\n' > "$T/bin/openroad"
chmod +x "$T/bin/openroad"

# Restricted PATH: stubs first, then system python3/coreutils only -- the
# host's real klt/openroad (and anything else from ~/.local/bin) must be
# invisible. /usr/bin/yosys may stay visible: flow/layout.sh (run by lvs.sh)
# only checks for it, and the stubbed `klt synthesize` fails before yosys
# is ever invoked.
PATH="$T/bin:/usr/bin:/bin"
export PATH

# run_h <script> [args...]: run a harness from $REPO, capture RC + OUT
RC=0
OUT=""
run_h() {
    RC=0
    OUT="$(cd "$REPO" && "$@" 2>&1)" || RC=$?
}

# The worktree is dirty with this issue's own in-progress edits; snapshot
# that state so the final assertion proves the TEST added nothing.
STATUS_BEFORE="$(git -C "$REPO" status --porcelain)"

touch_sentinel() { touch "$T/sentinel"; }
# assert_no_writes <name>: nothing under the committed-evidence trees is
# newer than the sentinel (flow/build is gitignored scratch and exempt)
no_writes() {
    [[ -z "$(find "$REPO/layout" "$REPO/measurements" "$REPO/signoff" \
        -newer "$T/sentinel" -print -quit 2>/dev/null)" ]]
}

# expect_invocation <name> <expected-cwd> <expected-argv-json>: the log
# contains a line exactly matching cwd+argv
expect_invocation() {
    local name="$1" cwd="$2" argvjson="$3"
    if KLT_STUB_LOG="$KLT_LOG" python3 - "$cwd" "$argvjson" <<'PY'
import json, os, sys
expected = {"cwd": sys.argv[1], "argv": json.loads(sys.argv[2])}
with open(os.environ["KLT_STUB_LOG"], encoding="utf-8") as f:
    lines = [json.loads(l) for l in f if l.strip()]
sys.exit(0 if any(l == expected for l in lines) else 1)
PY
    then ok "$name"; else bad "$name"; fi
}

# assert_sta_requests <name> <default|target|routed>: every logged `sta`
# request reads the committed DEF directly (lef-only run) or its
# name-sanitized copy in the build dir (control + SPEF runs), and the SPEF
# annotated is this run's own sanitized one -- never a layout/ path the
# target did not ask for.
assert_sta_requests() {
    local name="$1" mode="$2"
    if KLT_STUB_LOG="$KLT_LOG" KLT_STUB_MODE="$mode" python3 <<'PY'
import json, os, sys
log, mode = os.environ["KLT_STUB_LOG"], os.environ["KLT_STUB_MODE"]
repo, t = os.environ["KLT_STUB_REPO"], os.environ["KLT_STUB_T"]
expect = {
    "default": (repo + "/layout/logic_tile.def",
                repo + "/flow/build/sta/logic_tile.sanitized.def",
                repo + "/flow/build/sta/"),
    "routed": (repo + "/layout/experimental/logic_tile_routed.def",
               repo + "/flow/build/sta_routed/logic_tile_routed.sanitized.def",
               repo + "/flow/build/sta_routed/"),
    "target": (t + "/target/logic_tile.def",
               repo + "/flow/build/sta_target/logic_tile.sanitized.def",
               repo + "/flow/build/sta_target/"),
}[mode]
problems = []
for line in open(log, encoding="utf-8"):
    if not line.strip():
        continue
    d = json.loads(line)
    if d["argv"][:1] != ["sta"]:
        continue
    with open(d["argv"][1], encoding="utf-8") as f:
        req = json.load(f)
    defp, spefp = req.get("def"), req.get("spef")
    if defp not in (expect[0], expect[1]):
        problems.append(f"def={defp}")
    if spefp and not spefp.startswith(expect[2]):
        problems.append(f"spef={spefp}")
if problems:
    print("\n".join(sorted(set(problems))), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
    then ok "$name"; else bad "$name"; fi
}

# no_invocations_since <name>: the log gained no lines since the marker
LOG_MARK=0
mark_log() { LOG_MARK="$(wc -l < "$KLT_LOG")"; }
no_new_invocations() {
    [[ "$(wc -l < "$KLT_LOG")" -eq "$LOG_MARK" ]]
}

# ---- 1. --target + write-mode refusals (before anything creates scratch) -
touch_sentinel

run_h "$REPO/flow/drc.sh" --target "$T/target" --update
assert "drc: --target --update refused (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
out_has "drc: refusal names the read-only rule" '*read-only*'
mark_log
run_h "$REPO/flow/erc.sh" --target "$T/target" --update
assert "erc: --target --update refused (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
assert "erc: refusal ran no klt" no_new_invocations
run_h "$REPO/flow/lvs.sh" --target "$T/target" --update
assert "lvs: --target --update refused (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
run_h "$REPO/flow/lvs.sh" --target "$T/target" --update-report
assert "lvs: --target --update-report refused (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
assert "lvs: refusals ran no klt" no_new_invocations
run_h "$REPO/flow/sta-sweep.sh" --target "$T/target" --update
assert "sta: --target --update refused (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
assert "sta: refusal ran no klt" no_new_invocations
assert "refusals wrote nothing under layout/, measurements/ or signoff/" no_writes
assert "refusals created no target artifacts" bash -c "[[ -z \$(ls -A '$T/target') ]]"

# ---- 2. drc.sh -----------------------------------------------------------
# (a) default mode: byte-identical argv + cwd, and the full check path
# (report diff + klt drc --check) exits 0 against the committed report.
: > "$KLT_LOG"
run_h "$REPO/flow/drc.sh"
assert "drc default: exit 0 (clean, reproducible, fresh) (rc=$RC)" bash -c "[[ $RC -eq 0 ]]" || echo "$OUT"
expect_invocation "drc default: klt drc argv+cwd byte-identical" "$REPO" \
    '["drc", "layout/logic_tile.gds", "--deck", "sky130", "--pdk", "sky130A", "--format", "json"]'
expect_invocation "drc default: klt drc --check argv+cwd byte-identical" "$REPO" \
    '["drc", "--check", "layout/logic_tile.drc.json"]'

# (b) target mode: argv names the target GDS, nothing under layout/ is
# consulted, trimmed report lands in the build dir, exit 0.
cp "$REPO/layout/logic_tile.gds" "$T/target/logic_tile.gds"
touch_sentinel
: > "$KLT_LOG"
run_h "$REPO/flow/drc.sh" --target "$T/target"
assert "drc target: clean measurement exits 0 (rc=$RC)" bash -c "[[ $RC -eq 0 ]]" || echo "$OUT"
expect_invocation "drc target: argv names the target GDS" "$REPO" \
    "[\"drc\", \"$T/target/logic_tile.gds\", \"--deck\", \"sky130\", \"--pdk\", \"sky130A\", \"--format\", \"json\"]"
assert "drc target: no klt drc --check (no committed counterpart)" \
    bash -c "! grep -q -- '--check' '$KLT_LOG'"
assert "drc target: trimmed report in the build dir, location printed" \
    bash -c "[[ -f '$REPO/flow/build/logic_tile.drc.json' ]]"
out_has "drc target: location printed" '*flow/build*'
assert "drc target: wrote nothing committed" no_writes

# edge: trailing slash behaves like the plain path
: > "$KLT_LOG"
run_h "$REPO/flow/drc.sh" --target "$T/target/"
assert "drc target: trailing slash accepted (rc=$RC)" bash -c "[[ $RC -eq 0 ]]"
expect_invocation "drc target: trailing slash argv identical" "$REPO" \
    "[\"drc\", \"$T/target/logic_tile.gds\", \"--deck\", \"sky130\", \"--pdk\", \"sky130A\", \"--format\", \"json\"]"

# edge: the committed layout dir spelled explicitly behaves as the default
: > "$KLT_LOG"
run_h "$REPO/flow/drc.sh" --target "$REPO/layout"
assert "drc --target layout: exit 0 as the default (rc=$RC)" bash -c "[[ $RC -eq 0 ]]"
expect_invocation "drc --target layout: default relative argv" "$REPO" \
    '["drc", "layout/logic_tile.gds", "--deck", "sky130", "--pdk", "sky130A", "--format", "json"]'
expect_invocation "drc --target layout: freshness cross-check still runs" "$REPO" \
    '["drc", "--check", "layout/logic_tile.drc.json"]'

# edge: missing dir / duplicate flag / dir without the GDS
mark_log
run_h "$REPO/flow/drc.sh" --target "$T/nonexistent"
assert "drc: missing --target dir fails (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
out_has "drc: missing dir named in the error" '*does not exist*'
assert "drc: missing dir ran no klt" no_new_invocations
run_h "$REPO/flow/drc.sh" --target "$T/target" --target "$T/target"
assert "drc: --target twice fails (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
mkdir -p "$T/empty"
run_h "$REPO/flow/drc.sh" --target "$T/empty"
assert "drc: target dir missing logic_tile.gds fails loudly (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
out_has "drc: missing-GDS error names the --target directory" '*--target directory*'

# ---- 3. erc.sh ------------------------------------------------------------
# (a) default argv+cwd byte-identical (the stub report is not the committed
# bytes, so the committed-copy diff fails at the very end: rc != 0 expected)
: > "$KLT_LOG"
run_h "$REPO/flow/erc.sh"
expect_invocation "erc default: klt erc argv+cwd byte-identical" "$REPO" \
    '["erc", "layout/logic_tile.gds", "flow/erc_supply_spec.json", "--top", "logic_tile", "--pdk", "sky130", "--format", "json"]'
assert "erc default: fails at the committed-copy diff (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
out_has "erc default: failure is the committed-copy diff" '*differs from the committed copy*'
# (b) target: argv names the target GDS, exit 0, nothing written
touch_sentinel
: > "$KLT_LOG"
run_h "$REPO/flow/erc.sh" --target "$T/target"
assert "erc target: clean measurement exits 0 (rc=$RC)" bash -c "[[ $RC -eq 0 ]]" || echo "$OUT"
expect_invocation "erc target: argv names the target GDS" "$REPO" \
    "[\"erc\", \"$T/target/logic_tile.gds\", \"flow/erc_supply_spec.json\", \"--top\", \"logic_tile\", \"--pdk\", \"sky130\", \"--format\", \"json\"]"
assert "erc target: trimmed report in the build dir" \
    bash -c "[[ -f '$REPO/flow/build/logic_tile.erc.json' ]]"
out_has "erc target: location printed" '*flow/build*'
assert "erc target: wrote nothing committed" no_writes

# ---- 4. sta-sweep.sh ------------------------------------------------------
# (b/e) target: the whole sweep against the uncommitted layout, read-only,
# exiting 0 through the structure-only envelope gate.
touch_sentinel
: > "$KLT_LOG"
cp "$REPO/layout/logic_tile.def" "$T/target/logic_tile.def"
run_h "$REPO/flow/sta-sweep.sh" --target "$T/target"
assert "sta target: clean measurement exits 0 (rc=$RC)" bash -c "[[ $RC -eq 0 ]]" || echo "$OUT"
out_has "sta target: trimmed per-corner reports printed under build/sta_target" '*sta_target/corners-trimmed*'
expect_invocation "sta target: extract argv names the target GDS" "$REPO" \
    "[\"extract\", \"$T/target/logic_tile.gds\", \"--deck\", \"sky130\", \"--parasitics\", \"--spef\", \"$REPO/flow/build/sta_target/logic_tile.raw.spef\", \"--def-net-names\", \"--def-net-connections\", \"$REPO/flow/build/sta_target/logic_tile.connections.def\", \"--def-pins\", \"$T/target/logic_tile.def\", \"--abstract-cells\", \"sky130_fd_sc_hd__*\", \"-o\", \"$REPO/flow/build/sta_target/logic_tile.parasitics.spice\", \"--format\", \"json\"]"
assert_sta_requests "sta target: all sta requests read the target DEF only" target
assert "sta target: no invocation consults layout/" bash -c "! grep -q '$REPO/layout/' '$KLT_LOG'"
assert "sta target: wrote nothing committed" no_writes

# (a) default: extract argv byte-identical, every request reads the
# committed DEF; the committed-copy diffs fail at the end (rc != 0).
: > "$KLT_LOG"
run_h "$REPO/flow/sta-sweep.sh"
expect_invocation "sta default: extract argv byte-identical" "$REPO" \
    "[\"extract\", \"$REPO/layout/logic_tile.gds\", \"--deck\", \"sky130\", \"--parasitics\", \"--spef\", \"$REPO/flow/build/sta/logic_tile.raw.spef\", \"--def-net-names\", \"--def-net-connections\", \"$REPO/flow/build/sta/logic_tile.connections.def\", \"--def-pins\", \"$REPO/layout/logic_tile.def\", \"--abstract-cells\", \"sky130_fd_sc_hd__*\", \"-o\", \"$REPO/flow/build/sta/logic_tile.parasitics.spice\", \"--format\", \"json\"]"
assert_sta_requests "sta default: all sta requests read the committed DEF" default
assert "sta default: fails at the committed-copy diff (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"

# (d) --routed still selects layout/experimental; --target names it as the
# exact alias.
: > "$KLT_LOG"
run_h "$REPO/flow/sta-sweep.sh" --routed
expect_invocation "sta --routed: extract argv names the experimental tile" "$REPO" \
    "[\"extract\", \"$REPO/layout/experimental/logic_tile_routed.gds\", \"--deck\", \"sky130\", \"--parasitics\", \"--spef\", \"$REPO/flow/build/sta_routed/logic_tile_routed.raw.spef\", \"--def-net-names\", \"--def-net-connections\", \"$REPO/flow/build/sta_routed/logic_tile_routed.connections.def\", \"--def-pins\", \"$REPO/layout/experimental/logic_tile_routed.def\", \"--abstract-cells\", \"sky130_fd_sc_hd__*\", \"-o\", \"$REPO/flow/build/sta_routed/logic_tile_routed.parasitics.spice\", \"--format\", \"json\"]"
assert_sta_requests "sta --routed: all requests read the experimental DEF" routed
ROUTED_EXTRACT_LINE="$(grep -F "\"$REPO/layout/experimental/logic_tile_routed.gds\"" "$KLT_LOG" | head -1)"
: > "$KLT_LOG"
run_h "$REPO/flow/sta-sweep.sh" --target "$REPO/layout/experimental"
ALIAS_EXTRACT_LINE="$(grep -F "\"$REPO/layout/experimental/logic_tile_routed.gds\"" "$KLT_LOG" | head -1)"
printf '%s\n' "$ROUTED_EXTRACT_LINE" > "$T/routed.line"
printf '%s\n' "$ALIAS_EXTRACT_LINE" > "$T/alias.line"
assert "sta: --routed extract line found" bash -c "[[ -s '$T/routed.line' ]]"
assert "sta: --target layout/experimental is the exact --routed alias" \
    cmp -s "$T/routed.line" "$T/alias.line"
# edge: --routed and --target conflict
run_h "$REPO/flow/sta-sweep.sh" --routed --target "$T/target"
assert "sta: --routed + --target conflict fails (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
run_h "$REPO/flow/sta-sweep.sh" --target "$T/nonexistent"
assert "sta: missing --target dir fails (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
out_has "sta: missing dir named in the error" '*does not exist*'

# ---- 5. lvs.sh ------------------------------------------------------------
# The harness regenerates its reference netlist via flow/layout.sh in check
# mode first; under the stub that run fails after writing synth_response.json
# (tolerated by lvs.sh's check mode), so pre-seed the as-built netlist it
# then picks up.
mkdir -p "$REPO/flow/build/.klt/place-and-route"
cat > "$REPO/flow/build/.klt/place-and-route/logic_tile.v" <<'V'
module logic_tile(clk, rst, out);
input clk;
input rst;
output out;
endmodule
V

# (a) default argv byte-identical (the --pins list comes from the stub
# netlist's own port declarations; the committed-copy diff fails at the end)
: > "$KLT_LOG"
run_h "$REPO/flow/lvs.sh"
expect_invocation "lvs default: extract argv byte-identical" "$REPO" \
    "[\"extract\", \"$REPO/layout/logic_tile.gds\", \"--deck\", \"sky130\", \"--abstract-cells\", \"sky130_fd_sc_hd__[!f]*\", \"--def-net-names\", \"--pins\", \"clk,rst,out\", \"-o\", \"$REPO/flow/build/lvs/logic_tile.gate.spice\", \"--format\", \"json\"]"
assert "lvs default: lvs request built from the committed GDS" \
    bash -c "grep -q '\"netlist\": \"logic_tile.gate.spice\"' '$REPO/flow/build/lvs/lvs_request.json'"
assert "lvs default: fails at the committed-copy diff (rc=$RC)" bash -c "[[ $RC -ne 0 ]]"
# (b) target: argv names the target GDS, exit 0, nothing written
touch_sentinel
: > "$KLT_LOG"
run_h "$REPO/flow/lvs.sh" --target "$T/target"
assert "lvs target: clean compare exits 0 (rc=$RC)" bash -c "[[ $RC -eq 0 ]]" || echo "$OUT"
expect_invocation "lvs target: extract argv names the target GDS" "$REPO" \
    "[\"extract\", \"$T/target/logic_tile.gds\", \"--deck\", \"sky130\", \"--abstract-cells\", \"sky130_fd_sc_hd__[!f]*\", \"--def-net-names\", \"--pins\", \"clk,rst,out\", \"-o\", \"$REPO/flow/build/lvs/logic_tile.gate.spice\", \"--format\", \"json\"]"
assert "lvs target: trimmed report in the build dir" \
    bash -c "[[ -f '$REPO/flow/build/lvs/logic_tile.lvs.json' ]]"
out_has "lvs target: location printed" '*flow/build/lvs*'
assert "lvs target: wrote nothing committed" no_writes

# ---- 6. the test itself never dirties the worktree ------------------------
if [[ "$(git -C "$REPO" status --porcelain)" == "$STATUS_BEFORE" ]]; then
    ok "test dirtied no tracked/untracked path beyond where it started"
else
    bad "test dirtied no tracked/untracked path beyond where it started"
    git -C "$REPO" status --porcelain
fi

echo "----"
if [[ "$rc_all" -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "FAILURES PRESENT"
fi
exit "$rc_all"
