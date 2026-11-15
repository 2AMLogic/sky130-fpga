#!/usr/bin/env bash
# sim/sdf_port_interconnect/test_pdk_gate.sh (issue #269)
#
# Hermetic regression for run.sh's PDK-model resolution gate -- in particular
# the relaxed half added for CI: after the four path-pinned candidates miss,
# a flat-layout model directory (<root>/sky130A/libs.ref/sky130_fd_sc_hd/
# verilog) is accepted only when BOTH sky130_fd_sc_hd.v and primitives.v
# sha256-match flow/tool_versions.sh's recorded values.
#
# What this script can prove hermetically is the refusal direction: a
# wrong-hash flat directory (or a half-matching one, or no models at all)
# must FAIL the run with the named pinned-revision error -- never a warning
# and never a substitution -- while the path-pinned candidates keep working
# exactly as before. The acceptance direction (a hash-matching flat
# directory is accepted and the full fixture then passes) cannot be faked
# here -- fabricating files that hash to the recorded values is the one
# thing sha256 prevents -- so it is exercised end-to-end by the gate-sim
# workflow step that runs the fixture against the fetched ciel models.
#
# Needs no iverilog and no PDK: a stub simulator pair is put on PATH via
# ICARUS13_BIN_DIR so run.sh's Icarus leg passes and the PDK leg is what is
# under test. Runs serially; finishes in seconds.
#
# Exit status: 0 iff every check passes; non-zero on any mismatch.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

source "$REPO/flow/tool_versions.sh"

# Stub simulators: -V reports 13.0 so resolve_icarus13() accepts the stub;
# a real compile/vvp invocation succeeds silently (the tests below assert on
# the PDK-resolution behaviour, which happens before either matters).
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nif [[ "$1" == "-V" ]]; then echo "Icarus Verilog version 13.0 (stable) (v13_0)"; fi\nexit 0\n' >"$T/bin/iverilog"
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/vvp"
chmod +x "$T/bin/iverilog" "$T/bin/vvp"

FAKE_HOME="$T/fakehome"
mkdir -p "$FAKE_HOME"

# mk_flat <dir> <models-bytes> <primitives-bytes>: lay out a flat ciel model
# directory with the given file contents (their sha256 is therefore under
# the test's control).
mk_flat() {
    local d="$1/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
    mkdir -p "$d"
    printf '%s' "$2" >"$d/sky130_fd_sc_hd.v"
    printf '%s' "$3" >"$d/primitives.v"
}

# run_fixture: run.sh under the hermetic environment; stdout/stderr in
# $T/out / $T/err, status in $RC.
run_fixture() {
    RC=0
    ( cd "$REPO" \
      && HOME="$FAKE_HOME" ICARUS13_BIN_DIR="$T/bin" \
         env ${PDK_ROOT:+PDK_ROOT="$PDK_ROOT"} \
         ./sim/sdf_port_interconnect/run.sh ) \
      >"$T/out" 2>"$T/err" || RC=$?
}

REFUSAL="error: the pinned sky130A revision was not found."

# ---- 1. wrong-hash flat directory: must refuse, naming the mismatch -------
WRONG_ROOT="$T/wrong-hash"
mk_flat "$WRONG_ROOT" "not the real cell models" "not the real primitives"
# sanity: the fabricated bytes must genuinely differ from the recorded hashes
if [[ "$(sha256sum "$WRONG_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v" | awk '{print $1}')" \
      == "$RECORDED_PDK_MODELS_SHA256" ]]; then
    bad "test bug: fabricated models hash to the recorded value"
fi

PDK_ROOT="$WRONG_ROOT" run_fixture
if [[ $RC -ne 0 ]]; then ok "wrong-hash flat dir refused (rc=$RC)"; else bad "wrong-hash flat dir ACCEPTED"; fi
if grep -qF "$REFUSAL" "$T/err"; then
    ok "wrong-hash refusal is the named pinned-revision error"
else
    bad "wrong-hash refusal missing the named error (fail, not warn)"
fi
if grep -q "refused on hash mismatch" "$T/err"; then
    ok "refusal names the refused directory"
else
    bad "refusal does not name the refused directory"
fi
if grep -q "cell models" "$T/out"; then
    bad "run proceeded past resolution despite the hash mismatch"
else
    ok "no simulation ran past the refused resolution"
fi

# ---- 2. half-matching flat dir (models match, primitives wrong): refuse ----
HALF_ROOT="$T/half-hash"
mk_flat "$HALF_ROOT" "not the real cell models" "not the real primitives either"
PDK_ROOT="$HALF_ROOT" run_fixture
if [[ $RC -ne 0 && "$(grep -cF "$REFUSAL" "$T/err")" -eq 1 ]]; then
    ok "half-matching flat dir (one file off) refused"
else
    bad "half-matching flat dir not refused cleanly (rc=$RC)"
fi

# ---- 3. PDK_ROOT set but holds no models: the named refusal, not a crash ---
EMPTY_ROOT="$T/empty"
mkdir -p "$EMPTY_ROOT"
PDK_ROOT="$EMPTY_ROOT" run_fixture
if [[ $RC -ne 0 && "$(grep -cF "$REFUSAL" "$T/err")" -eq 1 ]]; then
    ok "empty PDK_ROOT refused with the named error"
else
    bad "empty PDK_ROOT not refused with the named error (rc=$RC)"
fi

# ---- 4. PDK_ROOT unset entirely: still the named error --------------------
unset PDK_ROOT
run_fixture
if [[ $RC -ne 0 && "$(grep -cF "$REFUSAL" "$T/err")" -eq 1 ]]; then
    ok "unset PDK_ROOT refused with the named error"
else
    bad "unset PDK_ROOT not refused with the named error (rc=$RC)"
fi

# ---- 5. path-pinned candidates are unchanged: accepted WITHOUT hashes -----
# A versions/<PDK_SHA>/ tree whose model files are deliberately wrong must
# still resolve (the path encodes the revision); run.sh then proceeds past
# resolution (and fails later on the stub-simulator transcripts, which is
# expected here). The assertions are: the banner names the pinned path, and
# the refusal never fires.
PINNED_ROOT="$T/pinned"
d="$PINNED_ROOT/sky130/versions/${RECORDED_PDK_VERSION##* }/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mkdir -p "$d"
printf 'wrong bytes, but the path is pinned\n' >"$d/sky130_fd_sc_hd.v"
printf 'wrong bytes, but the path is pinned\n' >"$d/primitives.v"
PDK_ROOT="$PINNED_ROOT" run_fixture
if grep -qF "cell models      : $d" "$T/out"; then
    ok "path-pinned candidate accepted without a hash check (unchanged)"
else
    bad "path-pinned candidate no longer resolves from its path"
fi
if grep -qF "$REFUSAL" "$T/err"; then
    bad "path-pinned candidate was refused"
else
    ok "path-pinned candidate not refused"
fi

# ---- 6. strict-refusal text still documents how to satisfy the gate -------
PDK_ROOT="$EMPTY_ROOT" run_fixture
if grep -q "hash-matching flat" "$T/err"; then
    ok "refusal text mentions the hash-matching flat-layout option"
else
    bad "refusal text no longer mentions the hash-matching flat-layout option"
fi

if [[ $rc_all -eq 0 ]]; then
    echo "PASS: test_pdk_gate"
else
    echo "FAIL: test_pdk_gate"
fi
exit "$rc_all"
