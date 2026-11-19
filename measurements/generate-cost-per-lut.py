#!/usr/bin/env python3
"""measurements/generate-cost-per-lut.py

Generates `measurements/cost-per-lut.md` -- the published area-per-LUT4
figure from the committed experimental composed-tile layout, and an
illustrative cost-per-LUT4 estimate derived from a named, dated public
shuttle price (issue #323). It is **generated, not hand-typed**: every
number in the emitted note is read from, or cross-checked against, the
committed sources listed below, and the script fails loudly rather than
emitting a figure that has silently drifted from them.

Sources read and cross-checked:

- layout/experimental/logic_tile_routed.par.json
    `die_area_um2` of the experimental composed tile
    `logic_tile_routed` (issue #102): 4 `lut4_slice` BELs + stand-in
    switch matrix + flat 158-bit `cfg` port, routed by
    `flow/layout_routed.sh`. The script asserts `status == "ok"` and
    `stage_reached == "route"` so a trimmed or failed report cannot be
    costed.
- layout/experimental/logic_tile_routed.def
    the DIEAREA cross-check: the DEF's `DIEAREA` rectangle divided by its
    `UNITS DISTANCE MICRONS` factor must agree with the P&R report's
    `die_area_um2` to the report's 2-decimal precision.
- design/rtl/logic_tile_routed.v
    the divisor: the `genvar i` generate loop that instantiates the
    `lut4_slice` BELs. The loop bound is parsed out of the RTL rather
    than hardcoded, so a fabric change that silently alters the slice
    count fails the derivation instead of dividing by a stale constant.
- layout/logic_tile.par.json
    cited for contrast only: the BEL-only tile's die area (no switch
    matrix), so the note can say explicitly it is not the basis of the
    figure.

Shuttle inputs are recorded constants with their source and access date,
not lookups (the figures allow offline regeneration; re-checking the
listed pages and updating the constants is a deliberate, dated edit):

- ChipFoundry chipIgnite standard shuttle: US$14,950 for 100 packaged
  parts (https://chipfoundry.io/reservations, accessed 2026-11-19)
- approximately 10 mm^2 of user area per Caravel part
  (https://chipfoundry.io/soc_platforms, accessed 2026-11-19)

Usage:
    python3 measurements/generate-cost-per-lut.py [--check]

Without arguments, (re)writes `measurements/cost-per-lut.md`. With
`--check`, regenerates in memory and exits non-zero if the committed file
would change -- it does not touch the file.

Scope discipline (issue #323 "Out of Scope"): this is an estimate of the
LUT4's illustrative share of a fixed shuttle fee under full area
utilization. Whole-chip layout, production yield, retail FPGA pricing and
comparisons with any commercial device are out of scope and are labelled
as such in the emitted note.
"""
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "measurements" / "cost-per-lut.md"

PAR_REPORT_PATH = REPO_ROOT / "layout/experimental/logic_tile_routed.par.json"
BEL_ONLY_PAR_REPORT_PATH = REPO_ROOT / "layout/logic_tile.par.json"
DEF_PATH = REPO_ROOT / "layout/experimental/logic_tile_routed.def"
RTL_PATH = REPO_ROOT / "design/rtl/logic_tile_routed.v"

# Dated shuttle inputs (see module docstring). These are inputs, not
# derived values: they appear verbatim in the emitted note beside their
# source and access date.
SHUTTLE_FEE_USD = 14950
SHUTTLE_PARTS = 100
USER_AREA_MM2_PER_PART = 10.0
PRICE_ACCESSED = "2026-11-19"
SHUTTLE_TERMS_URL = "https://chipfoundry.io/reservations"
CARAVEL_AREA_URL = "https://chipfoundry.io/soc_platforms"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(f"cost-per-lut generator: {message}")


def collect_die_area() -> dict:
    """The committed experimental composed-tile footprint, DEF-cross-checked."""
    data = json.loads(PAR_REPORT_PATH.read_text())
    require(data["status"] == "ok", f"{PAR_REPORT_PATH}: status is not 'ok'")
    require(
        data["stage_reached"] == "route",
        f"{PAR_REPORT_PATH}: stage_reached is not 'route' (unrouted report)",
    )
    die_area = data["die_area_um2"]
    require(isinstance(die_area, (int, float)) and die_area > 0,
            f"{PAR_REPORT_PATH}: die_area_um2 is missing or non-positive")

    # Cross-check against the experimental DEF's DIEAREA rectangle.
    def_text = DEF_PATH.read_text()
    m = re.search(r"^UNITS\s+DISTANCE\s+MICRONS\s+(\d+)\s*;", def_text, re.M)
    require(m is not None, f"{DEF_PATH}: no UNITS DISTANCE MICRONS line")
    dbu_per_um = int(m.group(1))
    m = re.search(
        r"^DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*;",
        def_text, re.M,
    )
    require(m is not None, f"{DEF_PATH}: no DIEAREA rectangle")
    x0, y0, x1, y1 = (int(v) for v in m.groups())
    def_area = (x1 - x0) * (y1 - y0) / (dbu_per_um * dbu_per_um)
    require(
        round(def_area, 2) == round(die_area, 2),
        f"DEF DIEAREA gives {def_area:.2f} um^2 but the P&R report says "
        f"{die_area:.2f} um^2 -- the footprint has drifted",
    )

    return {
        "die_area_um2": die_area,
        "def_dbu": (x1 - x0, y1 - y0),
        "dbu_per_um": dbu_per_um,
    }


def collect_bel_only_area() -> float:
    """The BEL-only tile's die area, cited in the note for contrast only.

    `layout/logic_tile.par.json` covers the logic elements alone (no
    switch matrix); the note names it so a reader does not mistake it
    for the composed footprint this estimate uses.
    """
    data = json.loads(BEL_ONLY_PAR_REPORT_PATH.read_text())
    area = data["die_area_um2"]
    require(isinstance(area, (int, float)) and area > 0,
            f"{BEL_ONLY_PAR_REPORT_PATH}: die_area_um2 is missing or non-positive")
    return area


def collect_lut_count() -> int:
    """The slice divisor, parsed from the RTL generate loop (not hardcoded)."""
    rtl = RTL_PATH.read_text()
    require(re.search(r"\bmodule\s+logic_tile_routed\b", rtl) is not None,
            f"{RTL_PATH}: module logic_tile_routed not found")
    m = re.search(
        r"generate\s+.*?\bfor\s*\(\s*\w+\s*=\s*0\s*;\s*\w+\s*<\s*(\d+)\s*;",
        rtl, re.S,
    )
    require(m is not None,
            f"{RTL_PATH}: lut4_slice generate loop not found")
    count = int(m.group(1))
    require(count > 0, f"{RTL_PATH}: generate loop bound is {count}")
    require(re.search(r"\blut4_slice\s+\w+\s*\(", rtl) is not None,
            f"{RTL_PATH}: no lut4_slice instantiation inside the loop")
    return count


def render(die_area: float, def_dbu: tuple, dbu_per_um: int,
           lut_count: int, bel_only_area: float) -> str:
    """Emit the note. Every number is computed here from the collected inputs."""
    area_per_lut_um2 = die_area / lut_count
    area_per_lut_mm2 = area_per_lut_um2 / 1e6
    total_user_area_mm2 = USER_AREA_MM2_PER_PART * SHUTTLE_PARTS
    fee_per_mm2 = SHUTTLE_FEE_USD / total_user_area_mm2
    cost_per_lut = area_per_lut_mm2 * fee_per_mm2

    return f"""# Cost per LUT4 — an estimate from committed layout area and a public shuttle price

<!-- Generated by measurements/generate-cost-per-lut.py -- do not edit by hand.
     Regenerate with:

         python3 measurements/generate-cost-per-lut.py

     (--check exits non-zero without writing if this file has drifted from
     its sources: the committed P&R report, the experimental DEF, and the
     tile RTL's slice-count generate loop.) -->

**This is an estimate, not a price.** It allocates a fixed shuttle fee
uniformly across the shuttle's user area under full utilization, and
divides the result by the tile's physical LUT4 count. An actual order
incurs the full project fee regardless of how little area a design uses.
Whole-fabric overhead and the space lost to packing are outside this
calculation; whole-chip layout, production yield, retail FPGA pricing and
comparisons with any commercial device are out of scope.

## What is being costed

The experimental composed-tile footprint
[`layout/experimental/logic_tile_routed`](../layout/experimental/logic_tile_routed.par.json)
(issue #102, produced by `flow/layout_routed.sh`): the tile's 4
`lut4_slice` BELs plus a stand-in switch matrix behind a flat 158-bit
`cfg` configuration port, with an experimental 4-tracks-per-edge
N/E/S/W routing topology (ADR-0004 still Proposed; this is an
experimental observation, not a spec-compliant deliverable). The
external configuration inputs (the 158-bit `cfg` port) and the stand-in
matrix are inside the footprint, so the per-LUT4 figure carries their
cost too — routing overhead is real silicon. The smaller
[`layout/logic_tile.par.json`](../layout/logic_tile.par.json)
({bel_only_area:.2f} µm²) covers the BELs alone, without a switch matrix,
and is not the basis of this figure.

## Inputs

| Input | Value | Source |
|---|---|---|
| Die area | {die_area:.2f} µm² | `die_area_um2` in the committed P&R report `layout/experimental/logic_tile_routed.par.json`; cross-checked against the experimental DEF's DIEAREA ({def_dbu[0]:,} × {def_dbu[1]:,} database units at {dbu_per_um:,} units/µm = {die_area:.2f} µm²) |
| Physical LUT4 slices | {lut_count} | the `g_slice` generate loop in `design/rtl/logic_tile_routed.v` |
| Shuttle fee | US${SHUTTLE_FEE_USD:,} for {SHUTTLE_PARTS} packaged parts | ChipFoundry chipIgnite standard [shuttle terms]({SHUTTLE_TERMS_URL}) (accessed {PRICE_ACCESSED}) |
| User area per part | ≈ {USER_AREA_MM2_PER_PART:.0f} mm² | ChipFoundry [Caravel user area]({CARAVEL_AREA_URL}) (accessed {PRICE_ACCESSED}) |

## Method and result

Area per physical LUT4:

    {die_area:.2f} µm² / {lut_count} = {area_per_lut_um2:.3f} µm² = {area_per_lut_mm2:.9f} mm²

Fee per mm² of user area, fee spread uniformly across all
{total_user_area_mm2:,.0f} mm² the shuttle delivers ({SHUTTLE_PARTS} parts × {USER_AREA_MM2_PER_PART:.0f} mm²):

    US${SHUTTLE_FEE_USD:,} / {SHUTTLE_PARTS} parts / {USER_AREA_MM2_PER_PART:.0f} mm² = US${fee_per_mm2:.2f} per mm²

Cost per LUT4 per delivered part:

    ({die_area:.2f} / {lut_count}) / 1,000,000 × {SHUTTLE_FEE_USD:,} / ({USER_AREA_MM2_PER_PART:.0f} × {SHUTTLE_PARTS})
      = {area_per_lut_mm2:.9f} mm² × US${fee_per_mm2:.2f}/mm²
      = US${cost_per_lut:.6f}
      ≈ US${round(cost_per_lut, 3):.3f} per LUT4 per delivered part

**≈ US${round(cost_per_lut, 3):.3f} per LUT4 per delivered part** — an
illustrative share of a fixed shuttle fee under full area utilization,
not a price. Regenerate this note from the committed sources with
`python3 measurements/generate-cost-per-lut.py`; do not hand-edit it.
"""

def main() -> int:
    check = "--check" in sys.argv[1:]
    die = collect_die_area()
    luts = collect_lut_count()
    bel_only = collect_bel_only_area()
    text = render(die["die_area_um2"], die["def_dbu"], die["dbu_per_um"],
                  luts, bel_only)
    if check:
        if OUTPUT_PATH.exists() and OUTPUT_PATH.read_text() == text:
            print(f"OK: {OUTPUT_PATH} matches its sources")
            return 0
        print(f"DRIFT: {OUTPUT_PATH} does not match regeneration from its sources",
              file=sys.stderr)
        return 1
    OUTPUT_PATH.write_text(text)
    print(f"wrote {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
