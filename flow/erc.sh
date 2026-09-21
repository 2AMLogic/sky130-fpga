#!/usr/bin/env bash
# flow/erc.sh
#
# Run the `klt erc` (klayout-tools) supply-spec ERC against the committed
# tile layout (`layout/logic_tile.gds`, from #9 / flow/layout.sh) and check
# the result against the committed report under layout/. This is the
# reproducibility harness for T1 checklist item 11 -- power delivery
# (structural) -- of docs/design-evidence-tiers.md in 2AMLogic/klayout-tools
# (approved as klayout-tools#2025, tracked here by issue #51 and the
# gap-to-T1 tracker issue #4): a committed supply spec declaring every
# supply as a nets[] entry, and a committed `klt erc --format json` report
# against the committed GDS whose input content-hash matches it. Mirrors
# flow/drc.sh's and flow/lvs.sh's "regenerate from source every run" and
# check/`--update` pattern.
#
# Scope note: this harness does NOT gate the run on a clean verdict, unlike
# flow/drc.sh's `status: clean` requirement. The committed report is
# expected to carry erc_findings while the layout has no power delivery
# network -- VPWR currently resolves to 7 electrical islands and VGND to 8
# (the 15 isolated met1 row-rail stripes issue #41 names), and
# erc.missing_tie is not computed at all (the spec deliberately declares no
# ties[]: klayout-tools#2169; see layout/erc-supply-spec.json's comment
# block). That finding set is the evidence this report exists to record,
# not a failure of this harness -- the harness fails only when the report
# itself can no longer be reproduced byte-for-byte from the committed
# layout+spec, or no longer content-hash-pins them. When the PDN work
# tracked in #41 lands and the layout is re-routed, `--update` rewrites
# the committed report to the new geometry's verdict.
#
# Usage:
#   ./flow/erc.sh            # rerun klt erc against the committed layout
#                             # and spec, diff the (trimmed) report against
#                             # the committed copy under layout/, and verify
#                             # the report still content-hash-pins the
#                             # committed GDS and spec. Exit 0 iff identical
#                             # and fresh; non-zero otherwise.
#   ./flow/erc.sh --update   # rerun and overwrite the committed report.
#                             # Run this (and commit the result) after an
#                             # intentional layout change (i.e. after
#                             # `flow/layout.sh --update`).
#
# Requires on $PATH: `klt` (klayout-tools) and `python3`. Unlike
# flow/drc.sh / flow/lvs.sh it requires NO PDK install: `klt erc` reads
# only the committed GDS and the committed spec JSON -- it opens no PDK
# path (its own --pdk switch only selects klt's built-in antenna-ratio
# table, which this repo deliberately does not pass; the antenna verdict is
# not item 11's subject, klayout-tools#1994, and the committed report
# honestly carries 'unchecked' antenna verdicts instead).
#
# Exit `klt erc` contract (docs/cli/erc.md in klayout-tools): the exit code
# follows the payload's top-level status field -- 0 clean/clean_partial,
# 3 violations, 4 not_checked -- all of which mean THE RUN COMPLETED and
# are accepted here (the verdict is read from the committed payload, not
# the exit code); this script itself fails on klt erc exit 1 (failed to
# run / malformed spec / no gate geometry) and 2 (usage error), on a
# report-vs-committed diff, or on a content-hash mismatch (no longer
# pins the committed GDS or spec -- i.e. the layout or spec changed
# without regenerating the report).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYOUT_DIR="$REPO_ROOT/layout"
BUILD_DIR="$SCRIPT_DIR/build"
GDS_NAME="logic_tile.gds"
SPEC_NAME="erc-supply-spec.json"
REPORT_NAME="logic_tile.erc.json"
TOP_CELL="logic_tile"

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
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found on PATH" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

COMMITTED_GDS="$LAYOUT_DIR/${GDS_NAME}"
COMMITTED_SPEC="$LAYOUT_DIR/${SPEC_NAME}"
COMMITTED_REPORT="$LAYOUT_DIR/${REPORT_NAME}"
RAW_REPORT="$BUILD_DIR/${REPORT_NAME}.raw"
GENERATED_REPORT="$BUILD_DIR/${REPORT_NAME}"

if [[ ! -f "$COMMITTED_GDS" ]]; then
    echo "error: no committed GDS at $COMMITTED_GDS -- run flow/layout.sh --update first" >&2
    exit 1
fi
if [[ ! -f "$COMMITTED_SPEC" ]]; then
    echo "error: no committed supply spec at $COMMITTED_SPEC" >&2
    exit 1
fi

# Run with repo-root-relative input paths so the report's "file"/"spec"
# fields -- and thus the committed report itself -- are identical across
# invoking hosts/checkout locations (mirrors flow/drc.sh).
echo "=== klt erc ${GDS_NAME} (spec: ${SPEC_NAME}, top: ${TOP_CELL}) ==="
set +e
( cd "$REPO_ROOT" && klt erc "layout/${GDS_NAME}" "layout/${SPEC_NAME}" --top "$TOP_CELL" --format json ) > "$RAW_REPORT"
ERC_RC=$?
set -e
if [[ "$ERC_RC" -eq 1 || "$ERC_RC" -eq 2 ]]; then
    echo "error: klt erc failed to run (exit $ERC_RC, see $RAW_REPORT)" >&2
    exit 1
fi
if [[ "$ERC_RC" -ne 0 && "$ERC_RC" -ne 3 && "$ERC_RC" -ne 4 ]]; then
    echo "error: klt erc exited with an undocumented code $ERC_RC -- see $RAW_REPORT and docs/cli/erc.md's exit-code contract" >&2
    exit 1
fi

# Show what the run graded, compactly (the full gates[] payload stays in
# the report files; the text-format equivalent of the fields the claim
# reads: the document "Gate on status, not the exit code" quote).
python3 - "$RAW_REPORT" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
print(f"    status: {doc.get('status')}  erc_status: {doc.get('erc_status')}  "
      f"erc_finding_count: {doc.get('erc_finding_count')}  gates: {doc.get('gate_count')}")
for f in doc.get("erc_findings", []):
    print(f"    {f.get('rule')}: {f.get('net') or ''}{(' <- ' + f['other_net']) if f.get('other_net') else ''} -- {f.get('description')}")
PYEOF

# Trim volatile (tool-version) fields out of the response before
# comparing/committing -- see flow/erc_report_trim.py's own header comment.
python3 "$SCRIPT_DIR/erc_report_trim.py" "$RAW_REPORT" "$GENERATED_REPORT"

# Freshness cross-check: there is no `klt erc --check` verb (unlike
# `klt drc --check`, which flow/drc.sh uses for this role), so this script
# performs the same content-hash re-verification itself -- the regenerated
# report's provenance block must hash-pin exactly the committed GDS and
# the committed spec it claims to describe. `klt erc` content-hashes the
# raw input files (sha256), so both sides are recomputed here, not trusted.
python3 - "$GENERATED_REPORT" "$COMMITTED_GDS" "$COMMITTED_SPEC" <<'PYEOF'
import hashlib, json, sys
report, gds, spec = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(report))
def sha256(path):
    return "sha256:" + hashlib.sha256(open(path, "rb").read()).hexdigest()
problems = []
pin_gds = doc.get("provenance", {}).get("input", {}).get("content_hash")
pin_spec = doc.get("provenance", {}).get("spec", {}).get("content_hash")
actual_gds, actual_spec = sha256(gds), sha256(spec)
if pin_gds != actual_gds:
    problems.append(f"input content_hash {pin_gds!r} != committed GDS {actual_gds!r}")
if pin_spec != actual_spec:
    problems.append(f"spec content_hash {pin_spec!r} != committed spec {actual_spec!r}")
if problems:
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    sys.exit(1)
print(f"    provenance: report pins committed GDS ({actual_gds[:19]}...) and committed spec ({actual_spec[:19]}...)")
PYEOF

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
    echo "       layout or spec changed (or the flow is non-reproducible) without regenerating the report -- run '$0 --update' and commit the result" >&2
    exit 1
fi

echo "=== committed ERC report matches regenerated output (reproducible, findings-recorded-as-found, fresh) ==="
