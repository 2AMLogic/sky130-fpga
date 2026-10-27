"""flow/_stream_gen.py

Shared scaffolding for the frame-stream generators flow/ctrl_route.py,
flow/output_route.py, flow/route_diag.py and flow/lut_basis.py: the header
constants, the frozen-model pip set and its membership check, the standard
wiring manifest, the assemble -> pack -> decode round trip, the per-case
`.fasm/.bin/.cfg` writer and the common `main()` wrapper. The case-specific
`cases()`, `fasm_text()` and `required_routes()` and every distinct-stream
check stay in the generators.

Callers put `flow/` on `sys.path` before importing this (they run under
`python3 -I`). Not a public API beyond `flow/` -- hence the leading underscore.
"""
import argparse
import sys
from pathlib import Path

from _modload import load_module

REPO = Path(__file__).resolve().parent.parent

F = load_module("fasm_to_bitstream", REPO / "flow" / "fasm_to_bitstream.py")

BELS = "ABCD"
EDGES = "NESW"          # tin[4*dir + idx] order of the benches: 0=N 1=E 2=S 3=W
LOGIC = "X1Y1"
DEFAULT_SNAPSHOT = REPO / "sim" / "bitstream" / "fabric_spec.json"


def model_pips(snap):
    """The frozen pip model of the logic tile as a set of (src wire, dst wire)."""
    return {(sw, dw) for st, sw, dt, dw in snap["pips"] if st == LOGIC and dt == LOGIC}


def check_pips(model, wanted, prefix=""):
    """Raise unless every (src, dst) in `wanted` is in `model`; `prefix` is e.g. '<case>: '."""
    for sw, dw in wanted:
        if (sw, dw) not in model:
            raise F.AsmError(f"{prefix}pip {LOGIC}.{sw}.{dw} is not in the frozen fabric model")


def manifest(snap, ltile, outs=True):
    """GRID/TILE header, the S1BEG<j> OUT lines (unless `outs` is false) and END."""
    cols, rows = snap["grid"]
    _, lx, ly = ltile
    out = [f"GRID {cols} {rows}", f"TILE {lx} {ly}"]
    if outs:
        out += [f"OUT {x} {EDGES.index('S')} {j}" for j, x in enumerate(BELS)]   # S1BEG<j>
    out.append("END")
    return "\n".join(out) + "\n"


def roundtrip(cid, text, snap):
    """assemble -> pack -> decode a case; -> (asm, data, cfg), failing if decode(pack()) != assembled cfg."""
    asm = F.assemble(text, snap, None)
    data = F.pack(asm["positions"], snap)
    cfg, _ = F.decode(data, snap)
    if cfg != asm["cfg"]:
        raise F.AsmError(f"{cid}: decode(pack()) != assembled cfg")
    return asm, data, cfg


def check_reprogrammed(cid, cfg, prev_cfg):
    if cfg == prev_cfg:
        raise F.AsmError(f"{cid}: stream identical to its predecessor (no reprogramming)")


def write_case(out, cid, text, data, cfg):
    (out / f"{cid}.fasm").write_text(text)
    (out / f"{cid}.bin").write_bytes(data)
    (out / f"{cid}.cfg").write_text(f"{cfg:040x}\n")


def run_main(generate, description, argv=None):
    """argparse (<out> [--snapshot]) + error reporting shared by the generators' main()."""
    ap = argparse.ArgumentParser(description=description)
    ap.add_argument("out")
    ap.add_argument("--snapshot", default=str(DEFAULT_SNAPSHOT))
    a = ap.parse_args(argv)
    try:
        generate(a.out, a.snapshot)
    except (F.AsmError, F.BitstreamError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0
