#!/usr/bin/env python3
"""Control-jump directional route diagnostic streams for the single-LOGIC4 harness (issue #181).

EXPERIMENTAL, DIAGNOSTIC ONLY. Writes one assembler-generated frame stream per
(control sink, directional source) route that the existing switch-matrix
description offers into a control-jump mux, for sim/tb_ctrl_route.v (run by
flow/generated_tile_replay.sh on the generated LOGIC4 tile through
FrameData/FrameStrobe, and on the repository composition). These are NOT
mapper output and make no routing, mapper-policy, timing or ratified-fabric
claim; the matrix is not widened.

Neighbouring checks this is different from:
  * the LUT-input route diagnostic (flow/route_diag.py, #176) covers LUT inputs;
  * the registered fixtures (#156) exercise each BEL's EN/SR once, not every
    directional source;
  * design/fabulous/tb_switch_matrix_equiv.v drives matrix select fields directly.

Required set: derived from the frozen pip model in sim/bitstream/fabric_spec.json:
  EN  every pip <N|E|S|W>1END<k> -> J_EN_BEG<k> (k = 0..3), whose enable reaches
      exactly BEL k through J_EN_BEG<k> -> J_EN_END<k> -> L<k>_EN: 4 x 4 = 16
  SR  every pip <N|E|S|W>1END0 -> J_SR_BEG0, whose reset reaches all four BELs
      through J_SR_BEG0 -> J_SR_END0 -> L<x>_SR: 4
= 20 route obligations. The generator fails if the case list differs from that
set (missing or duplicate) or the destination fan-out is not as stated.

Every stream configures all four BELs identically as a registered constant-one
function (FF=1, INIT = all ones), so the register state is independently
observable and no data track is needed (control and data cannot contend for a
track). It routes all four enables and the reset from explicit edges and each
BEL output to its own output track S1BEG<j> (j = BEL index). The case line
records only identifiers and the chosen role edges:

    <case> <EN|SR> <bel|-> <tested edge> <reset edge> <four enable edges, BEL A..D>

  EN_<X>_<E>  enable of BEL X is routed from edge E (tested); the other three
              enables are routed from idle edges; reset from a distinct edge.
  SR_<E>      shared reset is routed from edge E (tested); each BEL's enable is
              routed from its own edge.

Case order is EN (edge-major, then BEL) then SR, so consecutive streams on one
live tile change the selected source; the generator checks that every stream
differs from its predecessor. Every route is set only through FASM pips and
features processed by the existing assembler; no ConfigBits index is computed
here. The expected register state is derived by sim/tb_ctrl_route.v from the
case identifier and the applied stimulus only.

Usage: flow/ctrl_route.py <out dir> [--snapshot sim/bitstream/fabric_spec.json]
Writes <out>/<case>.fasm/.bin/.cfg, <out>/ctrl.wiring, <out>/cases.txt and
<out>/required.txt (the sorted required "<EN|SR> <bel|-> <edge>" coverage keys).
"""
import argparse
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


F = _load("fasm_to_bitstream", REPO / "flow" / "fasm_to_bitstream.py")

BELS = "ABCD"
EDGES = "NESW"          # tin[4*dir + idx] order of the benches: 0=N 1=E 2=S 3=W
LOGIC = "X1Y1"


def required_routes(snap):
    """-> set of ('EN', bel, edge) / ('SR', '-', edge) read from the frozen pip model."""
    pips = {(sw, dw) for st, sw, dt, dw in snap["pips"] if st == LOGIC and dt == LOGIC}
    req = set()
    for sw, dw in pips:
        if len(sw) != 6 or sw[0] not in EDGES or sw[1:5] != "1END" or sw[5] not in "0123":
            continue
        k = int(sw[5])
        if dw.startswith("J_EN_BEG"):
            if dw != f"J_EN_BEG{k}":
                raise F.AsmError(f"matrix offers non-same-index enable source {sw} -> {dw}; extend the diagnostic deliberately")
            req.add(("EN", BELS[k], sw[0]))
        elif dw.startswith("J_SR_BEG"):
            if dw != "J_SR_BEG0" or k != 0:
                raise F.AsmError(f"matrix offers unexpected reset source {sw} -> {dw}; extend the diagnostic deliberately")
            req.add(("SR", "-", sw[0]))
    # destination fan-out: enable k reaches exactly BEL k, reset reaches every BEL
    for k, x in enumerate(BELS):
        for need in ((f"J_EN_BEG{k}", f"J_EN_END{k}"), (f"J_EN_END{k}", f"L{x}_EN"),
                     ("J_SR_BEG0", "J_SR_END0"), ("J_SR_END0", f"L{x}_SR")):
            if need not in pips:
                raise F.AsmError(f"pip {LOGIC}.{need[0]}.{need[1]} is not in the frozen fabric model")
    en_dest = {(sw, dw) for sw, dw in pips if dw.endswith("_EN")}
    if en_dest != {(f"J_EN_END{k}", f"L{x}_EN") for k, x in enumerate(BELS)}:
        raise F.AsmError(f"enable destination fan-out differs from one jump wire per BEL: {sorted(en_dest)}")
    sr_dest = {(sw, dw) for sw, dw in pips if dw.endswith("_SR")}
    if sr_dest != {("J_SR_END0", f"L{x}_SR") for x in BELS}:
        raise F.AsmError(f"reset destination fan-out differs from one shared jump wire: {sorted(sr_dest)}")
    return req


def _roles(kind, bel, edge):
    """-> (reset edge, four enable edges as a string), distinct on track index 0."""
    e = EDGES.index(edge)
    if kind == "SR":
        return edge, "".join(EDGES[(e + 1 + k) % 4] for k in range(4))
    k0 = BELS.index(bel)
    en = [EDGES[e] if k == k0 else EDGES[(e + 1 + k) % 4] for k in range(4)]
    r = EDGES[(e + 1) % 4] if k0 == 0 else EDGES[(e + 2) % 4]
    return r, "".join(en)


def cases(req):
    """-> [(case_id, kind, bel, edge, reset edge, enable edges)] in load order."""
    out = []
    for e in EDGES:
        for x in BELS:
            if ("EN", x, e) in req:
                r, en = _roles("EN", x, e)
                out.append((f"C_EN_{x}_{e}", "EN", x, e, r, en))
    for e in EDGES:
        if ("SR", "-", e) in req:
            r, en = _roles("SR", "-", e)
            out.append((f"C_SR_{e}", "SR", "-", e, r, en))
    return out


def fasm_text(case_id, kind, bel, edge, redge, en):
    L = [f"# issue #181 control-route diagnostic case {case_id} (assembler-generated, not mapper output)"]
    for k, x in enumerate(BELS):
        L += [f"{LOGIC}.{en[k]}1END{k}.J_EN_BEG{k}", f"{LOGIC}.J_EN_BEG{k}.J_EN_END{k}",
              f"{LOGIC}.J_EN_END{k}.L{x}_EN"]
    L += [f"{LOGIC}.{redge}1END0.J_SR_BEG0", f"{LOGIC}.J_SR_BEG0.J_SR_END0"]
    L += [f"{LOGIC}.J_SR_END0.L{x}_SR" for x in BELS]
    L += [f"{LOGIC}.L{x}_O.S1BEG{j}" for j, x in enumerate(BELS)]
    for x in BELS:
        L += [f"{LOGIC}.{x}.INIT[15:0] = 'b{'1' * 16}", f"{LOGIC}.{x}.FF"]
    return "\n".join(L) + "\n"


def pips_of_case(text):
    """The control pips of a rendered FASM, as {'en': [edge per BEL], 'sr': edge} (self-check helper)."""
    en, sr = [None] * 4, None
    for it in F.parse_fasm(text):
        parts = it["name"].split(".")
        if it["hi"] is not None or len(parts) != 2:
            continue
        s, d = parts
        if d.startswith("J_EN_BEG"):
            en[int(d[-1])] = s[0]
        elif d == "J_SR_BEG0":
            sr = s[0]
    return {"en": en, "sr": sr}


def check_model_pips(snap, rows):
    model = {(sw, dw) for st, sw, dt, dw in snap["pips"] if st == LOGIC and dt == LOGIC}
    for cid, kind, bel, edge, redge, en in rows:
        wanted = [(f"{redge}1END0", "J_SR_BEG0")] + [(f"{en[k]}1END{k}", f"J_EN_BEG{k}") for k in range(4)]
        wanted += [(f"L{x}_O", f"S1BEG{j}") for j, x in enumerate(BELS)]
        for sw, dw in wanted:
            if (sw, dw) not in model:
                raise F.AsmError(f"{cid}: pip {LOGIC}.{sw}.{dw} is not in the frozen fabric model")


def manifest(snap, ltile):
    cols, rows = snap["grid"]
    _, lx, ly = ltile
    out = [f"GRID {cols} {rows}", f"TILE {lx} {ly}"]
    out += [f"OUT {x} {EDGES.index('S')} {j}" for j, x in enumerate(BELS)]   # S1BEG<j>
    out.append("END")
    return "\n".join(out) + "\n"


def generate(out_dir, snap_path):
    snap = F.load_snapshot(snap_path)
    req = required_routes(snap)
    if len(req) != 20:
        raise F.AsmError(f"expected 20 required control routes, snapshot offers {len(req)}")
    rows = cases(req)
    keys = [(k, b, e) for _, k, b, e, _, _ in rows]
    if len(set(keys)) != len(keys) or set(keys) != req:
        raise F.AsmError("case list does not cover the required control-route set exactly once")
    for cid, kind, bel, edge, redge, en in rows:
        if en[0] == redge:
            raise F.AsmError(f"{cid}: reset and enable A share the index-0 track edge {redge}")
        if kind == "EN" and en[BELS.index(bel)] != edge:
            raise F.AsmError(f"{cid}: tested enable edge mismatch")
        if kind == "SR" and redge != edge:
            raise F.AsmError(f"{cid}: tested reset edge mismatch")
    check_model_pips(snap, rows)
    ltile = F.logic_tile(snap)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    prev_cfg, lst, cfgs = None, [], set()
    for cid, kind, bel, edge, redge, en in rows:
        text = fasm_text(cid, kind, bel, edge, redge, en)
        if pips_of_case(text) != {"en": list(en), "sr": redge}:
            raise F.AsmError(f"{cid}: rendered FASM does not route the recorded role edges")
        asm = F.assemble(text, snap, None)
        data = F.pack(asm["positions"], snap)
        cfg, _ = F.decode(data, snap)
        if cfg != asm["cfg"]:
            raise F.AsmError(f"{cid}: decode(pack()) != assembled cfg")
        if sorted(asm["bel_used"]) != [0, 1, 2, 3]:
            raise F.AsmError(f"{cid}: expected all four BELs configured")
        if cfg == prev_cfg:
            raise F.AsmError(f"{cid}: stream identical to its predecessor (no reprogramming)")
        prev_cfg = cfg
        cfgs.add(cfg)
        (out / f"{cid}.fasm").write_text(text)
        (out / f"{cid}.bin").write_bytes(data)
        (out / f"{cid}.cfg").write_text(f"{cfg:040x}\n")
        lst.append(f"{cid} {kind} {bel} {edge} {redge} {en}")
    if len(cfgs) != len(rows):
        raise F.AsmError("two control-route cases assemble to the same configuration")
    (out / "ctrl.wiring").write_text(manifest(snap, ltile))
    (out / "cases.txt").write_text("\n".join(lst) + "\n")
    (out / "required.txt").write_text("\n".join(sorted(f"{k} {b} {e}" for k, b, e in req)) + "\n")
    print(f"ctrl_route: {len(lst)} streams = 16 enable (4 BELs x 4 edges) + 4 shared-reset edges, every one a pip "
          f"of the frozen model, assembled through flow/fasm_to_bitstream.py; required set read from the snapshot")
    return lst


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("out")
    ap.add_argument("--snapshot", default=str(REPO / "sim" / "bitstream" / "fabric_spec.json"))
    a = ap.parse_args(argv)
    try:
        generate(a.out, a.snapshot)
    except (F.AsmError, F.BitstreamError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
