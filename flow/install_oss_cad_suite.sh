#!/usr/bin/env bash
# flow/install_oss_cad_suite.sh
#
# Shared installer for the pinned YosysHQ OSS CAD Suite (issue #350).
# flow/nextpnr.sh, flow/blinky.sh and .github/workflows/fabulous-nextpnr.yml
# each used to keep their own copy of the same download / sha256-verify /
# extract / .pin-stamp sequence (plus the yosys/nextpnr version check), so a
# change to the tool bundle's contents had three places to land. Source this
# file after flow/tool_versions.sh (the pins live there) and call
# install_oss_cad_suite at the point in the caller's own order where the
# tools must be on PATH:
#
#   source "$REPO/flow/tool_versions.sh"
#   source "$REPO/flow/install_oss_cad_suite.sh"
#   install_oss_cad_suite                # optional arg: build dir
#
# What one call does (the sequence every caller used to repeat):
#   1. Reuses an already-unpacked tree at <build>/oss-cad-suite/ iff
#      nextpnr-generic is executable there, its .pin stamp matches
#      RECORDED_OSS_CAD_SHA256 and -- when the tarball is still in
#      <build>/dl/ -- the tarball re-verifies against that sha256. A tree
#      with a matching stamp is reused even with the archive absent, so an
#      unpacked install keeps working offline.
#   2. Otherwise fetches the pinned release tarball into <build>/dl/. A
#      byte-valid cached copy is kept; a missing or corrupt one is
#      re-downloaded and re-verified BEFORE anything is unpacked, so a
#      poisoned cache entry cannot clobber a valid unpacked tree.
#   3. Extracts the tool subset (bin, lib, libexec, share/yosys,
#      share/nextpnr, etc) with --strip-components=1 and rewrites the .pin
#      stamp.
#   4. Puts <tree>/bin first on PATH and checks the installed yosys and
#      nextpnr-generic version strings against RECORDED_YOSYS_VERSION /
#      RECORDED_NEXTPNR_VERSION, exiting non-zero on any mismatch.
#
# Nothing is installed host-wide; everything lands under the build dir
# (default <repo>/flow/build beside this file, override with the optional
# argument). Sets for the caller:
#   OSS          absolute path of the unpacked tree
#   OSS_FETCHED  1 iff this call downloaded/extracted, 0 iff it reused an
#                already-unpacked tree (flow/blinky.sh reports this in its
#                "tools fetched-this-run/cached" status line)
#   YV, NV       the installed yosys / nextpnr-generic version strings
#                (flow/nextpnr.sh writes them into its normalized log's
#                first line, so they must survive the call)
#
# Callers keep their own invocation order around the call: flow/blinky.sh
# and the CI workflow install BEFORE flow/fabulous.sh (FABulous shells out
# to yosys, and CI needs it on PATH for its standalone generator run),
# while flow/nextpnr.sh installs after its FABulous model run.
# Regression test: flow/test_install_oss_cad_suite.sh (stubbed curl + tool
# binaries; exercises the empty cache, reuse, offline reuse, stampless
# re-extract, corrupt-archive refetch and version-guard paths).

install_oss_cad_suite() {
    local repo build tgz
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    build="${1:-$repo/flow/build}"
    OSS="$build/oss-cad-suite"
    # shellcheck disable=SC2034  # OSS_FETCHED is read by the caller (blinky.sh)
    OSS_FETCHED=0
    mkdir -p "$build/dl"
    tgz="$build/dl/$RECORDED_OSS_CAD_TARBALL"
    if [[ ! -x "$OSS/bin/nextpnr-generic" ]] || \
       [[ ! -f "$OSS/.pin" ]] || [[ "$(cat "$OSS/.pin")" != "$RECORDED_OSS_CAD_SHA256" ]] || \
       { [[ -f "$tgz" ]] && ! echo "$RECORDED_OSS_CAD_SHA256  $tgz" | sha256sum -c --quiet - >/dev/null 2>&1; }; then
        if [[ ! -f "$tgz" ]] || ! echo "$RECORDED_OSS_CAD_SHA256  $tgz" | sha256sum -c --quiet -; then
            curl -fsSL -o "$tgz" \
              "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${RECORDED_OSS_CAD_TAG}/${RECORDED_OSS_CAD_TARBALL}"
            echo "$RECORDED_OSS_CAD_SHA256  $tgz" | sha256sum -c --quiet -
        fi
        rm -rf "$OSS"; mkdir -p "$OSS"
        tar -xzf "$tgz" -C "$OSS" --strip-components=1 \
            oss-cad-suite/bin oss-cad-suite/lib oss-cad-suite/libexec \
            oss-cad-suite/share/yosys oss-cad-suite/share/nextpnr oss-cad-suite/etc
        echo "$RECORDED_OSS_CAD_SHA256" >"$OSS/.pin"
        # shellcheck disable=SC2034  # OSS_FETCHED is read by the caller (blinky.sh)
        OSS_FETCHED=1
    fi
    export PATH="$OSS/bin:$PATH"
    YV="$(yosys -V | awk '{print $2}')"
    NV="$(nextpnr-generic --version 2>&1 | grep -o 'nextpnr-[0-9][^)" ]*' | head -1)"
    echo "=== yosys $YV (pinned $RECORDED_YOSYS_VERSION), $NV (pinned $RECORDED_NEXTPNR_VERSION) ==="
    [[ "$YV" == "$RECORDED_YOSYS_VERSION" && "$NV" == "$RECORDED_NEXTPNR_VERSION" ]] || {
        echo "toolchain version mismatch" >&2; exit 1; }
}
