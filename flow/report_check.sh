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
#     `[--update]`: flow/layout.sh and flow/synth.sh. Scripts with
#     additional modes or extra flags (flow/lvs.sh's `--update-report`,
#     the compact one-line parses) keep their own case block.
#   - target_dir_arg <operand>  validate one `--target <dir>` operand and
#     record it in TARGET_DIR. Shared by all four --target-carrying
#     signoff drivers (flow/drc.sh, flow/erc.sh, flow/lvs.sh,
#     flow/sta-sweep.sh; issues #259, #370): the operand must name an
#     existing directory, must be non-empty (an explicitly empty operand
#     is a usage error, never an omitted flag -- before #370 a
#     `--target "" --update` fell through to `[[ -n "$TARGET_DIR" ]]`
#     treating the empty value as "no --target given" and refreshed the
#     committed layout the caller meant to override), and `--target`
#     may be given only once.
#   - parse_target_update_mode "$@"  parse the `[--target <dir>] [--update]`
#     command line flow/drc.sh and flow/erc.sh share byte-for-byte
#     (previously two hand-copied 30-line loops). Sets MODE ("update" or
#     "check") and records TARGET_DIR via target_dir_arg; anything else
#     prints the usage line and exits 1.
#   - resolve_target_mode  normalize the recorded TARGET_DIR (already
#     validated by target_dir_arg) against the sourcing driver's
#     $REPO_ROOT/layout: the committed layout directory spelled
#     explicitly collapses to TARGET_MODE "default" (TARGET_DIR cleared);
#     any other directory sets TARGET_MODE "target" with TARGET_DIR
#     absolutized. Used by flow/drc.sh, flow/erc.sh and flow/lvs.sh
#     (flow/sta-sweep.sh keeps its own alias handling for --routed).
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

# TARGET_DIR is consumed by the sourcing driver's own body (target
# selection, read-only refusals), not by this file -- same SC2034
# situation as parse_update_mode's MODE above; the directive covers the
# whole function.
# shellcheck disable=SC2034
target_dir_arg() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        echo "error: --target requires a non-empty directory argument" >&2
        exit 1
    fi
    if [[ -n "${TARGET_DIR:-}" ]]; then
        echo "error: --target given twice" >&2
        exit 1
    fi
    if [[ ! -d "$value" ]]; then
        echo "error: --target directory does not exist: $value" >&2
        exit 1
    fi
    TARGET_DIR="$value"
}

# shellcheck disable=SC2034
parse_target_update_mode() {
    MODE="check"
    TARGET_DIR=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update)
                MODE="update"
                ;;
            --target)
                if [[ $# -lt 2 ]]; then
                    echo "error: --target requires a directory argument" >&2
                    echo "usage: $0 [--target <dir>] [--update]" >&2
                    exit 1
                fi
                target_dir_arg "$2"
                shift
                ;;
            "")
                MODE="check"
                ;;
            *)
                echo "usage: $0 [--target <dir>] [--update]" >&2
                exit 1
                ;;
        esac
        shift
    done
}

# shellcheck disable=SC2034
resolve_target_mode() {
    TARGET_MODE="default"
    if [[ -n "${TARGET_DIR:-}" ]]; then
        TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
        if [[ "$TARGET_DIR" == "$REPO_ROOT/layout" ]]; then
            TARGET_MODE="default"
            TARGET_DIR=""
        else
            TARGET_MODE="target"
        fi
    fi
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
