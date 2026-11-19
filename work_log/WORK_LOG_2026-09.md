# Work Log Archive — 2026-09

Sections moved byte-for-byte from [WORK_LOG.md](../WORK_LOG.md) by `loom-daemon work-docs archive`.

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
