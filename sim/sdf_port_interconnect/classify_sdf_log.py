#!/usr/bin/env python3
"""classify_sdf_log.py -- per-`INTERCONNECT`-entry applied/rejected verdicts.

Reads a hand-written case SDF and the `vvp` transcript of the run that
annotated it, and prints one line per `INTERCONNECT` entry saying whether
Icarus applied it.

Why a parser and not `vvp`'s exit status (issue #250): `vvp` exits 0 after
skipping an annotation it could not apply. The only in-band signal is the
transcript, where Icarus prints

    VPI error: Could not insert intermodpath!
    SDF ERROR: <sdf-path>:<line>: Could not find intermodpath!

The `SDF ERROR` form carries the offending SDF line number, so messages are
attributed to entries by line rather than by order or by count -- which also
keeps the benign header diagnostics out of the per-entry verdicts. The
fixture's `(VOLTAGE 1.800::1.800)` / `(TEMPERATURE 25.000::25.000)` triples
have no typ value, so `-T typ` emits `Chosen value not defined.` for them on
every run; those are header lines, not entries, and are reported separately
as notes. The committed logic_tile SDF has the same `min::max` header form,
so this is the same benign noise the real flow produces.

The unnumbered `VPI error:` lines are counted too: they are the VPI-side half
of the same failure and their count must agree with the number of entries
whose own `SDF ERROR` line reported a missing intermodpath. A disagreement is
surfaced rather than hidden, because it would mean the attribution is wrong.

Usage:
    classify_sdf_log.py --sdf <case.sdf> --log <vvp transcript>
    classify_sdf_log.py --sdf <case.sdf> --log <...> --verdict-only
"""

from __future__ import annotations

import argparse
import re
import sys

# `(INTERCONNECT <source> <destination> (<delay>))`, captured with the
# 1-based line number it sits on.
_INTERCONNECT_RE = re.compile(r"\(\s*INTERCONNECT\s+(\S+)\s+(\S+)\s")

# `SDF ERROR: /abs/path/case.sdf:18: Could not find intermodpath!`
# `SDF WARNING: /abs/path/case.sdf:18: <...>`
_SDF_MSG_RE = re.compile(r"^SDF (ERROR|WARNING):\s+(?P<path>[^:]*):(?P<line>\d+):\s*(?P<text>.*)$")

# The VPI-side half of the same failure; carries no line number.
_VPI_ERR_RE = re.compile(r"^VPI error:\s*(?P<text>.*)$")

# Texts that mean "this entry was not annotated". Matched case-insensitively
# as substrings so a future Icarus wording change in punctuation does not
# silently turn a rejection into an "applied".
_REJECT_MARKERS = (
    "could not find intermodpath",
    "could not insert intermodpath",
    "could not find module instance",
    "unable to find",
)


def parse_entries(sdf_path: str) -> list[tuple[int, str, str]]:
    entries = []
    with open(sdf_path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, start=1):
            match = _INTERCONNECT_RE.search(line)
            if match:
                entries.append((lineno, match.group(1), match.group(2)))
    return entries


def parse_log(log_path: str) -> tuple[dict[int, list[str]], list[str], list[str]]:
    """-> (messages keyed by SDF line, header/unattributed messages, VPI errors)."""
    by_line: dict[int, list[str]] = {}
    unattributed: list[str] = []
    vpi_errors: list[str] = []
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            match = _SDF_MSG_RE.match(line)
            if match:
                by_line.setdefault(int(match.group("line")), []).append(line)
                continue
            vpi = _VPI_ERR_RE.match(line)
            if vpi:
                vpi_errors.append(line)
                continue
            if line.startswith(("SDF ERROR", "SDF WARNING")):
                unattributed.append(line)
    return by_line, unattributed, vpi_errors


def is_rejection(message: str) -> bool:
    lowered = message.lower()
    return any(marker in lowered for marker in _REJECT_MARKERS)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdf", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument(
        "--verdict-only",
        action="store_true",
        help="print a single APPLIED/REJECTED/MIXED verdict for the whole case",
    )
    args = parser.parse_args(argv[1:])

    entries = parse_entries(args.sdf)
    if not entries:
        print(f"error: no INTERCONNECT entries found in {args.sdf}", file=sys.stderr)
        return 2

    by_line, unattributed, vpi_errors = parse_log(args.log)

    verdicts = []
    lines_out = []
    rejected_lines = set()
    for lineno, source, destination in entries:
        messages = by_line.get(lineno, [])
        rejects = [m for m in messages if is_rejection(m)]
        if rejects:
            verdict = "REJECTED"
            rejected_lines.add(lineno)
        else:
            verdict = "APPLIED"
        verdicts.append(verdict)
        detail = ""
        if messages:
            detail = "  | " + " ; ".join(
                m.split(": ", 1)[1] if ": " in m else m for m in messages
            )
        lines_out.append(
            f"{verdict:8s} line {lineno:>3d}  {source} -> {destination}{detail}"
        )

    if args.verdict_only:
        unique = set(verdicts)
        print("MIXED" if len(unique) > 1 else verdicts[0])
        return 0

    for line in lines_out:
        print(line)

    # Header-level diagnostics: real, printed on every run, and NOT per-entry
    # verdicts. Reported so the transcript is fully accounted for.
    entry_lines = {lineno for lineno, _, _ in entries}
    header_messages = [
        m for lineno, msgs in sorted(by_line.items()) if lineno not in entry_lines
        for m in msgs
    ]
    for message in header_messages:
        print(f"NOTE     {message}  (SDF header line, not an INTERCONNECT entry)")
    for message in unattributed:
        print(f"NOTE     {message}  (no SDF line number attributed)")

    if len(vpi_errors) != len(rejected_lines):
        print(
            f"NOTE     {len(vpi_errors)} unnumbered 'VPI error' line(s) vs "
            f"{len(rejected_lines)} line-attributed rejection(s) -- counts disagree, "
            f"attribution may be incomplete"
        )
    elif vpi_errors:
        print(
            f"NOTE     {len(vpi_errors)} unnumbered 'VPI error' line(s), matching the "
            f"{len(rejected_lines)} line-attributed rejection(s)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
