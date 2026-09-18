#!/usr/bin/env python3
"""flow/erc_report_trim.py

Reduce a `klt erc --format json` response to the stable, committable
evidence written as `layout/logic_tile.erc.json` -- mirroring
`flow/drc_report_trim.py`'s and `flow/lvs_report_trim.py`'s own rationale.

Two things happen here.

**The per-gate array is summarized, not dropped.** `klt erc` emits a
`gates` array with one entry per gate-role (poly) shape, each carrying a
per-stackup-level antenna accumulation -- 232 gates x 7 levels, ~600 KB of
JSON for this tile. That is a derived, fully-regenerable intermediate, and
committing 600 KB of it on every layout change would swamp the diff of the
verdict it exists to support. It is replaced by two histograms --
`antenna_verdict_counts` (every *level*'s verdict across every gate) and
`antenna_gate_verdict_counts` (each *gate*'s rolled-up `antenna_verdict`,
so `layout/README.md`'s "0 `violate` across N gates" claim is checkable
directly) -- **plus the full, untrimmed entry for any gate whose rolled-up
verdict is `"violate"` or `"unchecked"`** (`antenna_gates_not_passing`). So
a clean run commits a small summary and a dirty run commits the offending
gates in full -- the summary can never hide a violation, because a
violation is what stops it from being a summary.

**Why the predicate is not simply `!= "pass"`.** It was, and that was a
bug: on sky130 every gate here rolls up to `"pass_partial"`, never
`"pass"`, so `!= "pass"` matched all 232 gates and the "summary" was the
full 612 KB array it exists to avoid. `pass_partial` is the *expected*
verdict on this PDK and not a violation -- per `klt erc`'s own rollup
(klayout-tools#1997), it means at least one graded level was compared and
passed while at least one other graded level's role has no entry in the
selected PDK's limit table. sky130's antenna table has no met3/met4/met5
entries, and this tile routes on met1-met3 with supply straps on
met4/met5, so every gate necessarily has ungraded levels. The verdicts
that mean something went unverified or wrong are `"violate"` (a real
antenna violation) and `"unchecked"` (no graded level was *ever* compared
-- i.e. nothing was verified at all); those, and only those, are committed
in full. This matches `flow/erc.sh`'s own failure gate, which likewise
fails only on `"violate"`.

**`erc_findings` is never touched.** The ERC finding list (shorts, floating
supply islands, `erc.missing_tie`) is this report's actual verdict -- the
thing `layout/README.md`'s power-connectivity claim cites -- so it is
committed verbatim, however long it is.

Also **synthesizes the `provenance` block `klt erc` does not write**.
Every other klt verb whose JSON this repo commits as evidence carries one
(`klt drc`: `deck`/`input` content hashes; `klt place-and-route`/`klt sta`:
the PDK revision too); `klt erc` carries none at all -- filed generically
and since fixed upstream as klayout-tools#2036, but not in the klt build
this repo pins, so the hashes are computed here instead. The shape
deliberately mirrors `layout/logic_tile.drc.json`'s, including `pdk: null`
for the same reason its DRC sibling has it: the PDK revision for this claim
is pinned by `flow/erc.sh`'s run-time banner
(`flow/tool_versions.sh`'s `RECORDED_PDK_VERSION`), and
`flow/audit_evidence.py` accounts for the null explicitly rather than
letting a provenance-less report pass unnoticed.

It carries one field its DRC sibling does not: `provenance.klt_version`,
the klt build that actually produced the verdict. `klt erc` postdates
`flow/tool_versions.sh`'s `RECORDED_KLT_VERSION`, so this report **cannot**
have been produced by the same klt as the committed GDS, and omitting the
field would leave that discrepancy invisible -- the exact kind of quiet
overclaim issue #41 was filed about. Recording it costs nothing and makes
the mismatch self-evident in the committed artifact. The verdict itself
does not depend on resolving it: this is a statement about the geometry of
one specific GDS, whose hash the same block pins.

Usage:
    erc_report_trim.py <response.json> <layout_gds_sha256> <supply_spec_sha256> \
<klt_version> <output.json>
"""

import sys

from _report_trim import run_cli

# Rolled-up per-gate `antenna_verdict` values that mean something was
# violated or was never verified at all -- see the module docstring for why
# `"pass_partial"` is deliberately absent. Gates with these verdicts are
# committed in full rather than summarized.
NOT_PASSING_GATE_VERDICTS = frozenset({"violate", "unchecked"})


def trim(
    response: dict,
    layout_gds_sha256: str,
    supply_spec_sha256: str,
    klt_version: str,
) -> dict:
    trimmed = dict(response)
    gates = trimmed.pop("gates", []) or []

    counts: dict = {}
    gate_counts: dict = {}
    not_passing = []
    for gate in gates:
        for level in gate.get("levels", []) or []:
            verdict = level.get("verdict", "unknown")
            counts[verdict] = counts.get(verdict, 0) + 1
        gate_verdict = gate.get("antenna_verdict", "unknown")
        gate_counts[gate_verdict] = gate_counts.get(gate_verdict, 0) + 1
        if gate_verdict in NOT_PASSING_GATE_VERDICTS:
            not_passing.append(gate)

    # Keep each histogram's key set stable across runs so a clean-to-clean
    # diff is a pure count diff, never a key appearing/disappearing.
    for verdict in ("pass", "unchecked", "violate"):
        counts.setdefault(verdict, 0)
    for verdict in ("pass", "pass_partial", "unchecked", "violate"):
        gate_counts.setdefault(verdict, 0)

    trimmed["antenna_verdict_counts"] = counts
    trimmed["antenna_gate_verdict_counts"] = gate_counts
    if not_passing:
        trimmed["antenna_gates_not_passing"] = not_passing
    trimmed["provenance"] = {
        "pdk": None,
        "klt_version": klt_version,
        "input": {"content_hash": layout_gds_sha256},
        "spec": {"content_hash": supply_spec_sha256},
    }
    return trimmed


def main(argv: list) -> int:
    return run_cli(
        argv,
        trim,
        extra_args=("layout_gds_sha256", "supply_spec_sha256", "klt_version"),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
