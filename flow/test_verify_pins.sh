#!/usr/bin/env bash
# flow/test_verify_pins.sh (issues #281, #286): regression tests for
# signoff/verify-pins.sh's per-member hash coverage.
#
# The checker must compare EVERY member hash an envelope records against the
# file's live bytes -- not just the artifact the manifest's art_rel names:
#   * item 1 (multi-input, #281): every provenance.input.paths member. Its
#     attestation.checks hashes must NOT be re-reported on top -- every
#     hashed check path is already an input member, so a tampered member is
#     named exactly once (dedup, not a double print).
#   * items 9 and 10 (single-input, #286): their member hashes live ONLY in
#     attestation.checks. Before the fix, appending a line to a testbench
#     (item 9) or a hygiene file such as LICENSE (item 10) left the envelope
#     with a stale recorded hash and the script reported clean; the
#     authoritative `klt signoff --attest --check` CI step caught it one step
#     later, but verify-pins.sh exists (issue #52) to be the independent,
#     klt-free second opinion that makes exactly this drift legible.
#
# Method: copy the COMMITTED tree (git archive HEAD) into a mktemp dir,
# trap-cleaned, and tamper only inside the copy -- the real tree is never
# touched and is asserted clean at the end. Member lists are derived from the
# envelopes themselves, so adding a file never desyncs the test. Legs per
# envelope:
#   * per member: tamper -> exit nonzero, output names it
#   * all members tampered at once -> every one named
#   * a member deleted (not modified) -> named failure, no traceback
# plus, item-1 only: hashed attestation members reported exactly once, and a
# bare-string member path resolved like the single-input branch resolves one
# (no TypeError). Hashless attestation entries (command/pin checks) are
# exercised implicitly: every clean run passes with them present.
# Needs python3 and git only: no klt, no PDK, no network (the same contract
# verify-pins.sh itself declares). Exit nonzero on any mismatch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV1="signoff/item-1-design-sources.json"
ENV9="signoff/item-9-testbenches.json"
ENV10="signoff/item-10-repo-hygiene.json"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pristine"
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$T/pristine"
# The script under test is taken from the WORKING TREE, not HEAD: this test
# travels in the same commit as verify-pins.sh's fixes (#281, #286), and a
# pre-commit run must exercise the new checker rather than silently re-testing
# the merged one (every other file -- envelopes, members -- stays committed).
cp "$REPO_ROOT/signoff/verify-pins.sh" "$T/pristine/signoff/verify-pins.sh"
cp -a "$T/pristine" "$T/repo"

rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }
run_pins() { (cd "$T/repo" && ./signoff/verify-pins.sh) >"$T/out" 2>&1; }
fresh_copy() { rm -rf "$T/repo"; cp -a "$T/pristine" "$T/repo"; }
expect_clean() {
    if run_pins && grep -q "pin verification clean" "$T/out"; then ok "$1"; else bad "$1"; sed -n '1,20p' "$T/out"; fi
}
expect_drift() {  # <name> <path the output must name>
    local name="$1" want="$2"
    if run_pins; then bad "$name: verify-pins exited 0"
    elif ! grep -qF -- "$want" "$T/out"; then
        bad "$name: exited nonzero but never named $want"; grep -m5 FAIL "$T/out"
    else ok "$name -> named $want"; fi
}

members_of() {  # <envelope json> <mode: input|attestation> -> member paths on stdout
    python3 - "$1" "$2" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))
if sys.argv[2] == "input":
    for e in env["provenance"]["input"]["paths"]:
        p = e["path"]
        print(p["path"] if isinstance(p, dict) else p)
else:
    for c in env.get("attestation", {}).get("checks", []):
        if "path" in c and "content_hash" in c:
            print(c["path"])
PY
}

envelope_legs() {  # <tag> <env_rel> <mode>
    local tag="$1" env_rel="$2" mode="$3" m missed
    local -a MEMBERS
    mapfile -t MEMBERS < <(members_of "$T/pristine/$env_rel" "$mode")
    if [[ "${#MEMBERS[@]}" -lt 2 ]]; then
        bad "$tag: derived only ${#MEMBERS[@]} members from $env_rel ($mode)"; return
    fi

    # ---- per-member tamper: every member the envelope records is checked ----
    for m in "${MEMBERS[@]}"; do
        printf '\n// drift probe\n' >> "$T/repo/$m"
        expect_drift "$tag tampered $m" "$m"
        cp "$T/pristine/$m" "$T/repo/$m"
    done
    expect_clean "$tag: tree restored after per-member legs"

    # ---- all members tampered at once: every one named, not just the first ----
    for m in "${MEMBERS[@]}"; do printf '\n// drift probe\n' >> "$T/repo/$m"; done
    if run_pins; then bad "$tag all-members tamper: verify-pins exited 0"
    else
        missed=0
        for m in "${MEMBERS[@]}"; do grep -qF -- "$m" "$T/out" || { bad "$tag all-members tamper: $m not named"; missed=1; }; done
        [[ "$missed" -eq 0 ]] && ok "$tag: all ${#MEMBERS[@]} members tampered -> every one named"
    fi
    fresh_copy

    # ---- deleted member: named failure, not a FileNotFoundError traceback ----
    rm "$T/repo/${MEMBERS[0]}"
    if run_pins; then bad "$tag deleted member: verify-pins exited 0"
    elif grep -q "Traceback" "$T/out"; then bad "$tag deleted member: crashed with a traceback"
    elif ! grep -qF -- "${MEMBERS[0]}" "$T/out"; then bad "$tag deleted member: ${MEMBERS[0]} not named"
    else ok "$tag: deleted member -> named failure, no traceback"; fi
    fresh_copy
}

# ---- positive control ----
expect_clean "untouched copy passes clean"

# ---- per-envelope member coverage (item 1: input set; items 9/10:
#      attestation.checks, the only place their member hashes live) ----
envelope_legs "item-1" "$ENV1" input
envelope_legs "item-9" "$ENV9" attestation
envelope_legs "item-10" "$ENV10" attestation

# ---- item-1 attestation hashes are deduped, not double-reported (#286):
#      every hashed check path is already an input member, so tampering one
#      must produce exactly ONE failing check ----
DUP="$(members_of "$T/pristine/$ENV1" attestation | head -1)"
printf '\n// drift probe\n' >> "$T/repo/$DUP"
if run_pins; then bad "item-1 dedup: verify-pins exited 0"
else
    n="$(grep -c '^  FAIL' "$T/out")"
    if [[ "$n" -eq 1 ]]; then ok "item-1 member tampered -> exactly one failing check (deduped, not double-reported)"
    else bad "item-1 dedup: expected 1 FAIL line, got $n"; grep '^  FAIL' "$T/out"; fi
fi
fresh_copy

# ---- bare-string member path: resolved like the single-input branch resolves
#      one (beside the envelope), no TypeError; hashes unchanged so still clean ----
python3 - "$T/repo/$ENV1" <<'PY'
import json, sys
f = sys.argv[1]
env = json.load(open(f))
paths = env["provenance"]["input"]["paths"]
old = paths[0]["path"]
assert isinstance(old, dict), "expected the committed dict path form"
paths[0]["path"] = "../" + old["path"]   # bare string, resolved beside signoff/
json.dump(env, open(f, "w"), indent=1)
PY
if run_pins; then
    if grep -q "TypeError" "$T/out"; then bad "bare-string member path: TypeError"
    else ok "bare-string member path resolves beside the envelope (no TypeError)"; fi
else bad "bare-string member path: verify-pins failed"; grep -m5 FAIL "$T/out"; fi

# ---- the real tree was never touched (every path the legs above touch) ----
mapfile -t WATCHED < <(
    { members_of "$T/pristine/$ENV1" input
      members_of "$T/pristine/$ENV9" attestation
      members_of "$T/pristine/$ENV10" attestation; } | sort -u
)
dirty="$(git -C "$REPO_ROOT" status --porcelain -- \
    signoff/block-manifest.json signoff/tier-report.json \
    signoff/item-1-inventory.json signoff/item-9-inventory.json \
    signoff/item-10-inventory.json "$ENV1" "$ENV9" "$ENV10" "${WATCHED[@]}")"
[[ -z "$dirty" ]] || bad "real tree mutated by the test: $dirty"

if [[ "$rc_all" -ne 0 ]]; then echo "test_verify_pins: FAIL"; exit 1; fi
echo "test_verify_pins: PASS"
