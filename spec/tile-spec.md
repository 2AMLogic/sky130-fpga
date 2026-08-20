# Tile spec (DRAFT): LUT4-class logic tile + demonstration fabric

- **Status**: Draft — ratified enough to unblock RTL/tile-description work
  under #1; individual parameters may still tighten once physical design
  (`spec/framework-gaps.md` items G2–G3) and timing characterization (item
  G4) return real data.
- **Framework**: FABulous tile/fabric description format (see
  `spec/decisions/0001-fabric-framework-choice.md`).
- **Scope discipline**: this spec covers exactly **one logic tile type plus
  a 2×2 to 4×4 demonstration fabric**. Anything beyond that — more tile
  types, a bigger fabric, additional hard IP — is explicitly out of scope
  for this issue and for the repo until the tile itself is verified
  (DRC/LVS-clean, timing-characterized). See "Out of scope" below and
  `CLAUDE.md`.

## Summary table

| Parameter | Target | Rationale |
|---|---|---|
| LUT count per tile | 4 × LUT4 | Standard eFPGA "CLB-class" grouping; large enough to be a meaningful PnR/DRC/LVS stress case (the canary's actual job — see `CLAUDE.md`), small enough to keep the first physical-design pass tractable. |
| FF arrangement | 1 FF per LUT, output-only (4 FFs/tile) | Simplest per-LUT register that keeps every LUT independently combinational-or-registered; matches the common FABulous-style "LUT + optional output FF" slice. Each FF: single shared clock domain per tile, per-FF clock-enable, shared async/sync reset (reset style TBD at RTL time). |
| Carry support | **No** dedicated carry chain in v1 | Deliberate scope cut, not an oversight (see "Carry: rationale" below). |
| Switch matrix routing | Per-tile local switch matrix; **4 general-purpose routing tracks per tile edge** (N/E/S/W), FABulous-style sparse (Wilton-class) switch box connecting BEL pins to tracks and tracks to neighboring tiles | Track count chosen as a minimal but non-trivial routing fabric — enough to route the 2×2–4×4 demo fabric's expected designs without being a large PnR search space for a first tile. Exact switch population (which track connects to which BEL pin) is generated from the FABulous tile description, not hand-specified here. |
| Physical routing pitch | Deferred to physical design (see note below) | "Pitch" for a switch matrix has both an architectural meaning (track count, above) and a physical-layout meaning (metal pitch on sky130). Only the architectural target is ratified here; the physical metal-layer pitch is a `layout/` deliverable, tracked as `spec/framework-gaps.md` item G3. |
| Tile I/O | BEL pins (4× LUT4 in, 4× LUT4/FF out) + 4 edges × 4 tracks of general routing + tile config/bitstream port | Standard FABulous tile boundary shape: BEL-level ports plus routing-track ports per edge. |
| Fabric size (demonstration) | 2×2 to 4×4 tile grid, single tile type, bitstream-programmable | Matches README's "Target specification" table; smallest grid that exercises inter-tile routing without growing scope. |
| Bitstream | Fully documented, open format, generated via the FABulous flow | No proprietary or undocumented bitstream fields — verification (`sim/`) depends on being able to construct and inspect bitstreams directly. |
| Timing | No numbers in this spec | FABulous's own docs mark BEL timing as placeholder-constant; this repo publishes no timing claim until it is backed by characterized sky130 data (`spec/framework-gaps.md` item G4). |

## LUT count per tile: 4× LUT4

A tile groups **4 independent 4-input LUTs (LUT4)**. This is the "LUT4-class"
logic element named in the issue title, sized as a small CLB-style cluster
rather than a single bare LUT:

- Large enough that the tile is a genuine place-and-route and physical-design
  stress case — the point of this canary (`CLAUDE.md`: "a dense, regular
  logic tile is exactly the kind of workout `klt par` exists to be stressed
  by").
- Small enough that DRC/LVS signoff and timing characterization for the
  *first* tile pass stay tractable — this repo's stated maturity ladder puts
  "tile layout DRC/LVS-clean" and "tile timing characterized" before fabric
  assembly, and a smaller tile gets there faster.

## FF arrangement: 1 FF per LUT, output-only

Each LUT4 has exactly one associated flip-flop on its output, selectable
(via bitstream configuration) between registered and combinational LUT
output — the standard "LUT + optional output register" slice shape. No
input-side or mid-chain FFs in v1.

- All 4 FFs in a tile share one clock domain and one reset, each with an
  independent clock-enable — this is a minimal-but-real per-LUT register
  file rather than a single shared register, while avoiding a
  multi-clock-domain tile for the first physical design pass.
- Reset style (sync vs. async, active level) is an RTL-level decision, not
  fixed by this spec; it must not add a second clock-tree topology to the
  tile before the tile is characterized.

## Carry support: No (v1)

**Decision: no dedicated carry chain in the first tile.** This is a
deliberate scope cut, not an omission:

- The canary's success criterion is a DRC/LVS-clean, timing-characterized
  tile and a working demonstration fabric — not arithmetic performance.
  Carry logic adds tile area, inter-tile carry-chain routing (which
  couples adjacent tiles' physical design together), and additional BELs
  to characterize, all before the base tile itself is verified.
- FABulous-based fabrics (including STRIVE-class designs) commonly do
  include carry logic; omitting it here is a repo-scope decision, not a
  claim that carry is unsupportable in this framework. Once the base tile
  is DRC/LVS-clean and characterized, adding a carry chain is a natural,
  well-scoped follow-on tile revision — explicitly **not** this issue's or
  this repo's current-phase work (see "Out of scope").

## Switch matrix / routing pitch target

Two distinct things are both called "pitch" here, and only one is ratified
by this spec:

1. **Architectural target (ratified here): 4 general-purpose routing tracks
   per tile edge**, in a FABulous-style per-tile local switch matrix (a
   sparse/Wilton-class switch box, not a full crossbar) connecting the
   tile's BEL pins to routing tracks and routing tracks to the corresponding
   tracks on neighboring tiles. Four tracks per edge is chosen as the
   minimum that gives nextpnr real routing choices for the 2×2–4×4
   demonstration fabric without generating a large switch matrix on the
   first physical-design pass. The exact per-track switch population (which
   BEL pin/track connects to which other track) is a generated artifact of
   the FABulous tile description (`spec/framework-gaps.md` item G1), not
   hand-specified in this document.
2. **Physical layout pitch (NOT ratified here — deferred)**: the actual
   metal-layer routing pitch used inside the switch matrix on sky130 (which
   metal layer(s), minimum track pitch in µm) is a `layout/` decision made
   during physical design against the ratified sky130 PDK design rules, not
   an architectural spec parameter. We do not commit to a specific µm value
   in this document — see `spec/framework-gaps.md` item G3 for that
   follow-on work item. Treat any pitch number quoted informally elsewhere
   before that item lands as provisional.

## Fabric (demonstration): 2×2 to 4×4, single tile type

The demonstration fabric is a grid of 2×2 to 4×4 instances of **the one
tile type defined above**, bitstream-programmable, per the README's target
spec. No I/O tile, clock tile, or second logic-tile type is defined by this
spec — see "Out of scope."

## Out of scope (explicitly, for this issue and until the tile is verified)

Per `CLAUDE.md`, the following are **not** part of this spec and proposals
to add them are declined until the base tile is DRC/LVS-clean and
timing-characterized:

- Fabric larger than 4×4 tiles.
- Additional tile types (I/O tiles, BRAM/DSP tiles, clock-distribution
  tiles, a second logic-tile variant).
- Carry chain logic (see "Carry support" above) — tracked as a natural
  follow-on once the base tile is verified, not scoped here.
- Any timing number not backed by characterized sky130 data
  (`spec/framework-gaps.md` item G4).
- A specific physical routing-pitch (µm) commitment for the switch matrix
  (`spec/framework-gaps.md` item G3).
