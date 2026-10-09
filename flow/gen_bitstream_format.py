#!/usr/bin/env python3
"""Generate design/bitstream-format.md from the committed config-bit map (issue #131).

EXPERIMENTAL HARNESS FORMAT ONLY. The document describes the as-built G1
harness fabric (one LOGIC4 tile, ADR-0004/0005 still Proposed). It is not the
ratified-fabric bitstream format and does not close spec/framework-gaps.md G6.

Single source: sim/bitstream/logic4_configmem.map (cfg bit -> frame position)
and sim/bitstream/fabric_spec.json (frozen generator tile_specs: feature ->
{frame position: value}). The fixtures sim/bitstream/{top_io,top_reg}.cfg are
decoded through the same tables and the result is embedded in the document, so
a layout change that disagrees with the fixtures fails generation.

    python3 flow/gen_bitstream_format.py            # rewrite the document
    python3 flow/gen_bitstream_format.py --check    # exit 1 if it is stale

stdlib only; no toolchain.
"""
import argparse
import difflib
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MAP = "sim/bitstream/logic4_configmem.map"
SPEC = "sim/bitstream/fabric_spec.json"
FIXTURES = ("top_io", "top_reg")
OUT = "design/bitstream-format.md"
CFG_BITS = 158
NBEL = 4


class FormatError(Exception):
    pass


def load(root):
    cb_pos = []
    for n, line in enumerate((root / MAP).read_text().splitlines()):
        a, b = line.split()
        if int(a) != n:
            raise FormatError(f"{MAP}: line {n} has index {a}")
        cb_pos.append(int(b))
    if len(cb_pos) != CFG_BITS or len(set(cb_pos)) != CFG_BITS:
        raise FormatError(f"{MAP}: expected {CFG_BITS} distinct positions")
    spec = json.loads((root / SPEC).read_text())
    if spec["cb_pos"] != cb_pos:
        raise FormatError(f"{SPEC} cb_pos disagrees with {MAP}")
    fb = spec["arch"]["frame_bits_per_row"]
    tile = [t for t, k in spec["tile_map"].items() if k == spec["logic_type"]]
    if len(tile) != 1:
        raise FormatError("expected exactly one logic tile")
    return cb_pos, fb, tile[0], spec["tile_specs"][tile[0]]


def build_fields(cb_pos, tspec):
    """-> (owner[cb] = (kind, name, detail), muxes{dst: (bits, {src: {cb: val}})})"""
    pos2cb = {p: i for i, p in enumerate(cb_pos)}
    owner = {}

    def claim(cb, val):
        if cb in owner:
            raise FormatError(f"cfg[{cb}] claimed twice: {owner[cb]} and {val}")
        owner[cb] = val

    muxes = {}
    for feat, bits in sorted(tspec.items()):
        src, _, dst = feat.partition(".")
        if re.fullmatch(r"[A-D]", src):
            m = re.fullmatch(r"INIT(?:\[(\d+)\])?|FF", dst)
            if not m:
                raise FormatError(f"unknown BEL feature {feat}")
            (p, v), = bits.items()
            if v != "1":
                raise FormatError(f"{feat}: expected single set bit")
            if dst == "FF":
                claim(pos2cb[int(p)], ("BEL", src, "FF (reg_sel)"))
            else:
                claim(pos2cb[int(p)], ("BEL", src, f"INIT[{m.group(1) or 0}]"))
        else:
            if not bits:
                continue  # hard-wired pip: no config bits
            pats = {pos2cb[int(p)]: int(v) for p, v in bits.items()}
            muxes.setdefault(dst, {})[src] = pats
    out = {}
    for dst, srcs in muxes.items():
        cbs = sorted(set().union(*[set(p) for p in srcs.values()]))
        for p in srcs.values():
            if sorted(p) != cbs:
                raise FormatError(f"mux {dst}: sources use different bit sets")
        pats = [tuple(p[c] for c in cbs) for p in srcs.values()]
        if len(set(pats)) != len(pats):
            raise FormatError(f"mux {dst}: duplicate select encodings")
        for i, c in enumerate(cbs):
            claim(c, ("MUX", dst, f"select bit {i} (ascending cfg index)"))
        out[dst] = (cbs, srcs)
    if sorted(owner) != list(range(CFG_BITS)):
        miss = sorted(set(range(CFG_BITS)) - set(owner))
        raise FormatError(f"cfg bits without an owner: {miss}")
    nb = sum(1 for o in owner.values() if o[0] == "BEL")
    nm = sum(1 for o in owner.values() if o[0] == "MUX")
    if (nb, nm) != (68, 90):
        raise FormatError(f"expected 68 BEL + 90 matrix bits, got {nb} + {nm}")
    return owner, out


def decode_fixture(cfg, owner, muxes):
    bels = []
    for i, name in enumerate("ABCD"):
        init = (cfg >> (17 * i)) & 0xFFFF
        ff = (cfg >> (17 * i + 16)) & 1
        for j in range(16):
            if owner[17 * i + j] != ("BEL", name, f"INIT[{j}]"):
                raise FormatError(f"BEL {name} INIT[{j}] not at cfg[{17*i+j}]")
        if owner[17 * i + 16] != ("BEL", name, "FF (reg_sel)"):
            raise FormatError(f"BEL {name} FF not at cfg[{17*i+16}]")
        bels.append((name, init, ff))
    sels = []
    for dst, (cbs, srcs) in sorted(muxes.items()):
        val = tuple((cfg >> c) & 1 for c in cbs)
        hit = [s for s, p in srcs.items() if tuple(p[c] for c in cbs) == val]
        if not any(val):
            if len(hit) > 1:
                raise FormatError(f"mux {dst}: all-zero select matches {hit}")
            continue  # all-zero (reset/default) select
        if len(hit) != 1:
            raise FormatError(f"mux {dst}: select {val} matches {hit}")
        sels.append((dst, hit[0], val))
    return bels, sels


def render(root):
    cb_pos, fb, tile, tspec = load(root)
    owner, muxes = build_fields(cb_pos, tspec)
    L = []
    w = L.append
    w("# LOGIC4 harness bitstream format (as-built, experimental)")
    w("")
    w("> **Status: experimental, as-built harness format. NOT the ratified-fabric")
    w("> format.** It documents the G1 harness fabric exactly as generated by")
    w("> FABulous 2.2.0 (one LOGIC4 tile plus CAP boundary cells). ADR-0004 and")
    w("> ADR-0005 are still Proposed, so the ratified fabric's bitstream is not")
    w("> defined here and `spec/framework-gaps.md` G6 remains **OPEN**.")
    w("")
    w("<!-- GENERATED by flow/gen_bitstream_format.py from "
      f"`{MAP}` and `{SPEC}`; do not edit.")
    w("     Regenerate: python3 flow/gen_bitstream_format.py -->")
    w("")
    w(f"Tile `{tile}` has {CFG_BITS} config bits: 68 BEL bits (4 BELs x "
      "(16 LUT INIT + 1 `reg_sel`)) and 90 switch-matrix select bits, in "
      f"{-(-(max(cb_pos) + 1) // fb)} used frames of {fb} bits. `cfg[i]` is "
      "line `i` of the config-bit map; its frame position is "
      f"`{fb}*frame + bit`. The serialized frame stream is described in "
      "`sim/README.md` (\"Serialized format\"); this file only lists what each "
      "bit means.")
    w("")
    w("## Per-bit table")
    w("")
    w("| cfg bit | frame | frame bit | position | owner | meaning |")
    w("|---|---|---|---|---|---|")
    for i in range(CFG_BITS):
        p = cb_pos[i]
        k, n, d = owner[i]
        who = f"BEL {n}" if k == "BEL" else f"matrix mux `{n}`"
        w(f"| {i} | {p // fb} | {p % fb} | {p} | {who} | {d} |")
    w("")
    w("## Switch-matrix mux encodings")
    w("")
    w("The select pattern is written with the lowest cfg index first (the "
      "order of the cfg bits in each heading). A destination is "
      "driven by the source whose pattern matches. Sources absent from a "
      "destination's list have no connection; patterns not listed are "
      "unassigned.")
    w("")
    for dst, (cbs, srcs) in sorted(muxes.items()):
        w(f"### `{dst}` (cfg bits {', '.join(map(str, cbs))})")
        w("")
        w("| source | select bits |")
        w("|---|---|")
        for s, p in sorted(srcs.items(), key=lambda kv: [kv[1][c] for c in cbs][::-1]):
            w(f"| `{s}` | `{''.join(str(p[c]) for c in cbs)}` |")
        w("")
    w("## Fixture cross-check")
    w("")
    w("The committed decoded vectors are run through the tables above "
      "(`cfg` is read as a 160-bit hex number, `cfg[i]` = bit `i`).")
    w("")
    for name in FIXTURES:
        cfg = int((root / f"sim/bitstream/{name}.cfg").read_text().strip(), 16)
        if cfg >> CFG_BITS:
            raise FormatError(f"{name}.cfg has bits above {CFG_BITS}")
        bels, sels = decode_fixture(cfg, owner, muxes)
        w(f"### `sim/bitstream/{name}.cfg`")
        w("")
        w(f"`{cfg:040x}` ({bin(cfg).count('1')} bits set)")
        w("")
        for n, init, ff in bels:
            w(f"- BEL {n}: INIT = `16'h{init:04x}`, FF (reg_sel) = {ff}")
        if sels:
            w("- non-zero matrix selects (destination <- source):")
            for dst, src, val in sels:
                w(f"  - `{dst}` <- `{src}`")
        w("")
    return "\n".join(L).rstrip("\n") + "\n"


def main(argv=None, root=REPO):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="fail if the committed document differs from a regeneration")
    ap.add_argument("--root", type=Path, default=root)
    a = ap.parse_args(argv)
    try:
        text = render(a.root)
    except FormatError as e:
        print(f"gen_bitstream_format: {e}", file=sys.stderr)
        return 1
    out = a.root / OUT
    if not a.check:
        out.write_text(text)
        print(f"wrote {OUT}")
        return 0
    cur = out.read_text() if out.exists() else ""
    if cur != text:
        sys.stderr.writelines(difflib.unified_diff(
            cur.splitlines(True), text.splitlines(True), OUT, "regenerated"))
        print(f"gen_bitstream_format: {OUT} is stale; run "
              "python3 flow/gen_bitstream_format.py", file=sys.stderr)
        return 1
    print(f"{OUT} up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
