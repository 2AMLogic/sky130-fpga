#!/usr/bin/env python3
"""Boundary output-track source diagnostic streams for the single-LOGIC4 harness (issue #180).

EXPERIMENTAL, DIAGNOSTIC ONLY. Writes one assembler-generated frame stream per
(output edge, output track, source) route that the existing switch-matrix
description offers onto a boundary output track, for sim/tb_output_route.v (run
by flow/generated_tile_replay.sh on the generated LOGIC4 tile through
FrameData/FrameStrobe, and on the repository composition). These are NOT
mapper output and make no routing, mapper-policy, timing, inter-tile or
ratified-fabric claim; the matrix is not widened.

Neighbouring checks this is different from:
  * the LUT basis diagnostic (flow/lut_basis.py, #172) uses ONE fixed output
    route set (BEL A..D -> S1BEG0..3);
  * the LUT-input and control-jump route diagnostics (flow/route_diag.py #176,
    flow/ctrl_route.py #181) cover routes INTO the BELs, not out to the tracks;
  * design/fabulous/tb_switch_matrix_equiv.v drives matrix select fields
    directly and never goes through frame programming.

Required set: derived from the frozen pip model in sim/bitstream/fabric_spec.json:
every pip X1Y1.<src>.<E>1BEG<i> into one of the 16 output tracks (4 edges x 4
tracks); each offers the four BEL outputs and the three incoming tracks of the
same index on the other edges = 7 sources, 16 x 7 = 112 (output edge, track,
source) obligations. The generator fails if the case list differs from that set
(missing or duplicate) or the matrix offers a source this generator does not
model.

Tokens: a source is `A`..`D` (BEL output L<X>_O) or `N`/`E`/`S`/`W` (the incoming
track <edge>1END<i> of the sink's own track index i).

Every stream configures ALL 16 output tracks explicitly: the tested sink from
its tested source, and each of the other 15 from a deterministic "background"
source that depends on the case (so consecutive streams reprogram many select
fields at once and an aliased sink shows as a wrong value on a neighbour). It
also configures the four BELs as distinguishable combinational functions of
one input track each, fed from the tested sink's OWN edge E (so no BEL value is
correlated with any candidate source of the tested sink, which are the same-index
tracks of the three OTHER edges):

    BEL A = pin0 of E1END..   BEL B = NOT pin1   BEL C = pin2   BEL D = NOT pin3
    (pin k of BEL <X_k> is the track <E>1END<k>; both polarities appear)

The case line records only identifiers: "<case> <E> <i> <tok> <16 background
tokens>" (background token per sink, sink index 4*edge + track, edge order NESW).
No ConfigBits index is computed here: every route is set only through FASM pips
and features processed by the existing assembler. The expected boundary outputs
are derived by sim/tb_output_route.v from these identifiers and the applied
stimulus only -- never from cfg, the map or internal matrix signals.

Case order is edge-major, then track, then source in the matrix list order
(incoming edges NESW, then BELs A..D).

`predict` (below) is the independent per-case failure model used by
flow/generated_tile_replay.sh for scratch mutants: it re-derives, from this case
list, the stimulus set and the mux source position rule (position 0..2 = the
incoming tracks of the other edges in N,E,S,W order, 3..6 = BEL A..D; the rule
flow/test_output_route.py cross-checks against the assembler's own encoding),
never from the generated RTL or the DUT, which cases a given source permutation
/ sink alias must break.

Usage: flow/output_route.py <out dir> [--snapshot sim/bitstream/fabric_spec.json]
       flow/output_route.py predict <out dir> swap  <sink> <posA> <posB>
       flow/output_route.py predict <out dir> alias <sink> <other sink>
Writes <out>/<case>.fasm/.bin/.cfg, <out>/out.wiring, <out>/cases.txt and
<out>/required.txt (the sorted required "<E> <i> <tok>" coverage keys).
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
INVERT = {"A": False, "B": True, "C": False, "D": True}    # BEL polarity (both appear)
ENV = (0x0000, 0xFFFF, 0xAAAA, 0xCCCC, 0xF0F0, 0xFF00)      # same set as sim/tb_output_route.v


def sink_name(n):
    return f"{EDGES[n // 4]}1BEG{n % 4}"


def tokens_of(n):
    """Source tokens of sink n in matrix list order: incoming edges (NESW, not own), then BELs."""
    return [e for e in EDGES if e != EDGES[n // 4]] + list(BELS)


def src_name(tok, track):
    return f"L{tok}_O" if tok in BELS else f"{tok}1END{track}"


def required_routes(snap):
    """-> set of (edge, track, token) read from the frozen pip model."""
    req = set()
    for st, sw, dt, dw in snap["pips"]:
        if st != LOGIC or dt != LOGIC:
            continue
        if not (len(dw) == 6 and dw[0] in EDGES and dw[1:5] == "1BEG" and dw[5] in "0123"):
            continue
        e, t = dw[0], int(dw[5])
        if len(sw) == 4 and sw[0] == "L" and sw[1] in BELS and sw[2:] == "_O":
            req.add((e, t, sw[1]))
        elif len(sw) == 6 and sw[0] in EDGES and sw[1:5] == "1END" and sw[5] == str(t) and sw[0] != e:
            req.add((e, t, sw[0]))
        else:
            raise F.AsmError(f"matrix offers an unmodelled output source {sw} -> {dw}; extend the diagnostic deliberately")
    return req


def background(idx, n, src_tok):
    """Deterministic background token of sink n in case #idx (the tested sink keeps its tested source)."""
    toks = tokens_of(n)
    return src_tok if src_tok else toks[(idx * 3 + n * 5 + 1) % 7]


def cases(req):
    """-> [(case_id, edge, track, tok, 16 background tokens)] in load order."""
    out = []
    for ei, e in enumerate(EDGES):
        for t in range(4):
            for tok in tokens_of(4 * ei + t):
                if (e, t, tok) in req:
                    idx = len(out)
                    n_t = 4 * ei + t
                    bg = "".join(tok if n == n_t else background(idx, n, None) for n in range(16))
                    out.append((f"O_{e}{t}_{tok}", e, t, tok, bg))
    return out


def init_word(pin, invert):
    """INIT = projection of input pin (INIT[a] = a[pin]), optionally inverted; FASM 'b string."""
    v = sum(1 << a for a in range(16) if (a >> pin) & 1)
    if invert:
        v ^= 0xFFFF
    return format(v, "016b")


def fasm_text(case_id, edge, track, tok, bg):
    L = [f"# issue #180 output-route diagnostic case {case_id} (assembler-generated, not mapper output)"]
    for k, x in enumerate(BELS):          # BEL X = (NOT) pin k, fed from the tested sink's own edge
        L += [f"{LOGIC}.{edge}1END{k}.L{x}_I{k}", f"{LOGIC}.{x}.INIT[15:0] = 'b{init_word(k, INVERT[x])}"]
    for n in range(16):
        L.append(f"{LOGIC}.{src_name(bg[n], n % 4)}.{sink_name(n)}")
    return "\n".join(L) + "\n"


def sink_sources_of(text):
    """{sink index: token} read back from the rendered FASM output pips (self-check helper)."""
    got = {}
    for it in F.parse_fasm(text):
        parts = it["name"].split(".")
        if it["hi"] is not None or len(parts) != 2 or parts[1][1:5] != "1BEG":
            continue
        s, d = parts
        got[EDGES.index(d[0]) * 4 + int(d[5])] = s[1] if s[0] == "L" else s[0]
    return got


def check_model_pips(snap, rows):
    model = {(sw, dw) for st, sw, dt, dw in snap["pips"] if st == LOGIC and dt == LOGIC}
    for cid, e, t, tok, bg in rows:
        wanted = [(f"{e}1END{k}", f"L{x}_I{k}") for k, x in enumerate(BELS)]
        wanted += [(src_name(bg[n], n % 4), sink_name(n)) for n in range(16)]
        for sw, dw in wanted:
            if (sw, dw) not in model:
                raise F.AsmError(f"{cid}: pip {LOGIC}.{sw}.{dw} is not in the frozen fabric model")


def manifest(snap, ltile):
    cols, rows = snap["grid"]
    _, lx, ly = ltile
    return "\n".join([f"GRID {cols} {rows}", f"TILE {lx} {ly}", "END"]) + "\n"


def generate(out_dir, snap_path):
    snap = F.load_snapshot(snap_path)
    req = required_routes(snap)
    if len(req) != 112:
        raise F.AsmError(f"expected 112 required output routes (16 tracks x 7 sources), snapshot offers {len(req)}")
    rows = cases(req)
    keys = [(e, t, tok) for _, e, t, tok, _ in rows]
    if len(set(keys)) != len(keys) or set(keys) != req:
        raise F.AsmError("case list does not cover the required output-route set exactly once")
    check_model_pips(snap, rows)
    ltile = F.logic_tile(snap)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    prev_cfg, lst, cfgs = None, [], set()
    for cid, e, t, tok, bg in rows:
        text = fasm_text(cid, e, t, tok, bg)
        if sink_sources_of(text) != {n: bg[n] for n in range(16)} or bg[4 * EDGES.index(e) + t] != tok:
            raise F.AsmError(f"{cid}: rendered FASM does not route the recorded sink sources")
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
        lst.append(f"{cid} {e} {t} {tok} {bg}")
    if len(cfgs) != len(rows):
        raise F.AsmError("two output-route cases assemble to the same configuration")
    (out / "out.wiring").write_text(manifest(snap, ltile))
    (out / "cases.txt").write_text("\n".join(lst) + "\n")
    (out / "required.txt").write_text("\n".join(sorted(f"{e} {t} {tok}" for e, t, tok in req)) + "\n")
    print(f"output_route: {len(lst)} streams = 16 output tracks x 7 sources, every one a pip of the frozen model, "
          f"all 16 tracks and 4 BELs reprogrammed in each, assembled through flow/fasm_to_bitstream.py; "
          f"required set read from the snapshot")
    return lst


# ------------------------------------------------------------------ failure model
def _value(tok, track, tin, edge, env_unused=None):
    """Value of a source token at sink track `track` under stimulus tin (16 bits, tin[4*dir+idx])."""
    if tok in BELS:
        k = BELS.index(tok)
        return ((tin >> (4 * EDGES.index(edge) + k)) & 1) ^ int(INVERT[tok])
    return (tin >> (4 * EDGES.index(tok) + track)) & 1


def stimuli(edge, track):
    """The exact stimulus set of sim/tb_output_route.v for a case: yields 16-bit tin values."""
    ei = EDGES.index(edge)
    others = [i for i in range(4) if i != ei]
    for env in ENV:
        for v in range(128):
            tin = env
            for k in range(4):                         # edge-E tracks: the four BEL input pins
                tin = (tin & ~(1 << (4 * ei + k))) | (((v >> k) & 1) << (4 * ei + k))
            for j, o in enumerate(others):             # the three incoming candidates of the tested track
                tin = (tin & ~(1 << (4 * o + track))) | (((v >> (4 + j)) & 1) << (4 * o + track))
            yield tin


def predict(rows, mutant):
    """-> sorted failing case ids for a mutant, from the case list and the committed list order.

    mutant = ("swap", sink, posA, posB): the mux of `sink` exchanges two source positions;
             ("alias", sink, other): `sink` takes its select field from `other`'s field.
    """
    names = [sink_name(n) for n in range(16)]

    failing = []
    for cid, e, t, tok, bg in rows:
        eff = list(bg)
        kind, sink = mutant[0], mutant[1]
        n = names.index(sink)
        lst = tokens_of(n)
        pos = lst.index(bg[n])
        if kind == "swap":
            a, b = int(mutant[2]), int(mutant[3])
            pos = b if pos == a else a if pos == b else pos
        elif kind == "alias":
            o = names.index(mutant[2])
            pos = tokens_of(o).index(bg[o])
        else:
            raise ValueError(kind)
        eff[n] = lst[pos]
        if eff[n] == bg[n]:
            continue
        for tin in stimuli(e, t):
            if _value(eff[n], n % 4, tin, e) != _value(bg[n], n % 4, tin, e):
                failing.append(cid)
                break
    return sorted(failing)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "predict":
        out, mutant = argv[1], tuple(argv[2:])
        rows = [l.split() for l in (Path(out) / "cases.txt").read_text().splitlines()]
        got = predict([(r[0], r[1], int(r[2]), r[3], r[4]) for r in rows], mutant)
        print(" ".join(got))
        return 0
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
