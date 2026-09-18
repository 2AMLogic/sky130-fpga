#!/usr/bin/env python3
"""flow/par_request.py

Single source of the `klt.place_and_route.request/1` document that
`flow/layout.sh` and `flow/sdf-resim.sh` both submit to `klt
place-and-route` for the tile.

Why this exists (issue #44): both scripts used to build this request with
their own `cat > ... <<EOF` heredoc. The two runs must describe the *exact
same* place-and-route -- `flow/sdf-resim.sh`'s whole premise is that its
regenerated DEF is byte-identical to the committed `layout/logic_tile.def`
(see that script's own header comment) -- but nothing shared the text
between them. Issue #44 was filed after adding a field to `flow/layout.sh`'s
request alone silently made `flow/sdf-resim.sh` regenerate a *different*
DEF, caught only because that script happens to byte-diff the DEF it
re-derives. Single-sourcing the request body here removes that foot-gun;
the byte-diff in `flow/sdf-resim.sh` still proves reproducibility, it just
no longer has to *discover* a divergence that could have been prevented.

The fields that are always identical between the two callers (schema,
engine, PDK/cell library, floorplan, io, seed, target_stage) are hardcoded
constants below -- adding or changing one of them requires editing only
this file, not either caller. The fields that legitimately vary by caller
(the netlist path each run produces, and `flow/sdf-resim.sh`'s two extra
`post_route_spef`/`post_route_sdf` fields) are parameters. `hdl_toplevel`,
`clock_port` and `clock_period_ns` are also parameters even though both
current callers pass the same values, since `flow/layout.sh` and
`flow/sdf-resim.sh` each already hold their own copy of those three (used
elsewhere in each script, e.g. in the `klt synthesize` request) -- this
avoids inventing a second, silently-divergible copy of a value each script
must keep locally anyway.

Usage:
    par_request.py <netlist_path> <output.json> \\
        --hdl-toplevel <name> --clock-port <name> --clock-period-ns <n> \\
        [--post-route-spef] [--post-route-sdf]

Writes the `klt.place_and_route.request/1` JSON document to <output.json>.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys

# Fields identical across every caller -- the single source this issue asks
# for. A future field (e.g. a power/PDN block) belongs here.
_ENGINE = "openroad"
_CELL_LIBRARY = "sky130_fd_sc_hd"
_CORNER = "tt_025C_1v80"
_FLOORPLAN = {
    "method": "utilization",
    "utilization_pct": 40,
    "aspect_ratio": 1.0,
    "core_margin_um": 2.0,
    "site": "unithd",
}
_IO = {"layer_h": "met3", "layer_v": "met2"}

# The power delivery network (issue #41). Until this block existed, `klt
# place-and-route` drew only its unconditional `met1 -followpins` row rail
# over the standard-cell PG pins: 15 mutually isolated stripes, no straps,
# no via stack and no tapcells, i.e. a layout that could not be powered as
# drawn. `flow/lvs.sh`'s signal-connectivity-only compare cannot see that
# (its `gate-level-verilog` reference carries no supply pins at all), which
# is why the gap survived an LVS "match" -- `flow/erc.sh` is the check that
# binds it now.
#
# This is precisely the shared field par_request.py's header anticipated:
# it MUST be identical between flow/layout.sh and flow/sdf-resim.sh, since
# a PDN in one and not the other changes the floorplan and breaks
# sdf-resim's byte-identical-DEF premise (that is exactly the class of
# foot-gun issue #44 filed this file to remove).
#
# Geometry follows the block already in production on this PDK in the
# sibling `sky130-modexp` / `sky130-sar-adc` repos rather than being tuned
# here -- met1 followpins on the 5.44um `unithd` row pitch, met4/met5
# straps on a ~27um pitch offset to the die centre. Nothing in this repo
# sizes it against a current budget; see layout/README.md's "Power delivery
# network" section for what the resulting claim does and does not cover.
_POWER = {
    "power_net": "VPWR",
    "ground_net": "VGND",
    "straps": [
        {
            "layer": "met1",
            "width_um": 0.48,
            "pitch_um": 5.44,
            "offset_um": 0.0,
            "followpins": True,
        },
        {"layer": "met4", "width_um": 1.6, "pitch_um": 27.14, "offset_um": 13.57},
        {"layer": "met5", "width_um": 1.6, "pitch_um": 27.2, "offset_um": 13.6},
    ],
}
_SEED = 1
_TARGET_STAGE = "route"


def build_request(
    netlist_path: str,
    hdl_toplevel: str,
    clock_port: str,
    clock_period_ns: float,
    post_route_spef: bool = False,
    post_route_sdf: bool = False,
) -> dict:
    request = {
        "schema": "klt.place_and_route.request/1",
        "engine": _ENGINE,
        "netlist": netlist_path,
        "hdl_toplevel": hdl_toplevel,
        "pdk": {"cell_library": _CELL_LIBRARY, "corner": _CORNER},
        "floorplan": dict(_FLOORPLAN),
        "io": dict(_IO),
        "power": copy.deepcopy(_POWER),
        "constraints": {
            "clock_port": clock_port,
            "clock_period_ns": clock_period_ns,
        },
        "seed": _SEED,
        "target_stage": _TARGET_STAGE,
    }
    if post_route_spef:
        request["post_route_spef"] = True
    if post_route_sdf:
        request["post_route_sdf"] = True
    return request


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("netlist_path")
    parser.add_argument("output_path")
    parser.add_argument("--hdl-toplevel", required=True)
    parser.add_argument("--clock-port", required=True)
    parser.add_argument("--clock-period-ns", required=True, type=float)
    parser.add_argument("--post-route-spef", action="store_true")
    parser.add_argument("--post-route-sdf", action="store_true")
    args = parser.parse_args(argv[1:])

    clock_period_ns = args.clock_period_ns
    if clock_period_ns == int(clock_period_ns):
        clock_period_ns = int(clock_period_ns)

    request = build_request(
        netlist_path=args.netlist_path,
        hdl_toplevel=args.hdl_toplevel,
        clock_port=args.clock_port,
        clock_period_ns=clock_period_ns,
        post_route_spef=args.post_route_spef,
        post_route_sdf=args.post_route_sdf,
    )
    with open(args.output_path, "w", encoding="utf-8") as f:
        json.dump(request, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
