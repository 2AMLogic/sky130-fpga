# ADR-0006: Mapper-side LUT pin-assignment policy for the harness flow

- **Status**: Proposed -- pending operator ratification. Same
  ratification-via-PR policy as ADR-0002..0005. **`spec/tile-spec.md` is
  NOT edited**; nothing here is adopted until the operator ratifies it, and
  no flow, fabric or description change accompanies this record.
- **Date**: 2026-10-10
- **Decided by**: Builder (issue #161); rulings reserved to the operator
- **Related**: #161 (this issue), #137 (the experiment), #145 (fixtures from
  it), [ADR-0004](0004-g1-tile-description-discrepancies.md) item 3,
  [ADR-0005](0005-nextpnr-io-and-constant-handling.md),
  `design/fabulous/corpus/pin_experiment.md`,
  `design/fabulous/corpus/pin_experiment_results.txt`,
  `design/fabulous/corpus/README.md` (Hypotheses)

## Context

The as-built harness switch matrix is same-index (ADR-0004 item 3): LUT input
`Ik` sees only the index-`k` tracks. nextpnr's fabulous flow does not permute
LUT input pins, so which pin index each net lands on is decided by the
synthesis step (abc). `design/fabulous/corpus/README.md` hypothesised that
this, rather than the matrix population alone, explains the `fan4`
non-convergence, and noted that LUT pin permutation in the mapper flow would be
another possible remedy; the corpus does not evaluate alternatives.

The pin experiment (#137) is what exists, and its limits are its own:

- One design (`fan4`), one pad assignment, one router (nextpnr default), three
  seeds (1-3), a 60 s wall-clock budget, the as-implemented same-index
  single-LOGIC4 harness.
- Baseline and `variant-consistent` (each net keeps one pin index) were
  `route_nonconvergent` for all three seeds. `variant-distinct` (every input
  net on its own pin index) routed on all three seeds; those streams passed the
  independent oracle and matched FABulous `bit_gen` byte for byte.
- The experiment did not isolate a mechanism: the `distinct` policy also changes
  which pad nets compete for which same-index tracks, which was not separately
  varied. Budget timeouts are bounded non-convergence, not infeasibility, and
  the successes show only that this design routes in this harness.
- It says nothing about the ratified Wilton-class population, timing, area or
  larger fabrics, and does not choose among ADR-0004 options A/B/C.
- `pin_experiment.md` concludes that mapper-side pin assignment is a confounder
  for any routability evidence, and that a pin-permuting mapper step "would be
  a flow change that needs its own decision". This is that record.

Replayable fixtures of the three successful `distinct` streams exist
(`sim/bitstream/pin_experiment/`, #145). They are regression evidence for an
experiment, not an adopted policy; this ADR is what would (or would not) turn
that experimental policy into a flow rule.

## Options

### A. No mapper policy; document the confounder only

The flow keeps whatever pin assignment synthesis produces. Any routability
claim (corpus, ADR-0004 item 3 evidence, #74 work) must state the pin
assignment it was obtained under. The `fan4` pin-experiment fixtures stay
labelled experimental.

### B. Adopt a deterministic pin-alignment step in the harness flow

Add a post-synthesis step (e.g. the `distinct` policy of the experiment) that
permutes LUT input pins and INIT bits deterministically before nextpnr.
Harness-only: it is part of `flow/`, not of the tile deliverable, `rtl/`, the
tile description or the spec.

### C. Solve in the fabric; leave the mapper alone

Treat pin sensitivity as a property of the switch matrix and address it
through ADR-0004 item 3 (Wilton-class or richer population). No mapper step.

## Recommendation

**Option A for now**, with B and C kept open and revisited when the missing
evidence below exists. Reasoning:

- One design, one pad assignment and three seeds cannot distinguish "pin
  sharing is the cause" from "`distinct` happens to change pad-track
  competition". Adopting a flow rule on that base would turn an experiment into
  policy, which this repo's evidence discipline avoids.
- Option A costs nothing and removes the actual hazard (a silent confounder) by
  making pin assignment part of every routability claim.
- Choosing B now would let a mapper step mask the very fabric weakness
  ADR-0004 item 3 asks about, so a later A/B/C ruling there would rest on
  mapper-assisted evidence. Choosing C now presumes the fabric, not the mapper,
  is at fault, which is not shown either.
- If the operator wants routable designs sooner for harness work, B is the
  lowest-cost path and is reversible, provided its obligations below are met
  and results are always reported with the policy named.

This is a recommendation only; the choice is the operator's.

## Evidence still missing

- At least a second design showing the same pin-sharing correlation (and ideally
  one where `distinct` is not applicable or not sufficient). The `regcasc`
  extension proposal, if filed, is the natural candidate; none is claimed here.
- A control separating pin assignment from pad-track competition (vary pad
  assignment independently of pin policy).
- Any result on a Wilton-class population, to compare B against C directly.
- More seeds and a second router or longer budget, to separate non-convergence
  from infeasibility.

## Interaction with ADR-0004 item 3

- Item 3 asks whether the same-index matrix is a stand-in (A), the v1 spec
  population (B) or should become Wilton-class (C). Its recommendation (A until
  routability is evidenced) is unaffected by this record.
- This ADR separates the two remedies so item 3 is not ruled on mixed evidence.
  Under ADR-0006 option A, item 3 evidence must name the pin assignment. Under
  option B, item 3 evidence obtained with the pin step is evidence about the
  fabric *plus* that step, and must say so. Under option C, the mapper stays
  neutral and item 3 carries the whole question.
- No ADR-0006 option relaxes the ratified Wilton-class wording; none edits
  `spec/tile-spec.md`.

## Interaction with ADR-0005

- ADR-0005 keeps IO and constants in a harness-only overlay and folds constants
  into the LUT truth table by replicating INIT over unused upper inputs. Option B
  is the same kind of artefact (harness-only, outside `rtl/` and the spec) and
  would sit beside, not inside, that overlay.
- Option B must preserve ADR-0005 invariants: replicated INIT over unconnected
  pins stays functionally don't-care after permutation, and no pin may come to
  use `$PACKER_GND`/`$PACKER_VCC`. Pad access to all four tracks of a boundary
  tile (ADR-0005) already reduces, but does not remove, pin-order dependence.
- Options A and C need no change to ADR-0005.

## Obligations if option B is chosen

The experiment's checks are the baseline; ratification would make them
mandatory rather than experimental:

1. **Per-cell equivalence**: exhaustive over all assignments of the cell's
   connected nets, before and after permutation.
2. **Whole-netlist equivalence**: exhaustive over primary-input vectors where
   feasible; where not, state the bound and the method used instead.
3. **INIT permutation correctness**: INIT bits are permuted exactly with the
   pin connections. A negative control (a deliberately wrong or inverse
   permutation must be rejected) runs on every invocation, with unit tests.
4. **Don't-care pin handling**: dangling nets and unconnected pins of narrow
   LUTs may move, and the check proves they remain don't-care (ADR-0005
   replicated-INIT invariant).
5. **Conflict handling**: when a net needs more than four indices or one net
   would sit on two pins, leave the cell unchanged, log it, and never fail
   silently.
6. **Determinism**: the same input netlist yields the same output; no seed or
   iteration-order dependence.
7. **Downstream gates unchanged**: routed results still go through unchanged
   assembly, byte comparison with FABulous `bit_gen`, and an independent
   oracle simulation.
8. **Reporting**: every routability result states the policy used; results
   under B are never presented as baseline-mapper results.
9. **Scope**: harness-only, off by default unless the operator rules
   otherwise, and not a tile deliverable.

## Disposition

**Operator decision required** (A recommended for now; B or C to be chosen when
the missing evidence exists). Nothing is adopted by this record.

## Consequences

- Until ratified, no pin-assignment policy is adopted; the pin-experiment
  fixtures stay experimental and ADR-0004 item 3 and ADR-0005 stay Proposed.
- This record changes no `design/`, `flow/` behaviour, RTL, measurement or
  `spec/tile-spec.md`, and grants no routability, timing or area claim.
