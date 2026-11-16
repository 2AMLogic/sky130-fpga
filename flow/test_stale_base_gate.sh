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
#   2. the #307 shape: the run-time merge conflicts INSIDE an inventory JSON
#      (conflict markers make it unparseable). The guard step's whole run
#      block is extracted from the working-tree workflow and replayed in a
#      scratch repo whose main and branch both edit the inventory: it must
#      still print the conflicted-path listing, still emit the remedy line,
#      still report the unparseable inventory instead of dying on it, and
#      still exit 1.
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

# The real tree must not be touched by anything below. leg 0 reads the
# working-tree workflow, which legitimately carries uncommitted WIP in a
# pre-commit run, so the assertion is "no further mutation": snapshot the
# dirtiness up front -- BEFORE any work -- and compare against a fresh
# snapshot at the end. Porcelain alone is file-level, so appending to a
# file that is already dirty would be invisible; the `git diff HEAD` text
# makes the snapshot hunk-level, and porcelain contributes untracked
# paths. Snapshotting only at the end (and comparing it to itself) would
# make the guard a tautology that can never fail.
tree_state() {
    git -C "$REPO_ROOT" status --porcelain -- signoff/ "$P" "$WORKFLOW"
    git -C "$REPO_ROOT" diff HEAD -- signoff/ "$P" "$WORKFLOW"
}
dirty_before="$(tree_state)"

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
# Every needle below is anchored to the whole YAML/shell line (leading
# indentation, then the wiring, nothing else): the guard step's error prose
# and comments quote several of these strings, so an unanchored grep matches
# the echo text and the assertion survives deletion of the very wiring it
# pins -- the blocking defect the previous review round demonstrated.
merge_line="$(grep -nE '^[[:space:]]*if ! git merge FETCH_HEAD --no-edit' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
gate_line="$(grep -nE '^[[:space:]]*- name: Verify every manifest pin' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
if grep -qE "^[[:space:]]*if: github.event_name == 'pull_request'[[:space:]]*$" "$REPO_ROOT/$WORKFLOW" \
    && grep -qE '^[[:space:]]+git fetch origin main[[:space:]]*$' "$REPO_ROOT/$WORKFLOW" \
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
checkout_line="$(grep -nE '^[[:space:]]+uses: actions/checkout@v4[[:space:]]*$' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
depth_line="$(grep -nE '^[[:space:]]+fetch-depth: 0[[:space:]]*$' "$REPO_ROOT/$WORKFLOW" 2>/dev/null | head -1 | cut -d: -f1)"
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

# ---- leg 2 (issue #307): a conflict INSIDE an inventory JSON must not kill
#      the guard's diagnosis ----
# Replay the guard step's whole run block (extracted from the working-tree
# workflow, like leg 0 reads it) in a scratch repo where main and the branch
# BOTH edit signoff/item-9-inventory.json. git leaves conflict markers in it,
# so the guard's per-inventory json.load hits unparseable JSON; the block
# must still print the conflicted-path listing (with the unparseable one
# named), still emit the remedy line, and still exit 1. A second conflicted
# file pinned by item 10 (whose inventory parses fine) proves the other
# inventories are still mapped in the same degraded run.
GUARD_RUN="$T/guard-run.sh"
# Extract the run block: from the guard step's `run: |` to the first line
# dedented below the block-scalar content indentation, with that indentation
# stripped -- i.e. exactly the script the CI runner would execute.
awk '
  BEGIN { in_step = 0; in_run = 0; ci = -1 }
  !in_step && /^      - name: Base-freshness guard/ { in_step = 1; next }
  in_step && !in_run && /^        run: \|/ { in_run = 1; next }
  in_run {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      n = match($0, /[^ ]/) - 1
      if (ci == -1) ci = n
      if (n < ci) exit
      print substr($0, ci + 1)
  }
' "$REPO_ROOT/$WORKFLOW" > "$GUARD_RUN"
if [[ ! -s "$GUARD_RUN" ]]; then
    bad "leg2: could not extract the guard run block from $WORKFLOW"
elif ! grep -q "^set -euo pipefail$" "$GUARD_RUN" \
    || ! grep -q "^if ! git merge FETCH_HEAD --no-edit" "$GUARD_RUN"; then
    bad "leg2: extracted run block is not the guard script (missing set/merge lines)"
else
    cp -a "$T/pristine" "$T/repo2"
    cp "$REPO_ROOT/signoff/verify-pins.sh" "$T/repo2/signoff/verify-pins.sh"
    git -C "$T/repo2" init -q -b main
    git -C "$T/repo2" config user.email "stale-base-gate@test.invalid"
    git -C "$T/repo2" config user.name "stale-base-gate"
    git -C "$T/repo2" add -A
    git -C "$T/repo2" commit -qm "base: archive of the committed tree"

    # branch side: a valid-but-different edit to the inventory, plus an edit
    # to a workflow file item 10 pins
    git -C "$T/repo2" checkout -qb pr-conflicts-inventory
    python3 - "$T/repo2" <<'PY'
import json, sys
p = f"{sys.argv[1]}/signoff/item-9-inventory.json"
inv = json.load(open(p))
inv["testbenches"].append("sim/leg2_branch_probe.v")
inv["testbenches"].sort()
json.dump(inv, open(p, "w"), indent=1)
PY
    printf '\n# leg2 branch-side edit\n' >> "$T/repo2/.github/workflows/gate-sim.yml"
    git -C "$T/repo2" add -A
    git -C "$T/repo2" commit -qm "branch: edit the item-9 inventory and an item-10-pinned workflow"

    # main side: overlapping edits to the same two files -> textual conflict
    git -C "$T/repo2" checkout -q main
    python3 - "$T/repo2" <<'PY'
import json, sys
p = f"{sys.argv[1]}/signoff/item-9-inventory.json"
inv = json.load(open(p))
inv["testbenches"].append("sim/leg2_main_probe.v")
inv["testbenches"].sort()
json.dump(inv, open(p, "w"), indent=1)
PY
    printf '\n# leg2 main-side edit\n' >> "$T/repo2/.github/workflows/gate-sim.yml"
    git -C "$T/repo2" add -A
    git -C "$T/repo2" commit -qm "main: conflicting edits to the same files"

    git clone --bare -q "$T/repo2" "$T/origin.git"
    git -C "$T/repo2" remote add origin "$T/origin.git"
    git -C "$T/repo2" checkout -q pr-conflicts-inventory
    git -C "$T/repo2" fetch -q origin main
    # sanity: the conflict really is textual and really lands in the inventory
    git -C "$T/repo2" merge FETCH_HEAD --no-edit >"$T/leg2merge" 2>&1
    git -C "$T/repo2" diff --name-only --diff-filter=U > "$T/leg2conflicted"
    if ! grep -qF "signoff/item-9-inventory.json" "$T/leg2conflicted"; then
        bad "leg2 setup: the merge did not conflict in the inventory -- scenario broken"
        sed -n '1,10p' "$T/leg2merge"
    else
        git -C "$T/repo2" merge --abort 2>/dev/null
        git -C "$T/repo2" reset -q --hard
        # replay the guard block: it re-merges FETCH_HEAD itself, hits the
        # conflict, and must degrade gracefully instead of dying in json.load
        (cd "$T/repo2" && bash "$GUARD_RUN") > "$T/leg2out" 2>&1
        rc_guard=$?
        if [[ "$rc_guard" -ne 1 ]]; then
            bad "leg2: guard block exited $rc_guard on a conflicting-inventory merge (expected 1)"
        fi
        if ! grep -q "^remedy: git fetch origin main && git rebase origin/main" "$T/leg2out"; then
            bad "leg2: remedy line missing -- the diagnosis died before it (issue #307)"
            tail -20 "$T/leg2out"
        fi
        if ! grep -qF "signoff/item-9-inventory.json -> is an inventory that could not be parsed (conflict markers?)" "$T/leg2out"; then
            bad "leg2: the unparseable inventory was not reported as parse-degraded"
            tail -20 "$T/leg2out"
        fi
        if ! grep -qF ".github/workflows/gate-sim.yml -> pinned by signoff/item-10-inventory.json" "$T/leg2out"; then
            bad "leg2: the item-10-pinned conflict was not mapped (other inventories must still work)"
            tail -20 "$T/leg2out"
        fi
        if [[ "$rc_guard" -eq 1 ]] \
            && grep -q "^remedy: git fetch origin main && git rebase origin/main" "$T/leg2out" \
            && grep -qF "signoff/item-9-inventory.json -> is an inventory that could not be parsed (conflict markers?)" "$T/leg2out" \
            && grep -qF ".github/workflows/gate-sim.yml -> pinned by signoff/item-10-inventory.json" "$T/leg2out"; then
            ok "leg2: conflict inside an inventory -- listing, degraded-mapping note, remedy and exit 1 all survive"
        fi
    fi
fi

# ---- the real tree was never touched: tree_state was snapshotted before
#      any work (leg 0 reads the working-tree workflow, which legitimately
#      carries uncommitted WIP in a pre-commit run, so compare before vs.
#      after, not to zero) ----
dirty_after="$(tree_state)"
[[ "$dirty_before" == "$dirty_after" ]] || bad "real tree mutated by the test: $(diff <(echo "$dirty_before") <(echo "$dirty_after"))"

if [[ "$rc_all" -ne 0 ]]; then echo "test_stale_base_gate: FAIL"; exit 1; fi
echo "test_stale_base_gate: PASS"
