#!/usr/bin/env bash
# flow/test_verify_pins.sh (issue #281): regression test for the multi-input
# branch of signoff/verify-pins.sh.
#
# The checker must compare EVERY member of a multi-input envelope's
# provenance.input.paths against its live bytes -- not just the member the
# manifest's art_rel names. Before the fix, a design/rtl/*.v edit left item 1's
# envelope with a stale input-set hash and the script reported clean; the
# authoritative `klt signoff --attest --check` CI step caught it one step
# later, but verify-pins.sh exists (issue #52) to be the independent,
# klt-free second opinion that makes exactly this drift legible.
#
# Method: copy the COMMITTED tree (git archive HEAD) into a mktemp dir,
# trap-cleaned, and tamper only inside the copy -- the real tree is never
# touched and is asserted clean at the end. Legs:
#   * positive control: untouched copy -> exit 0, "pin verification clean"
#   * per member of item 1's paths: tamper -> exit nonzero, output names it
#   * all members tampered at once -> every one named
#   * a member deleted (not modified) -> named failure, no traceback
#   * a bare-string member path -> resolved like the single-input branch
#     resolves one (no TypeError), hashes still match
# Needs python3 and git only: no klt, no PDK, no network (the same contract
# verify-pins.sh itself declares). Exit nonzero on any mismatch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_REL="signoff/item-1-design-sources.json"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pristine"
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$T/pristine"
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

mapfile -t MEMBERS < <(python3 - "$T/pristine/$ENV_REL" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))
for e in env["provenance"]["input"]["paths"]:
    p = e["path"]
    print(p["path"] if isinstance(p, dict) else p)
PY
)
[[ "${#MEMBERS[@]}" -ge 2 ]] || { echo "error: no multi-input members found in $ENV_REL" >&2; exit 1; }

# ---- positive control ----
expect_clean "untouched copy passes clean"

# ---- per-member tamper: every member of the input set is checked ----
for m in "${MEMBERS[@]}"; do
    printf '\n// drift probe (issue 281 regression)\n' >> "$T/repo/$m"
    expect_drift "tampered $m" "$m"
    cp "$T/pristine/$m" "$T/repo/$m"
done
expect_clean "tree restored after per-member legs"

# ---- all members tampered at once: every one named, not just the first ----
for m in "${MEMBERS[@]}"; do printf '\n// drift probe\n' >> "$T/repo/$m"; done
if run_pins; then bad "all-members tamper: verify-pins exited 0"
else
    missed=0
    for m in "${MEMBERS[@]}"; do grep -qF -- "$m" "$T/out" || { bad "all-members tamper: $m not named"; missed=1; }; done
    [[ "$missed" -eq 0 ]] && ok "all ${#MEMBERS[@]} members tampered -> every one named"
fi

# ---- deleted member: named failure, not a FileNotFoundError traceback ----
fresh_copy
rm "$T/repo/${MEMBERS[0]}"
if run_pins; then bad "deleted member: verify-pins exited 0"
elif grep -q "Traceback" "$T/out"; then bad "deleted member: crashed with a traceback"
elif ! grep -qF -- "${MEMBERS[0]}" "$T/out"; then bad "deleted member: ${MEMBERS[0]} not named"
else ok "deleted member -> named failure, no traceback"; fi

# ---- bare-string member path: resolved like the single-input branch resolves
#      one (beside the envelope), no TypeError; hashes unchanged so still clean ----
fresh_copy
python3 - "$T/repo/$ENV_REL" <<'PY'
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

# ---- the real tree was never touched ----
dirty="$(git -C "$REPO_ROOT" status --porcelain -- \
    design/ signoff/item-1-inventory.json signoff/tier-report.json \
    signoff/block-manifest.json "$ENV_REL")"
[[ -z "$dirty" ]] || bad "real tree mutated by the test: $dirty"

if [[ "$rc_all" -ne 0 ]]; then echo "test_verify_pins: FAIL"; exit 1; fi
echo "test_verify_pins: PASS"
