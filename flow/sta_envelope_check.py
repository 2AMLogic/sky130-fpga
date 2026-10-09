#!/usr/bin/env python3
"""flow/sta_envelope_check.py

Gate for the multi-corner `klt sta` envelope this repo cites for T1
checklist item 5 (issue #68):
`measurements/timing-characterization/logic_tile.sta.json`, the trimmed
(`flow/sta_report_trim.py`) `pdk.corners` response of one real `klt sta`
run over the committed routed geometry with the extracted SPEF annotated.

`klt signoff` grades a `klt sta` citation `met` when every corner the
envelope itself declares is `timing_status: "constrained"` with
non-negative setup and hold slack -- it grades exactly the corner set the
run declared, and never compares that set against the spec. This script
adds the claim-side half the grader cannot know about, and refuses the
envelope unless **all** of the following hold:

- **Exact corner coverage**: the envelope's `corners[].corner` names are
  exactly the 18 ratified `sky130_fd_sc_hd` corners
  (`RATIFIED_CORNERS` below, the set ADR-0002 ratified and ADR-0003
  re-ratified) -- none omitted, none duplicated, none extra -- and each
  entry's own `deck.name` is that corner's liberty deck.
- **Graded timing**: every corner is `timing_status: "constrained"`, with
  numeric `worst_slack_ns >= 0` and `worst_hold_slack_ns >= 0`, zero
  setup/hold violation counts and zero total negative (setup and hold)
  slack. This is a superset of the grader's own pass rule, so an envelope
  that passes here cannot grade `unmet` on timing.
- **Real parasitics**: every corner's `spef_annotation.annotation_complete`
  is `true`, and the envelope pins the SPEF it annotated (`spef_sha256`)
  and the committed DEF/GDS it derives from (`layout_def_sha256`,
  `layout_gds_sha256`).
- **The 20 ns reference clock**: the response does not echo the request's
  `constraints.clock_period_ns`, but `klt sta` derives `fmax_mhz` as
  `1/(T - WNS)` from it. Every corner's reported `fmax_mhz` must be
  consistent with `T = CLOCK_PERIOD_NS` to within the rounding of the two
  reported fields, so an envelope produced against a different period
  fails here.
- **Routed geometry**: `geometry_source == "routed"` and `status == "ok"`.

With `--cross-check <corners-dir>`, every corner entry must additionally
agree field-for-field (every timing/power metric, `timing_status`,
`spef_annotation`, liberty `deck.content_hash`, analysed-DEF
`provenance.input.content_hash`, `spef_sha256`, `layout_def_sha256`) with
the separately-run single-corner SPEF report committed at
`<corners-dir>/<corner>/spef.sta.json` -- i.e. the one-session
multi-corner response and the per-corner sweep (which carries the
name-rewrite neutrality control) describe the same analysis.

Usage:
    sta_envelope_check.py <envelope.json> [--cross-check <corners-dir>]
                          [--expect-corners c1,c2,...]

`--expect-corners` (used by `flow/sta-sweep.sh`) additionally asserts the
caller's own corner list equals `RATIFIED_CORNERS`, so the sweep's list and
this gate cannot drift apart silently.

Exit status: 0 iff every check passes; 1 with one line per failure
otherwise; 2 on a usage error. Pure python3 -- no klt, no PDK -- so
`signoff/verify-pins.sh` re-runs it against the committed envelope.
"""

import json
import math
import os
import sys

STD_CELL_LIBRARY = "sky130_fd_sc_hd"
CLOCK_PERIOD_NS = 20.0

# The 18 sky130_fd_sc_hd liberty corners ADR-0002 ratified and ADR-0003
# re-ratified (spec/decisions/), identical to flow/sta-sweep.sh's
# ALL_CORNERS (which the sweep asserts via --expect-corners).
RATIFIED_CORNERS = (
    "ff_100C_1v65", "ff_100C_1v95", "ff_n40C_1v56", "ff_n40C_1v65",
    "ff_n40C_1v76", "ff_n40C_1v95", "ff_n40C_1v95_ccsnoise",
    "tt_025C_1v80", "tt_100C_1v80",
    "ss_100C_1v40", "ss_100C_1v60", "ss_n40C_1v28", "ss_n40C_1v35",
    "ss_n40C_1v40", "ss_n40C_1v44", "ss_n40C_1v60",
    "ss_n40C_1v60_ccsnoise", "ss_n40C_1v76",
)

# Per-corner fields that must agree with the single-corner SPEF report.
CROSS_CHECK_FIELDS = (
    "worst_slack_ns",
    "total_negative_slack_ns",
    "worst_hold_slack_ns",
    "total_negative_hold_slack_ns",
    "fmax_mhz",
    "timing_status",
    "setup_violation_count",
    "hold_violation_count",
    "clock_skew_ns",
    "estimated_power_mw",
    "spef_annotation",
)


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_sha256(value) -> bool:
    return (
        isinstance(value, str)
        and value.startswith("sha256:")
        and len(value) == len("sha256:") + 64
    )


#: Absolute uncertainty (ns) of the reported `worst_slack_ns` as an input to
#: the fmax consistency check. OpenROAD's `report_worst_slack_metric` and
#: `report_fmax_metric` are each derived from unrounded internal values and
#: published to ~4 decimals, so `1000 / (T - WNS)` reproduces `fmax_mhz`
#: only to within that slack resolution -- a relative error of
#: `WNS_RESOLUTION_NS / (T - WNS)`, which is ~1e-4 at the fast corners
#: where `T - WNS` is ~0.4 ns. Measured worst case on the committed
#: envelope: 1.1e-4 relative (ff_100C_1v95). The check still resolves the
#: clock period to ~0.1 ps: a request with any other period fails it.
WNS_RESOLUTION_NS = 6e-5


def _fmax_consistent(wns: float, fmax: float) -> bool:
    """`fmax_mhz == 1000 / (T - wns)` within the slack resolution above."""
    remaining = CLOCK_PERIOD_NS - wns
    if remaining <= 0:
        return False
    rel_tol = WNS_RESOLUTION_NS / remaining + 1e-5
    return math.isclose(fmax, 1000.0 / remaining, rel_tol=rel_tol)


def check(envelope: dict, cross_check_dir=None, observation=False) -> list:
    failures = []

    def fail(message: str) -> None:
        failures.append(message)

    if envelope.get("status") != "ok":
        fail(f"status is {envelope.get('status')!r}, not 'ok'")
    if envelope.get("geometry_source") != "routed":
        fail(f"geometry_source is {envelope.get('geometry_source')!r}, not 'routed'")
    for key in ("layout_def_sha256", "layout_gds_sha256", "spef_sha256"):
        if not _is_sha256(envelope.get(key)):
            fail(f"{key} is not a sha256 pin (got {envelope.get(key)!r})")
    input_hash = ((envelope.get("provenance") or {}).get("input") or {}).get(
        "content_hash"
    )
    if not _is_sha256(input_hash):
        fail("provenance.input.content_hash (the analysed DEF) is missing")

    corners = envelope.get("corners")
    if not isinstance(corners, list) or not corners:
        fail("no corners[] list -- not a multi-corner klt sta envelope")
        return failures

    names = [c.get("corner") if isinstance(c, dict) else None for c in corners]
    duplicates = sorted({n for n in names if names.count(n) > 1 and n is not None})
    missing = sorted(set(RATIFIED_CORNERS) - set(names))
    extra = sorted(set(names) - set(RATIFIED_CORNERS), key=str)
    if duplicates:
        fail(f"duplicate corner(s): {', '.join(duplicates)}")
    if missing:
        fail(f"ratified corner(s) missing from the envelope: {', '.join(missing)}")
    if extra:
        fail(f"corner(s) outside the ratified set: {', '.join(map(str, extra))}")
    if len(names) != len(RATIFIED_CORNERS):
        fail(f"{len(names)} corner entries, expected exactly {len(RATIFIED_CORNERS)}")

    for entry in corners:
        if not isinstance(entry, dict):
            fail("a corners[] entry is not an object")
            continue
        name = entry.get("corner")
        where = f"corner {name}"
        deck = entry.get("deck") or {}
        if deck.get("name") != f"{STD_CELL_LIBRARY}__{name}":
            fail(f"{where}: deck.name is {deck.get('name')!r}")
        if not _is_sha256(deck.get("content_hash")):
            fail(f"{where}: deck.content_hash is not a sha256 pin")
        setup = entry.get("worst_slack_ns")
        hold = entry.get("worst_hold_slack_ns")
        if observation:
            # Issue #113: experimental observation. The verdict is recorded
            # as found (a violating or unconstrained corner is publishable),
            # but the numbers must still be real measurements: a status of
            # "constrained" is required before any slack is read, because
            # the unconstrained sentinel (1e+39) is not a measurement.
            if entry.get("timing_status") not in ("constrained", "unconstrained"):
                fail(f"{where}: timing_status is {entry.get('timing_status')!r}")
        else:
            if entry.get("timing_status") != "constrained":
                fail(f"{where}: timing_status is {entry.get('timing_status')!r}, not 'constrained'")
            if not _is_number(setup) or setup < 0:
                fail(f"{where}: worst_slack_ns is {setup!r} (must be a number >= 0)")
            if not _is_number(hold) or hold < 0:
                fail(f"{where}: worst_hold_slack_ns is {hold!r} (must be a number >= 0)")
            for key in ("setup_violation_count", "hold_violation_count"):
                if entry.get(key) != 0:
                    fail(f"{where}: {key} is {entry.get(key)!r}, not 0")
            for key in ("total_negative_slack_ns", "total_negative_hold_slack_ns"):
                if entry.get(key) != 0:
                    fail(f"{where}: {key} is {entry.get(key)!r}, not 0")
        annotation = entry.get("spef_annotation") or {}
        if annotation.get("annotation_complete") is not True:
            fail(f"{where}: spef_annotation.annotation_complete is not true")
        fmax = entry.get("fmax_mhz")
        if observation:
            pass
        elif _is_number(setup) and _is_number(fmax):
            if not _fmax_consistent(setup, fmax):
                fail(
                    f"{where}: fmax_mhz {fmax} is inconsistent with a "
                    f"{CLOCK_PERIOD_NS:g} ns clock at WNS {setup} ns"
                )
        else:
            fail(f"{where}: fmax_mhz is {fmax!r}")

        if cross_check_dir is None or name not in RATIFIED_CORNERS:
            continue
        single_path = os.path.join(cross_check_dir, name, "spef.sta.json")
        try:
            with open(single_path, encoding="utf-8") as f:
                single = json.load(f)
        except (OSError, ValueError) as exc:
            fail(f"{where}: cannot read single-corner report {single_path}: {exc}")
            continue
        drift = [k for k in CROSS_CHECK_FIELDS if entry.get(k) != single.get(k)]
        single_prov = single.get("provenance") or {}
        if deck.get("content_hash") != (single_prov.get("deck") or {}).get("content_hash"):
            drift.append("deck.content_hash")
        if input_hash != (single_prov.get("input") or {}).get("content_hash"):
            drift.append("provenance.input.content_hash")
        for key in ("spef_sha256", "layout_def_sha256", "layout_gds_sha256"):
            if envelope.get(key) != single.get(key):
                drift.append(key)
        if drift:
            fail(
                f"{where}: multi-corner entry disagrees with {single_path} on: "
                + ", ".join(drift)
            )

    return failures


def main(argv: list) -> int:
    args = argv[1:]
    cross_check_dir = None
    expect = None
    observation = False
    positional = []
    while args:
        arg = args.pop(0)
        if arg == "--cross-check" and args:
            cross_check_dir = args.pop(0)
        elif arg == "--expect-corners" and args:
            expect = [c for c in args.pop(0).split(",") if c]
        elif arg == "--observation":
            observation = True
        elif arg.startswith("--"):
            positional = []
            break
        else:
            positional.append(arg)
    if len(positional) != 1:
        print(
            f"usage: {argv[0]} <envelope.json> [--cross-check <corners-dir>] "
            "[--expect-corners c1,c2,...] [--observation]",
            file=sys.stderr,
        )
        return 2

    failures = []
    if expect is not None and sorted(expect) != sorted(RATIFIED_CORNERS):
        failures.append(
            "the caller's corner list differs from RATIFIED_CORNERS: "
            f"caller-only {sorted(set(expect) - set(RATIFIED_CORNERS))}, "
            f"ratified-only {sorted(set(RATIFIED_CORNERS) - set(expect))}"
        )
    with open(positional[0], encoding="utf-8") as f:
        envelope = json.load(f)
    failures += check(envelope, cross_check_dir, observation)

    if failures:
        print(f"sta envelope check FAILED for {positional[0]}:", file=sys.stderr)
        for message in failures:
            print(f"  - {message}", file=sys.stderr)
        return 1
    if observation:
        statuses = sorted({str(c.get("timing_status")) for c in envelope["corners"]})
        print(
            f"sta observation envelope ok (structure only, verdicts NOT gated): "
            f"{len(envelope['corners'])} corners, timing_status {statuses}, "
            "SPEF annotation complete"
        )
        return 0
    binding = min(envelope["corners"], key=lambda c: c["worst_slack_ns"])
    print(
        f"sta envelope ok: {len(envelope['corners'])}/{len(RATIFIED_CORNERS)} ratified "
        "corners, all constrained, setup/hold non-negative, SPEF annotation complete; "
        f"binding setup corner {binding['corner']} WNS {binding['worst_slack_ns']} ns"
        + (" (cross-checked against the per-corner reports)" if cross_check_dir else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
