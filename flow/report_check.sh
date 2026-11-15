#!/usr/bin/env bash
# flow/report_check.sh
#
# Shared driver-convention helpers, sourced by the flow/*.sh evidence
# drivers (issue #265; the fourth helper of the kind tool_versions.sh,
# pdk_root.sh and gate_sim_verdict.sh already are). Three fragments that
# were previously hand-copied across the drivers, hoisted so a change to
# how this repo hashes an input or parses `--update` is a one-file edit
# instead of a seven-place hunt whose missed copy is silent:
#
#   - parse_update_mode "$@"  set MODE to "update" (`--update`) or "check"
#     (no argument); anything else prints the usage line and exits 1.
#     Used by the drivers whose argument surface is exactly
#     `[--update]`: flow/drc.sh, flow/erc.sh, flow/layout.sh and
#     flow/synth.sh. Scripts with additional modes or extra flags
#     (flow/lvs.sh's `--update-report`, the compact one-line parses)
#     keep their own case block.
#   - require_klt             exit 1 with the standard "klt not found on
#     PATH" message if `klt` is not on $PATH.
#   - sha256_of <path>        print "sha256:<hex>" over the file's raw
#     bytes -- the ONE hashing construction behind every provenance field
#     this repo writes (layout_gds_sha256, supply_spec_sha256,
#     layout_def_sha256/spef_sha256, the check-record input pins), so a
#     typo in the prefix or one site drifting to a different hash
#     construction cannot produce committed evidence whose provenance is
#     wrong while every gate still passes. The hash command is the
#     function's LAST command on purpose: its exit status is what the
#     caller sees, so a read failure on an existing input aborts the
#     driver under set -euo pipefail instead of recording an empty
#     "sha256:" digest -- flow/test_report_check.sh pins this contract.

# MODE is consumed by the sourcing driver's own body (check vs update
# branches), not by this file, so standalone analysis flags every
# assignment unused; the directive covers the whole function.
# shellcheck disable=SC2034
parse_update_mode() {
    MODE="check"
    case "${1:-}" in
        --update)
            MODE="update"
            ;;
        "")
            MODE="check"
            ;;
        *)
            echo "usage: $0 [--update]" >&2
            exit 1
            ;;
    esac
}

require_klt() {
    if ! command -v klt >/dev/null 2>&1; then
        echo "error: klt not found on PATH" >&2
        exit 1
    fi
}

sha256_of() {
    python3 -c "import hashlib,sys; print('sha256:'+hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
}
