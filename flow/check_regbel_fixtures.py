#!/usr/bin/env python3
"""Metadata check for the registered-BEL fixtures (issue #156, EXPERIMENTAL).

Proves from the committed fixture metadata (not from the mapper's intent) that
each of BEL A, B, C and D is exercised in registered mode, with its placement
pinned explicitly: for every letter L, sim/bitstream/corpus/regbel_<l>_s1 must

  * be listed in index.txt with the `regbel` oracle,
  * have a mapped.json with exactly one cell, `lut4_ff_bel`, ff == "1",
    bel == X1Y1/<L>,
  * route real EN and SR nets into that BEL (pins X1Y1/<L>.EN and .SR are each
    the sink of a net with pips) and drive q from X1Y1/<L>.O,
  * have a wiring manifest whose only BEL line is the index of <L> (A=0..D=3),
  * have a source that pins the BEL with NEXTPNR_BEL and corpus.json entries
    that require the same placement.

Usage: check_regbel_fixtures.py [repo-root]   (exit 1 with a message on any defect)
"""
import json
import re
import sys
from pathlib import Path

LETTERS = "ABCD"
STEM = "regbel_{l}_s1"


def check(repo):
    repo = Path(repo)
    fx = repo / "sim" / "bitstream" / "corpus"
    cj = json.loads((repo / "design/fabulous/corpus/corpus.json").read_text())
    cases = {c["name"]: c for c in cj["cases"]}
    idx = {}
    for line in (fx / "index.txt").read_text().splitlines():
        if line.strip():
            k, v = line.split()
            idx[k] = v
    errs = []
    for i, L in enumerate(LETTERS):
        stem = STEM.format(l=L.lower())
        bel = f"X1Y1/{L}"
        if idx.get(stem) != "regbel":
            errs.append(f"{stem}: not listed in index.txt with oracle regbel")
        c = cases.get(f"regbel_{L.lower()}")
        if not c or c.get("placement") != {bel: "FF"}:
            errs.append(f"{stem}: corpus.json does not require placement {{{bel}: FF}}")
        src = (repo / f"design/fabulous/corpus/regbel_{L.lower()}.v").read_text()
        if not re.search(rf'NEXTPNR_BEL\s*=\s*"{bel}"', src):
            errs.append(f"{stem}: source does not pin NEXTPNR_BEL = {bel}")
        try:
            m = json.loads((fx / f"{stem}.mapped.json").read_text())
            wiring = (fx / f"{stem}.wiring").read_text().split("\n")
        except OSError as e:
            errs.append(f"{stem}: {e}")
            continue
        cells = m["cells"]
        if len(cells) != 1 or cells[0].get("type") != "lut4_ff_bel" \
                or cells[0].get("bel") != bel or cells[0].get("ff") != "1":
            errs.append(f"{stem}: cells {cells} != one registered lut4_ff_bel on {bel}")
        sinks = {p for n in m["nets"] if n.get("pips") for p in n["pins"]}
        for pin in ("EN", "SR", "O"):
            if f"{bel}.{pin}" not in sinks:
                errs.append(f"{stem}: no routed net on {bel}.{pin}")
        bels = [l for l in wiring if l.startswith("BEL ")]
        if bels != [f"BEL {i}"]:
            errs.append(f"{stem}: wiring BEL lines {bels} != ['BEL {i}']")
        for w in ("IN en ", "IN rst ", "OUT q "):
            if not any(l.startswith(w) for l in wiring):
                errs.append(f"{stem}: wiring lacks '{w.strip()}'")
    return errs


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    errs = check(repo)
    if errs:
        for e in errs:
            print("error: " + e, file=sys.stderr)
        print("regbel fixture metadata: FAIL", file=sys.stderr)
        return 1
    print("regbel fixture metadata: PASS (BEL A, B, C, D each a single registered lut4_ff_bel "
          "pinned via NEXTPNR_BEL; EN, SR and O routed; wiring BEL index matches)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
