#!/usr/bin/env python3
"""LUT truth-table basis diagnostic streams for the single-LOGIC4 harness (issue #172).

EXPERIMENTAL, DIAGNOSTIC ONLY. Writes a deterministic set of assembler-generated
frame streams that together select every one of the 16 truth-table addresses
of every one of the four LUT4 BELs (A..D) of the G1 harness tile, for
sim/tb_lut_basis.v (run by flow/generated_tile_replay.sh on the generated
LOGIC4 tile and on the repository composition). These streams are NOT mapper
output: they say nothing about whether yosys/nextpnr map a given truth table
correctly, only whether a configured INIT address reaches the BEL output
through the real frame interface, the generated ConfigMem and the matrix.

Every stream uses the same fixed route set, chosen from the existing
description only (design/fabulous/Tile/LOGIC4/LOGIC4_switch_matrix.list and the
harness pad overlay, flow/nextpnr_io_overlay.py), and every pip is required to
exist in the frozen nextpnr pip model of sim/bitstream/fabric_spec.json:

  inputs   CAP_N pad IO<P>_O -> S1BEG<i> -> (wire) -> LOGIC4 S1END<i> -> L<X>_I<i>
           for i = 0..3 (pads A..D) and every BEL X in A..D. The matrix offers
           each LUT input pin I<i> exactly the four same-index tracks
           N/E/S/W1END<i>, so S1END<i> -> L<X>_I<i> is a legal route and LUT
           input i is driven by track S1END<i> on all four BELs at once.
  outputs  L<X>_O -> S1BEG<j> -> (wire) -> CAP_S S1END<j> -> pad IO<P>_I, with
           BEL A, B, C, D on track j = 0, 1, 2, 3 (pads A, B, C, D). Every output
           track may take any of the four BEL outputs, so all four BELs are
           observable simultaneously and a defect that moves a table onto a
           different BEL is visible.
  FF       never set: every BEL is in combinational mode (reg_sel = 0).

Cases (stream order = the order sim/tb_lut_basis.v loads them into ONE live
tile, without any reset in between, so a stale bit from an earlier case shows):

  blank            every INIT zero
  <X>_ones         BEL X INIT = all ones, other BELs zero
  <X>_aNN          BEL X INIT = one-hot address NN (0..15), other BELs zero
  <X>_zero         every INIT zero again (clears the last one-hot of BEL X)

for X = A, B, C, D: 1 + 4 x 18 = 73 streams. Each INIT bit is set only through a
FASM feature `X1Y1.<X>.INIT[15:0] = 'b...` processed by the existing assembler
(flow/fasm_to_bitstream.py assemble + pack, then decode back) -- no ConfigBits
index is computed here. The case list records only the identifier (BEL, kind,
address); the bench derives its expected outputs from that identifier, never
from the stream, cfg or map.

Usage: flow/lut_basis.py <out dir> [--snapshot sim/bitstream/fabric_spec.json]
Writes <out>/<case>.fasm/.bin/.cfg, <out>/basis.wiring and <out>/cases.txt.
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
PADS = "ABCD"
IN_CAP, LOGIC, OUT_CAP = "X1Y0", "X1Y1", "X1Y2"


def route_lines():
    """The fixed, shared route set (pips only; no BEL configuration)."""
    lines = []
    for i in range(4):                      # LUT input i <- pad PADS[i] on S1END<i>
        lines += [f"{IN_CAP}.IO{PADS[i]}_O.S1BEG{i}", f"{IN_CAP}.S1BEG{i}.S1END{i}"]
        lines += [f"{LOGIC}.S1END{i}.L{x}_I{i}" for x in BELS]
    for j, x in enumerate(BELS):            # BEL x output -> S1BEG<j> -> pad PADS[j]
        lines += [f"{LOGIC}.L{x}_O.S1BEG{j}", f"{LOGIC}.S1BEG{j}.S1END{j}",
                  f"{OUT_CAP}.S1END{j}.IO{PADS[j]}_I"]
    return lines


def cases():
    """-> [(case_id, bel letter or '-', kind, addr)] in load order."""
    out = [("blank", "-", "zero", 0)]
    for x in BELS:
        out.append((f"{x}_ones", x, "ones", 0))
        out += [(f"{x}_a{k:02d}", x, "onehot", k) for k in range(16)]
        out.append((f"{x}_zero", x, "zero", 0))
    return out


def init_word(kind, addr):
    """INIT value of the case's BEL, as the FASM 'b string (MSB = INIT[15])."""
    v = {"zero": 0, "ones": 0xFFFF, "onehot": 1 << addr}[kind]
    return format(v, "016b")


def fasm_text(case_id, bel, kind, addr):
    body = [f"# issue #172 LUT basis diagnostic case {case_id} (assembler-generated, not mapper output)"]
    body += route_lines()
    if bel != "-" and kind != "zero":
        body.append(f"{LOGIC}.{bel}.INIT[15:0] = 'b{init_word(kind, addr)}")
    return "\n".join(body) + "\n"


def check_routes(snap):
    """Every chosen pip must exist in the frozen nextpnr pip model."""
    model = {(st, sw, dw) for st, sw, dt, dw in snap["pips"] if st == dt}
    model |= {(st, sw, dw) for st, sw, dt, dw in snap["pips"] if st != dt}
    for line in route_lines():
        t, s, d = line.split(".")
        if (t, s, d) not in model:
            raise F.AsmError(f"route {line} is not a pip of the frozen fabric model")


def pips_of(text):
    pips = []
    for it in F.parse_fasm(text):
        parts = it["name"].split(".")
        if it["hi"] is None and len(parts) == 2:
            pips.append((it["tile"], parts[0], parts[1]))
    return pips


def manifest(wiring, snap, ltile):
    """IN <lut input> <dir> <idx> / OUT <bel> <dir> <idx>, traced from the FASM pips."""
    _, lx, ly = ltile
    cols, rows = snap["grid"]
    ins = sorted((PADS.index(p), d, k) for (t, p), d, k in wiring["ins"] if t == IN_CAP)
    outs = sorted((PADS.index(p), d, k) for (t, p), d, k in wiring["outs"] if t == OUT_CAP)
    if len(ins) != 4 or len(outs) != 4 or wiring["loops"]:
        raise F.AsmError(f"unexpected traced wiring {wiring}")
    out = [f"GRID {cols} {rows}", f"TILE {lx} {ly}"]
    out += [f"IN {i} {d} {k}" for i, d, k in ins]          # pad index = LUT input index
    out += [f"OUT {BELS[j]} {d} {k}" for j, d, k in outs]  # pad index = BEL index
    out.append("END")
    return "\n".join(out) + "\n"


def generate(out_dir, snap_path):
    snap = F.load_snapshot(snap_path)
    check_routes(snap)
    ltile = F.logic_tile(snap)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    blank_cfg, wiring_txt, lst = None, None, []
    for cid, bel, kind, addr in cases():
        text = fasm_text(cid, bel, kind, addr)
        asm = F.assemble(text, snap, None)          # bit assembly through the existing assembler
        data = F.pack(asm["positions"], snap)
        cfg, _ = F.decode(data, snap)                # independent frame-stream reader
        if cfg != asm["cfg"]:
            raise F.AsmError(f"{cid}: decode(pack()) != assembled cfg")
        if any(asm["bel_used"]) and kind == "zero":
            raise F.AsmError(f"{cid}: zero case configures a BEL")
        w = manifest(F.trace_wiring(pips_of(text), snap, ltile[0]), snap, ltile)
        if wiring_txt is None:
            wiring_txt = w
        elif w != wiring_txt:
            raise F.AsmError(f"{cid}: traced wiring differs from the shared route set")
        if blank_cfg is None:
            blank_cfg = cfg
        # generator self-check, no bit-index derivation: a case differs from the
        # blank (routes-only) stream in exactly as many bits as its INIT weight
        want = {"zero": 0, "ones": 16, "onehot": 1}[kind]
        if bin(cfg ^ blank_cfg).count("1") != want:
            raise F.AsmError(f"{cid}: {bin(cfg ^ blank_cfg).count('1')} bits differ from blank, want {want}")
        (out / f"{cid}.fasm").write_text(text)
        (out / f"{cid}.bin").write_bytes(data)
        (out / f"{cid}.cfg").write_text(f"{cfg:040x}\n")
        lst.append(f"{cid} {bel} {kind} {addr}")
    (out / "basis.wiring").write_text(wiring_txt)
    (out / "cases.txt").write_text("\n".join(lst) + "\n")
    n_onehot = sum(1 for c in cases() if c[2] == "onehot")
    print(f"lut_basis: {len(lst)} streams ({n_onehot} one-hot = 4 BELs x 16 addresses, "
          f"4 all-ones, {len(lst) - n_onehot - 4} all-zero) assembled through "
          f"flow/fasm_to_bitstream.py; shared route set of {len(route_lines())} pips, "
          f"all in the frozen pip model; wiring traced from the FASM")
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
