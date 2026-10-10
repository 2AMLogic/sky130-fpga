# LUT pin-index experiment (issue #137)

EXPERIMENTAL, opt-in, separate from the corpus. It tests one hypothesis from
`README.md` ("Hypotheses"): that `fan4` fails to route because the synthesized
netlist puts the same signal on different LUT input pin indices while the
harness switch matrix is same-index. It changes neither `corpus.json`, any
expectation, any committed fixture, the fabric model nor the spec, and it does
not ratify or pre-empt ADR-0004.

Run: `./flow/pin_experiment.sh [--export-fixtures] [--append-record design/fabulous/corpus/pin_experiment_results.txt]`
(same prerequisites as `flow/corpus.sh`); unit tests: `python3 flow/test_pin_experiment.py`.
Results are appended to `pin_experiment_results.txt`; old records are never edited.

## Design

Held fixed per trial: the `fan4` source, the pcf (pad assignment), the BEL
count (4 LUTs), the logical truth tables, the fabric model, the router
(nextpnr default), seeds 1-3 and the 60 s wall-clock budget. Varied: only
which LUT input pin each net and each INIT bit uses.

* `baseline`: the unchanged synthesized netlist.
* `variant-consistent`: every input net keeps one pin index in all LUTs
  (greedy colouring by fanout, then net id; nets sharing a LUT get different
  indices).
* `variant-distinct`: stricter; every input net gets its own pin index, so no
  two input nets share an index (the shape `quad4` has).

Pin connections are permuted per cell together with the exact INIT
permutation. Dangling undriven nets and unconnected pins on narrow LUTs are
don't-care pins and are moved freely; the check proves they stay don't-care.
Conflicts (a net needing a fifth index, one net on two pins) leave the cell
unchanged and are logged; none occurred for `fan4`. Before routing, the
variant must pass an exhaustive equivalence check (every cell over all
connected-net assignments, and the whole netlist over all 2^4 input vectors);
a wrong INIT permutation is rejected (negative control logged on every run,
and unit tests including the inverse-permutation case). Each successful route
goes through the unchanged assembly, byte comparison with FABulous
`bit_gen genBitstream`, and the independent `fan4` oracle simulation.

## Outcome (record dated in `pin_experiment_results.txt`)

| trial | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| baseline | route_nonconvergent | route_nonconvergent | route_nonconvergent |
| variant-consistent | route_nonconvergent | route_nonconvergent | route_nonconvergent |
| variant-distinct | success | success | success |

The three successes pass the oracle (61697 checks, 0 failures, 38/38
perturbations detected) and match FABulous `bit_gen`. The baseline reproduces
the corpus record (3 arcs unrouted at the budget).

## What this supports, and limits

* Consistent with the hypothesis in a narrower form than stated: the
  synthesized `fan4` netlist is already nearly consistent (only one LUT puts
  `d` on a different index than the others, and `b` and `c` share index I1).
  Making each net's index consistent did not help; giving every input net a
  distinct pin index did, for all three seeds. So in this harness, with this
  design, sharing a pin index between different input nets (b and c on I1)
  coincides with non-convergence, and removing it coincides with routing.
* It does not isolate a mechanism: only one design, one pad assignment, one
  router and three seeds; the `distinct` policy also changes which pad nets
  compete for which same-index tracks, which was not separately varied. Fixed
  budget timeouts remain bounded non-convergence, not infeasibility, and the
  successes show only that this design routes in this harness, not general
  routability.
* It says nothing about the ratified Wilton-class population, timing, area or
  larger fabrics, and it does not choose among ADR-0004 options A/B/C. It
  shows that mapper-side pin assignment is a confounder any routability
  evidence must control for; a pin-permuting mapper step would be a flow
  change that needs its own decision.

## Replayable fixtures (issue #145)

The successful `variant-distinct` streams are preserved as a separate,
opt-in experimental fixture set so tile changes cannot silently regress the
four-BEL fanout case. Export (needs the pinned mapper; routine replay does not):

    ./flow/pin_experiment.sh --export-fixtures [DIR] [--append-record design/fabulous/corpus/pin_experiment_results.txt]

Export is all-or-nothing and refuses (writing nothing) unless the distinct
variant is exhaustively equivalent to the baseline, no experiment problem
occurred, and every seed's distinct trial routed, assembled, matched FABulous
`bit_gen` byte for byte and passed the independent `fan4` oracle with all
perturbations detected. Baseline and `consistent` trials are never exported.
The set lives in `sim/bitstream/pin_experiment/` (not the baseline corpus
`sim/bitstream/corpus/`; `corpus.json`, its expectations and its fixtures are
unchanged and `fan4` stays an expected route_nonconvergent corpus case):
`fan4_distinct_s{1,2,3}.{fasm,mapped.json,bin,wiring,cfg}`, the transformed
pre-route netlist `fan4_distinct.netlist.json`, and `index.json` (case, policy,
seed, oracle, sha256 of every file, and the sha256 of the `fabric_spec.json` /
`logic4_configmem.map` snapshot the streams were assembled against).

Replay (`flow/pin_fixtures.py verify`, `sim/pin_fixture_replay.sh`) fails on a
missing or empty index, a case count other than 3, a missing or drifted file,
snapshot/map drift, a transformed netlist that no longer has one pin index per
input net, mapped INITs that differ from the transformed netlist, a stream that
does not reproduce from its FASM, a simulator error, or an absent terminal
`PASS` verdict. It runs from `./sim/run.sh` (RTL) and
`./flow/gate-sim-bitstream.sh` (zero-delay gate level, `--negative` adds the
failure-mode checks). Tests: `python3 flow/test_pin_fixtures.py`;
`sim/pin_fixture_negative.sh` proves a missing file, an empty index and a
function-changing LUT INIT corruption each fail.

Covered population: three seeds of one design (`fan4`), one pad assignment,
the `distinct` pin policy, on the experimental same-index single-LOGIC4
harness. The gate-level replay is zero delay with simulation-model loader and
pads. This is regression evidence for an experiment, not a verification of the
ratified fabric, not general routability, and not a timing claim; ADR-0004 and
ADR-0005 stay Proposed and no mapper policy is adopted.

## Registered case: `regcasc` (issue #160)

Question: does the pin-index confounder also explain the corpus's second,
independent non-convergence, `regcasc` seed 2 (1 arc unrouted; seeds 1 and 3
route)? Run: `./flow/pin_experiment.sh --case regcasc [--append-record design/fabulous/corpus/pin_experiment_results.txt]`.
Held fixed exactly as for `fan4`: source, pcf, fabric model, router, seeds
1-3, 60 s budget, FF placement behaviour; `corpus.json`, its expectations and
every committed fixture are unchanged, and nothing is exported
(`--export-fixtures` is refused for registered cases).

### Method

The same `consistent` / `distinct` policies are applied to the LUTs feeding
the register *and* to the registered BEL's data LUT (`ff_map.v`'s
pass-through, D on I0, I1..I3 absent). Only I0..I3 and INIT move; the
register's `FF` parameter, `SR`, `EN`, its output/state net and the implicit
UserCLK are never touched. Before anything is routed each variant must pass,
in `flow/pin_experiment.py`:

1. **Per-cell INIT check** for every BEL LUT (including the register's data
   LUT): the variant computes the baseline function for every assignment of
   its connected nets *and* every value of its unconnected/undriven pins.
2. **Structural invariants**: module ports, the cell set and types, every IO
   cell, every BEL's non-INIT parameters (incl. `FF`), its `SR`/`EN`/`O` nets
   and directions, the multiset of I-pin nets (only a permutation is legal)
   and the register interface (cell, state net, SR net, EN net, FF value) are
   identical to the baseline.
3. **One-step transition equivalence**: the register output is explicit
   current state `q`; for both values of `q` and all 2^7 `{a,b,c,d,e,en,rst}`
   vectors (256 transitions) the acyclic combinational cone is evaluated and
   `next_q = rst ? 0 : (en ? d : q)` applied; next state and every observable
   output must match the baseline. Outputs/inputs are compared per harness
   IO port.

The model is bounded and fails closed: more than one state element, no state
element, a combinational cycle, a control net that is not a primary input
(logic-driven or unconnected `SR`/`EN`), unknown BEL pins (e.g. an explicit
clock) or parameters, multiply-driven nets, or more than 16 primary inputs
stop the run with an `unsupported sequential shape` diagnostic before
routing. Every run also builds three negative controls from the baseline and
requires each to be a *completed* `REJECTED` verdict (not an unsupported
shape or a crash): (a) a LUT's connections swapped with INIT unchanged
(per-cell mismatch), (b) `SR` and `EN` exchanged on the register, and (c) the
output reconnected from the state net to the register's data-input net (FF
bypassed); (b) and (c) must also produce a transition-level witness, not only
a structural difference. Unit tests (`python3 flow/test_pin_experiment.py`)
cover the positive transform, these three classes, an FF-disable mutation,
an inverted data LUT, and each unsupported shape. A routed success then needs
assembly, byte identity with FABulous `bit_gen genBitstream`, and the
independent `regcasc` oracle in `sim/tb_logic_tile_bitstream.v` (both
starting states, all 128 vectors, hold-before-edge, 300-cycle reference
sequence) with **every** perturbation detected; a baseline that diverges
from `corpus.json` is reported as an experiment problem.

### Outcome (record dated 2026-10-10 in `pin_experiment_results.txt`)

| trial | seed 1 | seed 2 | seed 3 |
|---|---|---|---|
| baseline | success | route_nonconvergent (1 arc) | success |
| variant-consistent | success | route_nonconvergent (1 arc) | success |
| variant-distinct | success | route_nonconvergent (1 arc) | success |

The baseline reproduces the corpus record. All six variant successes pass the
oracle (313273 checks, 0 failures, 36/36 perturbations detected) and match
FABulous `bit_gen`; the `distinct` successes are different streams from the
baseline's (the transform reaches the bitstream). Both variants passed all
three equivalence checks and all three negative controls were completed
rejections. The run was performed twice (uncommitted and committed code)
with identical outcomes and stream hashes; only the committed-code record is
appended.

Result category **(a)**: seed 2 still fails under every policy.

### What this supports, and limits

* The synthesized `regcasc` netlist already has every net at LUT-input
  fanout 1, so the `consistent` plan is the identity (that variant is the
  baseline netlist, sha-identical, a determinism check rather than a separate
  treatment). `distinct` cannot give each of the 7 LUT-input nets its own
  index with 4 pins; it falls back to the `consistent` rule and moved
  `a,b,c,d` (XOR4 LUT, INIT unchanged by symmetry) and the register's data
  pin (I0 -> I2, INIT `AAAA` -> `F0F0`).
* Within this harness, pin-index assignment on the LUT inputs does not
  explain the `regcasc` seed-2 non-convergence: the one unrouted arc persists
  under both policies. This is a measured refutation of the pin-index
  hypothesis *for this case*, not a general one, and it says nothing about
  which arc or resource is the bottleneck (not isolated here).
* Not interchangeable with the combinational `fan4` result: here the
  `EN`/`SR` pad nets and the FF BEL path take part in routing and are, by
  construction, not permuted, so a confounder on those pins is untested.
  One design, one pad assignment, one router, three seeds; timeouts remain
  bounded non-convergence, never infeasibility.
* No fixture is exported, no corpus expectation, fabric population or ADR
  status changes, and no mapper policy is adopted.
