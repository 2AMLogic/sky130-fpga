#!/usr/bin/env python3
"""flow/tile_sdf_probe_gate.py

The gate half of the SDF settle-time probe (issue #382).

flow/tile-functional-verification.sh runs the four named tile checks of
sim/cocotb/test_logic_tile.py at zero delay and with the committed
measurements/timing-characterization/logic_tile_route.sdf back-annotated,
and both legs report the same 4/4 passes: nothing in that bench observes a
delay. The companion probe module
sim/cocotb/test_logic_tile_sdf_probe.py watches `out` across two of the same
stimuli and prints, per leg, the first poll at which it settled:

    SETTLE_PROBE registered_ns=<t> [poll_step_ps=<p>]
    SETTLE_PROBE combinational_ns=<t> [poll_step_ps=<p>]

It asserts only functional correctness and passes on both legs; whether the
annotated leg settled *later* is decided here. This module reads the two
legs' simulator logs (the `environment.test_log` artifact of each `klt
functional-verification` envelope) and refuses, loudly, everything but a
well-formed pair of readings whose annotated leg is later than the zero-delay
leg by at least the margin on every probed path:

  - a missing number (no line for a path, an empty or absent log) is refused
    -- it can never read as a pass;
  - a malformed, duplicated or unknown token on a tagged line is refused, and
    only the probe's own column-0 line counts (a logger-prefixed or
    traceback-quoted copy is ignored, which leaves the number missing);
  - a delta below the margin is refused, naming the path -- including the
    delta of zero a silently no-op annotation would produce.

The margin (default 0.1 ns) is loose on purpose: the probe is evidence that
annotation took effect, not a timing measurement, so the gate must not fail
on a one-poll shift while still refusing the zero-delay reading outright.
Arithmetic is exact decimal, never binary floating point, so a delta equal to
the margin passes.

Usage:
    tile_sdf_probe_gate.py --zero-log <path> --sdf-log <path>
                            [--min-delta-ns 0.1] [--format text|json]

Exit status: 0 iff the gate passes; 1 if it refuses (the reason is on
stderr); 2 on a usage error. The measured readings are printed on stdout.
The harness embeds parse_probe()'s result in each committed probe envelope
and runs this file's command line for the verdict, so both share one
implementation; flow/test_tile_sdf_probe_gate.py is the regression.
"""

import argparse
import json
import re
import sys
from decimal import Decimal, InvalidOperation

PROBE_TAG = "SETTLE_PROBE"
PROBED = ("registered", "combinational")
DEFAULT_MIN_DELTA_NS = "0.1"

_NUMBER = re.compile(r"[0-9]+(?:\.[0-9]+)?")
_KEY_VALUE = re.compile(r"([a-z_]+)=(\S*)")


class ProbeError(ValueError):
    """A probe log whose readings cannot be trusted: missing or malformed."""


def _decimal(text, what, source):
    if not _NUMBER.fullmatch(text):
        raise ProbeError(f"{source}: {what} is {text!r}, not a non-negative decimal number")
    return Decimal(text)


def parse_probe(log_text, source="log"):
    """Return the probe readings of one leg's log.

    {"registered_ns": Decimal, "combinational_ns": Decimal, "poll_step_ps": int|None};
    raises ProbeError when a reading is missing, malformed or duplicated.
    """
    readings = {}
    steps = set()
    for lineno, line in enumerate(log_text.splitlines(), 1):
        text = line.strip()
        if not text.startswith(PROBE_TAG):
            continue
        where = f"{source}:{lineno}"
        tokens = text.split()[1:]
        if not tokens:
            raise ProbeError(f"{where}: {PROBE_TAG} line carries no readings")
        pairs = []
        for token in tokens:
            match = _KEY_VALUE.fullmatch(token)
            if not match:
                raise ProbeError(f"{where}: token {token!r} is not <key>=<value>")
            pairs.append(match.groups())
        for key, value in pairs:
            if key == "poll_step_ps":
                if not re.fullmatch(r"[0-9]+", value) or int(value) == 0:
                    raise ProbeError(f"{where}: poll_step_ps is {value!r}, not a positive integer")
                steps.add(int(value))
            elif key.endswith("_ns") and key[:-3] in PROBED:
                if key in readings:
                    raise ProbeError(f"{where}: duplicate reading for {key} (first at {readings[key][1]})")
                readings[key] = (_decimal(value, key, where), where)
            else:
                raise ProbeError(f"{where}: unrecognised token {token!r}")
    if len(steps) > 1:
        raise ProbeError(f"{source}: poll_step_ps disagrees across lines: {sorted(steps)}")
    for kind in PROBED:
        if f"{kind}_ns" not in readings:
            raise ProbeError(f"{source}: no {PROBE_TAG} {kind}_ns reading (probe line missing)")
    return {f"{kind}_ns": readings[f"{kind}_ns"][0] for kind in PROBED} | {
        "poll_step_ps": next(iter(steps)) if steps else None}


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as exc:
        raise ProbeError(f"{path}: cannot read the probe log ({exc.strerror})") from exc


def gate(zero, sdf, min_delta_ns=DEFAULT_MIN_DELTA_NS):
    """Judge an annotated-vs-zero-delay pair of parse_probe() results.

    Returns {"passed": bool, "min_delta_ns": Decimal, "refused": [path, ...],
    "paths": {path: {"zero_delay_ns", "sdf_annotated_ns", "delta_ns"}}}.
    min_delta_ns must be a positive decimal (a str, or a Decimal); anything
    else is a usage error and raises ValueError.
    """
    try:
        margin = Decimal(str(min_delta_ns))
    except InvalidOperation:
        raise ValueError(f"min_delta_ns {min_delta_ns!r} is not a decimal number") from None
    if not margin.is_finite() or margin <= 0:
        raise ValueError(f"min_delta_ns must be positive, not {min_delta_ns!r}")

    paths = {}
    for kind in PROBED:
        key = f"{kind}_ns"
        zero_ns, sdf_ns = zero[key], sdf[key]
        paths[kind] = {"zero_delay_ns": zero_ns, "sdf_annotated_ns": sdf_ns,
                       "delta_ns": sdf_ns - zero_ns}
    refused = [kind for kind in PROBED if paths[kind]["delta_ns"] < margin]
    return {"passed": not refused, "min_delta_ns": margin, "refused": refused,
            "paths": paths}


def format_text(verdict):
    lines = [f"=== SDF settle-time probe gate (annotated must settle >= {verdict['min_delta_ns']} ns later) ==="]
    for kind in PROBED:
        p = verdict["paths"][kind]
        lines.append(f"    {kind:<13} zero-delay {p['zero_delay_ns']} ns   "
                     f"annotated {p['sdf_annotated_ns']} ns   "
                     f"delta {p['delta_ns']} ns   {'ok' if kind not in verdict['refused'] else 'REFUSED'}")
    return "\n".join(lines)


def format_json(verdict):
    def number(d):
        return float(d)
    doc = {"passed": verdict["passed"],
           "min_delta_ns": number(verdict["min_delta_ns"]),
           "paths": {kind: {k: number(v) for k, v in p.items()}
                     for kind, p in verdict["paths"].items()}}
    return json.dumps(doc, indent=2, sort_keys=True)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--zero-log", required=True,
                        help="test log of the probe's zero-delay leg")
    parser.add_argument("--sdf-log", required=True,
                        help="test log of the probe's SDF-annotated leg")
    parser.add_argument("--min-delta-ns", default=DEFAULT_MIN_DELTA_NS,
                        help="required annotated-minus-zero-delay settle delta in ns "
                             f"(default {DEFAULT_MIN_DELTA_NS})")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args(argv[1:])

    try:
        zero = parse_probe(_read(args.zero_log), args.zero_log)
        sdf = parse_probe(_read(args.sdf_log), args.sdf_log)
        verdict = gate(zero, sdf, args.min_delta_ns)
    except ProbeError as exc:
        print(f"error: probe gate refused: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        parser.error(f"--min-delta-ns: {exc}")

    print(format_text(verdict) if args.format == "text" else format_json(verdict))
    if not verdict["passed"]:
        for kind in verdict["refused"]:
            p = verdict["paths"][kind]
            print(f"error: probe gate refused: {kind} path settles only {p['delta_ns']} ns later "
                  f"on the annotated leg ({p['sdf_annotated_ns']} ns against {p['zero_delay_ns']} ns), "
                  f"less than the required {verdict['min_delta_ns']} ns -- the SDF delays are not "
                  f"reaching the annotated leg (a no-op annotation, or a probe that no longer "
                  f"observes them)", file=sys.stderr)
        return 1
    if args.format == "text":
        print("=== probe gate passed: the annotated leg settles later on both paths ===")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
