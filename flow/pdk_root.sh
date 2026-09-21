#!/usr/bin/env bash
# flow/pdk_root.sh
#
# Shared $PDK_ROOT/$PDK resolution helpers, sourced by flow/drc.sh,
# flow/layout.sh, flow/lvs.sh and flow/sta-sweep.sh (issue #45, mirrors the
# flow/_report_trim.py dedup done for #15). Two independent steps, since not
# every caller needs both:
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
