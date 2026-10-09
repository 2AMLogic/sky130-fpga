# timing-characterization-experimental

**Stand-in matrix, ADR-0004 Proposed -- observation, not spec.**

Multi-corner extracted-parasitics STA of the EXPERIMENTAL composed tile
`logic_tile_routed` (4x `lut4_slice` + the generated stand-in
`logic_tile_switch_matrix`; `layout/experimental/logic_tile_routed.{def,gds}`,
issue #102). Issue #113, framework gap G4 (composed-tile half). It sits
beside, and is deliberately separate from, the ratified BEL-only evidence in
`../timing-characterization/`, which contains no switch matrix.

```
logic_tile_routed.sta.json                  18-corner pdk.corners envelope (trimmed klt sta response)
logic_tile_routed.spef                      the (name-sanitized) SPEF both annotate; pins spef_sha256
corners/<corner>/lef-only.sta.json          per-corner, unannotated (LEF pin caps only)
corners/<corner>/spef.sta.json              per-corner, SPEF-annotated
records/<YYYYMMDD-HHMMSS>-<sha>.md          append-only records
```

Reproduce: `./flow/sta-sweep.sh --routed` (check mode: re-extracts, re-times
all 18 corners x {LEF-only, SPEF} plus the one multi-corner request, and
diffs against the committed files; exit 0 iff identical and every SPEF run
annotated completely). `./flow/sta-sweep.sh --routed --update` regenerates.
The committed SPEF carries the extractor's `*VERSION` header, so check mode
is exact only under the `klt` build named in the latest record (the BEL-only
check behaves the same way under a drifted build; see `flow/README.md`).
The 18 corners are the ratified `sky130_fd_sc_hd` set the BEL-only sweep uses.

## What is measured

`timing_status` is recorded per corner exactly as in #68: every corner
reports `"constrained"` (the numbers are real measurements, not the `1e+39`
unconstrained sentinel). Each SPEF run has `annotation_complete: true`
(325/325 nets), and the name-rewrite neutrality control (unannotated committed
DEF vs. unannotated rewritten DEF) holds at every corner.

Constraints differ from the BEL-only sweep in one respect: ideal clock `clk`,
20 ns reference period, **plus `input_delay_ns: 0` and `output_delay_ns: 0`**
on all non-clock inputs/outputs. With a clock-only SDC every port-to-port
path is unconstrained; with zero delays, `worst_slack_ns` reads as
`20 ns - (longest boundary-constrained path)`, i.e. the longest of
input->register, register->output and input->output paths. These delays are
a reference convention, not an interface spec.

Headline observations (see the record for the full table): tt_025C_1v80
worst boundary path about 2.64 ns (WNS 17.3558 ns); the slowest corner
`ss_n40C_1v28` shows WNS **-4.6838 ns** with 16 setup-violating endpoints
(longest boundary path about 24.7 ns against the 20 ns reference), and
`ss_n40C_1v35` is the next-slowest at +3.498 ns. Hold slack is positive but
small (0.055 to 0.38 ns) at every corner.

## What is NOT claimed

- **Not spec.** `spec/tile-spec.md` timing rows and ADR-0002/0003 are
  untouched. The ratified BEL-only criteria (setup/hold-clean at 20 ns,
  18 corners) are NOT claimed for the composed tile; the 20 ns period is a
  reference, and a negative slack at the slowest corner here is a recorded
  observation, not a failure of anything ratified. Promoting any figure needs
  a decision record, as ADR-0002/0003 did for the BEL-only row.
- **Stand-in matrix.** The topology (same-index) is ADR-0004 Proposed. If
  ADR-0004 is ratified differently, these numbers are invalidated and must be
  regenerated.
- **Worst-path identity is not known.** `klt sta` reports metrics, not the
  path. Configuration inputs (`cfg[...]`, a quasi-static 158-bit port) are
  also non-clock inputs and so are timed as if toggling every cycle; a
  config-bit -> track-output path is not a datapath and may be what binds. So
  the figure is NOT "a BEL-input-to-output path through the matrix" until
  path-level reporting/exclusion exists (filed upstream, generically: 2AMLogic/klayout-tools#2968; SPEF hierarchy-name mismatch: #2969).
- **Single-tile only.** No abutment, no inter-tile wire, no clock
  distribution (ideal clock, `clock_skew_ns` 0), no input slew/drive or
  output load model beyond the LEF pin capacitances.
- `fmax_mhz` is a `1/(T-WNS)` extrapolation from boundary slack, not a
  bisected or fabric Fmax. Parasitics are `klt extract` first-order lumped RC.
- No SDF/gate-level simulation, no bitstream-level timing test, and nothing
  here is cited by `signoff/`.
