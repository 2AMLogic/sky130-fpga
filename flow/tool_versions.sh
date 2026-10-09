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
# RECORDED_KLT_VERSION / RECORDED_OPENROAD_VERSION / RECORDED_PDK_VERSION
# below after an intentional toolchain-driven `--update`.
#
# The same reasoning applies to the *PDK* revision, which is why
# RECORDED_PDK_VERSION lives here too (issue #34, T1 checklist item 9 --
# "every claimed measurement has a committed testbench and a pinned PDK
# version"). Most artifacts pin it themselves: `klt place-and-route` and
# `klt sta` both write `provenance.pdk.{name,version}` into their reports,
# so layout/logic_tile.par.json and every per-corner report under
# measurements/timing-characterization/corners/ carry the open_pdks
# revision they were produced against, and check mode's own diff fails if
# the installed PDK differs. `klt drc` and `klt lvs` did not, before the
# klt build carrying the klayout-tools#1901 fix: pre-fix builds wrote
# `provenance.pdk: null` even when invoked with `--pdk sky130A`, and this
# file was then the single pinned source covering those two reports. The
# fixes landed: klayout-tools#1901 is closed, and klt 0.5.0 writes a real
# `provenance.pdk.{name,version}` into both reports -- the committed
# layout/logic_tile.drc.json and .lvs.json have pinned the PDK in-artifact
# since the 2026-09-21 re-stamp (issue #41, PR #55). For them this banner
# is now a double-check on top of the in-artifact pin, not their only pin;
# the one report that still records no PDK revision is
# layout/logic_tile.erc.json (`klt erc` writes no provenance block at all
# and reads no PDK install, klayout-tools#2036), for which the banner --
# plus the content-hash pins flow/erc_report_trim.py synthesizes on its
# actual inputs -- remains the stated pin.

# The klt / OpenROAD versions that produced the artifacts CURRENTLY
# committed under layout/ (and, until issue #68, also the STA evidence
# under measurements/timing-characterization/ -- see
# RECORDED_STA_KLT_VERSION below for that lineage now) (per
# layout/logic_tile.erc.json's provenance.klt_version pin and the successor
# records:
# measurements/timing-characterization/records/20260921-062500-e8a37ad.md
# and 20260921-062530-e8a37ad.md, superseders of the 20260909/20260915
# pre-PDN pair). Updated for issue #41's PDN regeneration: the post-PDN
# GDS/DEF/SPEF/SDF lineage was produced under 0.5.0+g2b7caa9939af, and
# check-mode diffs were re-verified 2026-09-21 on this tree under
# 0.5.0+g2b1e55e51bb8.dirty -- byte-identical GDS/DEF, identical verdict
# fields in every re-stamped report. The committed SDF
# (measurements/timing-characterization/logic_tile_route.sdf) is still of
# this lineage too.
RECORDED_KLT_VERSION="0.5.0+g2b7caa9939af"
RECORDED_OPENROAD_VERSION="26Q3-1278-g4421880472"

# The klt / OpenROAD that produced the STA evidence CURRENTLY committed by
# flow/sta-sweep.sh: every corners/*/*.sta.json, the multi-corner item-5
# envelope logic_tile.sta.json and the sanitized SPEF logic_tile.spef under
# measurements/timing-characterization/ (issue #68, successor record
# measurements/timing-characterization/records/20261008-234741-dc615b4.md).
# A deliberate design-flow upgrade: only a klt that emits `timing_status`
# (klayout-tools#1865) and accepts `pdk.corners` (klayout-tools#1871)
# produces an envelope `klt signoff` can grade for T1 item 5. Split from
# RECORDED_KLT_VERSION rather than replacing it because the layout/
# artifacts were NOT regenerated (and do not regenerate byte-identically
# under this newer toolchain -- record 20261008-233733-23e6b5e), so
# bumping the shared pin would misstate their lineage. Measured drift vs.
# the 0.5.0 lineage: binding-corner (ss_n40C_1v28) SPEF WNS 15.2146 ->
# 15.2145 ns (-0.1 ps); see the record for every corner. flow/sta-sweep.sh
# prints its banner against THESE two values.
RECORDED_STA_KLT_VERSION="0.7.0+g6fd0278268cc"
RECORDED_STA_OPENROAD_VERSION="26Q3-1510-g6cb3f2b704"

# The sky130A PDK revision those same committed artifacts were produced
# against -- the value `klt pdk find --pdk sky130A --format json` reports
# as `.version`, and the value both committed provenance blocks above
# already carry (layout/logic_tile.par.json's `provenance.pdk.version` and
# every corners/*/*.sta.json's). Restated here as the single pinned source
# for any committed report whose own `provenance.pdk` is null: once the
# pre-fix DRC/LVS reports, now only layout/logic_tile.erc.json
# (klayout-tools#2036). Update on an intentional PDK bump, together with
# the artifacts regenerated against it.
RECORDED_PDK_VERSION="open_pdks c6d73a35f524070e85faff4a6a9eef49553ebc2b"

# Prints the resolved sky130A PDK revision and, if it differs from
# RECORDED_PDK_VERSION above, a warning. Split out from
# print_tool_version_banner so a PDK-only flow (flow/drc.sh, flow/lvs.sh --
# neither of which needs `openroad`) can pin the PDK without emitting a
# spurious "OpenROAD unknown" warning. Safe to call once `klt pdk find` has
# already been confirmed to resolve.
#
# Usage: print_pdk_version_banner [pdk_variant]   (default: sky130A)
print_pdk_version_banner() {
    local variant="${1:-sky130A}"
    local installed_pdk
    installed_pdk="$(klt pdk find --pdk "$variant" --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"

    echo "=== pdk: ${variant} ${installed_pdk:-unknown} ==="
    if [[ "$installed_pdk" != "$RECORDED_PDK_VERSION" ]]; then
        {
            echo "warning: resolved ${variant} PDK (${installed_pdk:-unknown}) differs from the PDK revision the"
            echo "         currently committed artifacts were produced against (${RECORDED_PDK_VERSION})."
            echo "         A diff below may be a PDK revision change rather than a design regression -- most"
            echo "         committed reports, including layout/logic_tile.drc.json / .lvs.json since the klt"
            echo "         build carrying the klayout-tools#1901 fix, pin the PDK in their own provenance"
            echo "         block; the exception is layout/logic_tile.erc.json (klt erc reads no PDK install,"
            echo "         klayout-tools#2036), whose pin this banner carries. See flow/README.md's"
            echo "         'Toolchain versions' section (issue #34)."
        } >&2
    fi
}

# Prints the installed klt version and, if it differs from
# RECORDED_KLT_VERSION above, a warning. Split out from
# print_tool_version_banner for the same reason print_pdk_version_banner
# was: a klt-only flow (flow/erc.sh -- which needs neither `openroad` nor
# the PDK for its connectivity model, only for the antenna-limit table)
# can pin klt without emitting a spurious "OpenROAD unknown" warning.
#
# This matters more for ERC than for the other PDK-only flows: `klt erc`
# postdates RECORDED_KLT_VERSION entirely, so layout/logic_tile.erc.json
# cannot have been produced by the pinned klt and this banner is where
# that says so out loud. Safe to call once `klt` is confirmed on $PATH.
#
# Usage: print_klt_version_banner
print_klt_version_banner() {
    local installed_klt
    installed_klt="$(klt --version 2>/dev/null | awk '{print $2}')"

    echo "=== toolchain: klt ${installed_klt:-unknown} ==="
    if [[ "$installed_klt" != "$RECORDED_KLT_VERSION" ]]; then
        {
            echo "warning: installed klt (${installed_klt:-unknown}) differs from the klt that produced the"
            echo "         currently committed layout artifacts (${RECORDED_KLT_VERSION}). The report this run"
            echo "         writes pins its own klt version in provenance.klt_version, so the committed evidence"
            echo "         records which klt actually produced it -- see flow/README.md's 'Toolchain versions'"
            echo "         section before treating any diff below as a design regression."
        } >&2
    fi
}

# Prints the installed klt/OpenROAD versions and the resolved PDK revision
# and, if any differs from RECORDED_KLT_VERSION/RECORDED_OPENROAD_VERSION/
# RECORDED_PDK_VERSION above, a warning pointing back to this file and
# flow/README.md. Safe to call once `klt`/`openroad` are already confirmed
# present on $PATH.
#
# Usage: print_tool_version_banner [pdk_variant] [expected_klt] [expected_openroad]
# (defaults: sky130A, RECORDED_KLT_VERSION, RECORDED_OPENROAD_VERSION --
# flow/sta-sweep.sh passes the RECORDED_STA_* pair instead, issue #68).
print_tool_version_banner() {
    local installed_klt installed_openroad
    local expected_klt="${2:-$RECORDED_KLT_VERSION}"
    local expected_openroad="${3:-$RECORDED_OPENROAD_VERSION}"
    installed_klt="$(klt --version 2>/dev/null | awk '{print $2}')"
    installed_openroad="$(openroad -version 2>/dev/null | head -1 | awk '{print $1}')"

    echo "=== toolchain: klt ${installed_klt:-unknown}, OpenROAD ${installed_openroad:-unknown} ==="
    if [[ "$installed_klt" != "$expected_klt" || "$installed_openroad" != "$expected_openroad" ]]; then
        {
            echo "warning: installed toolchain (klt ${installed_klt:-unknown} / OpenROAD ${installed_openroad:-unknown}) differs from"
            echo "         the toolchain that produced the currently committed artifacts (klt ${expected_klt} /"
            echo "         OpenROAD ${expected_openroad}). A check-mode diff below on a byte-reproducibility"
            echo "         artifact (GDS/DEF/report, or a spef_sha256 provenance field) alongside matching *numeric*"
            echo "         STA/timing/wirelength results may be toolchain drift, not a design regression -- see"
            echo "         flow/README.md's 'Toolchain versions' section before treating it as one (issue #23)."
        } >&2
    fi

    print_pdk_version_banner "${1:-sky130A}"
}

# FABulous generator release this repo's tile description targets (spec gap
# G1). Source: PyPI `fabulous-fpga` 2.2.0 == git tag v2.2.0
# (432bb2873b83585d5178a8ba411f38254387ce94) of
# https://github.com/FPGA-Research-Manchester/FABulous (Apache-2.0).
# flow/fabulous.sh installs exactly this into flow/build/fab-venv (a
# throwaway, untracked venv); it is never installed host-wide. Bump together
# with a re-run of `flow/fabulous.sh --update-log` and design/README.md.
RECORDED_FABULOUS_VERSION="2.2.0"

# yosys + nextpnr-generic (FABulous `fabulous` viaduct uarch) used by
# flow/nextpnr.sh (issue #87, G1 caveat 1). Pinned as the YosysHQ OSS CAD
# Suite nightly below (yosys 0.69+260 dcd59343b, nextpnr-0.11.1-54-g861c57be),
# unpacked into the untracked flow/build/oss-cad-suite -- never installed
# host-wide (the host `yosys` under ~/.local/bin is a different build and is
# deliberately not used). The tarball is verified against the sha256 below.
# Bump together with a re-run of `flow/nextpnr.sh --update-log`.
RECORDED_OSS_CAD_TAG="2026-10-08"
RECORDED_OSS_CAD_TARBALL="oss-cad-suite-linux-x64-20261008.tgz"
RECORDED_OSS_CAD_SHA256="8fa59d93d6cadbbee352077c059f2c5b72cda301e4508d9064a23d1ec11579c7"
RECORDED_NEXTPNR_VERSION="nextpnr-0.11.1-54-g861c57be"
RECORDED_YOSYS_VERSION="0.69+260"
