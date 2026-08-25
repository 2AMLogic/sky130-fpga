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

import json
import sys

_DROP_TOP_LEVEL = ("layout", "reference")
_DROP_PROVENANCE = ("klt_version", "klayout_version")


def trim(response: dict, layout_gds_sha256: str, rtl_input_sha256: str) -> dict:
    trimmed = dict(response)
    for key in _DROP_TOP_LEVEL:
        trimmed.pop(key, None)
    if "environment" in trimmed and isinstance(trimmed["environment"], dict):
        environment = dict(trimmed["environment"])
        environment.pop("engine_version", None)
        trimmed["environment"] = environment
    if "provenance" in trimmed and isinstance(trimmed["provenance"], dict):
        provenance = dict(trimmed["provenance"])
        for key in _DROP_PROVENANCE:
            provenance.pop(key, None)
        trimmed["provenance"] = provenance
    trimmed["layout_gds_sha256"] = layout_gds_sha256
    trimmed["rtl_input_sha256"] = rtl_input_sha256
    return trimmed


def main(argv: list) -> int:
    if len(argv) != 5:
        print(
            f"usage: {argv[0]} <response.json> <layout_gds_sha256> <rtl_input_sha256> <output.json>",
            file=sys.stderr,
        )
        return 2
    src, layout_gds_sha256, rtl_input_sha256, dst = argv[1], argv[2], argv[3], argv[4]
    with open(src, encoding="utf-8") as f:
        response = json.load(f)
    trimmed = trim(response, layout_gds_sha256, rtl_input_sha256)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(trimmed, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
