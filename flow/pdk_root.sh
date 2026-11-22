#!/usr/bin/env bash
# flow/pdk_root.sh
#
# Shared $PDK_ROOT/$PDK and sky130_fd_sc_hd cell-model resolution helpers,
# sourced by flow/drc.sh, flow/layout.sh, flow/lvs.sh, flow/sta-sweep.sh
# and, since issue #375, the gate-level simulation drivers (issue #45
# mirrors the flow/_report_trim.py dedup done for #15). Two independent
# steps, since not every caller needs both:
#
#   - require_pdk_resolvable <variant>: fail loudly (exit 1) if
#     `klt pdk find --pdk <variant>` cannot resolve an install. Used by all
#     four scripts above.
#   - export_pdk_root_if_unset <variant>: if $PDK_ROOT is unset in the
#     invoking shell, export it (and $PDK) from `klt pdk find`'s own
#     resolved root, without overriding an operator's explicit
#     configuration. Used by flow/drc.sh, flow/lvs.sh and flow/sta-sweep.sh:
#     the lvs/sta pair delegate to `openroad` wrappers that only mount
#     $PDK_ROOT when it is set, and klt builds after the klayout-tools#1901
#     fix write a resolution-dependent `provenance.pdk.source` string into
#     every drc/lvs report -- so drc.sh needs the same deterministic
#     invocation-side resolution for its committed report to stay
#     byte-reproducible.
#
# sky130_cell_models_from_klt / resolve_sky130_cell_models below extend the
# same single-sourcing to the sky130_fd_sc_hd Verilog cell models every
# gate-level driver passes to iverilog (issue #375): the four hand-copied
# lookup blocks they replace had drifted into a dead `klt pdk find`
# fallback (flow/tile-functional-verification.sh queried the bare root,
# where the models never live) and a missing primitives.v guard
# (flow/gate-sim-routed.sh).
#
# Local-environment robustness (why export_pdk_root_if_unset exists): some
# local `openroad` installs are thin Docker wrappers (see e.g.
# `~/.local/bin/openroad`, "Local dev wrapper (not repo-managed)") that only
# mount $PDK_ROOT into the container when that variable is set in the
# invoking shell, even though `klt pdk find` itself resolves the PDK fine
# via a different search path (e.g. a default volare root) with no
# $PDK_ROOT set at all. This is not a klt/klayout-tools gap -- it
# accommodates that machine-local detail so flow/lvs.sh and
# flow/sta-sweep.sh work without requiring every invoking environment to
# already know about it. Exporting only when unset keeps an operator's
# explicit configuration authoritative.

# export_pdk_root_if_unset <pdk_variant>
#
# If $PDK_ROOT is already set in the invoking shell, does nothing (an
# operator's explicit configuration is never overridden). Otherwise,
# resolves <pdk_variant> via `klt pdk find --format json` and, if that
# succeeds, exports $PDK_ROOT (to the resolved root) and $PDK (to
# <pdk_variant>). Does not fail if resolution comes up empty here --
# require_pdk_resolvable below is what fails loudly for an unresolvable PDK.
export_pdk_root_if_unset() {
    local variant="$1"

    if [[ -z "${PDK_ROOT:-}" ]]; then
        local resolved_root
        resolved_root="$(klt pdk find --pdk "$variant" --format json 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('root',''))" 2>/dev/null || true)"
        if [[ -n "$resolved_root" ]]; then
            export PDK_ROOT="$resolved_root"
            export PDK="$variant"
        fi
    fi
}

# require_pdk_resolvable <pdk_variant>
#
# Fails loudly (prints the "no <variant> PDK install resolvable" error and
# exits 1) if `klt pdk find --pdk <variant>` cannot resolve an install.
# Exit status/stderr text is identical across all four callers.
require_pdk_resolvable() {
    local variant="$1"

    if ! klt pdk find --pdk "$variant" >/dev/null 2>&1; then
        echo "error: no $variant PDK install resolvable (klt pdk find --pdk $variant failed)" >&2
        echo "       set \$PDK_ROOT/\$PDK, or install via volare/ciel" >&2
        exit 1
    fi
}

# sky130_cell_models_from_klt [pdk_variant]
#
# Prints the sky130_fd_sc_hd Verilog cell-model directory that `klt pdk
# find` resolves for <pdk_variant> (default sky130A) -- <libs_ref>/
# sky130_fd_sc_hd/verilog from the find result's assets.libs_ref -- or
# nothing when klt is absent or resolution fails. Prints only the path;
# never fails the caller, never checks the directory's contents (callers
# that need both model files use resolve_sky130_cell_models below, and
# flow/tile-functional-verification.sh hash-gates what it accepts).
# Single-sourced here since issue #375; previously four hand-copied lookup
# blocks across the gate-sim drivers had drifted (one dead fallback, one
# missing primitives.v guard).
sky130_cell_models_from_klt() {
    local variant="${1:-sky130A}"

    command -v klt >/dev/null 2>&1 || return 0
    local libs_ref
    libs_ref="$(klt pdk find --pdk "$variant" --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("assets", {}).get("libs_ref", ""))' 2>/dev/null || true)"
    [[ -n "$libs_ref" ]] || return 0
    echo "$libs_ref/sky130_fd_sc_hd/verilog"
}

# resolve_sky130_cell_models [pdk_variant]
#
# Prints the sky130_fd_sc_hd Verilog cell-model directory and returns 0,
# trying in order (the exact precedence every pre-#375 caller used):
#   1. `klt pdk find`'s assets.libs_ref (sky130_cell_models_from_klt above)
#   2. $PDK_ROOT/<variant>/libs.ref/sky130_fd_sc_hd/verilog
#   3. $HOME/.volare/<variant>/libs.ref/sky130_fd_sc_hd/verilog
# A candidate is accepted only when BOTH sky130_fd_sc_hd.v and primitives.v
# exist in it -- both files are always passed to iverilog together, so a
# directory holding only one of them must fall through to the next
# candidate, not delay the failure to compile time. On no match prints the
# shared "could not resolve" error to stderr and returns 1 (callers run
# under set -e or append || exit 1 themselves).
resolve_sky130_cell_models() {
    local variant="${1:-sky130A}"
    local c cell_dir=""

    for c in "$(sky130_cell_models_from_klt "$variant")" \
             "${PDK_ROOT:+$PDK_ROOT/$variant/libs.ref/sky130_fd_sc_hd/verilog}" \
             "$HOME/.volare/$variant/libs.ref/sky130_fd_sc_hd/verilog"; do
        if [[ -n "$c" && -f "$c/sky130_fd_sc_hd.v" && -f "$c/primitives.v" ]]; then
            cell_dir="$c"
            break
        fi
    done
    if [[ -z "$cell_dir" ]]; then
        echo "error: could not resolve sky130_fd_sc_hd Verilog cell models (set PDK_ROOT)" >&2
        return 1
    fi
    echo "$cell_dir"
}
