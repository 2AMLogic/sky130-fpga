#!/usr/bin/env bash
# flow/klt_artifact.sh
#
# Shared .klt/<stage>/ artifact path resolver, sourced by flow/layout.sh,
# flow/sdf-resim.sh, flow/layout_routed.sh and flow/lvs.sh (issue #261,
# mirrors the flow/pdk_root.sh dedup done for #45).
#
# Why this exists (issue #261): all four scripts carried their own copy of
# the same fallback -- three of them hand-identical (`resolve_klt_artifact()`
# in flow/layout.sh and flow/sdf-resim.sh, the same fallback open-coded as
# an `if` in flow/lvs.sh) and flow/layout_routed.sh a fourth spelling
# (`resolve()`) whose semantics had drifted from the other three: it
# preferred a run-* copy over a present flat artifact and broke
# same-mtime ties lexicographically rather than newest-first, so it could
# hand `klt place-and-route` a netlist from an earlier run in a build dir
# that had accumulated more than one run-*. Converging all four on this one
# helper removes both the silent-divergence path and the stale-artifact
# selection.
#
# Semantics: klt >= 0.6.0 writes stage artifacts under
# .klt/<stage>/run-<id>/<artifact> instead of the flat .klt/<stage>/
# <artifact> of <= 0.5.x (observed with klt 0.6.0 / 0.7.0). Given the flat
# path a caller expects,
#
#   resolve_klt_artifact <flat_path>
#
# prints the flat path when it is present and non-empty (-s), else the
# newest run-* copy (newest by mtime first, `ls -1dt`), else the flat path
# unchanged -- so a caller's existing "did not produce" error still fires
# when neither exists. This is the single
# `# shellcheck disable=SC2012` that `ls` parse needs; before the dedup
# three of the four copies each carried their own suppression.

# shellcheck disable=SC2012
resolve_klt_artifact() {
    local flat="$1" dir base newest
    if [[ -s "$flat" ]]; then echo "$flat"; return 0; fi
    dir="$(dirname "$flat")"; base="$(basename "$flat")"
    newest="$(ls -1dt "$dir"/run-*/"$base" 2>/dev/null | head -1 || true)"
    echo "${newest:-$flat}"
}
