#!/usr/bin/env python3
"""flow/routed_pitch.py

Measure (not decide) the observed routing pitch / utilization of the
EXPERIMENTAL composed tile from its routed DEF and P&R report (issue #108,
G3 item (a) input). Read-only; deterministic; stdlib only.

Reports, per metal layer: the DEF track-grid pitch (um) the router used, and
the routed wire segments / total routed length / via counts actually found in
the DEF NETS section. Plus die/core area and utilization from the P&R report.

This is an observation of the same-index stand-in matrix (ADR-0004 Proposed).
It is NOT a pitch commitment: spec/tile-spec.md defers the physical pitch to a
decision record, and nothing here amends it.

Usage:  routed_pitch.py <routed.def> <routed.par.json> <output.json>
"""
import json
import re
import sys

LAYERS = ("li1", "met1", "met2", "met3", "met4", "met5")
PT = re.compile(r"\(\s*([-\d*]+)\s+([-\d*]+)(?:\s+[-\d*]+)?\s*\)")
RECT = re.compile(r"RECT\s*\([^)]*\)|TAPER")


def measure(def_text: str, par: dict) -> dict:
    units = int(re.search(r"UNITS DISTANCE MICRONS (\d+)", def_text).group(1))

    def um(v):
        return v / units

    tracks = {}
    for m in re.finditer(r"TRACKS ([XY]) (\d+) DO (\d+) STEP (\d+) LAYER (\w+)", def_text):
        axis, _start, _n, step, layer = m.groups()
        tracks.setdefault(layer, {})[axis] = um(int(step))
    nets_body = def_text.split("\nNETS ", 1)[1].split("\nEND NETS", 1)[0]
    net_count = int(nets_body.split()[0])
    seg_count = {layer: 0 for layer in LAYERS}
    seg_len = {layer: 0.0 for layer in LAYERS}
    vias = {}
    for line in nets_body.splitlines():
        m = re.match(r"\s*(?:\+ ROUTED|NEW)\s+(\w+)\s+(.*)$", line)
        if not m:
            continue
        layer, rest = m.groups()
        rest = RECT.sub("", rest)
        pts = PT.findall(rest)
        tail = PT.sub("", rest).replace(";", "").strip()
        if len(pts) == 1 and tail:
            vias[tail] = vias.get(tail, 0) + 1  # `layer ( x y ) VIA_NAME`
            continue
        if len(pts) == 2 and layer in seg_count:
            (x1, y1), (x2, y2) = pts
            x2 = x1 if x2 == "*" else x2
            y2 = y1 if y2 == "*" else y2
            seg_count[layer] += 1
            seg_len[layer] += um(abs(int(x2) - int(x1)) + abs(int(y2) - int(y1)))
    return {
        "schema": "sky130-fpga.routed-pitch-measurement/1",
        "status": "experimental-measurement",
        "note": "Observation of the ADR-0004-Proposed stand-in matrix; not a pitch commitment (spec/tile-spec.md defers it).",
        "def_units_per_um": units,
        "track_pitch_um": {layer: tracks[layer] for layer in LAYERS if layer in tracks},
        "routed_segments_by_layer": seg_count,
        "routed_length_um_by_layer": {k: round(v, 3) for k, v in seg_len.items()},
        "via_instances_by_name": dict(sorted(vias.items())),
        "net_count": net_count,
        "component_count": int(re.search(r"^COMPONENTS (\d+)", def_text, re.M).group(1)),
        "die_area_um2": par.get("die_area_um2"),
        "core_area_um2": par.get("core_area_um2"),
        "utilization_pct": par.get("utilization_pct"),
        "wirelength_um_reported": par.get("wirelength_um"),
    }


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    def_text = open(argv[1], encoding="utf-8").read()
    par = json.load(open(argv[2], encoding="utf-8"))
    out = measure(def_text, par)
    with open(argv[3], "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
