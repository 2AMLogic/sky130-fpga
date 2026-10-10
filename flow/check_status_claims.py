#!/usr/bin/env python3
"""Drift check for status claims quoted in README.md / spec/framework-gaps.md
(issue #125). stdlib only; reads committed files, needs no toolchain.

Markdown carries explicit markers, one per machine-checkable fact:

    <!-- status-claim: adr-0004=Proposed -->

Each marker is compared with the committed source of truth. Prose is never
parsed beyond these enumerated facts. Keys:

  adr-0004, adr-0005, adr-0006
                       first word of the ADR's `- **Status**:` line
  drc, lvs             `status` in layout/logic_tile.{drc,lvs}.json
  corner-count         N in "setup/hold-clean at all N corners"
                       (measurements/characterization-summary.md)
  binding-corner       "binding setup corner `X`" (same summary)
  t1-met               t1_met_count in signoff/tier-report.json
  t1-items             t1_item_count in signoff/tier-report.json

README.md must carry every key at least once (so deleting a marker is a
failure, not a silent pass). Exit 0 iff every marker holds.

    python3 flow/check_status_claims.py [--root DIR]
"""
import argparse
import json
import re
import sys
from pathlib import Path

DOCS = ("README.md", "spec/framework-gaps.md")
MARKER = re.compile(r"<!--\s*status-claim:\s*([A-Za-z0-9_.-]+)\s*=\s*(.*?)\s*-->")
SUMMARY = "measurements/characterization-summary.md"


def _adr_status(root, num, fname):
    text = (root / "spec/decisions" / fname).read_text()
    m = re.search(r"^- \*\*Status\*\*:\s*([A-Za-z]+)", text, re.M)
    if not m:
        raise ValueError(f"no '- **Status**:' line in {fname}")
    return m.group(1)


def _json(root, rel):
    return json.loads((root / rel).read_text())


def _summary_re(root, pattern):
    m = re.search(pattern, (root / SUMMARY).read_text())
    if not m:
        raise ValueError(f"pattern {pattern!r} not found in {SUMMARY}")
    return m.group(1)


def truth(root):
    """key -> zero-arg callable returning the authoritative value (str)."""
    return {
        "adr-0004": lambda: _adr_status(root, 4, "0004-g1-tile-description-discrepancies.md"),
        "adr-0005": lambda: _adr_status(root, 5, "0005-nextpnr-io-and-constant-handling.md"),
        "adr-0006": lambda: _adr_status(root, 6, "0006-lut-pin-assignment-policy.md"),
        "drc": lambda: str(_json(root, "layout/logic_tile.drc.json")["status"]),
        "lvs": lambda: str(_json(root, "layout/logic_tile.lvs.json")["status"]),
        "corner-count": lambda: _summary_re(root, r"setup/hold-clean at all (\d+) corners"),
        "binding-corner": lambda: _summary_re(root, r"binding setup corner `([^`]+)`"),
        "t1-met": lambda: str(_json(root, "signoff/tier-report.json")["t1_met_count"]),
        "t1-items": lambda: str(_json(root, "signoff/tier-report.json")["t1_item_count"]),
    }


def check(root):
    """Return a list of error strings (empty == all claims hold)."""
    root = Path(root)
    truths = truth(root)
    errors, seen = [], set()
    for doc in DOCS:
        p = root / doc
        if not p.exists():
            errors.append(f"{doc}: missing")
            continue
        for n, line in enumerate(p.read_text().splitlines(), 1):
            for key, val in MARKER.findall(line):
                if key not in truths:
                    errors.append(f"{doc}:{n}: unknown status-claim key {key!r}")
                    continue
                if doc == "README.md":
                    seen.add(key)
                try:
                    actual = truths[key]()
                except (OSError, ValueError, KeyError) as e:
                    errors.append(f"{doc}:{n}: cannot derive {key!r}: {e}")
                    continue
                if val != actual:
                    errors.append(f"{doc}:{n}: claim {key}={val!r} but source says {actual!r}")
    for key in sorted(set(truths) - seen):
        errors.append(f"README.md: required marker {key!r} is missing")
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    errs = check(ap.parse_args(argv).root)
    for e in errs:
        print(f"FAIL {e}", file=sys.stderr)
    if not errs:
        print("status-claims: all markers match their sources")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
