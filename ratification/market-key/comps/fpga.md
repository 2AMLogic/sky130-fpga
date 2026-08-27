# fpga comp data (generated, public-sources-only)

Generated 2026-08-27 from the upstream comp library's `fpga.md` entry by an internal, private-repo-only tool. This is a derived, filtered copy — regenerate rather than hand-edit. Every row below cites a public vendor datasheet or a public distributor pricing page; nothing internal survived extraction.

## Comparable parts

| Reference | Type | Granularity | What it shows | Source |
|---|---|---|---|---|
| FABulous "STRIVE-lineage" sky130 CLB (`FPGA-Research/eFPGA---RTL-to-GDS-with-SKY130`, Apache-2.0, public) | Open-source eFPGA fabric — **same framework (FABulous) and same PDK (sky130)** as our tile | `LUT4AB` macro: 8× LUT4 + integrated switch matrix per tile (1440 LUT4 total across 180 such tiles, per the repo's own README) | Post-place-and-route macro LEF (Cadence Innovus, file dated 2021-04-22): `SIZE 230.46 BY 229.84` µm = 0.05297 mm² per 8-LUT4 tile → **0.00662 mm² per LUT4**, switch matrix included | LEF: [`common/LEFfile/LUT4AB.lef`](https://github.com/FPGA-Research/eFPGA---RTL-to-GDS-with-SKY130/blob/main/UoM_eFPGA/common/LEFfile/LUT4AB.lef). Fabric ID: [FABulous chip gallery](https://fabulous.readthedocs.io/en/latest/gallery/index.html) ("eFPGA_STRIVE_sky130: 1440 LUT4s + 180 LUT5s") |
| Lattice iCE40 UltraPlus UP5K / UP3K | Standalone commercial small-FPGA family (packaged chip, not IP or a fabric source) | Whole-device LUT count, no per-tile breakdown published | 5280 (UP5K) / 2800 (UP3K) 4-input LUTs; 48-pin QFN 7×7 mm or 30-ball WLCSP 2.15×2.55 mm **package** footprint (not die area). No public per-LUT die area or price found this pass — see Re-verify | [Lattice iCE40 UltraPlus product page](https://www.latticesemi.com/en/Products/FPGAandCPLD/iCE40UltraPlus) (device selection table) |

