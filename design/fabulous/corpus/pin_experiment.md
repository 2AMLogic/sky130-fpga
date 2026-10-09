# LUT pin-index experiment (issue #137)

EXPERIMENTAL, opt-in, separate from the corpus. It tests one hypothesis from
`README.md` ("Hypotheses"): that `fan4` fails to route because the synthesized
netlist puts the same signal on different LUT input pin indices while the
harness switch matrix is same-index. It changes neither `corpus.json`, any
expectation, any committed fixture, the fabric model nor the spec, and it does
not ratify or pre-empt ADR-0004.

Run: `./flow/pin_experiment.sh [--append-record design/fabulous/corpus/pin_experiment_results.txt]`
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
