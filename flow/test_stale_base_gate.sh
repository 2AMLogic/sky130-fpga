#!/usr/bin/env bash
# flow/test_stale_base_gate.sh (issue #304): regression for the signoff gate's
# base-freshness guard.
#
# The gate enforces a CROSS-FILE invariant: a content_hash recorded in
# signoff/item-N-*.json pins the live bytes of an inventoried file elsewhere
# in the tree. Two PRs with disjoint file sets can therefore break the gate
# together while each is individually correct and individually green
# (#297/#298): one edits an inventoried file, the other adds that same file
# to an inventory pinned at its pre-edit hash, git merges them cleanly (no
# textual conflict), and the stale pairing first exists -- and first fails --
# at the merge commit on main.
#
# Nothing in a single PR's own tree can see that failure, which is why the
# gate must be evaluated against the PR merged with the CURRENT origin/main
# tip (the workflow-side guard this test also pins down, below).
#
# Legs:
#   0. workflow wiring: .github/workflows/signoff.yml (read from the WORKING
#      TREE, like test_verify_pins.sh reads verify-pins.sh) still fetches and
#      merges origin/main on pull_request runs, and still runs the pin gate
#      after that merge. Removing the guard fails this test.
#   1. the #297/#298 shape, end to end, with signoff/verify-pins.sh as the
#      oracle (python3+git, no klt/PDK/network): a base where the file is not
#      yet pinned, a branch that edits only the file, a branch that adds only
#      the pin at the pre-edit hash -- each passes alone; the clean git merge
#      of the two FAILS, naming the inventoried path and its item number.
#
# Method: copy the COMMITTED tree (git archive HEAD) into a mktemp git repo,
# trap-cleaned; every commit happens inside the copy -- the real tree is
# never touched and is asserted clean at the end. Needs python3 and git only.
# Exit nonzero on any mismatch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW=".github/workflows/signoff.yml"
P="sim/sdf_port_interconnect/test_pdk_gate.sh"
ENV9="signoff/item-9-testbenches.json"
INV9="signoff/item-9-inventory.json"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pristine"
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$T/pristine"
# The pin checker under test comes from the WORKING TREE (same reasoning as
# test_verify_pins.sh: a pre-commit run must exercise the current checker);
# the workflow file is likewise read from the working tree in leg 0.
cp "$REPO_ROOT/signoff/verify-pins.sh" "$T/pristine/signoff/verify-pins.sh"
cp -a "$T/pristine" "$T/repo"

rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }
run_pins() { (cd "$T/repo" && ./signoff/verify-pins.sh) >"$T/out" 2>&1; }

# ---- leg 0: the workflow still wires the base-freshness guard (this leg
#      fails if the #304 guard step is removed from signoff.yml, or if the
#      checkout loses the full history that merge needs) ----
if [[ -f "$REPO_ROOT/$WORKFLOW" ]]; then
    wf="$(cat "$REPO_ROOT/$WORKFLOW")"
else
    wf=""
fi
merge_line="$(grep -n 'git merge origin/main --no-edit' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'name: Verify every manifest pin' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
if grep -Fq "github.event_name == 'pull_request'" "$REPO_ROOT/$WORKFLOW" \
    && grep -Fq "git fetch origin main" "$REPO_ROOT/$WORKFLOW" \
    && [[ -n "$merge_line" ]]; then
    ok "leg0: signoff.yml fetches and merges the live origin/main tip on pull_request runs"
else
    bad "leg0: signoff.yml lost the base-freshness guard (pull_request-conditioned fetch+merge of origin/main)"
fi
if [[ -n "$merge_line" && -n "$gate_line" && "$merge_line" -lt "$gate_line" ]]; then
    ok "leg0: the pin gate runs after the run-time merge (it judges the merged tree)"
else
    bad "leg0: the pin gate does not run after the origin/main merge in signoff.yml"
fi
checkout_line="$(grep -n 'uses: actions/checkout@v4' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
depth_line="$(grep -n 'fetch-depth: 0' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ -n "$checkout_line" && -n "$depth_line" && "$depth_line" -gt "$checkout_line" ]]; then
    ok "leg0: the checkout is full-history (fetch-depth: 0) so the run-time merge has a shared ancestor"
else
    bad "leg0: signoff.yml's checkout lost fetch-depth: 0 -- the guard's origin/main merge dies with 'unrelated histories' under the default depth-1 clone"
fi

# ---- leg 1: the #297/#298 semantic-conflict shape, verified against
#      verify-pins.sh as the oracle ----
git -C "$T/repo" init -q -b main
git -C "$T/repo" config user.email "stale-base-gate@test.invalid"
git -C "$T/repo" config user.name "stale-base-gate"
git -C "$T/repo" add -A
git -C "$T/repo" commit -qm "base: archive of the committed tree"

# Setup commit: rewind item 9 to its pre-#298 state -- test_pdk_gate.sh not
# yet an attestation member -- so the legs below can replay exactly what the
# two PRs did. The envelope's checks entry, counts, provenance.input pin (the
# inventory's hash) and the manifest's item-9 pin must all move together, or
# the base itself is already red and the legs prove nothing.
pre_edit_sha() { "sha256:$("$HASH_BIN" "$T/repo/$P" | cut -d" " -f1)"; }
HASH_BIN="sha256sum"
if ! command -v sha256sum >/dev/null; then HASH_BIN="shasum -a 256"; fi
python3 - "$T/repo" "$P" <<'PY'
import hashlib, json, sys
repo, p = sys.argv[1], sys.argv[2]
def sha(rel):
    return "sha256:" + hashlib.sha256(open(f"{repo}/{rel}", "rb").read()).hexdigest()
inv_p = f"{repo}/signoff/item-9-inventory.json"
env_p = f"{repo}/signoff/item-9-testbenches.json"
man_p = f"{repo}/signoff/block-manifest.json"
inv = json.load(open(inv_p))
inv["testbenches"].remove(p)
inv["testbenches"].sort()
json.dump(inv, open(inv_p, "w"), indent=1)
env = json.load(open(env_p))
entry = next(c for c in env["attestation"]["checks"] if c.get("path") == p)
env["attestation"]["checks"].remove(entry)
att = env["attestation"]
att["check_count"] -= 1
att["passed_count"] -= 1
env["summary"] = (f"T1 item 9 (Testbenches shipped): {att['passed_count']}/"
                  f"{att['check_count']} attestation checks passed (klt signoff --attest)")
env["provenance"]["input"]["content_hash"] = sha("signoff/item-9-inventory.json")
json.dump(env, open(env_p, "w"), indent=1)
man = json.load(open(man_p))
man["evidence"]["9"]["content_hash"] = env["provenance"]["input"]["content_hash"]
json.dump(man, open(man_p, "w"), indent=1)
PY
if run_pins && grep -q "pin verification clean" "$T/out"; then
    ok "leg1 base (pre-#298 state, pin chain rewound consistently): verify-pins clean"
else
    bad "leg1 base: verify-pins not clean after rewinding item 9"; sed -n '1,20p' "$T/out"
fi
git -C "$T/repo" add -A
git -C "$T/repo" commit -qm "setup: drop test_pdk_gate.sh from item 9 (pre-#298 state)"
BASE="$(git -C "$T/repo" rev-parse HEAD)"

# Branch X (#297 shape): edit ONLY the inventoried file. No envelope names it
# on this branch, so the gate passes -- exactly why #297's own CI was green.
git -C "$T/repo" checkout -qb pr-edits-the-file
printf '\n# drift probe\n' >> "$T/repo/$P"
git -C "$T/repo" add -A
git -C "$T/repo" commit -qm "edit the inventoried harness (disjoint file set: the file only)"
if run_pins && grep -q "pin verification clean" "$T/out"; then
    ok "leg1 branch X (edits the file, pins nothing): gate passes alone"
else
    bad "leg1 branch X: gate should pass on this branch alone"; sed -n '1,20p' "$T/out"
fi

# Branch Y (#298 shape): add ONLY the pin -- the same file, at its PRE-EDIT
# hash (the bytes as they are on this branch's base). Disjoint from X's file
# set, so its own CI was green too.
git -C "$T/repo" checkout -qb pr-pins-the-file "$BASE"
python3 - "$T/repo" "$P" <<'PY'
import hashlib, json, sys
repo, p = sys.argv[1], sys.argv[2]
def sha(rel):
    return "sha256:" + hashlib.sha256(open(f"{repo}/{rel}", "rb").read()).hexdigest()
inv_p = f"{repo}/signoff/item-9-inventory.json"
env_p = f"{repo}/signoff/item-9-testbenches.json"
man_p = f"{repo}/signoff/block-manifest.json"
pre_edit = sha(p)   # bytes as they exist on this branch: the pre-edit hash
inv = json.load(open(inv_p))
inv["testbenches"].append(p)
inv["testbenches"].sort()
json.dump(inv, open(inv_p, "w"), indent=1)
env = json.load(open(env_p))
env["attestation"]["checks"].append({
    "check": "present", "role": "testbench", "path": p,
    "passed": True, "content_hash": pre_edit,
})
att = env["attestation"]
att["check_count"] += 1
att["passed_count"] += 1
env["summary"] = (f"T1 item 9 (Testbenches shipped): {att['passed_count']}/"
                  f"{att['check_count']} attestation checks passed (klt signoff --attest)")
env["provenance"]["input"]["content_hash"] = sha("signoff/item-9-inventory.json")
json.dump(env, open(env_p, "w"), indent=1)
man = json.load(open(man_p))
man["evidence"]["9"]["content_hash"] = env["provenance"]["input"]["content_hash"]
json.dump(man, open(man_p, "w"), indent=1)
PY
git -C "$T/repo" add -A
git -C "$T/repo" commit -qm "pin the harness into item 9 at its current (pre-edit) hash (disjoint file set: signoff/ only)"
if run_pins && grep -q "pin verification clean" "$T/out"; then
    ok "leg1 branch Y (pins the file at its pre-edit hash): gate passes alone"
else
    bad "leg1 branch Y: gate should pass on this branch alone"; sed -n '1,20p' "$T/out"
fi

# The merge: disjoint file sets, so git MUST merge cleanly -- assert that, or
# the scenario is not the incident shape (a textual conflict would be caught
# by git itself and prove nothing about the gate).
if merge_out="$(git -C "$T/repo" merge pr-edits-the-file --no-edit 2>&1)"; then
    if grep -q CONFLICT <<<"$merge_out"; then
        bad "leg1 merge: reported a conflict -- the file sets are not disjoint, scenario broken"
    else
        ok "leg1 merge: clean merge of the disjoint file sets (no textual conflict)"
    fi
else
    bad "leg1 merge: git merge failed -- scenario broken"; echo "$merge_out" | sed -n '1,10p'
fi

# The teeth: the gate fails on the merged tree -- where the new bytes and the
# old pin meet for the first time -- and names the inventoried path and item.
if run_pins; then
    bad "leg1 merged tree: verify-pins exited 0 -- the gate cannot see the #297/#298 shape"
else
    if grep -qF -- "$P" "$T/out" \
        && grep -qE "item-9 attestation pin for $P == live bytes" "$T/out"; then
        ok "leg1 merged tree: gate FAILS, naming the inventoried path and its item number"
    else
        bad "leg1 merged tree: gate failed but did not name $P / item 9"; grep -m5 FAIL "$T/out"
    fi
fi

# ---- the real tree was never touched (no further mutation: leg 0 reads the
#      working-tree workflow, which legitimately carries uncommitted WIP in a
#      pre-commit run, so compare dirtiness before vs. after, not to zero) ----
dirty_before="$(git -C "$REPO_ROOT" status --porcelain -- signoff/ "$P" "$WORKFLOW")"
dirty_after="$(git -C "$REPO_ROOT" status --porcelain -- signoff/ "$P" "$WORKFLOW")"
[[ "$dirty_before" == "$dirty_after" ]] || bad "real tree mutated by the test: $(diff <(echo "$dirty_before") <(echo "$dirty_after"))"

if [[ "$rc_all" -ne 0 ]]; then echo "test_stale_base_gate: FAIL"; exit 1; fi
echo "test_stale_base_gate: PASS"
