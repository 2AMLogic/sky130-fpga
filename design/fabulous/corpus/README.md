# Single-tile routability corpus (issue #115)

**EXPERIMENTAL decision evidence for ADR-0004 item 3.** It records what the
pinned yosys + nextpnr flow does with a small, explicit set of designs on the
single-LOGIC4 harness *as implemented*. It does **not** make the item 3
decision (same-index vs Wilton-class), does not ratify ADR-0004/0005, does not
amend `spec/`, and does not change the fabric, the pad overlay or any signoff
artifact. ADR-0004 stays **Proposed** with its recommendation unchanged; it
links here only as supporting evidence.

## What was measured, and under which constraints

- Fabric: the generated G1 LOGIC4 model with the current same-index switch
  matrix (4 tracks per edge), the current `CAP_*` terminators (loopbacks) and
  the scratch pad overlay of `flow/nextpnr_io_overlay.py` (8 pads: A-D on
  `X1Y0`, A-D on `X1Y2`). No inter-tile routing and no timing content.
- Mapper: FABulous 2.2.0, OSS CAD Suite 2026-10-08 (yosys 0.69+260,
  nextpnr-0.11.1-54-g861c57be), `flow/tool_versions.sh`. nextpnr's default
  router (router1), seeds below, wall-clock budget 60 s per run.
- **Harness pad constraints are part of every result.** Each case pins its
  ports to pads in a `.pcf` (inputs on `X1Y0`, outputs on `X1Y2`, as for
  `top_io`/`top_reg`). A different pad assignment could change an outcome; the
  corpus does not search pad assignments. Capacity: 8 pads, 4 BELs.
- Corpus size is deliberately small: 5 new cases x seeds 1-3, plus the two
  existing baseline designs (`top_io`, `top_reg`) at nextpnr's default seed 0
  (so they reproduce the committed `sim/bitstream/top_*` fixtures byte for
  byte).

## Cases (logical expectations written before mapping)

| case | source | intended shape (checked on the synthesized netlist) | functional oracle |
|------|--------|------------------------------------------------------|-------------------|
| `base_io` (baseline) | `../nextpnr/top_io.v` | 2 LUT BELs | `comb`, issue #74 |
| `base_reg` (baseline) | `../nextpnr/top_reg.v` | 1 LUT + 1 FF BEL, 1 internal net | `reg`, issue #74 |
| `quad4` | `quad4.v` | four distinct 4-input functions of a,b,c,d: 4 LUT BELs, no internal nets | exhaustive truth tables |
| `casc2` | `casc2.v` | `((a^b^c^d)&e)^f`: 2 LUTs, 1 LUT-to-LUT net (CAP loopback) | exhaustive over 6 inputs |
| `fan4` | `fan4.v` | input `a` shared by 4 LUTs (pad-net fanout 4), 4 BELs | exhaustive |
| `casc_fan` | `casc_fan.v` | shared parity LUT feeding 3 second-stage LUTs: 4 LUTs, one internal net with fanout 3 | exhaustive |
| `regcasc` | `regcasc.v` | 2 LUTs + FF BEL, EN/SR from pads, 2 internal nets | exhaustive state x vector + 300 random cycles vs. a reference register |

The topology check (`corpus.json` `topology`, computed by
`flow/corpus_run.py` from the yosys JSON before nextpnr runs) fixes LUT/FF
counts, the number of LUT-to-BEL nets, their maximum fanout and the maximum
pad-net fanout. A synthesis result that is simpler (or different) than
intended is `topology_mismatch`, a failure of the run, never evidence. The
oracles in `sim/tb_logic_tile_bitstream.v` are written from the source
`.v` files, not from mapper output.

## Results (record: `results.txt`, append-only)

| case | seed 1 | seed 2 | seed 3 | BELs used (seeds 1/2/3 or 0) |
|------|--------|--------|--------|------------------------------|
| `base_io` (seed 0) | success | | | A,D |
| `base_reg` (seed 0) | success | | | FF on A, LUT on C |
| `quad4` | success | success | success | A,B,C,D |
| `casc2` | success | success | success | A+C / A+B / C+D |
| `fan4` | route_nonconvergent | route_nonconvergent | route_nonconvergent | - |
| `casc_fan` | success | success | success | A,B,C,D |
| `regcasc` | success | **route_nonconvergent** | success | FF B, LUT C+D (seeds 1,3) |

Every `success` has: a real FASM from nextpnr, a bitstream assembled by
`flow/fasm_to_bitstream.py` that is byte-identical to FABulous's own
`bit_gen genBitstream`, and a simulation of that stream through the frame
loader model into `logic_tile_routed` against the case's oracle, with
configuration-perturbation checks (all perturbations detected in every run;
see `results.txt` for counts) and a loader/decoder/record `cfg` cross-check.
Committed fixtures: `sim/bitstream/corpus/` (11 streams, re-simulated by
`./sim/run.sh`). `route_nonconvergent` rows have **no bitstream and no
functional claim**.

### Outcome classes

- `success` - routed; verified end to end as above.
- `route_fail` - nextpnr reported the design unroutable (none observed).
- `capacity_packing` - nextpnr could not pack/place (none observed; the
  classifier is unit-tested in `flow/test_corpus_run.py`).
- `route_nonconvergent` - nextpnr packed and placed the design, entered
  routing, and still had unrouted arcs when the 60 s budget expired. nextpnr's
  default router has no iteration cap (it rips up and re-routes indefinitely),
  so this is *bounded-effort* evidence of non-convergence, **not a proof of
  infeasibility**. Unrouted arcs at the last progress report: 3 (`fan4`, all
  seeds), 1 (`regcasc` seed 2).
- `synthesis_error`, `topology_mismatch`, `tool_error`, `sim_fail` - failures
  of the run (missing tools, crashes, unrecognised diagnostics, synthesis
  simplification, simulation not passing). They are never recorded as
  routability measurements and make `flow/corpus.sh` exit non-zero.

## Observations (facts) and hypotheses (labelled)

Facts, within the scope above:
1. All four LUT BELs can be used at once with distinct functions (`quad4`,
   `casc_fan`), and a LUT-to-LUT cascade routes through the `CAP_*` loopbacks
   (`casc2`, `casc_fan`, `regcasc`); the bitstreams run correctly in the
   simulated tile, including the loopback paths.
2. Pad-signal routes may use a loopback as a route-through (for example
   `casc_fan` seed 3 sends input pads through `W1BEG -> X0Y1 -> E1END`
   before reaching the LUT inputs); the simulation and manifest model this.
3. `fan4` did not converge for any of the three seeds; `regcasc` converged for
   two of three seeds. The outcome therefore depends on the placement seed for
   at least one design.
4. One unscripted spot check (not part of the corpus and not reproduced by
   `flow/corpus.sh`): `fan4` seed 1 with `nextpnr-generic --router router2`
   also did not converge within 60 s (persistent `overused=2`).
5. A LUT pin the design leaves unconnected defaults to a switch-matrix track.
   In `casc_fan` seed 3 that track is the loopback of the same BEL's own
   output, i.e. a don't-care combinational cycle (made harmless by the
   replicated INIT). It is invisible in two-state function but holds an `X`
   forever in four-state simulation once an `X` enters it; the testbench now
   flushes the loopbacks between perturbations (see below).

Hypotheses (not demonstrated here):
- The same-index matrix lets LUT input pin `Ik` see only tracks of index `k`
  (plus loopback re-indexing through the `CAP_*`), and nextpnr's fabulous flow
  does not permute LUT input pins. In `fan4` the synthesized netlist puts
  `b`, `c` and `d` on pin I1 (and `d` also on I2) of different LUTs, whereas
  `quad4` gives every input a unique pin index; this is consistent with the
  non-convergence but was not isolated experimentally. If it is the cause, the
  limiting factor is pin-index assignment interacting with the population, and
  a Wilton-class population is not the only possible remedy (LUT pin
  permutation in the mapper flow would be another). The corpus does not
  evaluate alternatives.

## What this does and does not support

Supports: the as-implemented same-index harness can map, route, assemble and
correctly execute all-four-BEL, cascade and registered-cascade designs for the
seeds listed, and has at least one fanout shape (`fan4`) and one seed
(`regcasc` seed 2) that nextpnr could not route within the budget.

Does not support: any statement about the ratified Wilton-class population,
about routability of real designs or larger fabrics, inter-tile routing,
timing/Fmax, area or mux fan-in, or which of ADR-0004 options A/B/C to
choose. Three seeds, one router, one pad assignment per case and one yosys
netlist per case do not characterize the distribution.

## Reproduce and maintain

```bash
./flow/corpus.sh                       # needs flow/nextpnr.sh prerequisites + iverilog/vvp
./flow/corpus.sh --append-record design/fabulous/corpus/results.txt   # new dated record
./flow/corpus.sh --update              # after a deliberate evidence review: rewrite sim/bitstream/corpus
./sim/run.sh                           # committed fixtures only (iverilog + python3)
python3 flow/test_corpus_run.py        # classification unit tests (stdlib)
```

`flow/corpus.sh` exits non-zero when any observed outcome differs from the
`expect` entry in `corpus.json` **in either direction**: a recorded failure
that starts routing (new mapper, new seed behaviour, fabric change) and a
recorded success that stops routing both require an evidence review - update
`expect` and this table in the same change, and append a new record; never
edit old entries of `results.txt`. A baseline case that does not succeed also
fails the run, so an all-failed corpus cannot pass.

If a prerequisite (iverilog, Linux x64 for the OSS CAD Suite, network on the
first run) is missing, `flow/corpus.sh` exits 2 with "NOT RUN"; that is not a
result.

### Testbench changes made for this corpus (`sim/tb_logic_tile_bitstream.v`)

Existing `comb`/`reg` behaviour and counts are unchanged (5409 / 139651
checks, 26/26 and 27/27 perturbations). Added: six oracles, input slots `e`,
`f` and output slots `v`, `z`; a 100 ps transport delay on the CAP loopbacks
(so a perturbed configuration that closes a combinational cycle oscillates in
simulated time instead of hanging the simulator); a loopback flush between
perturbations (observation 5); and, for corpus designs only, a whole-table LUT
inversion in place of flipping LUT bits 0 and 1 (a single LUT entry can be
legitimately unobservable, e.g. an entry only read while a flop's EN is low,
and which entry that is depends on the placement).
