#!/usr/bin/env python3
"""flow/sdf_canonicalize.py

Canonicalize a `klt place-and-route --post_route_sdf`-written IEEE-1497 SDF
file so two runs of the identical, seeded request are byte-identical: the
only volatile field OpenSTA's `write_sdf` stamps is the header's `(DATE
...)` line (the SDF sibling of `flow/sta_sanitize_names.py`'s
`_CANONICAL_SPEF_DATE` rewrite for the SPEF header, and of the same
wall-clock-timestamp family as klayout-tools#1627 for `klt extract --spef`).

Usage:
    sdf_canonicalize.py <input.sdf> <output.sdf>
"""

from __future__ import annotations

import re
import sys

_DATE_RE = re.compile(r'^(\s*)\(DATE\s+"[^"]*"\)\s*$')
_CANONICAL_DATE_LINE = ' (DATE "canonicalized (see flow/sdf_canonicalize.py)")'


def canonicalize(text: str) -> str:
    out_lines = []
    for line in text.split("\n"):
        if _DATE_RE.match(line):
            out_lines.append(_CANONICAL_DATE_LINE)
        else:
            out_lines.append(line)
    return "\n".join(out_lines)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <input.sdf> <output.sdf>", file=sys.stderr)
        return 1
    input_path, output_path = argv[1], argv[2]
    with open(input_path, encoding="utf-8") as f:
        text = f.read()
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(canonicalize(text))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
