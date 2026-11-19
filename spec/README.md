# spec

Ratified tile/fabric spec + decision records.

- [`decisions/0001-fabric-framework-choice.md`](decisions/0001-fabric-framework-choice.md)
  — decision record: adopt the FABulous tile/fabric description format.
- [`decisions/0002-tile-timing-spec-ratification.md`](decisions/0002-tile-timing-spec-ratification.md)
  — decision record: ratify `tile-spec.md`'s Timing row from the original
  18-corner STA characterization (setup/hold-clean at all corners; no Fmax
  ratified).
- [`decisions/0003-tile-timing-spec-re-ratification.md`](decisions/0003-tile-timing-spec-re-ratification.md)
  — decision record: re-ratify the Timing row's SPEF WNS figure of record
  (15.1760 → 15.2146 ns) from the post-PDN successor STA record; ADR-0002's
  claim shape and no-Fmax carve-out stay in force.
- [`decisions/0004-g1-tile-description-discrepancies.md`](decisions/0004-g1-tile-description-discrepancies.md)
  — decision record: proposed rulings on the five discrepancies between the
  G1 tile description and the ratified spec.
- [`decisions/0005-nextpnr-io-and-constant-handling.md`](decisions/0005-nextpnr-io-and-constant-handling.md)
  — decision record: proposed handling of IO and constant drivers in the
  single-tile nextpnr bitstream flow.
- [`decisions/0006-lut-pin-assignment-policy.md`](decisions/0006-lut-pin-assignment-policy.md)
  — decision record: proposed mapper-side LUT pin-assignment policy for the
  harness flow.
- [`decisions/0007-standalone-fpga-configuration.md`](decisions/0007-standalone-fpga-configuration.md)
  — decision record: a small standalone-FPGA configuration is out of scope
  for now, with what it waits on and an indicative area extrapolation from
  the measured composed tile.
- [`tile-spec.md`](tile-spec.md) — draft LUT4-class tile spec (LUT count, FF
  arrangement, carry support, switch-matrix routing target) and the
  2×2–4×4 demonstration fabric target.
- [`framework-gaps.md`](framework-gaps.md) — concrete work items a sky130
  tile implementation needs that FABulous does not provide (physical
  design, DRC/LVS, timing characterization, bitstream-level verification),
  for follow-on issues.
