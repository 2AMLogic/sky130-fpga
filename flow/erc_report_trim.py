#!/usr/bin/env python3
"""flow/erc_report_trim.py

Reduce a `klt erc --format json` response to the stable subset committed as
`layout/logic_tile.erc.json` evidence: the full connectivity model
(`gates[]`, `levels[]`), the `erc_findings` list, the coverage blocks, and
content-addressed provenance (input/spec hashes), with tool-version fields
that change on a toolchain upgrade alone -- without any layout change --
stripped out.

Why strip those: `provenance.klt_version` and `provenance.klayout_version`
are bare tool-version strings, not part of the input/spec content
addressing. Mirrors `flow/drc_report_trim.py`'s identical rationale (see
that file's header comment): upgrading klt/KLayout alone should not produce
a spurious diff against the committed report. The content hashes that DO
address what the report claims about -- `provenance.input.content_hash`
(the analysed GDS) and `provenance.spec.content_hash` (this repo's
supply spec) -- are retained, and `flow/erc.sh` re-verifies both against the
committed files on every run, so dropping the version strings does not
weaken the freshness check.

Everything else -- status, erc_status, erc_findings, gates, coverage,
erc_coverage -- is retained unchanged (findings included: the committed
finding set is the evidence this report exists to record; see
`layout/README.md`'s "ERC scope, concretely" section).

Usage:
    erc_report_trim.py <response.json> <output.json>
"""

import sys

from _report_trim import run_cli, strip_nested

_DROP_PROVENANCE = ("klt_version", "klayout_version")


def trim(response: dict) -> dict:
    return strip_nested(response, "provenance", _DROP_PROVENANCE)


def main(argv: list) -> int:
    return run_cli(argv, trim)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
