# Roadmap

sky130-fpga delivers one verified, DRC/LVS-clean, timing-characterized LUT4-class
logic tile on SkyWater sky130, plus a small demonstration fabric, built with
klayout-tools and the open yosys + nextpnr + FABulous flow.

**Status as of 2026-11-14, `main` @ `515714f`.**

[`WORK_PLAN.md`](WORK_PLAN.md) is the generated view of issue labels,
[`spec/framework-gaps.md`](spec/framework-gaps.md) the narrative for gaps G1 to
G6, and [`signoff/tier-report.json`](signoff/tier-report.json) the graded
verdict of record. Where they disagree with this file, they win.

This file is unguarded prose. It carries none of the drift markers that
`flow/check_status_claims.py` enforces, and sits outside that script's `DOCS`
tuple, so the markered documents (`README.md`, `spec/framework-gaps.md`) win on
every number they guard — including `t1-met`, `t1-items`, `adr-0004` and
`corner-count`, which this file restates for narrative continuity only. The
issue and PR states below are a snapshot of the date above; `WORK_PLAN.md` is
the live view.

## Where it stands

On the README's maturity ladder, the rungs through "tile timing characterized"
are done for the BEL-only tile, bitstream-level tests exist only as an
experimental single-tile harness, and the later rungs are not started.

T1 evidence tier, graded by `klt signoff` 0.8.0: **9 of 11 items met, 1 not
applicable, 1 unmet.**

| Item | State | Evidence |
|---|---|---|
| 1 Design sources, 9 Testbenches shipped, 10 Repo hygiene | met | `signoff/item-{1,9,10}-inventory.json` (PR #237) |
| 2 Layout, 3 DRC clean, 4 LVS clean | met | `layout/logic_tile.{gds,drc.json,lvs.json}` |
| 5 Full corner verification | met | 18 corners, record `20261027-201500-9111a08` (PR #233) |
| 6 Monte Carlo evidence | not applicable | `signoff/item-6-not-applicable.json` (PR #214) |
| 7 Post-layout verification | **unmet** (`no_evidence`) | zero-delay leg passes; SDF-annotated leg has no citable run (#213) |
| 8 Characterization report | met | `measurements/characterization-summary.md` |
| 11 Power delivery (structural) | met | `layout/logic_tile.erc.json` |

Framework gaps: G1 largely closed (FABulous 2.2.0 pinned, nextpnr accepts the
model). G2 to G4 are closed for the BEL-only tile and *experimental only* for
the composed tile with the stand-in switch matrix (`layout/experimental/`,
`measurements/timing-characterization-experimental/`). G5 and G6 are open:
the harness format is documented (`design/bitstream-format.md`) and exercised,
the ratified fabric and inter-tile routing are not.

Two facts changed since the status text in `README.md` and
`spec/framework-gaps.md` was last written:

- **The committed layout no longer reproduces.** `flow/layout.sh` under the
  current klt and OpenROAD gives a physically different placement and routing
  from the committed klt-0.5.0 layout (45 of 47 logic cells moved, all 137 nets
  rerouted), which gates #162 and #213: record
  `measurements/layout-reproducibility/records/20261107-213000-9e83907.md`.
- **The upstream gap cited for item 7 has closed.**
  [klayout-tools#2897](https://github.com/2AMLogic/klayout-tools/issues/2897)
  closed on 2026-10-18. The retry here (record `20261017-sdf-sanitize-d811bcd`,
  PR #215) had shown that renaming escaped identifiers removes the simulator
  abort and that two obstacles remain: the layout drift above, and 28
  `INTERCONNECT` entries sourced from top-level input ports that are not applied.

## Now

1. **Isolate the port-sourced `INTERCONNECT` rejection without place-and-route.**
   Done when a hand-written minimal netlist + SDF reproducer under `sim/` shows
   whether Icarus Verilog 13 applies an `INTERCONNECT` delay whose source is a
   top-level input port, and a record states the cause and whether a tool-side
   or flow-side remedy exists. Needs only Icarus. Tracked as #250; feeds #213.
2. **Bring the status text in line with the two facts above.** Done when
   `README.md`, `spec/framework-gaps.md`, `signoff/README.md`,
   `measurements/README.md` and `sim/README.md` no longer name
   klayout-tools#2897 as the open blocker for item 7 and instead name the
   layout drift and the port-sourced `INTERCONNECT` finding, with
   `flow/check_status_claims.py` and `./flow/audit-evidence.sh` passing.
   Tracked as #251.
3. **Measure the regenerated layout under the pinned `klayout-tools==0.8.0`.**
   The #245 record used a development build and did not run DRC, LVS, ERC or
   the STA sweep on the regenerated layout. Done when a successor record under
   `measurements/layout-reproducibility/records/` reports those four results
   for the regenerated layout, with nothing under `layout/` changed. Needs a
   host that can run OpenROAD. Tracked as #252. This is the input to the
   decision under "Blocked and waiting".

## Next

- **Bound `flow/sdf-resim.sh` with `SIM_TIMEOUT_SECONDS`** (#162). Done per the
  issue's acceptance list. Unblocked once the layout decision below gives the
  script a geometry it can reproduce.
- **T1 item 7: SDF-annotated post-route run** (#213). Done when the tier report
  grades item 7 `met` from an envelope with `environment.sdf.annotated: true`.
  Blocked by #162, by the layout decision, and by the outcome of Now item 1.
  This is the last unmet T1 item.
- **Composed-tile binding path** (#117). Done when a new record under
  `measurements/timing-characterization-experimental/records/` names the worst
  path per corner with the 158 `cfg` bits excluded. The upstream capability
  has landed; the issue is held until an OpenROAD execution route completes
  the 18-corner runs.
- **Raw LVS reference netlists** (#216, PR #217). Done when both the as-built
  and routed LVS checks pass on unsanitized reference netlists and
  `flow/lvs_sanitize_verilog.py` is removed. Held on the same OpenROAD
  execution route; PR #217 currently conflicts with `main`.

## Later (each waits on the question it states)

- **Ratified composed tile (G2 to G4).** Which switch-matrix topology is the
  fabric's? ADR-0004 is Proposed; the composed-tile layout and timing stay
  experimental until it is ruled on.
- **Physical routing pitch (G3 item a).** What pitch does the spec commit to?
  The observed pitch in `layout/README.md` is an input; no decision record yet.
- **Bitstream verification of the ratified fabric, including inter-tile
  routing on the 2×2 demonstration grid (G5).** Depends on ADR-0004 and
  ADR-0005. Is an experimental 2×2 harness on the stand-in matrix worth
  building before those are ruled on, or is that fabric growth ahead of the
  tile?
- **Bitstream format document for the ratified fabric (G6).** Follows G5.
- **Characterized BEL timing model, propagated-clock and bisected-Fmax
  analysis (G4).** Which geometry is the one of record (the layout decision)?

## Blocked and waiting

- **Layout of record: re-layout and re-stamp, or freeze.** The #245 record
  leaves two choices: regenerate the layout with the current toolchain and
  re-stamp every dependent report and pin, or keep the klt-0.5.0 geometry as
  frozen evidence with its toolchain pinned. The ratified timing row in
  `spec/tile-spec.md` quotes a figure from the committed geometry (ADR-0003),
  so a re-layout ends in a re-ratification. No issue is filed for it yet.
- **ADR-0004, ADR-0005, ADR-0006** are Proposed, pending operator ratification.
- **OpenROAD execution route** for #117 and #216 (see those issues).
- **PR #63** (dependency update policy) is open with no review label; #3 and
  #65 are housekeeping holds (#82 closed on 2026-11-14).

Of the 12 open issues, 7 carry `loom:blocked`. The five that do not are the
three Now items — #250 (`loom:triage`), #251 and #252 (both `loom:curated` and
estimated) — plus #253 and #255, two code-simplification issues already
promoted to `loom:issue` and drawable as they stand. The Now items are filed:
they need execution, not re-filing. `WORK_PLAN.md` is the authority on what is
drawable at any later date.

## Not planned

- A production-size FPGA, more tile types, a carry chain in v1, or wider
  routing: fabric growth before the tile is verified is declined (`CLAUDE.md`).
- Evidence tiers above T1: the grader reports them as `tier_not_supported`.
