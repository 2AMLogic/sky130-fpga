#!/usr/bin/env bash
# test-merge-pr-hold-state-staleness.sh - Regression test for issue #31.
#
# merge-pr.sh runs under `set -euo pipefail`. Its
# _check_champion_hold_state_staleness() extracted the Champion hold marker
# with an UNGUARDED assignment:
#
#   hold_head="$(printf '%s\n' "$comments" \
#       | grep -o 'champion:hold-state head=[0-9a-f]*' \
#       | tail -1 \
#       | sed -n 's/.*head=\([0-9a-f]*\)/\1/p')"
#
# When the PR's comments contain NO `champion:hold-state` marker -- the common
# case, since that marker is only posted when Champion records a hold episode --
# `grep -o` exits 1. Under `pipefail` the whole pipeline exits 1, and because the
# pipeline feeds a plain variable assignment (no `if`/`||`/`&&` guard), `set -e`
# kills the ENTIRE script immediately, printing nothing. The `[[ -n "$hold_head" ]]
# || return 0` line on the very next row is never reached.
#
# Live incident (2026-09-15, during `/loom:sweep 28`): `merge-pr.sh 30 --auto`
# exited 1 with zero output on a `loom:pr`-labeled, CLEAN, perfectly mergeable PR.
#
# The fix: guard the assignment (`|| true`) so "no marker found" yields the
# expected empty string instead of a script-fatal status -- with NO behavior
# change when a marker IS present.
#
# Test strategy (mirrors test-merge-pr-dirty-worktree-guard.sh):
#   1. Static assertion that the live source guards the assignment.
#   2. Behavioral tests that run the ACTUAL function body extracted from
#      merge-pr.sh inside a REAL child `bash` process configured exactly like
#      merge-pr.sh (`set -euo pipefail`), calling it UNGUARDED and then echoing a
#      sentinel. A child that never prints the sentinel is the bug reproducing.
#      (a) comments present, NO marker      -> completes, no warning  [the bug]
#      (b) comments present, STALE marker   -> completes, warning fires
#      (c) comments present, CURRENT marker -> completes, no warning
#      (d) no comments at all               -> completes, no warning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MERGE_PR="$SCRIPTS_DIR/merge-pr.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

[[ -f "$MERGE_PR" ]] || { echo "ERROR: $MERGE_PR not found" >&2; exit 1; }

# --- Extract the ACTUAL function body from the live source (no drift) ---
extract_fn() {
    local name="$1" file="$2"
    awk -v fn="$name" '
      $0 ~ "^"fn"\\(\\) \\{" { grab=1 }
      grab { print }
      grab && /^}/ { exit }
    ' "$file"
}

FN_BODY="$(extract_fn _check_champion_hold_state_staleness "$MERGE_PR")"
if [[ -n "$FN_BODY" ]]; then
    pass "extracted _check_champion_hold_state_staleness() from merge-pr.sh"
else
    fail "could not extract _check_champion_hold_state_staleness() from merge-pr.sh"
    echo ""
    echo "Tests run: $TESTS_RUN, Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
    exit 1
fi

# --- Test 1: source guards the marker-extraction assignment ---
echo "Test 1: merge-pr.sh guards the hold-state extraction against a no-match grep"

# The assignment must not be able to trip `set -e` under `pipefail`. Accept
# either guard shape: `|| true` on the assignment, or inside the pipeline.
if printf '%s\n' "$FN_BODY" | grep -qE '\|\|[[:space:]]*true'; then
    pass "the hold_head extraction carries a no-match guard (|| true)"
else
    fail "the hold_head extraction must be guarded so a no-match grep cannot abort the script"
fi

# --- Behavioral harness: run the real body in a real `set -euo pipefail` shell ---
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/loom-merge-holdstate.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

FN_FILE="$TMP_ROOT/fn.sh"
printf '%s\n' "$FN_BODY" > "$FN_FILE"

# Runs the extracted function in a child bash configured like merge-pr.sh.
# $1 = PR head SHA, $2 = the stubbed comment body stream (may be empty).
# Echoes the child's combined output; the child's exit status is returned.
run_case() {
    local head_sha="$1" comments="$2"
    local case_script="$TMP_ROOT/case.sh" comments_file="$TMP_ROOT/comments.txt"

    printf '%s' "$comments" > "$comments_file"

    cat > "$case_script" <<CASE
#!/usr/bin/env bash
# Same shell options merge-pr.sh sets.
set -euo pipefail

REPO_NWO="owner/repo"
PR_NUMBER="30"
PR_HEAD_SHA="$head_sha"

warning() { echo "WARN: \$*"; }

# Stub the forge call: emit the fixture comment bodies, exactly as
# forge_get_pr_comments would (one body per line, empty output when the PR has
# no comments at all).
forge_get_pr_comments() { cat "$comments_file"; }

source "$FN_FILE"

# Call it UNGUARDED, exactly as _check_loom_pr_label does.
_check_champion_hold_state_staleness

echo "REACHED_END"
CASE

    local out rc
    set +e
    out="$(bash "$case_script" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out"
    return $rc
}

STALE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
HEAD_SHA="cafebabecafebabecafebabecafebabecafebabe"

# --- Test 2 (a): comments present, NO hold-state marker -> must complete ---
echo ""
echo "Test 2: a PR whose comments contain no champion:hold-state marker does not abort the script"

set +e
out_a="$(run_case "$HEAD_SHA" "$(printf '%s\n' 'LGTM, approving.' 'Judge review: APPROVED' '<!-- loom:lease host=h sweep=s -->')")"
rc_a=$?
set -e

if [[ $rc_a -eq 0 ]] && [[ "$out_a" == *"REACHED_END"* ]]; then
    pass "(a) marker-free comments: function returns 0 and the script runs to completion"
else
    fail "(a) expected completion; rc=$rc_a, out: ${out_a:-<empty>}"
fi

if [[ "$out_a" != *"WARN:"* ]]; then
    pass "(a) no spurious staleness warning when no marker exists"
else
    fail "(a) unexpected warning with no marker present; out: $out_a"
fi

# --- Test 3 (b): STALE marker present -> warning still fires (no regression) ---
echo ""
echo "Test 3: a stale champion:hold-state marker still produces the staleness warning"

set +e
out_b="$(run_case "$HEAD_SHA" "$(printf '%s\n' 'Some earlier comment' "<!-- champion:hold-state head=$STALE_SHA -->")")"
rc_b=$?
set -e

if [[ $rc_b -eq 0 ]] \
   && [[ "$out_b" == *"REACHED_END"* ]] \
   && [[ "$out_b" == *"WARN:"* ]] \
   && [[ "$out_b" == *"$STALE_SHA"* ]] \
   && [[ "$out_b" == *"$HEAD_SHA"* ]]; then
    pass "(b) stale marker: warning fires naming both the recorded and current head"
else
    fail "(b) expected staleness warning; rc=$rc_b, out: ${out_b:-<empty>}"
fi

# --- Test 4 (c): marker matching the current head -> no warning ---
echo ""
echo "Test 4: a champion:hold-state marker naming the current head produces no warning"

set +e
out_c="$(run_case "$HEAD_SHA" "$(printf '%s\n' "<!-- champion:hold-state head=$HEAD_SHA -->")")"
rc_c=$?
set -e

if [[ $rc_c -eq 0 ]] \
   && [[ "$out_c" == *"REACHED_END"* ]] \
   && [[ "$out_c" != *"WARN:"* ]]; then
    pass "(c) current marker: completes with no warning"
else
    fail "(c) expected silent completion; rc=$rc_c, out: ${out_c:-<empty>}"
fi

# --- Test 5 (d): PR with zero comments -> must complete ---
echo ""
echo "Test 5: a PR with zero comments does not abort the script"

set +e
out_d="$(run_case "$HEAD_SHA" "")"
rc_d=$?
set -e

if [[ $rc_d -eq 0 ]] \
   && [[ "$out_d" == *"REACHED_END"* ]] \
   && [[ "$out_d" != *"WARN:"* ]]; then
    pass "(d) comment-free PR: completes with no warning"
else
    fail "(d) expected completion; rc=$rc_d, out: ${out_d:-<empty>}"
fi

# --- Test 6 (e): multiple hold episodes -> the LAST marker wins ---
echo ""
echo "Test 6: with multiple hold-state markers, the last one still wins"

OLDER_SHA="0123456789abcdef0123456789abcdef01234567"
set +e
out_e="$(run_case "$HEAD_SHA" "$(printf '%s\n' "<!-- champion:hold-state head=$OLDER_SHA -->" 'unrelated chatter' "<!-- champion:hold-state head=$STALE_SHA -->")")"
rc_e=$?
set -e

if [[ $rc_e -eq 0 ]] \
   && [[ "$out_e" == *"REACHED_END"* ]] \
   && [[ "$out_e" == *"$STALE_SHA"* ]] \
   && [[ "$out_e" != *"$OLDER_SHA"* ]]; then
    pass "(e) last marker wins (existing extraction semantics preserved)"
else
    fail "(e) expected the last marker to win; rc=$rc_e, out: ${out_e:-<empty>}"
fi

# --- Summary ---
echo ""
echo "Tests run: $TESTS_RUN, Passed: $TESTS_PASSED, Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
