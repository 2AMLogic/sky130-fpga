#!/usr/bin/env bash
# flow/drc.sh
#
# Run a full sky130 foundry-rule-deck DRC check (`klt drc`, klayout-tools)
# against the committed tile layout (`layout/logic_tile.gds`, from #9 /
# flow/layout.sh) and check the result against the committed report under
# layout/. This is the reproducibility harness for T1 item 3 (DRC clean)
# of docs/design-evidence-tiers.md in 2AMLogic/klayout-tools, per issue
# #11: "latest `klt drc` JSON report with `status: clean`, fresh
# (provenance matching current sources)." Mirrors flow/layout.sh's and
# flow/synth.sh's "regenerate from source every run" pattern.
#
# Scope note: this is DRC only -- a full foundry sky130 rule-deck check via
# `klt drc`'s default headless curated engine. It does NOT run LVS (a
# separate follow-on, issue #12) or re-derive the layout itself (that is
# flow/layout.sh's job; this script only checks the layout already
# committed under layout/). See layout/README.md for what the committed
# DRC report does and does not claim.
#
# Usage:
#   ./flow/drc.sh            # rerun DRC against the committed layout and
#                             # diff the (trimmed) report against the
#                             # committed copy under layout/. Exit 0 if
#                             # identical and clean; non-zero otherwise.
#   ./flow/drc.sh --update   # rerun DRC and overwrite the committed report.
#                             # Run this (and commit the result) after an
#                             # intentional layout change (i.e. after
#                             # `flow/layout.sh --update`).
#
# Requires on $PATH: `klt` (klayout-tools). Requires a resolvable sky130A
# PDK install (`klt pdk find --pdk sky130A`; $PDK_ROOT/$PDK, volare, or
# ciel) -- `klt drc`'s curated sky130 deck is PDK-install-independent for
# the check itself, but `--pdk` is required up front to resolve/report the
# PDK the deck is being run against.
#
# Exit status: 0 iff `klt drc` reports `status: clean` and (in the default,
# non-`--update` mode) the regenerated report (after volatile-field
# trimming -- see flow/drc_report_trim.py) matches the committed copy; 3 if
# the committed report has drifted from re-derived provenance (surfaced via
# `klt drc --check`, run last as a freshness cross-check); non-zero
# otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
GDS_NAME="logic_tile.gds"
REPORT_NAME="logic_tile.drc.json"
DECK="sky130"
PDK_VARIANT="sky130A"

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

if ! command -v klt >/dev/null 2>&1; then
    echo "error: klt not found on PATH" >&2
    exit 1
fi

if ! klt pdk find --pdk "$PDK_VARIANT" >/dev/null 2>&1; then
    echo "error: no $PDK_VARIANT PDK install resolvable (klt pdk find --pdk $PDK_VARIANT failed)" >&2
    echo "       set \$PDK_ROOT/\$PDK, or install via volare/ciel" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

COMMITTED_GDS="$LAYOUT_DIR/${GDS_NAME}"
COMMITTED_REPORT="$LAYOUT_DIR/${REPORT_NAME}"
RAW_REPORT="$BUILD_DIR/${REPORT_NAME}.raw"
GENERATED_REPORT="$BUILD_DIR/${REPORT_NAME}"

if [[ ! -f "$COMMITTED_GDS" ]]; then
    echo "error: no committed GDS at $COMMITTED_GDS -- run flow/layout.sh --update first" >&2
    exit 1
fi

# Run with a repo-root-relative input path so the report's "file" field
# (and thus the committed report itself) is identical across invoking
# hosts/checkout locations -- mirrors flow/layout.sh's/flow/synth.sh's own
# absolute-path avoidance.
echo "=== klt drc ${GDS_NAME} (deck: ${DECK}) ==="
if ! ( cd "$REPO_ROOT" && klt drc "layout/${GDS_NAME}" --deck "$DECK" --pdk "$PDK_VARIANT" --format json | tee "$RAW_REPORT" ); then
    echo "error: klt drc failed (see $RAW_REPORT)" >&2
    exit 1
fi

if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$RAW_REPORT')).get('status') == 'clean' else 1)"; then
    echo "error: klt drc did not report status 'clean' against ${GDS_NAME} (see $RAW_REPORT)" >&2
    exit 1
fi

# Trim volatile (tool-version) fields out of the response before
# comparing/committing -- see flow/drc_report_trim.py's own header comment.
python3 "$SCRIPT_DIR/drc_report_trim.py" "$RAW_REPORT" "$GENERATED_REPORT"

if [[ "$MODE" == "update" ]]; then
    cp "$GENERATED_REPORT" "$COMMITTED_REPORT"
    echo "=== report written to ${COMMITTED_REPORT} ==="
    exit 0
fi

if [[ ! -f "$COMMITTED_REPORT" ]]; then
    echo "error: no committed report at $COMMITTED_REPORT -- run '$0 --update' to create it" >&2
    exit 1
fi

status=0
if ! diff -u "$COMMITTED_REPORT" "$GENERATED_REPORT"; then
    echo "error: regenerated report differs from the committed copy at $COMMITTED_REPORT" >&2
    status=1
fi

if [[ "$status" -ne 0 ]]; then
    echo "       layout changed (or the flow is non-reproducible) without regenerating the report -- run '$0 --update' and commit the result" >&2
    exit 1
fi

# Freshness cross-check: klt drc's own --check verb re-hashes the input
# layout and deck named in the committed report's provenance block and
# compares against the recorded content_hash values -- the mechanism this
# issue's "provenance ... so freshness is verifiable later" acceptance
# criterion relies on. Cheap mode only (no --rerun) here; a full re-run
# already happened above.
echo "=== klt drc --check ${REPORT_NAME} (provenance freshness) ==="
if ! ( cd "$REPO_ROOT" && klt drc --check "layout/${REPORT_NAME}" ); then
    echo "error: committed report at $COMMITTED_REPORT has drifted from its recorded provenance (content hash mismatch)" >&2
    exit 1
fi

echo "=== committed DRC report matches regenerated output (reproducible, clean, fresh) ==="
