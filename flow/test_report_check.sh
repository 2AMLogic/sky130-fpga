#!/usr/bin/env bash
# flow/test_report_check.sh: regression tests for the report_check.sh
# helpers (issue #265). Needs no klt/PDK/network: sha256_of runs against a
# temp file and a directory, the other negative paths run in subshells.
# Exit nonzero on any mismatch.
#
# The load-bearing case is sha256_of's exit status (PR #279 review): the
# hash command must be the function's last command so its failure reaches
# the caller. Under set -euo pipefail a driver that assigns
# V="$(sha256_of ...)" must abort on an existing-but-unreadable input --
# the echo-prefixed form returned echo's status (always 0) and recorded
# the empty "sha256:" string in a provenance field while every gate
# passed. A directory is used as the bad input because it exists but
# cannot be opened as a file for any uid, which is exactly the read
# failure an existence precheck cannot catch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./report_check.sh
source "$HERE/report_check.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc_all=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1: $2"; rc_all=1; }

# sha256_of: value and format must equal the inline expression it replaced,
# byte-for-byte (PR #279 acceptance criterion), now including the failure
# path.
printf 'hello' > "$T/f"
want="sha256:$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$T/f")"
got="$(sha256_of "$T/f")"
if [[ "$got" == "$want" && "$got" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    ok "sha256_of value+format"
else
    bad "sha256_of value+format" "want $want got $got"
fi

out="$(sha256_of "$T" 2>/dev/null)"; src=$?
if [[ $src -ne 0 && -z "$out" ]]; then
    ok "sha256_of existing-but-unreadable input: rc=$src, no sha256: line"
else
    bad "sha256_of existing-but-unreadable input" "rc=$src out=$out"
fi

# The driver contract itself: under set -euo pipefail the assignment must
# abort, not continue past the failed hash.
assign_contract() (
    set -euo pipefail
    # shellcheck source=./report_check.sh
    . "$HERE/report_check.sh"
    # shellcheck disable=SC2034  # the assignment's exit status under set -e
    V="$(sha256_of "$T")"       # is the contract; the value is never read.
)
if assign_contract 2>/dev/null; then
    bad "set -e assignment aborts" "assignment continued past a failed hash"
else
    ok "set -e assignment aborts under set -euo pipefail"
fi

# The argument-position contract (issue #296; replay strengthened per
# issue #303): routed_checks.sh passed "$(sha256_of ...)" straight into
# lvs_report_trim.py / erc_report_trim.py. A command substitution in
# argument position never reaches set -e, so a failed hash passed the
# empty string through as layout_gds_sha256 /
# provenance.input.content_hash while every gate passed -- the same class
# the assignment contract above forecloses, reached through a different
# call shape.
#
# Per-statement isolation is the load-bearing property (issue #303): the
# original guard eval'd the extracted statements as one block, so under
# set -e the first failing statement aborted the whole replay and no later
# statement was ever reached -- re-introducing the #296 defect at the erc
# site left the suite green, and which site was guarded depended on file
# order. Each extracted statement therefore replays in its OWN subshell
# and is judged on its own.
#
# The per-statement assertion is "no consumer output", not "every
# statement fails": with GDS/SPEC set to directories every assignment
# statement fails on the hash (expected), but the invariant that matters
# is that no trim-script consumer ever receives a digest derived from a
# failed hash.
argument_contract() (
    set -euo pipefail
    # shellcheck source=./report_check.sh
    . "$HERE/report_check.sh"
    # Stub the trim-script consumers (invoked as `python3 <script>`) and
    # the read-only `klt --version` probe a consumer statement carries, so
    # the suite needs neither a trim script nor klt; sha256_of's own
    # `python3 -c` hashing call goes through to the real interpreter so the
    # hash genuinely fails on the directory input.
    # Invoked only via the eval'd statements below; shellcheck cannot see that.
    # shellcheck disable=SC2317
    python3() {
        if [[ "${1:-}" == "-c" ]]; then command python3 "$@"
        else echo "consumer saw args: $*"; fi
    }
    # shellcheck disable=SC2317
    klt() { echo "klt-stub 0.0"; }
    # Consumed by the eval'd statements below; shellcheck cannot see that.
    # shellcheck disable=SC2034
    SCRIPT_DIR="$HERE" BUILD_DIR="$T/build" TOP="t"
    # shellcheck disable=SC2034
    GDS="$T" SPEC="$T" RTL_HASH="unused"  # unreadable input = a directory
    # In per-statement isolation a consumer statement no longer sees an
    # earlier assignment's digest: pre-set the placeholders or set -u
    # aborts it on an unbound variable before the consumer stub runs --
    # a vacuous pass indistinguishable from the guard working.
    # shellcheck disable=SC2034
    GDS_SHA="fixture-placeholder" SPEC_SHA="fixture-placeholder"
    # Extract non-comment sha256_of-bearing statements (line continuations
    # joined), each prefixed with its first physical line number so a
    # failure names the site. The non-empty assertion keeps a future
    # extraction change that matches nothing from passing vacuously.
    lines=()
    mapfile -t lines < <(awk '
        { s = $0; lnr = NR
          while (s ~ /\\$/) { sub(/\\$/, "", s); if ((getline nxt) <= 0) break; s = s nxt }
          if (s ~ /^[[:space:]]*#/) next
          if (s ~ /sha256_of/) print lnr ":" s
        }' "$HERE/routed_checks.sh")
    if (( ${#lines[@]} == 0 )); then
        echo "FAIL argument_contract: extracted zero sha256_of statements from routed_checks.sh" >&2
        exit 1
    fi
    for entry in "${lines[@]}"; do
        lineno="${entry%%:*}"
        stmt="${entry#*:}"
        # shellcheck disable=SC2294  # replaying the driver's real statements is the test
        out_stmt="$(eval "$stmt" 2>/dev/null)" || :
        if [[ -n "$out_stmt" ]]; then
            echo "FAIL argument_contract: routed_checks.sh:$lineno reached a consumer on a failed hash: $out_stmt" >&2
            exit 1
        fi
    done
)
out="$(argument_contract 2>&1)"; src=$?
if [[ $src -eq 0 && -z "$out" ]]; then
    ok "argument-position sha256_of never reaches the trim-script consumer (per-statement replay)"
else
    bad "argument-position sha256_of replay" "rc=$src out=$out"
fi

# Static shape assertion (issue #303): the behavioural replay above is
# scoped to routed_checks.sh by its variable fixture, but sha256_of is
# called from every driver. Assert across every report_check.sh-sourcing
# driver under flow/ that every non-comment sha256_of call site is in
# VAR="$(sha256_of ...)" assignment form. No ordering or fixture
# dependence, and the file list comes from the grep itself rather than a
# hardcoded set of names, so a new driver is covered on arrival.
#
# Per-line policy (issue #309): the anchor admits leading whitespace and
# an optional local/declare prefix so an assignment inside an if block or
# function is not a false positive, and the greedy .* is closed off by
# rejecting any line that still carries sha256_of after the assignment's
# closing `)"` -- the regex alone would otherwise backtrack across
# `; cmd "$(sha256_of ...)"` and accept a compound statement.
shape_line_ok() {
    local line="$1"
    local re='^[[:space:]]*((local|declare)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*"\$\(sha256_of .*\)"[\\[:space:]]*$'
    [[ "$line" =~ $re ]] || return 1
    local rest="${line#*\)\"}"   # text after the first `)"`, i.e. past the assignment
    [[ "$rest" != *sha256_of* ]]
}
shape_contract() (
    set -euo pipefail
    self="$(basename "${BASH_SOURCE[0]}")"
    bad=0
    while IFS= read -r f; do
        base="$(basename "$f")"
        # report_check.sh defines sha256_of (no call sites) and this
        # harness is the checker itself; neither is a driver.
        if [[ "$base" == "report_check.sh" || "$base" == "$self" ]]; then continue; fi
        while IFS= read -r entry; do
            lineno="${entry%%:*}"
            line="${entry#*:}"
            # comment lines carry the policy, not a call shape
            if [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi
            if ! shape_line_ok "$line"; then
                echo "FAIL shape_contract: $base:$lineno sha256_of not in VAR=\"\$(sha256_of ...)\" assignment form" >&2
                bad=1
            fi
        done < <(grep -n 'sha256_of' "$f")
    done < <(grep -ln 'report_check\.sh' "$HERE"/*.sh)
    exit "$bad"
)
out="$(shape_contract 2>&1)"; src=$?
if [[ $src -eq 0 && -z "$out" ]]; then
    ok "sha256_of call sites across all report_check.sh drivers are in assignment form"
else
    bad "sha256_of assignment-form shape across drivers" "rc=$src out=$out"
fi

# shape_line_ok probes (issue #309): the per-line policy must accept the
# shapes the column-0-only anchor false-positived on (indented, local- and
# declare-prefixed, continuation) and must still reject bare argument
# position and the compound statement shapes the greedy .* used to accept.
# Probe lines are intentionally literal data (no expansion); shellcheck
# cannot see that each is fed to the shape policy as text, not run.
# shellcheck disable=SC2016
while IFS='|' read -r expect desc line; do
    if shape_line_ok "$line"; then got=pass; else got=fail; fi
    if [[ "$got" == "$expect" ]]; then
        ok "shape_line_ok $desc"
    else
        bad "shape_line_ok $desc" "expected $expect, got $got"
    fi
done <<'EOF'
pass|column-0 assignment|GDS_SHA="$(sha256_of "$GDS")"
pass|indented assignment|    GDS_SHA="$(sha256_of "$GDS")"
pass|local-prefixed assignment|local GDS_SHA="$(sha256_of "$GDS")"
pass|declare-prefixed assignment|declare GDS_SHA="$(sha256_of "$GDS")"
pass|continuation line|GDS_SHA="$(sha256_of "$GDS")" \
pass|nested substitution|X="$(sha256_of "$(dirname "$F")/g")"
fail|bare argument position|python3 trim.py "$(sha256_of "$SPEC")"
fail|compound ; second call|X="$(sha256_of a)"; python3 trim.py "$(sha256_of b)"
fail|compound env-prefix call|X="$(sha256_of a)" python3 trim.py "$(sha256_of b)"
EOF

# parse_update_mode: check (no argument), update (--update), and the
# negative path (usage line + exit 1).
m="$(parse_update_mode; echo "$MODE")"
if [[ "$m" == "check" ]]; then ok "parse_update_mode default -> check"; else bad "parse_update_mode default" "got $m"; fi
m="$(parse_update_mode --update; echo "$MODE")"
if [[ "$m" == "update" ]]; then ok "parse_update_mode --update -> update"; else bad "parse_update_mode --update" "got $m"; fi
out="$(parse_update_mode --bogus 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == "usage: $0 [--update]" ]]; then
    ok "parse_update_mode bad arg -> usage, rc=1"
else
    bad "parse_update_mode bad arg" "rc=$src out=$out"
fi

# require_klt: negative path in a subshell with klt stripped from PATH.
out="$(PATH=/nonexistent require_klt 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == "error: klt not found on PATH" ]]; then
    ok "require_klt off PATH -> message, rc=1"
else
    bad "require_klt off PATH" "rc=$src out=$out"
fi

# target_dir_arg / parse_target_update_mode / resolve_target_mode
# (issue #370): the shared --target validation. The load-bearing case is
# the empty operand: the pre-#370 drivers stored it and later treated it
# as an omitted flag, so an empty shell variable in a write-mode
# invocation refreshed the committed layout.
TARGET_DIR=""
target_dir_arg "$T"
if [[ "$TARGET_DIR" == "$T" ]]; then
    ok "target_dir_arg records the operand"
else
    bad "target_dir_arg records the operand" "got ${TARGET_DIR:-<unset>}"
fi
out="$(TARGET_DIR="" target_dir_arg "" 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == *"non-empty directory"* ]]; then
    ok "target_dir_arg empty operand -> directory diagnostic, rc=1"
else
    bad "target_dir_arg empty operand" "rc=$src out=$out"
fi
out="$(TARGET_DIR="$T" target_dir_arg "$T" 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == "error: --target given twice" ]]; then
    ok "target_dir_arg second --target -> refused"
else
    bad "target_dir_arg second --target" "rc=$src out=$out"
fi
out="$(TARGET_DIR="" target_dir_arg "$T/missing" 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == *"does not exist"* ]]; then
    ok "target_dir_arg nonexistent directory -> diagnostic, rc=1"
else
    bad "target_dir_arg nonexistent directory" "rc=$src out=$out"
fi

parse_target_update_mode
if [[ "$MODE" == "check" && -z "$TARGET_DIR" ]]; then
    ok "parse_target_update_mode default -> check"
else
    bad "parse_target_update_mode default" "mode=$MODE target=${TARGET_DIR:-<unset>}"
fi
parse_target_update_mode --update
if [[ "$MODE" == "update" ]]; then
    ok "parse_target_update_mode --update -> update"
else
    bad "parse_target_update_mode --update" "mode=$MODE"
fi
mkdir -p "$T/tlayout"
parse_target_update_mode --target "$T/tlayout"
if [[ "$MODE" == "check" && "$TARGET_DIR" == "$T/tlayout" ]]; then
    ok "parse_target_update_mode --target <dir> recorded"
else
    bad "parse_target_update_mode --target" "mode=$MODE target=${TARGET_DIR:-<unset>}"
fi
out="$(parse_target_update_mode --target "" 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == *"non-empty directory"* ]]; then
    ok "parse_target_update_mode empty --target operand -> diagnostic, rc=1"
else
    bad "parse_target_update_mode empty --target" "rc=$src out=$out"
fi
out="$(parse_target_update_mode --bogus 2>&1)"; src=$?
if [[ $src -eq 1 && "$out" == "usage: $0 [--target <dir>] [--update]" ]]; then
    ok "parse_target_update_mode bad arg -> usage, rc=1"
else
    bad "parse_target_update_mode bad arg" "rc=$src out=$out"
fi

# resolve_target_mode: the committed-layout alias collapses to the
# default; any other directory becomes target mode, absolutized.
# Consumed by the sourced resolve_target_mode, which standalone
# analysis cannot see.
# shellcheck disable=SC2034
REPO_ROOT="$T"
mkdir -p "$T/layout" "$T/other"
TARGET_DIR="$T/layout"; resolve_target_mode
if [[ "$TARGET_MODE" == "default" && -z "$TARGET_DIR" ]]; then
    ok "resolve_target_mode committed-layout alias -> default"
else
    bad "resolve_target_mode committed-layout alias" "mode=$TARGET_MODE target=${TARGET_DIR:-<unset>}"
fi
TARGET_DIR="$T/other/"; resolve_target_mode
if [[ "$TARGET_MODE" == "target" && "$TARGET_DIR" == "$T/other" ]]; then
    ok "resolve_target_mode other directory -> target, absolutized"
else
    bad "resolve_target_mode other directory" "mode=$TARGET_MODE target=${TARGET_DIR:-<unset>}"
fi
TARGET_DIR=""; resolve_target_mode
if [[ "$TARGET_MODE" == "default" && -z "$TARGET_DIR" ]]; then
    ok "resolve_target_mode omitted -> default"
else
    bad "resolve_target_mode omitted" "mode=$TARGET_MODE target=${TARGET_DIR:-<unset>}"
fi

exit "$rc_all"
