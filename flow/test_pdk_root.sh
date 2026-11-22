#!/usr/bin/env bash
# flow/test_pdk_root.sh (issue #375)
#
# Hermetic regression for flow/pdk_root.sh's sky130_fd_sc_hd cell-model
# resolution helpers -- the two functions that replaced the four hand-copied
# lookup blocks across the gate-level simulation drivers:
#
#   - sky130_cell_models_from_klt: <libs_ref>/sky130_fd_sc_hd/verilog from
#     `klt pdk find`'s assets.libs_ref (empty when klt is absent or fails);
#   - resolve_sky130_cell_models: klt libs_ref, then $PDK_ROOT, then
#     ~/.volare, requiring BOTH sky130_fd_sc_hd.v and primitives.v, failing
#     loudly otherwise.
#
# What is pinned here, per the two defects issue #375 fixed:
#
#   1. the klt fallback must append sky130_fd_sc_hd/verilog to libs_ref --
#      the pre-#375 flow/tile-functional-verification.sh block queried the
#      find result's bare root, where the models never live, so the
#      documented fallback never matched (dead candidate);
#   2. a partial directory holding only sky130_fd_sc_hd.v must be SKIPPED,
#      not accepted -- the pre-#375 flow/gate-sim-routed.sh copy omitted the
#      primitives.v guard even though it passes "$CELL_DIR/primitives.v" to
#      iverilog, delaying the failure to compile time;
#   3. the failure path must be a nonzero exit plus the shared diagnostic,
#      never a silent empty resolution.
#
# Hermetic: a stub `klt` on PATH answers `pdk find` with scratch JSON, HOME
# is redirected at a scratch tree, and PDK_ROOT is unset or pointed at
# scratch. Needs bash and python3 only; no PDK install, no iverilog.
#
# Exit status: 0 iff every check passes; non-zero on any mismatch.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=flow/pdk_root.sh
source "$HERE/pdk_root.sh"

rc_all=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc_all=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAKE_HOME="$T/home"
mkdir -p "$FAKE_HOME"

# mk_models <dir> <models|-> <primitives|-> : lay out a candidate directory
# (<dir>/sky130_fd_sc_hd.v etc.); '-' leaves the file out (partial dir).
mk_models() {
    local d="$1"
    mkdir -p "$d"
    [[ "$2" == "-" ]] || printf '%s' "cell models $2" >"$d/sky130_fd_sc_hd.v"
    [[ "$3" == "-" ]] || printf '%s' "primitives $3" >"$d/primitives.v"
}

# stub_klt <libs_ref|-|fail>: put a stub klt on $T/bin's PATH answering
# `pdk find` with the given libs_ref ('fail': exit 1, like an unresolvable
# PDK). The JSON it answers with lives in $T/klt-json, so the stub itself
# stays quote-free. $T/bin is also used klt-absent (empty) via run_helper.
stub_klt() {
    mkdir -p "$T/bin"
    if [[ "$1" == "fail" ]]; then
        cat >"$T/bin/klt" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    else
        printf '{"root": "%s", "assets": {"libs_ref": "%s"}}\n' \
            "$T/klt-root" "$1" >"$T/klt-json"
        cat >"$T/bin/klt" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_KLT_JSON_FILE"
EOF
    fi
    chmod +x "$T/bin/klt"
}

# run helper under a controlled environment: PATH (klt stub or none), HOME,
# PDK_ROOT unset or set. Prints what the helper printed; rc in RRC.
run_helper() {
    local fn="$1" path_dir="$2" pdk_root="$3"
    RRC=0
    ( PATH="$path_dir:$PATH" HOME="$FAKE_HOME" STUB_KLT_JSON_FILE="$T/klt-json" \
        env ${pdk_root:+PDK_ROOT="$pdk_root"} \
        bash -c "source '$HERE/pdk_root.sh'; $fn" ) >"$T/out" 2>"$T/err" || RRC=$?
}

NO_KLT_DIR="$T/klt-absent"
mkdir -p "$NO_KLT_DIR"

# ---- 1. sky130_cell_models_from_klt: libs_ref + verilog appended ---------
V="$T/klt-root/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$V" a b
stub_klt "$T/klt-root/sky130A/libs.ref"
run_helper "sky130_cell_models_from_klt" "$T/bin" "-"
if [[ "$RRC" -eq 0 && "$(cat "$T/out")" == "$V" ]]; then
    ok "from_klt resolves <libs_ref>/sky130_fd_sc_hd/verilog with PDK_ROOT unset"
else
    bad "from_klt did not resolve the verilog dir (rc=$RRC, out='$(cat "$T/out")')"
fi

# ---- 2. sky130_cell_models_from_klt: absent klt -> empty, rc 0 -----------
run_helper "sky130_cell_models_from_klt" "$NO_KLT_DIR" "-"
if [[ "$RRC" -eq 0 && -z "$(cat "$T/out")" ]]; then
    ok "from_klt is empty and clean with klt absent"
else
    bad "from_klt not clean with klt absent (rc=$RRC, out='$(cat "$T/out")', err='$(cat "$T/err")')"
fi

# ---- 3. sky130_cell_models_from_klt: failing klt -> empty, rc 0 ----------
stub_klt fail
run_helper "sky130_cell_models_from_klt" "$T/bin" "-"
if [[ "$RRC" -eq 0 && -z "$(cat "$T/out")" ]]; then
    ok "from_klt is empty and clean when klt pdk find fails"
else
    bad "from_klt not clean on klt failure (rc=$RRC, out='$(cat "$T/out")')"
fi

# ---- 4. resolve: partial klt dir (no primitives.v) falls through ---------
# The gate-sim-routed.sh defect: a sky130_fd_sc_hd.v-only directory must be
# skipped, not accepted.
VK="$T/klt-partial/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$VK" a -
stub_klt "$T/klt-partial/sky130A/libs.ref"
VP="$T/pdk-full/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$VP" b c
run_helper "resolve_sky130_cell_models" "$T/bin" "$T/pdk-full"
if [[ "$RRC" -eq 0 && "$(cat "$T/out")" == "$VP" ]]; then
    ok "resolve skips the primitives.v-less klt dir, falls through to PDK_ROOT"
else
    bad "resolve accepted or mishandled the partial klt dir (rc=$RRC, out='$(cat "$T/out")')"
fi

# ---- 5. resolve: partial PDK_ROOT dir falls through to ~/.volare ---------
stub_klt fail
PP="$T/pdk-partial/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$PP" d -
VH="$FAKE_HOME/.volare/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$VH" e f
run_helper "resolve_sky130_cell_models" "$T/bin" "$T/pdk-partial"
if [[ "$RRC" -eq 0 && "$(cat "$T/out")" == "$VH" ]]; then
    ok "resolve skips the primitives.v-less PDK_ROOT dir, falls through to ~/.volare"
else
    bad "resolve accepted or mishandled the partial PDK_ROOT dir (rc=$RRC, out='$(cat "$T/out")')"
fi

# ---- 6. resolve: full klt candidate wins over a full PDK_ROOT ------------
VF="$T/klt-full/sky130A/libs.ref/sky130_fd_sc_hd/verilog"
mk_models "$VF" g h
stub_klt "$T/klt-full/sky130A/libs.ref"
run_helper "resolve_sky130_cell_models" "$T/bin" "$T/pdk-full"
if [[ "$RRC" -eq 0 && "$(cat "$T/out")" == "$VF" ]]; then
    ok "resolve keeps the klt-first precedence over PDK_ROOT"
else
    bad "resolve lost the klt-first precedence (rc=$RRC, out='$(cat "$T/out")')"
fi

# ---- 7. resolve: no candidate holds both files -> rc 1 + diagnostic ------
stub_klt fail
rm -rf "$FAKE_HOME/.volare"
run_helper "resolve_sky130_cell_models" "$T/bin" "$T/pdk-partial"
DIAG="error: could not resolve sky130_fd_sc_hd Verilog cell models (set PDK_ROOT)"
if [[ "$RRC" -ne 0 && -z "$(cat "$T/out")" && "$(grep -cF "$DIAG" "$T/err")" -eq 1 ]]; then
    ok "resolve fails nonzero with exactly the shared diagnostic when nothing matches"
else
    bad "resolve failure path wrong (rc=$RRC, out='$(cat "$T/out")', err='$(cat "$T/err")')"
fi

if [[ "$rc_all" -ne 0 ]]; then echo "test_pdk_root: FAIL"; exit 1; fi
echo "test_pdk_root: PASS"
