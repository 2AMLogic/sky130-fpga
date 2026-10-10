# Work Log

Chronological record of merged pull requests and closed issues, maintained by the Loom Guide role. Newest entries appear first.

### 2026-10-10

- **PR #194**: docs(flow): document gate-sim scripts and add script-to-evidence index
- **PR #191**: G5: verify generated tile clock and frame forwarding ports (#188)
- **PR #192**: Gate verification: replay route diagnostics on the synthesized tile (#189)
- **PR #190**: feat(flow): enforce append-only on sim/ evidence ledgers at PR time (#183)
- **PR #187**: feat(sim): boundary output-track source diagnostic through frame programming (#180)
- **PR #186**: feat(flow): strict ConfigMem frame adapter validation (#169)
- **PR #185**: feat(sim): control-jump directional route diagnostic through frame programming (#181)
- **Issue #193** (closed): flow/README: document gate-sim scripts and add a script-to-evidence index
- **Issue #188** (closed): G5: verify generated tile clock and frame forwarding ports
- **Issue #189** (closed): Gate verification: replay directional and control route diagnostics on the synthesized tile
- **Issue #183** (closed): Evidence: enforce append-only on sim/*results.txt ledgers at PR time
- **Issue #180** (closed): G5: verify every boundary output-track source through generated-tile frame programming
- **Issue #169** (closed): Verification: reject malformed streams in the ConfigMem frame adapter
- **Issue #181** (closed): G5: verify every directional reset and enable source through generated-tile frame programming
- **Issue #168** (closed): Guard telemetry: retain worktree-write-confinement check
- **PR #182**: Pin-index experiment: registered regcasc case with one-register transition equivalence (#160)
- **PR #179**: feat(sim): LUT-input directional route diagnostic through frame programming (#176)
- **PR #178**: Gate verification: replay the LUT-address basis against the synthesized composed tile
- **PR #175**: G5: LUT basis diagnostic, every truth-table address on every BEL through the generated tile (#172)
- **PR #174**: ci: select generated-tile differential replay on its RTL and helper dependencies
- **PR #171**: ci: trigger harness-format drift check on document and fixture changes
- **PR #167**: fix(sim): distinguish RTL mutation kills from simulator infrastructure failures
- **PR #166**: spec: draft ADR-0006 (Proposed) for mapper-side LUT pin-assignment policy
- **Issue #160** (closed): Routability: test whether the LUT pin-index confounder also explains the regcasc seed-2 non-convergence
- **Issue #176** (closed): G5: cover every LUT-input directional route through generated-tile frame programming
- **Issue #177** (closed): Gate verification: replay the LUT-address basis against the synthesized composed tile
- **Issue #163** (closed): Guard telemetry: retain stash-scope:create-redirect check
- **Issue #172** (closed): G5: prove all LUT truth-table addresses on every BEL through generated-tile frame replay
- **Issue #173** (closed): CI: select generated-tile differential replay for its RTL and runtime dependencies
- **Issue #170** (closed): CI: trigger harness-format drift checks on document and fixture changes
- **Issue #164** (closed): Verification: distinguish RTL mutation kills from simulator infrastructure failures
- **Issue #161** (closed): Spec: draft ADR-0006 (Proposed) for mapper-side LUT pin-assignment policy
- **PR #159**: Bound simulator processes; timeouts are infrastructure failures (#157)
- **PR #158**: G5: exercise registered control wiring on every generated-tile BEL (#156)
- **PR #155**: G5: replay committed streams through the integrated FABulous-generated tile
- **Issue #157** (closed): Verification: bound simulator processes and reject timeouts as infrastructure failures
- **Issue #156** (closed): G5: exercise registered control wiring on every generated-tile BEL
- **Issue #140** (closed): G5: replay committed streams through the integrated FABulous-generated tile

### 2026-10-09

- **Issue #148** (closed): Guard telemetry: retain unresolved worktree write confinement check

- **PR #151**: Evidence audit: validate supersession graphs before exempting stale hashes
- **PR #152**: fix(flow): audit nested layout reports for PDK provenance (#149)
- **PR #147**: Replay distinct-pin fan4 fixtures in RTL and gate suites (#145)
- **PR #146**: Gate-sim negative controls: require completed functional rejection (#141)
- **PR #142**: Routability: opt-in LUT pin-index experiment for fan4 (#137)
- **Issue #150** (closed): Evidence audit: validate supersession graphs before exempting stale hashes
- **Issue #149** (closed): Evidence audit: include nested experimental layout reports
- **Issue #145** (closed): G5: preserve successful pin-aligned fan4 streams for RTL and gate replay
- **Issue #144** (closed): Guard telemetry: retain raw-field body literal-at check
- **Issue #141** (closed): Verification: require completed functional rejection in gate bitstream negative controls
- **Issue #137** (closed): Routability: isolate LUT pin-index assignment in the single-tile fanout failure
- **PR #139**: G5: replay routability corpus against composed-tile gate netlist
- **PR #138**: G5: verify generated FABulous ConfigMem RTL against recorded configuration map
- **PR #134**: G6: generate as-built harness bitstream-format table with drift check
- **PR #133**: ci: run zero-delay gate-level re-sims on PRs (#130)
- **PR #128**: G5: bounded single-tile routability corpus to inform ADR-0004 (#115)
- **PR #127**: docs: single-source README status claims and add drift check (#125)
- **PR #126**: sim: RTL mutation check proving the testbenches can fail (#124)
- **Issue #135** (closed): G5: replay the routability corpus against the composed-tile gate netlist
- **Issue #136** (closed): G5: verify generated FABulous ConfigMem RTL against the recorded configuration map
- **Issue #131** (closed): G6: generate the as-built harness bitstream-format table from the config-bit map with a drift check
- **Issue #94** (closed): Guard telemetry: retain rm-scope-unresolved-var containment check
- **Issue #130** (closed): CI: run the zero-delay gate-level bitstream and routed re-sims on pull requests
- **Issue #115** (closed): G5: bounded single-tile routability corpus to inform ADR-0004
- **Issue #125** (closed): Docs: single-source README/framework-gaps status claims and add a drift check
- **Issue #124** (closed): Verification: RTL mutation check proving the sim/ testbenches can fail
- **PR #122**: docs: reconcile stale composed-tile status prose (#120)
- **PR #121**: feat(sim): gate-level bitstream-driven run on composed-tile netlist (#119)
- **PR #118**: feat(timing): experimental 18-corner STA of composed tile (G4, #113)
- **PR #116**: feat(sim): gate-level zero-delay re-sim of composed tile (#112)
- **PR #114**: feat(sim): experimental bitstream-driven single-LOGIC4 harness test (G5/G6, #74)
- **PR #111**: feat(layout): experimental DRC/LVS/ERC observations + routing pitch on composed tile (G3, #108)
- **PR #110**: ci: run flow/audit-evidence.sh on PRs (#109)
- **PR #107**: feat(layout): experimental composed-tile physical canary (G2, #102)
- **PR #106**: feat(lvs): re-enable LVS power connectivity under klt 0.7.0; T1 item 11 met (#69)
- **PR #105**: Guard generated switch-matrix RTL against drift in sim/run.sh
- **PR #104**: Verify switch-matrix RTL against FABulous; fix generator select order (#96)
- **PR #103**: docs(readme): G1 status reflects nextpnr result (#87) and Proposed ADR-0004/0005
- **PR #101**: ci: reproduce FABulous and nextpnr G1 logs on description/flow changes
- **Issue #120** (closed): Docs: reconcile composed-tile status with experimental physical and bitstream evidence
- **Issue #119** (closed): G5: run existing bitstream fixtures against the experimental composed-tile netlist
- **Issue #113** (closed): G4: multi-corner STA of the experimental composed tile (observation, separate from BEL-only row)
- **Issue #112** (closed): Gate-level zero-delay re-simulation of the experimental composed tile
- **Issue #109** (closed): CI: reproduce the klt flow check modes and flow/audit-evidence.sh on pull requests
- **Issue #108** (closed): G3: run DRC/LVS on the experimental composed-tile layout and record routing pitch
- **Issue #102** (closed): G2: produce a separate physical canary for the composed logic tile
- **Issue #99** (closed): Guard generated switch-matrix RTL against drift in sim/run.sh
- **Issue #98** (closed): README: G1 status still says nextpnr has not been run (stale since #87)
- **Issue #97** (closed): CI job to reproduce the FABulous and nextpnr G1 logs on flow/description changes
- **Issue #96** (closed): Verify the repo switch-matrix RTL against FABulous's generated switch matrix and config-bit order
- **Issue #74** (closed): G5/G6: bitstream-driven functional test and format doc for the single logic tile
- **Issue #69** (closed): T1 item 11: klayout-tools#2121 has landed — re-enable LVS power connectivity and reach power_connectivity "match"

- **PR #95**: ADR-0005: IO and constant handling for single-tile nextpnr flow (#92)
- **PR #93**: feat(rtl): composed LOGIC4 tile (BELs + switch matrix), RTL-only (#90)
- **PR #91**: G1: run pinned nextpnr on the generated LOGIC4 model (#87)
- **PR #89**: ci: run RTL testbench suite on pull requests
- **PR #88**: Generate LOGIC4 switch-matrix RTL and verify in sim/
- **PR #84**: spec: ADR-0004 for the five G1 tile-description discrepancies
- **PR #83**: docs: README and RTL headers no longer say G1 is open (#79)
- **PR #81**: feat(timing): cite a multi-corner klt sta envelope for T1 item 5 (#68)
- **Issue #92** (closed): Decision record: IO and constant-driver handling for the single-tile nextpnr bitstream flow
- **Issue #90** (closed): Compose the tile: instantiate the switch matrix with the BELs and verify the composed RTL in sim/
- **Issue #87** (closed): G1 follow-up: run nextpnr on the generated LOGIC4 model (startable subset of #74)
- **Issue #86** (closed): CI: run sim/run.sh testbenches on every PR and main push
- **Issue #85** (closed): CI: run the existing tile RTL regression suite on pull requests
- **Issue #79** (closed): Docs: README and RTL headers still say G1 is open after #73 closed it
- **Issue #78** (closed): Tile switch matrix: generate RTL from the FABulous description and verify it in sim/
- **Issue #77** (closed): spec: write decision record for the five G1 tile-description discrepancies (ADR-0004)
- **Issue #68** (closed): T1 item 5: re-run the 18-corner timing sweep under a klt sta that emits timing_status, and cite it

### 2026-10-08

- **PR #76**: feat(design): pin FABulous 2.2.0 and commit LOGIC4 tile description (G1)
- **PR #75**: docs(measurements): re-try SDF-annotated leg after klayout-tools#1890 closed; still BLOCKED (#72)
- **PR #71**: feat(signoff): bind T1 items 1, 2, 9, 10 to audited artifacts
- **Issue #73** (closed): G1: pin FABulous and commit a tile description for the logic tile
- **Issue #72** (closed): Re-run the SDF-annotated gate-level leg now that klayout-tools#1890 is closed
- **Issue #67** (closed): T1 items 1, 2, 9, 10: bind each to its audited artifact now that klayout-tools#2718 has landed

### 2026-09-22

- **PR #64**: feat: drop git-history-derived stamps from the characterization summary
- **Issue #61** (closed): Drop git-history-derived "Committed at" stamps from the characterization summary generator (decision per #57 item 4)

### 2026-09-21

- **PR #62**: docs: refresh post-ADR-0003 staleness in traceability row 12, measurements README and ADR index
- **PR #60**: feat: add klt signoff block manifest and graded T1 tier report
- **PR #58**: docs: match flow prose to post-#1901 PDK pins; add lvs trigger
- **PR #59**: spec: re-ratify timing row WNS from post-PDN STA record (ADR-0003)
- **PR #56**: fix: point layout/README's ERC run block at the surviving spec path
- **PR #55**: fix: add the logic tile's power grid and substantiate the T1 item-4 claim with real power-connectivity evidence
- **PR #54**: feat: add klt erc supply spec and committed ERC report (T1 item 11)
- **Issue #57** (closed): Post-ADR-0003 freshness pass: claim-traceability row 12, measurements/README timing section, spec/README ADR index
- **Issue #53** (closed): flow/audit-evidence.sh is red on main: record 20260915-133517-234b13b's pinned flow/sdf-resim.sh hash drifted (PRs #46/#47)
- **Issue #52** (closed): Commit a klt signoff block manifest so this block's T1 state is graded, not hand-read
- **Issue #49** (closed): klt toolchain drift: repo pins klt 0.3.0, environment has 0.5.0 — drc/lvs/layout check modes fail on metadata-only diffs
- **Issue #42** (closed): Re-ratify spec/tile-spec.md's Timing row against the PDN-bearing layout (ADR-0003)
- **Issue #50** (closed): klt lvs power_connectivity reports VPB reaching 12 nets across 47 instances — real PDN gap or abstracted-cell extraction artifact?
- **Issue #41** (closed): logic_tile.gds has no power grid (15 isolated met1 rails, 0 straps/vias/tapcells) — the LVS 'match' is signal-only and README cites it for T1 item 4
- **Issue #51** (closed): T1 item 11 (power delivery, structural): no klt erc supply spec or report in this repo

### 2026-09-18

- **PR #48**: refactor: deduplicate PDK_ROOT resolution across flow/*.sh
- **PR #46**: fix: resolve_icarus13() no longer mistakes a found-on-PATH result for not-found
- **PR #47**: Single-source the klt place-and-route request across layout.sh/sdf-resim.sh
- **Issue #45** (closed): Deduplicate PDK_ROOT resolution block across flow/*.sh (mirrors #15)
- **Issue #43** (closed): flow/sdf-resim.sh rejects a PATH-resolved Icarus 13 (resolve_icarus13 conflates 'found on PATH' with 'not found')
- **Issue #44** (closed): The klt place-and-route request is hand-duplicated in flow/layout.sh and flow/sdf-resim.sh; only a byte-diff catches a divergence

### 2026-09-15

- **PR #40**: audit: trace every published claim to a committed harness + pinned PDK (#34)
- **PR #38**: docs: refresh README status line to reflect current tile state
- **PR #37**: feat(measurements): aggregated characterization summary (T1 item 8)
- **PR #36**: fix: guard merge-pr.sh champion:hold-state extraction against set -e abort
- **PR #32**: feat: SDF-annotated gate-level re-simulation of the routed tile
- **PR #30**: spec: ratify tile timing spec row from PR #22 STA record (ADR-0002)
- **Issue #4** (closed): Track the gap to T1 sim-validated / bronze (klayout-tools design-evidence tiers)
- **Issue #34** (closed): [Epic #4] T1 item 9: testbenches-shipped / pinned-PDK audit
- **Issue #39** (closed): Remove stale 'just opened' status line in README.md
- **Issue #35** (closed): [Epic #4] T1 item 10: repo hygiene — README status refresh
- **Issue #33** (closed): [Epic #4] T1 item 8: aggregated characterization report
- **Issue #31** (closed): merge-pr.sh: _check_champion_hold_state_staleness aborts merge (set -e + pipefail + grep -o no-match)
- **Issue #29** (closed): [Epic #4] T1 item 7: SDF-annotated gate-level re-simulation
- **Issue #28** (closed): [Epic #4] T1 item 5: ratify tile timing spec rows (decision record)

### 2026-09-12

- **PR #27**: Update README maturity-ladder — timing characterization landed
- **Issue #26** (closed): README maturity-ladder 'Current position' is stale again — timing characterization landed (#20 closed, PR #22 merged) but README still says 'in progress'

### 2026-09-10

- **PR #25**: fix: surface klt/OpenROAD toolchain version drift in flow check mode
- **PR #22**: G4 timing characterization: 18-corner klt sta sweep of the committed routed tile with extracted (SPEF) parasitics
- **PR #24**: docs: update maturity-ladder Current position to reflect landed rungs
- **Issue #23** (closed): flow/sta-sweep.sh and flow/layout.sh check mode report spurious non-reproducibility on a newer klt/OpenROAD install
- **Issue #20** (closed): G4 timing characterization: multi-corner `klt sta` sweep of the committed routed tile with extracted (SPEF) parasitics, recorded under `measurements/`
- **Issue #21** (closed): README maturity-ladder 'Current position' is stale — still says RTL work not started
