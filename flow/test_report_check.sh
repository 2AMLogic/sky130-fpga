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

exit "$rc_all"
