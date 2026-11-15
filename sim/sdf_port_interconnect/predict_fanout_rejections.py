#!/usr/bin/env python3
"""predict_fanout_rejections.py -- apply the fanout model to a real SDF.

The reproducer in this directory establishes, on a hand-written fixture,
that Icarus Verilog 13.0's `$sdf_annotate` can create at most ONE
interconnect modpath per bit-selected top-level port net: on such a net
carrying N `INTERCONNECT` entries it annotates one and rejects the other
N-1, while scalar-port and instance-pin-sourced nets are unaffected at any
fanout. See the record named in README.md.

This script applies that model to a real SDF, with no simulator involved, so
the per-entry count it predicts can be checked against what a real run
observed. On `measurements/timing-characterization/logic_tile_route.sdf` it
predicts 28 rejections with sinks S0 x12, S1 x12, A x4 -- the exact figures
record 20261017-sdf-sanitize-d811bcd Result 3 reported from a live run and
left unexplained.

Classification of a source token, which is all the model needs:

  `in[0]`, `ce[2]`       bit-selected bare port   -> capped at one entry
  `clk`, `rst`           scalar bare port         -> unaffected
  `<inst>.<pin>`         instance pin             -> unaffected

Escaped-identifier instance names (`g_slice\\[0\\]\\.u_slice\\/_09_.S0`) are
instance pins, not bit-selected ports: the `[0]` inside them is part of an
escaped name, and the trailing `.<pin>` is what makes them instance pins.
The regex below therefore anchors the bit-select to the END of an otherwise
plain identifier, which an escaped name never satisfies.

Which entry survives depends on instance declaration order in the netlist,
which an SDF does not carry -- so this script predicts the COUNT and the
multiset of sinks that can be rejected, not which named entry survives.
Where every entry on a net shares one sink pin name (the `in[N]` nets, all
`S0` or all `S1`), the predicted sink multiset is exact. Where the sinks
differ (the `ce[N]` nets, `A` and `B`), the identity of the survivor is
netlist-ordered, so both are reported and `--expect-sinks` is matched
against the possibility that contains the expectation.

Usage:
    predict_fanout_rejections.py --sdf <file>
    predict_fanout_rejections.py --sdf <file> --expect-rejections 28 \\
        --expect-sinks 'S0=12,S1=12,A=4'

Exit status: 0 if no expectation was given or every expectation held;
1 otherwise.
"""

from __future__ import annotations

import argparse
import collections
import re
import sys

_INTERCONNECT_RE = re.compile(
    r"\(\s*INTERCONNECT\s+(?P<src>\S+)\s+(?P<dst>\S+)\s+\((?P<delay>[^)]*)\)"
)

# A plain identifier ending in a bit-select, and nothing more: `in[0]`,
# `lut_init[63]`. An escaped instance name cannot match (it carries `\` and
# a trailing `.<pin>`), so instance pins never land in this class.
_BITSEL_PORT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*\[\d+\]$")
_SCALAR_PORT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def classify_source(token: str) -> str:
    if _BITSEL_PORT_RE.match(token):
        return "bitsel-port"
    if _SCALAR_PORT_RE.match(token):
        return "scalar-port"
    return "instance-pin"


def sink_pin(destination: str) -> str:
    return destination.rsplit(".", 1)[-1]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdf", required=True)
    parser.add_argument("--expect-rejections", type=int, default=None)
    parser.add_argument(
        "--expect-sinks",
        default=None,
        help="comma-separated PIN=COUNT expectation for the rejected sinks",
    )
    args = parser.parse_args(argv[1:])

    nets: dict[str, list[tuple[str, str]]] = collections.defaultdict(list)
    with open(args.sdf, encoding="utf-8") as fh:
        for line in fh:
            match = _INTERCONNECT_RE.search(line)
            if match:
                nets[match.group("src")].append(
                    (match.group("dst"), match.group("delay"))
                )

    total = sum(len(v) for v in nets.values())
    by_class: collections.Counter[str] = collections.Counter()
    for source, destinations in nets.items():
        by_class[classify_source(source)] += len(destinations)

    predicted = 0
    rejected_sinks: collections.Counter[str] = collections.Counter()
    affected_delays: set[str] = set()
    affected_nets: list[tuple[str, int, list[str]]] = []

    for source, destinations in sorted(nets.items()):
        if classify_source(source) != "bitsel-port" or len(destinations) < 2:
            continue
        pins = [sink_pin(d) for d, _ in destinations]
        affected_nets.append((source, len(destinations), pins))
        predicted += len(destinations) - 1
        affected_delays.update(delay for _, delay in destinations)
        # One survivor per net; which one is netlist-ordered. When every
        # destination shares a sink pin name the rejected multiset is exact.
        counts = collections.Counter(pins)
        if len(counts) == 1:
            pin = next(iter(counts))
            rejected_sinks[pin] += len(destinations) - 1
        else:
            # Ambiguous: record the whole net and resolve against the
            # expectation below rather than guessing.
            rejected_sinks["<ambiguous:" + "/".join(sorted(counts)) + ">"] += (
                len(destinations) - 1
            )

    print(f"SDF                     : {args.sdf}")
    print(f"INTERCONNECT entries    : {total}")
    for name in ("bitsel-port", "scalar-port", "instance-pin"):
        print(f"  {name:<22}: {by_class.get(name, 0)}")
    print(f"affected nets (bitsel-port, fanout > 1): {len(affected_nets)}")
    for source, fanout, pins in affected_nets:
        print(f"  {source:<14} fanout {fanout}  sinks {sorted(set(pins))}")
    print(f"predicted rejections    : {predicted}")
    print(f"predicted rejected sinks: {dict(rejected_sinks)}")
    print(f"delays on affected nets : {sorted(affected_delays)}")
    if affected_delays and affected_delays == {"0.000:0.000:0.000"}:
        print(
            "note: every affected entry carries a 0.000 delay triple, so dropping "
            "them removes no delay from the simulation"
        )

    ok = True
    if args.expect_rejections is not None:
        if predicted == args.expect_rejections:
            print(f"OK   predicted rejections == expected {args.expect_rejections}")
        else:
            print(
                f"FAIL predicted {predicted} rejections, expected "
                f"{args.expect_rejections}",
                file=sys.stderr,
            )
            ok = False

    if args.expect_sinks:
        expected = {}
        for part in args.expect_sinks.split(","):
            pin, _, count = part.partition("=")
            expected[pin.strip()] = int(count)
        # Resolve each ambiguous net group against the expectation: an
        # `<ambiguous:A/B>` group of size k is satisfied if the expectation
        # attributes k rejections to one of its pins.
        resolved = collections.Counter(
            {k: v for k, v in rejected_sinks.items() if not k.startswith("<ambiguous:")}
        )
        for key, count in rejected_sinks.items():
            if not key.startswith("<ambiguous:"):
                continue
            pins = key[len("<ambiguous:"):-1].split("/")
            chosen = next(
                (p for p in pins if expected.get(p, 0) - resolved.get(p, 0) == count),
                None,
            )
            if chosen is None:
                print(
                    f"FAIL ambiguous sink group {key} x{count} matches no pin in the "
                    f"expectation {expected}",
                    file=sys.stderr,
                )
                ok = False
            else:
                resolved[chosen] += count
                print(
                    f"OK   ambiguous sink group {key} x{count} attributed to {chosen} "
                    f"(netlist declaration order decides the survivor)"
                )
        if dict(resolved) == expected:
            print(f"OK   predicted rejected sinks == expected {expected}")
        elif ok:
            print(
                f"FAIL predicted rejected sinks {dict(resolved)}, expected {expected}",
                file=sys.stderr,
            )
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
