#!/usr/bin/env python3
"""flow/lvs_report_trim.py

Reduce a `klt lvs --format json` response to the stable, committable
evidence written as `layout/logic_tile.lvs.json` -- mirroring
`flow/par_report_trim.py`'s and `flow/drc_report_trim.py`'s own rationale:
strip fields that change on a toolchain upgrade or an invoking machine's
own scratch-directory layout alone (`provenance.klt_version`,
`provenance.klayout_version`, `environment.engine_version`, and the
top-level `layout`/`reference` fields, which `klt lvs` echoes back as this
invocation's local absolute paths into `flow/build/lvs/` -- gitignored
scratch, never reproducible across machines/checkouts) so re-running this
flow does not produce a spurious diff against the committed report.

Also injects two content-addressed provenance fields tied to *persistent*,
git-tracked sources (rather than `klt lvs`'s own `environment.layout_sha256`
/ `reference_sha256`, which hash the ephemeral scratch netlists this run
derived them from) -- this is the "layout hash / netlist hash" issue #12's
acceptance criteria calls for, checkable at any later point without
re-running the flow:

- `layout_gds_sha256` -- sha256 of the committed `layout/logic_tile.gds`
  bytes this LVS run actually extracted from (matches
  `layout/logic_tile.drc.json`'s own `provenance.input.content_hash`
  convention).
- `rtl_input_sha256` -- the same `provenance.input.content_hash` `klt
  synthesize` computed over `design/rtl/lut4_slice.v` + `design/rtl/
  logic_tile.v` while deriving this run's as-built reference netlist
  (matches `layout/logic_tile.par.json`'s own provenance.input.content_hash
  field for the same RTL when unchanged).

Usage:
    lvs_report_trim.py <response.json> <layout_gds_sha256> <rtl_input_sha256> <output.json>
"""

import sys

from _report_trim import run_cli, strip_nested

_DROP_TOP_LEVEL = ("layout", "reference")
_DROP_ENVIRONMENT = ("engine_version",)
_DROP_PROVENANCE = ("klt_version", "klayout_version")


def trim(response: dict, layout_gds_sha256: str, rtl_input_sha256: str) -> dict:
    trimmed = dict(response)
    for key in _DROP_TOP_LEVEL:
        trimmed.pop(key, None)
    trimmed = strip_nested(trimmed, "environment", _DROP_ENVIRONMENT)
    trimmed = strip_nested(trimmed, "provenance", _DROP_PROVENANCE)
    trimmed["layout_gds_sha256"] = layout_gds_sha256
    trimmed["rtl_input_sha256"] = rtl_input_sha256
    return trimmed


def main(argv: list) -> int:
    return run_cli(argv, trim, extra_args=("layout_gds_sha256", "rtl_input_sha256"))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
