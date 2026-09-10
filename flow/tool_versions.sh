#!/usr/bin/env bash
# flow/tool_versions.sh
#
# Shared toolchain-version banner, sourced by flow/layout.sh and
# flow/sta-sweep.sh's check mode.
#
# Why this exists (issue #23): klayout-tools (`klt`) and OpenROAD make no
# output-format stability promise across releases. `klt place-and-route`
# (wirelength_um, fill-cell placement) and `klt extract --spef` (raw SPEF
# byte content) have already been observed to shift between the toolchain
# that produced the artifacts currently committed under layout/ and
# measurements/ (klt 0.3.0+gc6dbf66c53c6 / OpenROAD 26Q3-1278-g4421880472)
# and a newer klt 0.4.0 install -- *without* moving any numeric STA/timing
# result (worst_slack_ns, total_negative_slack_ns, nets_annotated, status)
# at the precision this repo publishes. A bare check-mode diff on a
# byte-reproducibility artifact (layout/logic_tile.gds/.def/.par.json, or a
# spef_sha256 provenance field) is indistinguishable from a real design
# regression unless the reader also knows the installed toolchain differs
# from the one that produced the committed copy -- this file makes that
# context visible up front instead of relying on the reader to already know
# it or to go diff tool versions by hand.
#
# This is informational only, not enforced -- this repo has no CI and no
# pinned container image (out of scope here; tracked as a possible
# follow-up), so a version mismatch does not abort the script. The diff
# itself stays authoritative; this banner exists only so a future
# non-reproducibility report is not mistaken for a design regression
# without first ruling out toolchain drift. See flow/README.md's
# "Toolchain versions" section for the full rationale and how to update
# RECORDED_KLT_VERSION / RECORDED_OPENROAD_VERSION below after an
# intentional toolchain-driven `--update`.

# The klt / OpenROAD versions that produced the artifacts CURRENTLY
# committed under layout/ and measurements/timing-characterization/ (per
# layout/logic_tile.par.json's own provenance and this record:
# measurements/timing-characterization/records/20260909-225431-86f71d2.md).
# Update these two values (and this comment's record reference) whenever
# `--update` is run with a different toolchain.
RECORDED_KLT_VERSION="0.3.0+gc6dbf66c53c6"
RECORDED_OPENROAD_VERSION="26Q3-1278-g4421880472"

# Prints the installed klt/OpenROAD versions and, if either differs from
# RECORDED_KLT_VERSION/RECORDED_OPENROAD_VERSION above, a warning pointing
# back to this file and flow/README.md. Safe to call once `klt`/`openroad`
# are already confirmed present on $PATH.
print_tool_version_banner() {
    local installed_klt installed_openroad
    installed_klt="$(klt --version 2>/dev/null | awk '{print $2}')"
    installed_openroad="$(openroad -version 2>/dev/null | head -1 | awk '{print $1}')"

    echo "=== toolchain: klt ${installed_klt:-unknown}, OpenROAD ${installed_openroad:-unknown} ==="
    if [[ "$installed_klt" != "$RECORDED_KLT_VERSION" || "$installed_openroad" != "$RECORDED_OPENROAD_VERSION" ]]; then
        {
            echo "warning: installed toolchain (klt ${installed_klt:-unknown} / OpenROAD ${installed_openroad:-unknown}) differs from"
            echo "         the toolchain that produced the currently committed artifacts (klt ${RECORDED_KLT_VERSION} /"
            echo "         OpenROAD ${RECORDED_OPENROAD_VERSION}). A check-mode diff below on a byte-reproducibility"
            echo "         artifact (GDS/DEF/report, or a spef_sha256 provenance field) alongside matching *numeric*"
            echo "         STA/timing/wirelength results may be toolchain drift, not a design regression -- see"
            echo "         flow/README.md's 'Toolchain versions' section before treating it as one (issue #23)."
        } >&2
    fi
}
