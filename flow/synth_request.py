#!/usr/bin/env python3
"""flow/synth_request.py

Single source of the `klt.synthesize.request/1` document that
`flow/layout.sh`, `flow/sdf-resim.sh` and `flow/layout_routed.sh` all
submit to `klt synthesize` for the tile.

Why this exists (issue #261): all three scripts used to build this request
with their own hand-written copies -- a `cat > ... <<EOF` heredoc in
`flow/layout.sh` and `flow/sdf-resim.sh` (byte-identical between the two,
but nothing shared the text) and an inline `json.dump` in
`flow/layout_routed.sh`. This is the synthesize-stage sibling of
flow/par_request.py's issue #44 rationale, one stage upstream of it:
`flow/sdf-resim.sh`'s whole premise is that its regenerated DEF is
byte-identical to the committed `layout/logic_tile.def` -- which requires
its synthesis netlist to match `flow/layout.sh`'s -- which required those
copies to stay identical by hand. Single-sourcing the request body here
removes that divergence path; `flow/sdf-resim.sh`'s byte-diff still proves
reproducibility, it just no longer has to *discover* a divergence that
could have been prevented.

The fields that are identical across every caller (schema, engine, PDK
cell library, corner) are hardcoded constants below -- adding or changing
one of them requires editing only this file, not any caller. The fields
that legitimately vary by caller (the source files each run synthesizes,
the toplevel, the clock period) are parameters -- `flow/layout_routed.sh`
synthesizes three sources under a different toplevel than the other two,
even though all three pass the same clock period.

Usage:
    synth_request.py <output.json> \\
        --source <rtl.v> [--source <rtl.v> ...] \\
        --hdl-toplevel <name> --clock-period-ns <n>

Writes the `klt.synthesize.request/1` JSON document to <output.json>.
"""

from __future__ import annotations

import argparse
import json
import sys

# Fields identical across every caller -- the single source this issue asks
# for. A future field (e.g. a synthesis strategy knob) belongs here.
_ENGINE = "yosys"
_CELL_LIBRARY = "sky130_fd_sc_hd"
_CORNER = "tt_025C_1v80"


def build_request(
    sources: list[str],
    hdl_toplevel: str,
    clock_period_ns: float,
) -> dict:
    return {
        "schema": "klt.synthesize.request/1",
        "engine": _ENGINE,
        "sources": list(sources),
        "hdl_toplevel": hdl_toplevel,
        "pdk": {"cell_library": _CELL_LIBRARY, "corner": _CORNER},
        "constraints": {"clock_period_ns": clock_period_ns},
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_path")
    parser.add_argument("--source", action="append", required=True)
    parser.add_argument("--hdl-toplevel", required=True)
    parser.add_argument("--clock-period-ns", required=True, type=float)
    args = parser.parse_args(argv[1:])

    # Same integral normalization flow/par_request.py applies, so a caller
    # passing "20" writes 20, not 20.0 -- the shape every caller's
    # hand-written copy produced.
    clock_period_ns = args.clock_period_ns
    if clock_period_ns == int(clock_period_ns):
        clock_period_ns = int(clock_period_ns)

    request = build_request(
        sources=args.source,
        hdl_toplevel=args.hdl_toplevel,
        clock_period_ns=clock_period_ns,
    )
    with open(args.output_path, "w", encoding="utf-8") as f:
        json.dump(request, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
