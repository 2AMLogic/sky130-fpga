#!/usr/bin/env python3
"""LUT-input directional route diagnostic streams for the single-LOGIC4 harness (issue #176).

EXPERIMENTAL, DIAGNOSTIC ONLY. Writes one assembler-generated frame stream per
(BEL, LUT input pin, source edge) route that the existing switch-matrix
description offers into a LUT input, for sim/tb_route_diag.v (run by
flow/generated_tile_replay.sh on the generated LOGIC4 tile through
FrameData/FrameStrobe, and on the repository composition). These are NOT
mapper output and make no routing, mapper-policy, timing or ratified-fabric
claim; the matrix is not widened.

This is different from two neighbouring checks:
  * component select sweeps (design/fabulous/tb_switch_matrix_equiv.v) drive the
    matrix cfg field directly and never go through frame programming;
  * the LUT basis diagnostic (flow/lut_basis.py, issue #172) selects every INIT
    address but routes every LUT input from the single edge S1END.

Required case set: derived from the frozen pip model in
sim/bitstream/fabric_spec.json -- every pip X1Y1.<N|E|S|W>1END<i> -> L<X>_I<p>
(4 BELs x 4 pins x 4 edges = 64 for the current same-index matrix). The
generator fails if the case list differs from that set (missing or duplicate).

Each stream: one pip <edge>1END<p> -> L<X>_I<p> (the route under test), the
BEL output pip L<X>_O -> S1BEG<j> (BEL index j, an existing legal matrix route),
and BEL X INIT = projection of pin p (INIT[a] = a[p]) so that, in combinational
mode, BEL X's output equals the value on the selected boundary track. All other
BELs keep INIT = 0 and no routes (their outputs must stay 0, which exposes
sink/configuration-slice aliasing). Each INIT is set only through a FASM
feature processed by the existing assembler; no ConfigBits index is computed
here. The list records only identifiers: "<case> <BEL> <pin> <edge>".

Case order is edge-major, then pin, then BEL, so consecutive streams on one live
tile change the selected source (and BEL/pin); the generator checks that every
stream differs from its predecessor in the configuration.

Usage: flow/route_diag.py <out dir> [--snapshot sim/bitstream/fabric_spec.json]
Writes <out>/<case>.fasm/.bin/.cfg, <out>/route.wiring, <out>/cases.txt and
<out>/required.txt (the sorted required "<BEL> <pin> <edge>" coverage keys).
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
    """Every (bel, pin, edge) with a pip <edge>1END<pin> -> L<bel>_I<pin> in the logic tile."""
    req = set()
    for st, sw, dt, dw in snap["pips"]:
        if st != LOGIC or dt != LOGIC:
            continue
        if len(dw) == 5 and dw[0] == "L" and dw[1] in BELS and dw[2:4] == "_I" and dw[4] in "0123":
            if len(sw) == 6 and sw[0] in EDGES and sw[1:5] == "1END" and sw[5] in "0123":
                req.add((dw[1], int(dw[4]), sw[0], int(sw[5])))
    bad = [r for r in req if r[1] != r[3]]
    if bad:
        raise F.AsmError(f"matrix offers non-same-index LUT-input sources {sorted(bad)}; extend the diagnostic deliberately")
    return {(b, p, e) for b, p, e, _ in req}


def cases(req):
    """-> [(case_id, bel, pin, edge)] in load order."""
    return [(f"R_{x}_I{p}_{e}", x, p, e) for e in EDGES for p in range(4) for x in BELS
            if (x, p, e) in req]


def init_word(pin):
    """INIT = projection of input pin (INIT[a] = a[pin]); FASM 'b string, MSB = INIT[15]."""
    v = sum(1 << a for a in range(16) if (a >> pin) & 1)
    return format(v, "016b")


def fasm_text(case_id, bel, pin, edge):
    return "\n".join([
        f"# issue #176 route diagnostic case {case_id} (assembler-generated, not mapper output)",
        f"{LOGIC}.{edge}1END{pin}.L{bel}_I{pin}",
    ] + [f"{LOGIC}.L{x}_O.S1BEG{j}" for j, x in enumerate(BELS)] + [
        f"{LOGIC}.{bel}.INIT[15:0] = 'b{init_word(pin)}",
    ]) + "\n"


def check_model_pips(snap, lst):
    model = {(sw, dw) for st, sw, dt, dw in snap["pips"] if st == LOGIC and dt == LOGIC}
    for _, bel, pin, edge in lst:
        for sw, dw in [(f"{edge}1END{pin}", f"L{bel}_I{pin}")] + [(f"L{x}_O", f"S1BEG{j}") for j, x in enumerate(BELS)]:
            if (sw, dw) not in model:
                raise F.AsmError(f"pip {LOGIC}.{sw}.{dw} is not in the frozen fabric model")


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
    if len(req) != 64:
        raise F.AsmError(f"expected 64 required routes, snapshot offers {len(req)}")
    lst = cases(req)
    keys = [(b, p, e) for _, b, p, e in lst]
    if len(set(keys)) != len(keys) or set(keys) != req:
        raise F.AsmError("case list does not cover the required route set exactly once")
    check_model_pips(snap, lst)
    ltile = F.logic_tile(snap)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    prev_cfg, rows = None, []
    for cid, bel, pin, edge in lst:
        text = fasm_text(cid, bel, pin, edge)
        asm = F.assemble(text, snap, None)
        data = F.pack(asm["positions"], snap)
        cfg, _ = F.decode(data, snap)
        if cfg != asm["cfg"]:
            raise F.AsmError(f"{cid}: decode(pack()) != assembled cfg")
        if asm["bel_used"] != ["ABCD".index(bel)]:
            raise F.AsmError(f"{cid}: expected exactly one configured BEL")
        if cfg == prev_cfg:
            raise F.AsmError(f"{cid}: stream identical to its predecessor (no reprogramming)")
        prev_cfg = cfg
        (out / f"{cid}.fasm").write_text(text)
        (out / f"{cid}.bin").write_bytes(data)
        (out / f"{cid}.cfg").write_text(f"{cfg:040x}\n")
        rows.append(f"{cid} {bel} {pin} {edge}")
    # distinct streams: no two cases share a configuration
    cfgs = {(out / f"{c[0]}.cfg").read_text() for c in lst}
    if len(cfgs) != len(lst):
        raise F.AsmError("two route cases assemble to the same configuration")
    (out / "route.wiring").write_text(manifest(snap, ltile))
    (out / "cases.txt").write_text("\n".join(rows) + "\n")
    (out / "required.txt").write_text("\n".join(sorted(f"{b} {p} {e}" for b, p, e in req)) + "\n")
    print(f"route_diag: {len(rows)} streams = 4 BELs x 4 pins x 4 edges, every one a pip of the frozen "
          f"model, assembled through flow/fasm_to_bitstream.py; required set read from the snapshot")
    return rows


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
