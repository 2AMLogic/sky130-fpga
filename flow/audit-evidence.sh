#!/usr/bin/env bash
# flow/audit-evidence.sh
#
# Re-run the claim -> harness -> pinned-PDK audit published as
# measurements/claim-traceability.md, against the committed tree.
#
# Why (issue #34): T1 checklist item 9 of docs/design-evidence-tiers.md in
# 2AMLogic/klayout-tools requires that *every* claimed measurement has a
# committed testbench/harness and a pinned PDK version. A prose audit is
# true on the day it is written; this script is the part that stays true --
# it re-derives the audit from the tree on every invocation, so a new
# record, a new report type, an edited harness a record already pinned by
# hash, or a PDK swap all show up as a failure instead of silently
# invalidating the published traceability table.
#
# Unlike the other flow/*.sh entry points this one needs NO toolchain at
# all: no klt, no openroad, no yosys, no PDK install, no network. It reads
# only committed files (plus flow/tool_versions.sh's RECORDED_PDK_VERSION,
# the repo's single pinned PDK source), so it is runnable from any clean
# checkout and is the cheapest check in the repo.
#
# There is no --update mode: measurements/*/records/ is append-only, so a
# failure is fixed by correcting the tree, by adding a new record, or -- for
# a deliberate, method-neutral change -- by adding a cited entry to
# flow/audit_evidence.py's ALLOWED_INPUT_DRIFT / PDK_NULL_UPSTREAM_GAP
# tables. Never by rewriting a published record.
#
# Usage:
#   ./flow/audit-evidence.sh
#
# Exit status: 0 iff every record is traceable to a committed harness, every
# hash a record pins still describes the committed file, and every committed
# report either pins RECORDED_PDK_VERSION or is a known, filed upstream gap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found on PATH" >&2
    exit 1
fi

# RECORDED_PDK_VERSION -- the single pinned PDK source this audit checks
# every claim against. Sourced, not duplicated, so there is exactly one
# place to update on an intentional PDK bump.
# shellcheck source=./tool_versions.sh
source "$SCRIPT_DIR/tool_versions.sh"

echo "=== evidence audit against pinned PDK: ${RECORDED_PDK_VERSION} ==="
exec python3 "$SCRIPT_DIR/audit_evidence.py" \
    --recorded-pdk "$RECORDED_PDK_VERSION" \
    --repo-root "$REPO_ROOT"
