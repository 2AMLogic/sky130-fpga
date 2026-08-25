#!/usr/bin/env python3
"""flow/_report_trim.py

Shared CLI driver and nested-dict-strip helper for the `flow/*_report_trim.py`
scripts (`par_report_trim.py`, `drc_report_trim.py`, `lvs_report_trim.py`).
Each of those scripts reduces a `klt <tool> --format json` response to the
stable subset committed as `layout/logic_tile.*.json` evidence; this module
holds only the boilerplate that was previously hand-copied across all three:
the `main(argv)` shape (argv-length check, JSON load, call the tool-specific
`trim()`, JSON-dump with `indent=2, sort_keys=True` and a trailing newline)
and the "copy a nested dict, pop keys out of it, put it back" pattern each
script applies to `provenance` and one other nested container.

Not a public API beyond this package's own three callers -- hence the
leading underscore in the filename.
"""

import json
import sys


def strip_nested(d: dict, container_key: str, drop_keys: tuple) -> dict:
    """Return a copy of `d` with `drop_keys` popped from its `container_key`
    sub-dict, leaving `d` itself and any other keys untouched. No-op if
    `container_key` is absent or not a dict."""
    if container_key not in d or not isinstance(d[container_key], dict):
        return d
    result = dict(d)
    container = dict(result[container_key])
    for key in drop_keys:
        container.pop(key, None)
    result[container_key] = container
    return result


def run_cli(argv: list, trim_fn, extra_args: tuple = ()) -> int:
    """Shared `main(argv)` body: `<response.json> [extra_args...]
    <output.json>`, loading `response.json`, calling
    `trim_fn(response, *extras)`, and JSON-dumping the result to
    `output.json`."""
    nargs = 3 + len(extra_args)
    if len(argv) != nargs:
        usage = " ".join(f"<{name}>" for name in extra_args)
        usage = f" {usage}" if usage else ""
        print(
            f"usage: {argv[0]} <response.json>{usage} <output.json>",
            file=sys.stderr,
        )
        return 2
    src = argv[1]
    extras = argv[2 : 2 + len(extra_args)]
    dst = argv[-1]
    with open(src, encoding="utf-8") as f:
        response = json.load(f)
    trimmed = trim_fn(response, *extras)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(trimmed, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0
