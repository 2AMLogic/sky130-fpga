# ADR-0007: A small standalone-FPGA configuration is out of scope for now

- **Status**: Proposed — pending operator ratification. Same
  ratification-via-PR policy as ADR-0002..0006. **No spec file is edited**;
  nothing here authorizes a build, adds a tile type, or grows the fabric —
  it records a scoping decision and the evidence behind it.
- **Date**: 2026-11-19
- **Decided by**: Builder (issue #325)
- **Related**: #325 (this issue), `CLAUDE.md` (scope discipline: "the tile is
  the scope, not the FPGA"), [`spec/tile-spec.md`](../tile-spec.md),
  [ADR-0004](0004-g1-tile-description-discrepancies.md) (switch-matrix
  topology, Proposed),
  [ADR-0005](0005-nextpnr-io-and-constant-handling.md) (IO as harness-only
  overlay),
  [`spec/framework-gaps.md`](../framework-gaps.md) items G5–G6,
  #162/#213 (layout reproducibility), #102 (experimental composed tile)

## Question

The parts of this fabric that draw public interest are tiny standalone
FPGAs: a few hundred to about a thousand LUTs with I/O in a small package.
Is a standalone configuration of this fabric on sky130 worth specifying,
and what would it need? This record decides that question; it is not a
commitment to build anything.

## Decision

**Out of scope for now.** The indicative sizing below shows area is not the
obstacle — a 256–1024-LUT array extrapolates to roughly 0.35–1.4 mm² of tile
array on sky130, which a small package can hold. The obstacle is that none of
the evidence a standalone part would rest on exists yet: the ratified fabric
has never been assembled, and the tile at its centre is not fully verified.
Specifying a standalone configuration now would be fabric growth ahead of the
tile, which `CLAUDE.md` declines explicitly.

### What it waits on

A standalone record becomes worth writing when, first, the ratified
demonstration fabric (2×2–4×4) exists at all — inter-tile routing and the
bitstream path are open gap items G5/G6 with only an experimental
single-tile harness so far — and the tile itself is verified, which means
T1 item 7 (SDF-annotated post-layout verification) closed and the committed
layout reproducing under the current toolchain (#162, #213); second, the
switch-matrix topology decision (ADR-0004, still Proposed) lands, because the
only composed-tile area measurement uses the stand-in same-index matrix and
is labelled experimental for exactly that reason; and third, because a
standalone part needs what the ratified spec deliberately does not contain —
I/O and configuration/control tile types, configuration storage with a load
path, and a pad ring/package decision — a future "in scope" record would have
to specify and independently verify each of those as its own spec change, so
the prerequisite list is the tile-plus-demo-fabric verification ladder, not
one missing component.

### Indicative sizing (extrapolation, not a claim)

Recorded so the "is it worth it" question has numbers attached. **Every
figure here is an extrapolation of a measured tile; none is a claim about a
built part, and no standalone configuration has been characterized for
timing** (per the issue, timing characterization of a standalone
configuration is out of scope; no timing claim is made or implied).

| Quantity | Value | Source (file, date) |
|---|---|---|
| LUT4s per tile | 4 | `spec/tile-spec.md` summary table, "LUT count per tile" row (as of `7fa81b8`, 2026-11-17) |
| Target LUT range | 256–1024 LUTs → **64–256 tiles** | issue #325's "a few hundred to about a thousand LUTs", divided by 4 LUTs/tile |
| Composed tile, die | 5527.18 µm² (core 4754.56 µm², 43.7% utilization) | `layout/experimental/logic_tile_routed.par.json`, landed `84a5927` 2026-10-09 (klt 0.7.0, OpenROAD 26Q3-1510, issue #102) — **experimental**, stand-in same-index matrix |
| BEL-only tile, die | 1965.15 µm² (core 1523.96 µm²) | `layout/logic_tile.par.json`, post-PDN record landed `0054e5e` 2026-09-21 — the committed deliverable, but it contains **no switch matrix** |
| Tile-array area, extrapolated | **≈ 0.35 mm² (64 tiles) to ≈ 1.4 mm² (256 tiles)** | 64/256 × 5527.18 µm², linear scaling of the composed-tile die figure |

Method and uncertainty: linear extrapolation of the one measured composed-tile
die area across tile count; it excludes everything a real part adds beyond
the tile array (I/O tiles, configuration storage and its load path, pad ring,
package, clocking distribution) and ignores die-edge and aspect-ratio effects.
Two further caveats bound it: the stand-in same-index switch matrix is not
the ratified Wilton-class population (ADR-0004 Proposed — a richer matrix
changes per-tile area), and the composed measurement sits at 43.7% utilization
so a denser pass could shrink it. Treat the range as an order-of-magnitude
answer: **the area is not the blocker; the missing verified fabric is.**

I/O count and configuration storage/load path are deliberately **not
specified** here: naming them is the job of an "in scope" record, and writing
them now would imply a fabric shape the repo has not ratified.

### Sibling canaries

The two sibling FPGA canaries carry this same question in their own
repositories. This record answers only this repo's question and is **not**
declared shared: no cross-linked records exist in the sibling repos (they
were not examined for this issue). If those repos adopt a matching record,
cross-link all three and revisit the shared-answer wording at that point.

## Consequences

- No RTL, tile, fabric, pad-ring, package, or bitstream-loader change
  accompanies this record; `spec/tile-spec.md` and `spec/tile-spec.json` are
  untouched, and no ratified requirement is relaxed.
- The waits-on list above is the re-entry condition: once it clears, a new
  decision record owns the in-scope case — LUT count, I/O count,
  configuration storage and load path, and implied area derived from
  then-current measurements (with their own commit citations), not from the
  extrapolation in this record.
- Nothing in this record creates a timing, routability or area claim for any
  standalone configuration; the sizing table is context, not evidence of a
  buildable part.
