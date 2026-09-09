#!/usr/bin/env python3
"""flow/sta_report_trim.py

Reduce a `klt sta --format json` response to the stable subset committed as
`measurements/timing-characterization/corners/<corner>/{lef-only,spef}.sta.json`
evidence: the timing/power metrics, the SPEF-annotation audit block, and
content-addressed provenance -- with every field that is either a local
absolute filesystem path or a bare tool-version string stripped out.

Same rationale as `flow/par_report_trim.py`: absolute paths (`def_path`,
`spef_path`) point into the invoking machine's own checkout/scratch
directory and are never reproducible across machines, and tool-version
strings (`engine_version`, `provenance.klt_version`,
`provenance.klayout_version`) change on a toolchain upgrade alone, with no
design change involved. `provenance.pdk.source` is stripped for the same
reason `flow/par_report_trim.py` strips it: it names how `find_pdk()`
happened to resolve the PDK in the invoking shell, which flips on whether
`$PDK_ROOT` was exported. `provenance.pdk.name`/`.version` are retained.

Unlike `par_report_trim.py` this script also *injects* two
content-addressed provenance fields, mirroring what
`flow/lvs_report_trim.py` does for LVS:

- `layout_def_sha256` -- the hash of the committed, git-tracked routed DEF
  (`layout/logic_tile.def`) this corner run characterizes. `klt sta`'s own
  `provenance.input.content_hash` hashes the DEF actually handed to
  OpenSTA, which for a SPEF-annotated run is the name-sanitized derivative
  (see `flow/sta_sanitize_names.py`), not the committed file -- so without
  this field a SPEF run's report could not be traced back to the committed
  layout.
- `spef_sha256` -- the hash of the SPEF annotated into this run, or `null`
  for a LEF-only run.

Together with `provenance.deck.content_hash` (the liberty corner) and
`provenance.input.content_hash` (the analysed DEF) these let every
published number be traced back to its extraction run without re-running
the flow, which is `spec/framework-gaps.md` G4's stated verification bar.

Usage:
    sta_report_trim.py <response.json> <layout_def_sha256> <spef_sha256|-> <output.json>

Pass `-` for <spef_sha256> on a LEF-only run.
"""

import sys

from _report_trim import run_cli, strip_nested

_DROP_TOP_LEVEL = ("def_path", "spef_path", "engine_version")
_DROP_PROVENANCE = ("klt_version", "klayout_version")
_DROP_PDK = ("source",)


def trim(response: dict, layout_def_sha256: str, spef_sha256: str) -> dict:
    trimmed = dict(response)
    for key in _DROP_TOP_LEVEL:
        trimmed.pop(key, None)
    trimmed = strip_nested(trimmed, "provenance", _DROP_PROVENANCE)
    if isinstance(trimmed.get("provenance"), dict):
        trimmed["provenance"] = strip_nested(
            trimmed["provenance"], "pdk", _DROP_PDK
        )
    trimmed["layout_def_sha256"] = layout_def_sha256
    trimmed["spef_sha256"] = None if spef_sha256 == "-" else spef_sha256
    return trimmed


def main(argv: list) -> int:
    return run_cli(argv, trim, extra_args=("layout_def_sha256", "spef_sha256"))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
