#!/usr/bin/env python3
"""FASM -> serialized configuration for the experimental LOGIC4 harnesses.

EXPERIMENTAL HARNESS COVERAGE ONLY. Targets the existing G1 harness fabric
(design/fabulous, LOGIC4 inside CAP_* boundary cells, with optional scratch
pad overlay) and its experimental multi-tile extension. See sim/README.md
for the single-tile format and sim/fabric_bitstream_results.txt for the 2x2 run.

What it does (python3 standard library only, so `sim/run.sh` can use it
without any mapping tool):

  snapshot  (regeneration only; needs the FABulous venv for the pickle and
            bit_gen constants) freeze the generator outputs this flow depends
            on -- bitStreamSpec.bin, the LOGIC4 ConfigMem, the nextpnr pip
            model -- into sim/bitstream/fabric_spec.json and the loader's
            sim/bitstream/logic4_configmem.map.
  summary   normalise nextpnr's post-route JSON (drops absolute paths) into the
            committed <design>.mapped.json.
  assemble  FASM + snapshot + mapped summary -> FABulous-format frame stream
            (.bin, byte-identical to `bit_gen genBitstream`, which
            flow/bitstream.sh checks), wiring manifest (.wiring) and the
            decoded tile vectors (.cfg, 158 bits per LOGIC4).
  decode    independent frame-stream reader -> concatenated tile vectors.
  check     re-assemble every committed fixture and require byte identity.

Strictness: every FASM line must be accounted for. Logic-tile and CAP-tile
features must exist in the generated bitStreamSpec; the only FASM lines that
are dropped from the bit assembly are the overlay's zero-bit pad pips, and they
are listed, counted and cross-checked against nextpnr's routed netlist.
Unknown features, out-of-range selections, conflicting bit assignments,
duplicates, malformed lines and an explicit `= 0` on a zero-bit (pad, wire or
CAP) pip are errors (AsmError / BitstreamError).
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

CFG_BITS = 158
DIRS = "NESW"           # direction index 0..3, same order as the repo RTL ports


class AsmError(Exception):
    """FASM / mapping input rejected by the assembler."""


class BitstreamError(Exception):
    """Serialized configuration rejected by the loader."""


# ----------------------------------------------------------------------------
# FASM parsing
# ----------------------------------------------------------------------------
_FEATURE = re.compile(
    r"^(X\d+Y\d+)\.([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*?)"
    r"(?:\[(\d+)(?::(\d+))?\])?"
    r"(?:\s*=\s*(?:'b([01_]+)|(\d+)))?$")


def parse_fasm(text):
    """-> list of dict(line, tile, name, hi, lo, bits). Strict subset of FASM.

    `bits` is None for a bare feature (value 1), else the MSB-first bit string
    (for `feat[hi:lo] = 'b...`) or a 1-character string for `feat[n] = 0|1`.
    Full-line comments and blank lines are the only things ignored.
    """
    out = []
    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _FEATURE.match(line)
        if not m:
            raise AsmError(f"line {no}: malformed FASM line {line!r}")
        tile, name, hi, lo, bstr, dec = m.groups()
        hi = int(hi) if hi is not None else None
        lo = int(lo) if lo is not None else (hi if hi is not None else None)
        bits = None
        if bstr is not None:
            bits = bstr.replace("_", "")
            if hi is None:
                raise AsmError(f"line {no}: value without index on {line!r}")
            if len(bits) != hi - lo + 1 or hi < lo:
                raise AsmError(f"line {no}: width mismatch in {line!r}")
        elif dec is not None:
            if hi is None and dec not in ("0", "1"):
                raise AsmError(f"line {no}: bad value in {line!r}")
            if hi != lo or dec not in ("0", "1"):
                raise AsmError(f"line {no}: bad value in {line!r}")
            bits = dec
        elif hi is not None and hi != lo:
            raise AsmError(f"line {no}: range without value in {line!r}")
        out.append(dict(line=no, tile=tile, name=name, hi=hi, lo=lo, bits=bits))
    return out


def expand(item, tile_spec):
    """Expand one parsed line into [(spec_key, value)] with range checking."""
    name, hi, lo, bits = item["name"], item["hi"], item["lo"], item["bits"]
    if hi is None:
        if name not in tile_spec:
            raise AsmError(f"line {item['line']}: unknown feature {item['tile']}.{name}")
        return [(name, int(bits) if bits is not None else 1)]
    res = []
    values = bits if bits is not None else "1"
    # bits are MSB first: values[0] is bit `hi`
    for k, v in zip(range(hi, lo - 1, -1), values):
        # FABulous names bit 0 of a vector without an index suffix ("A.INIT")
        key = f"{name}[{k}]"
        if key not in tile_spec and k == 0 and name in tile_spec:
            key = name
        if key not in tile_spec:
            raise AsmError(f"line {item['line']}: out-of-range or unknown feature "
                           f"{item['tile']}.{key}")
        res.append((key, int(v)))
    return res


# ----------------------------------------------------------------------------
# snapshot (frozen generator outputs)
# ----------------------------------------------------------------------------
def load_snapshot(path):
    s = json.loads(Path(path).read_text())
    s["tile_specs"] = {t: {f: {int(p): v for p, v in bits.items()}
                           for f, bits in spec.items()}
                       for t, spec in s["tile_specs"].items()}
    s["cb_pos"] = [int(p) for p in s["cb_pos"]]
    return s


def logic_tiles(snap):
    """Tile names in cfg order: Y increasing, then X, first tile in low bits."""
    cols, rows = snap["grid"]
    tiles = [f"X{x}Y{y}" for y in range(rows) for x in range(cols)
             if snap["tile_map"].get(f"X{x}Y{y}") == snap["logic_type"]]
    if not tiles:
        raise AsmError(f"no {snap['logic_type']} tiles in fabric")
    return tiles


def logic_tile(snap):
    """Coordinate of the sole tile for callers implementing single-tile diagnostics."""
    tiles = logic_tiles(snap)
    if len(tiles) != 1:
        raise AsmError(f"expected exactly one {snap['logic_type']} tile, got {tiles}")
    m = re.fullmatch(r"X(\d+)Y(\d+)", tiles[0])
    return tiles[0], int(m.group(1)), int(m.group(2))


_WIRE = re.compile(r"^([NESW])1(BEG|END)(\d)$")
_PAD = re.compile(r"^IO([A-D])_([OI])$")
_SRC_OUT = re.compile(r"^(?:L[A-D]|IO[A-D])_O$")   # physical driver: BEL or pad output


def pad_pip_rows(snap):
    """Overlay pad pips (the only zero-bit pips outside the generated spec)."""
    rows = set()
    for st, sw, dt, dw in snap["pips"]:
        if _PAD.match(sw) or _PAD.match(dw):
            rows.add((st, sw, dw))
    return rows


# ----------------------------------------------------------------------------
# assembly
# ----------------------------------------------------------------------------
def assemble(fasm_text, snap, mapped):
    """-> dict with positions, cfg, manifest data and the line accounting."""
    items = parse_fasm(fasm_text)
    tiles = logic_tiles(snap)
    index = {tile: i for i, tile in enumerate(tiles)}
    stride = snap["arch"]["frame_bits_per_row"] * snap["arch"]["max_frames_per_col"]
    pads = pad_pip_rows(snap)
    specs = snap["tile_specs"]

    owner = {}          # (tile, position) -> (value, feature)
    seen = set()
    bel_used, sel_bits = set(), set()
    pips = []           # (tile, src, dst) of every pip line (bit-bearing or not)
    pad_lines = []      # accounted-for zero-bit pad pips
    pad_line_nos = []
    n_logic = n_cap = 0
    cb_of_pos = {p: cb for cb, p in enumerate(snap["cb_pos"])}

    for it in items:
        tile = it["tile"]
        if tile not in snap["tile_map"] or snap["tile_map"][tile] == "NULL":
            raise AsmError(f"line {it['line']}: feature on unconfigured/NULL tile {tile}")
        name = it["name"]
        # pad pip: only the overlay's, only on the overlay's tiles, no bits.
        parts = name.split(".")
        if len(parts) == 2 and (tile, parts[0], parts[1]) in pads and it["hi"] is None:
            if it["bits"] == "0":
                # an explicit `= 0` disables the pip; it must not count as a route
                raise AsmError(f"line {it['line']}: disabled pad pip {tile}.{name} = 0 "
                               f"(pad pips are zero-bit; omit the line instead)")
            if (tile, name) in seen:
                raise AsmError(f"line {it['line']}: duplicate {tile}.{name}")
            seen.add((tile, name))
            pad_lines.append((tile, parts[0], parts[1]))
            pad_line_nos.append(it["line"])
            pips.append((tile, parts[0], parts[1]))
            continue
        spec = specs.get(tile)
        if spec is None:
            raise AsmError(f"line {it['line']}: no bitstream spec for tile {tile}")
        for key, val in expand(it, spec):
            if (tile, key) in seen:
                raise AsmError(f"line {it['line']}: duplicate feature {tile}.{key}")
            seen.add((tile, key))
            if not val and not spec[key]:
                raise AsmError(f"line {it['line']}: disabled zero-bit pip {tile}.{key} = 0 "
                               f"(omit the line instead)")
            if tile not in index:
                if spec[key]:
                    raise AsmError(f"line {it['line']}: unexpected config bits on {tile}.{key}")
                n_cap += 1
                pips.append((tile, *key.split(".")))
                continue
            n_logic += 1
            i = index[tile]
            m = re.fullmatch(r"([A-D])\.(INIT(?:\[\d+\])?|FF)", key)
            if m:
                bel_used.add(4 * i + "ABCD".index(m[1]))
            if not val:
                continue        # vector bit 0: feature not set (bits stay 0)
            if not m:
                pips.append((tile, *key.split(".")))
                sel_bits.update(i * CFG_BITS + cb_of_pos[q] for q in spec[key])
            for pos, bv in spec[key].items():
                prev = owner.get((tile, pos))
                if prev and prev[0] != int(bv):
                    raise AsmError(f"line {it['line']}: conflicting assignment of bit {pos} "
                                   f"by {key} and {prev[1]}")
                owner[(tile, pos)] = (int(bv), key)

    positions = {}
    cfg = 0
    for (tile, pos), (v, _) in owner.items():
        if pos not in cb_of_pos:
            raise AsmError(f"bit {tile}:{pos} is not mapped by the ConfigMem")
        i = index[tile]
        positions[i * stride + pos] = v
        if v:
            cfg |= 1 << (i * CFG_BITS + cb_of_pos[pos])
    wiring, links = None, []
    if mapped is not None:      # mapped=None: bit assembly only (unit tests)
        wiring, links = fabric_wiring(pips, snap, tiles)
        check_against_mapped(pips, bel_used, cfg, mapped, index, wiring)
    red = redundancy_records(pips, snap, index)
    result = dict(positions=positions, cfg=cfg, bel_used=sorted(bel_used),
                  sel_bits=sorted(sel_bits), tile_wiring=wiring, red=red, pad_lines=pad_lines,
                  pad_line_nos=pad_line_nos, n_logic=n_logic, n_cap=n_cap, n_lines=len(items),
                  links=links)
    if len(tiles) == 1:  # retain the single-tile diagnostic API
        result["ltile"] = logic_tile(snap)
        result["wiring"] = wiring[tiles[0]] if wiring is not None else None
    return result


def trace_wiring(pips, snap, ltile):
    """Single-tile view used by the LUT basis diagnostic."""
    wiring, _ = fabric_wiring(pips, snap, [ltile])
    return wiring[ltile]


def fabric_wiring(pips, snap, tiles):
    """Derive pad/loopback wiring and direct inter-LOGIC4 hops from FASM.

    Edges come only from the FASM pips plus the generated pip model for the
    inter-tile hop of a wire pip. Every non-logic pip must belong to a traced
    path; an orphan is an error.
    """
    ext = {}
    for st, sw, dt, dw in snap["pips"]:
        if st != dt:
            ext[(st, sw)] = (dt, dw)
    pred = {}
    for (t, s), (dt, dw) in ext.items():
        pred[(dt, dw)] = (t, s)
    used = set()
    wiring = {t: dict(ins=[], outs=[], loops=[]) for t in tiles}
    driven = {(t, d) for t, s, d in pips}
    feeding = {(t, s) for t, s, d in pips}
    links = []
    for t, s, d in pips:
        if t in wiring:
            dst = ext.get((t, s))
            if dst and dst[0] in wiring and dst[1] == d:
                if (t, s) not in driven or dst not in feeding:
                    raise AsmError(f"orphan wire hop {t}.{s}.{d}")
                links.append((t, s, *dst))
                used.add((t, s, d))
            continue
        ps, pd = _PAD.match(s), _PAD.match(d)
        if ps and ps.group(2) == "O":          # pad drives a track toward the logic tile
            node = (t, d)
            hop = ext.get(node)
            if not hop or hop[0] not in wiring or not _WIRE.match(hop[1]):
                raise AsmError(f"pad pip {t}.{s}.{d} does not reach the logic tile")
            used.update([(t, s, d), (t, d, hop[1])])
            m = _WIRE.match(hop[1])
            wiring[hop[0]]["ins"].append(((t, ps.group(1)), DIRS.index(m[1]), int(m[3])))
        elif pd and pd.group(2) == "I":        # track from the logic tile into a pad
            src = pred.get((t, s))
            if not src or src[0] not in wiring:
                raise AsmError(f"pad pip {t}.{s}.{d} is not fed by the logic tile")
            m = _WIRE.match(src[1])
            used.update([(t, s, d), (src[0], src[1], s)])
            wiring[src[0]]["outs"].append(((t, pd.group(1)), DIRS.index(m[1]), int(m[3])))
        elif (t, s) in ext and ext[(t, s)][1] == d:  # plain wire hop (BEG -> END)
            continue
        elif _WIRE.match(s) and _WIRE.match(d):  # CAP loopback END -> BEG
            src = pred.get((t, s))
            hop = ext.get((t, d))
            if not src or not hop or src[0] not in wiring or hop[0] != src[0]:
                raise AsmError(f"cap pip {t}.{s}.{d} is not a logic-tile loopback")
            a, b = _WIRE.match(src[1]), _WIRE.match(hop[1])
            used.update([(t, s, d), (src[0], src[1], s), (t, d, hop[1])])
            wiring[src[0]]["loops"].append((DIRS.index(a[1]), int(a[3]), DIRS.index(b[1]), int(b[3])))
        else:
            raise AsmError(f"unclassified non-logic pip {t}.{s}.{d}")
    for t, s, d in pips:   # wire hops must all lie on a traced path
        if (t, s) in ext and ext[(t, s)][1] == d and (t, s, d) not in used:
            raise AsmError(f"orphan wire hop {t}.{s}.{d}")
    for w in wiring.values():
        for rows in w.values():
            rows.sort()
    return wiring, sorted(links)


def redundancy_records(pips, snap, index):
    """Same-driver redundancy evidence for the configured routing-select bits.

    For every mux of the logic tile that the FASM configures, a flip of one of
    its select bits is provably redundant when the original and the flipped
    encoding select inputs resolving, through the configured pips, to the same
    physical driver (a BEL or pad output wire). The original encoding is
    resolved in the configured routing; the flipped one with the flipped
    select in effect, so a chain that passes back through the mux being
    flipped closes a cycle through the flip. A chain that reaches a node with
    two configured drivers or closes a combinational cycle (a flip can create
    one) is not provable. Everything unproven -- including a flipped encoding with no
    input, where the generated mux drives 0 -- is absent from the result and
    stays a strict SURVIVED in the bench (issue #342). CAP delay is irrelevant
    under the bench's sampling model: two same-driven mux inputs carry the
    same settled value at every sampling point.

    Returns [(cfg bit, mux, selected src, flipped src, driver)], driver spelled
    "<tile>.<wire>", for the manifest's RED lines.
    """
    ext = {}
    for st, sw, dt, dw in snap["pips"]:
        if st != dt:
            ext[(st, sw)] = (dt, dw)
    drv, multi, sel = {}, set(), {}
    for t, s, d in pips:
        hop = (t, s) in ext and ext[(t, s)][1] == d
        node = ext[(t, s)] if hop else (t, d)
        if node in drv and drv[node] != (t, s):
            multi.add(node)
        else:
            drv.setdefault(node, (t, s))
        if t in index and not hop:
            sel[(t, d)] = s

    def driver(node, flip=None):
        seen = set()
        while node not in seen:
            seen.add(node)
            if node in multi or not _SRC_OUT.match(node[1]) and node not in drv:
                return None
            if _SRC_OUT.match(node[1]):
                return f"{node[0]}.{node[1]}"
            node = flip[1] if flip is not None and node == flip[0] else drv[node]
        return None            # configured cycle: redundancy not provable

    cb_of_pos = {p: cb for cb, p in enumerate(snap["cb_pos"])}
    out = []
    for (ltile, mux), s0 in sel.items():
        positions, enc, enc_of = None, {}, {}
        for key, bits in snap["tile_specs"][ltile].items():
            src, dot, dst = key.rpartition(".")
            if not dot or dst != mux or not bits:
                continue
            pos = tuple(sorted(bits))
            if positions is None:
                positions = pos
            elif pos != positions:
                raise AsmError(f"mux {mux}: select positions differ between {src} and other inputs")
            e = 0
            for r, p in enumerate(positions):
                e |= int(bits[p]) << r
            if e in enc:
                raise AsmError(f"mux {mux}: inputs {enc[e]} and {src} share encoding {e}")
            enc[e] = src
            enc_of[src] = e
        if not enc or s0 not in enc_of:
            continue
        for r, p in enumerate(positions):
            s2 = enc.get(enc_of[s0] ^ (1 << r))
            if s2 is None:
                continue       # flipped encoding selects no input: mux drives 0
            d0, d2 = driver((ltile, s0)), driver((ltile, s2), ((ltile, mux), (ltile, s2)))
            if d0 is not None and d0 == d2:
                out.append((index[ltile] * CFG_BITS + cb_of_pos[p], mux, s0, s2, d0))
    return sorted(out)


def check_against_mapped(pips, bel_used, cfg, mapped, index, wiring):
    """Cross-check the FASM against nextpnr's routed netlist (normalised)."""
    want = {f"{t}.{s}.{d}" for t, s, d in pips}
    got = set()
    for net in mapped["nets"]:
        got.update(p for p in net["pips"])
    if want != got:
        raise AsmError("FASM pips differ from routed netlist: only in FASM "
                       f"{sorted(want - got)}, only in netlist {sorted(got - want)}")
    # BEL configuration
    seen = set()
    for cell in mapped["cells"]:
        if cell["type"] != "lut4_ff_bel":
            continue
        tile, bel = cell["bel"].split("/")
        if tile not in index:
            raise AsmError(f"BEL placed on non-logic tile {tile}")
        i = "ABCD".index(bel)
        offset = index[tile] * CFG_BITS + 17 * i
        init = int(cell["init"], 2)
        got_init = (cfg >> offset) & 0xFFFF
        got_ff = (cfg >> (offset + 16)) & 1
        if got_init != init or got_ff != int(cell["ff"]):
            raise AsmError(f"BEL {tile}/{bel}: FASM config INIT={got_init:04x} FF={got_ff} "
                           f"!= netlist INIT={init:04x} FF={cell['ff']}")
        seen.add(index[tile] * 4 + i)
    if seen != set(bel_used):
        raise AsmError(f"FASM configures BELs {sorted(bel_used)}, netlist places {sorted(seen)}")
    # port <-> pad directions against the wiring derived from the FASM
    by_pad = {tuple(p["pad"]): p for p in mapped["ports"]}
    used_pads = {}
    for w in wiring.values():
        for key, direction in (("ins", "input"), ("outs", "output")):
            for pad, _, _ in w[key]:
                if pad in used_pads:
                    raise AsmError(f"pad {pad} wired twice")
                used_pads[pad] = direction
    if used_pads != {pad: port["dir"] for pad, port in by_pad.items()}:
        raise AsmError("netlist ports and FASM pads differ")


def named_wiring(asm, mapped, tile=None):
    by_pad = {tuple(p["pad"]): p["name"] for p in mapped["ports"]}
    w = asm["wiring"] if tile is None else asm["tile_wiring"][tile]
    return ([(by_pad[tp], d, k) for tp, d, k in w["ins"]],
            [(by_pad[tp], d, k) for tp, d, k in w["outs"]], w["loops"])


def manifest_text(asm, snap, mapped):
    cols, rows = snap["grid"]
    out = [f"GRID {cols} {rows}"]
    for tile in asm["tile_wiring"]:
        x, y = tile[1:].split("Y")
        out.append(f"TILE {x} {y}")
        ins, outs, loops = named_wiring(asm, mapped, tile)
        out += [f"IN {n} {d} {k}" for n, d, k in sorted(ins)]
        out += [f"OUT {n} {d} {k}" for n, d, k in sorted(outs)]
        out += [f"LOOP {a} {b} {c} {d}" for a, b, c, d in loops]
    out.extend(f"LINK {st} {sw} {dt} {dw}" for st, sw, dt, dw in asm["links"])
    out += [f"BEL {i}" for i in asm["bel_used"]]
    out += [f"SEL {b}" for b in asm["sel_bits"]]
    out += [f"RED {bit} {mx} {s0} {s1} {drv}" for bit, mx, s0, s1, drv in asm["red"]]
    out.append("END")
    return "\n".join(out) + "\n"


def map_text(snap):
    tiles = logic_tiles(snap)
    lines = []
    for i, tile in enumerate(tiles):
        # Multi-tile rows qualify each local frame position by X and Y.
        prefix = " ".join(tile[1:].split("Y")) + " " if len(tiles) > 1 else ""
        lines.extend(f"{prefix}{i * CFG_BITS + cb} {pos}\n" for cb, pos in enumerate(snap["cb_pos"]))
    return "".join(lines)


# ----------------------------------------------------------------------------
# serialization (FABulous frame stream)
# ----------------------------------------------------------------------------
def pack(positions, snap):
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    index = {tile: i for i, tile in enumerate(logic_tiles(snap))}
    nbytes = (fbits + 7) // 8
    out = bytearray.fromhex(a["sync_header_hex"])
    for col in range(cols):
        for f in range(nfr):
            out += ((col << (fbits - sel_w)) | (1 << f)).to_bytes(nbytes, "big")
            for y in range(rows - 2, 0, -1):          # interior rows, Y descending
                word = 0
                i = index.get(f"X{col}Y{y}")
                if i is not None:
                    for b in range(fbits):
                        if positions.get((i * nfr + f) * fbits + b):
                            word |= 1 << b
                out += word.to_bytes(nbytes, "big")
    out += (1 << a["desync_bit"]).to_bytes(nbytes, "big")
    return bytes(out)


def frame_records(data, snap):
    """Structural frame-stream reader -> [(column, row, frame, raw word)].

    One framing loop shared by every consumer of the serialized stream (issue
    #363): after validating the complete stream it returns one record per
    LOGIC4 row of each frame write, zero words included, in wire order, with
    the payload word kept raw so each caller applies its own interpretation.
    Tile identity comes from snapshot geometry + logic_tiles(snap); the
    configuration map (cb_pos) is deliberately not consulted.

    Checks: sync header, complete big-endian words, one-hot frame strobe,
    reserved bits and column range, exactly one write per (column, frame)
    with a complete payload in descending interior-row order, zero data on
    non-LOGIC4 tiles, an exact final desync word with no trailing bytes, and
    every column x frame present.
    """
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    logic = set(logic_tiles(snap))
    nbytes = (fbits + 7) // 8
    hdr = bytes.fromhex(a["sync_header_hex"])
    if data[:len(hdr)] != hdr:
        raise BitstreamError("bad or missing sync header")
    pos = len(hdr)
    row_order = list(range(rows - 2, 0, -1))
    got, out = set(), []
    while True:
        if pos + nbytes > len(data):
            raise BitstreamError("truncated: missing frame-select word / desync word")
        word = int.from_bytes(data[pos:pos + nbytes], "big")
        pos += nbytes
        strobe = word & ((1 << nfr) - 1)
        if strobe == 0:                            # must be the exact desync word
            if word != 1 << a["desync_bit"]:
                raise BitstreamError(f"malformed desync word {word:#010x}")
            if pos != len(data):
                raise BitstreamError("trailing data after desync word")
            break
        col, frame = word >> (fbits - sel_w), strobe.bit_length() - 1
        reserved = (word >> nfr) & ((1 << (fbits - sel_w - nfr)) - 1)
        if reserved or strobe & (strobe - 1) or col >= cols:
            raise BitstreamError(f"invalid frame-select word {word:#010x}")
        if (col, frame) in got:
            raise BitstreamError(f"duplicate frame {frame} for column {col}")
        got.add((col, frame))
        need = nbytes * len(row_order)
        if pos + need > len(data):
            raise BitstreamError("truncated frame data")
        for i, y in enumerate(row_order):
            w = int.from_bytes(data[pos + i * nbytes:pos + (i + 1) * nbytes], "big")
            if f"X{col}Y{y}" in logic:
                out.append((col, y, frame, w))
            elif w:
                raise BitstreamError(f"data for tile X{col}Y{y} which has no config bits")
        pos += need
    if len(got) != cols * nfr:
        raise BitstreamError(f"incomplete stream: {len(got)} of {cols * nfr} frames")
    return out


def decode(data, snap):
    """Strict frame-stream reader -> (cfg int, set of positions set).

    Framing and completeness come from frame_records(); this layer only
    interprets each raw payload word through the configuration map.
    """
    a = snap["arch"]
    fbits, nfr = a["frame_bits_per_row"], a["max_frames_per_col"]
    index = {tile: i for i, tile in enumerate(logic_tiles(snap))}
    mapped_pos = set(snap["cb_pos"])
    cb_of_pos = {p: cb for cb, p in enumerate(snap["cb_pos"])}
    cfg, bitpos = 0, set()
    for col, row, frame, fw in frame_records(data, snap):
        i = index[f"X{col}Y{row}"]
        for b in range(fbits):
            if fw >> b & 1:
                p = frame * fbits + b
                if p not in mapped_pos:
                    raise BitstreamError(f"set bit at unmapped frame position {p}")
                cfg |= 1 << (i * CFG_BITS + cb_of_pos[p])
                bitpos.add(i * nfr * fbits + p)
    return cfg, bitpos


# ----------------------------------------------------------------------------
# snapshot / summary builders (regeneration only)
# ----------------------------------------------------------------------------
def parse_configmem(text):
    """ConfigMem.v -> cb_pos list (cross-checking the assign and latch views)."""
    emu = {int(a): int(b) for a, b in
           re.findall(r"assign\s+ConfigBits\[(\d+)\]\s*=\s*Emulate_Bitstream\[(\d+)\]", text)}
    lat = {}
    for m in re.finditer(r"config_latch\s+Inst_frame(\d+)_bit(\d+)\s*\(\s*\.D\(FrameData\[(\d+)\]\),"
                         r"\s*\.E\(FrameStrobe\[(\d+)\]\),\s*\.Q\(ConfigBits\[(\d+)\]\)", text):
        fr, bt, fd, fs, cb = map(int, m.groups())
        if fr != fs or bt != fd:
            raise AsmError(f"inconsistent latch instance frame{fr}_bit{bt}")
        lat[cb] = fr * 32 + bt
    if emu != lat:
        raise AsmError("ConfigMem Emulate_Bitstream view disagrees with the latch view")
    if sorted(emu) != list(range(CFG_BITS)):
        raise AsmError(f"expected {CFG_BITS} contiguous ConfigBits, got {len(emu)}")
    return [emu[i] for i in range(CFG_BITS)]


def build_snapshot(spec_bin, configmem_v, pips_txt, fabric_provenance):
    import pickle
    import fabulous_bit_gen.bit_gen as bg
    d = pickle.load(open(spec_bin, "rb"))
    arch = dict(frame_bits_per_row=d["ArchSpecs"]["FrameBitsPerRow"],
                max_frames_per_col=d["ArchSpecs"]["MaxFramesPerCol"],
                frame_select_width=d["ArchSpecs"]["FrameSelectWidth"],
                sync_header_hex=bg.SYNC_HEADER_HEX, desync_bit=bg.DESYNC_BIT)
    cols = max(int(re.match(r"X(\d+)Y", t).group(1)) for t in d["TileMap"]) + 1
    rows = max(int(re.search(r"Y(\d+)", t).group(1)) for t in d["TileMap"]) + 1
    logic = sorted({k for k in d["TileMap"].values() if k not in ("NULL",)
                    and d["FrameMap"].get(k)})
    assert len(logic) == 1, logic
    specs = {t: {f: {str(p): v for p, v in b.items()} for f, b in s.items()}
             for t, s in d["TileSpecs"].items()}
    pips = []
    for line in pips_txt.splitlines():
        if line and not line.startswith("#"):
            st, sw, dt, dw = line.split(",")[:4]
            pips.append([st, sw, dt, dw])
    return dict(provenance=fabric_provenance, arch=arch, grid=[cols, rows],
                logic_type=logic[0], tile_map=d["TileMap"], tile_specs=specs,
                cb_pos=parse_configmem(configmem_v), pips=pips)


def build_mapped(post_json):
    """nextpnr post-route JSON -> normalised, path-free summary."""
    m = json.loads(Path(post_json).read_text())["modules"]["top"]
    bit_name = {}
    for pname, p in m["ports"].items():
        for b in p["bits"]:
            bit_name[b] = pname
    ports, cells, pins_of = [], [], {}
    for cname, c in m["cells"].items():
        bel = c["attributes"]["NEXTPNR_BEL"]
        if c["type"] == "lut4_ff_bel":
            cells.append(dict(type=c["type"], bel=bel, init=c["parameters"]["INIT"],
                              ff=c["parameters"]["FF"]))
        for pin, bits in c["connections"].items():
            for b in bits:
                pins_of.setdefault(b, []).append(f"{bel}.{pin}")
        if c["type"].startswith("IO_1_"):
            pad = c["connections"]["PAD"][0]
            tile, letter = bel.split("/")
            ports.append(dict(name=bit_name[pad], pad=[tile, letter],
                              dir=m["ports"][bit_name[pad]]["direction"]))
    nets = []
    for nname, n in m["netnames"].items():
        r = n["attributes"].get("ROUTING", " ").strip()
        pips = []
        if r:
            # entries: wire;;1;wire;pipname;1;wire;pipname;1 ... (pip names
            # are the only tokens of the form tile/src.dst)
            for t in r.split(";"):
                if re.fullmatch(r"X\d+Y\d+/\w+\.\w+", t):
                    pips.append(t.replace("/", ".", 1))
        nets.append(dict(pins=sorted(pins_of.get(n["bits"][0], [])), pips=sorted(pips)))
    nets = [n for n in nets if n["pips"]]
    nets.sort(key=lambda n: (n["pins"], n["pips"]))
    cells.sort(key=lambda c: c["bel"])
    ports.sort(key=lambda p: p["name"])
    return dict(ports=ports, cells=cells, nets=nets)


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
def sha256(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def cfg_hex(cfg, snap):
    digits = (len(logic_tiles(snap)) * CFG_BITS + 3) // 4
    return f"{cfg:0{digits}x}"


def cmd_assemble(a):
    snap = load_snapshot(a.snapshot)
    mapped = json.loads(Path(a.mapped).read_text())
    asm = assemble(Path(a.fasm).read_text(), snap, mapped)
    data = pack(asm["positions"], snap)
    cfg, _ = decode(data, snap)
    if cfg != asm["cfg"]:
        raise AsmError("internal: decode(pack()) != assembled cfg")
    Path(a.out + ".bin").write_bytes(data)
    Path(a.out + ".wiring").write_text(manifest_text(asm, snap, mapped))
    Path(a.out + ".cfg").write_text(cfg_hex(cfg, snap) + "\n")
    if a.filtered_fasm:
        # FASM minus the accounted-for zero-bit pad pips: the input for
        # FABulous's own bit_gen cross-check (flow/bitstream.sh).
        drop = set(asm["pad_line_nos"])
        keep = [l for n, l in enumerate(Path(a.fasm).read_text().splitlines(), 1) if n not in drop]
        Path(a.filtered_fasm).write_text("\n".join(keep) + "\n")
    print(f"assembled {Path(a.fasm).name}: {asm['n_lines']} FASM lines = {len(asm['pad_lines'])} zero-bit "
          f"pad pips (cross-checked against the routed netlist) + lines expanding to "
          f"{asm['n_logic']} logic-tile and {asm['n_cap']} cap/wire spec features; "
          f"{bin(asm['cfg']).count('1')} cfg bits set; {len(data)} bytes")


def cmd_decode(a):
    snap = load_snapshot(a.snapshot)
    cfg, _ = decode(Path(a.bin).read_bytes(), snap)
    print(cfg_hex(cfg, snap))


def cmd_check(a):
    base = Path(a.dir)
    sbase = Path(a.snapshot_dir) if a.snapshot_dir else base
    snap = load_snapshot(sbase / "fabric_spec.json")
    ok = True
    if (sbase / "logic4_configmem.map").read_text() != map_text(snap):
        print("DRIFT logic4_configmem.map"); ok = False
    for fasm in sorted(base.glob("*.fasm")):
        stem = fasm.with_suffix("")
        mapped = json.loads(stem.with_suffix(".mapped.json").read_text())
        asm = assemble(fasm.read_text(), snap, mapped)
        want = {".bin": pack(asm["positions"], snap),
                ".wiring": manifest_text(asm, snap, mapped).encode(),
                ".cfg": (cfg_hex(asm["cfg"], snap) + "\n").encode()}
        for ext, blob in want.items():
            if stem.with_suffix(ext).read_bytes() != blob:
                print(f"DRIFT {stem.name}{ext}"); ok = False
        print(f"checked {fasm.name}: reproduces {', '.join(sorted(want))}")
    if not ok:
        sys.exit(1)
    print("PASS: fasm_to_bitstream fixtures reproduce")


def cmd_snapshot(a):
    prov = dict(fabulous=a.fabulous_version, source=a.source)
    snap = build_snapshot(a.spec, Path(a.configmem).read_text(), Path(a.pips).read_text(), prov)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "fabric_spec.json").write_text(json.dumps(snap, indent=0, sort_keys=True) + "\n")
    (out / "logic4_configmem.map").write_text(map_text(load_snapshot(out / "fabric_spec.json")))


def cmd_summary(a):
    Path(a.out).write_text(json.dumps(build_mapped(a.post_json), indent=1, sort_keys=True) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("assemble")
    p.add_argument("--fasm", required=True); p.add_argument("--snapshot", required=True)
    p.add_argument("--mapped", required=True); p.add_argument("--out", required=True,
                                                             help="output stem")
    p.add_argument("--filtered-fasm", help="also write the FASM without pad pips")
    p.set_defaults(fn=cmd_assemble)
    p = sp.add_parser("decode")
    p.add_argument("bin"); p.add_argument("--snapshot", required=True)
    p.set_defaults(fn=cmd_decode)
    p = sp.add_parser("check")
    p.add_argument("dir", help="fixture directory (sim/bitstream)")
    p.add_argument("--snapshot-dir", help="directory holding fabric_spec.json / logic4_configmem.map "
                   "(default: the fixture directory; issue #115 corpus fixtures share sim/bitstream's)")
    p.set_defaults(fn=cmd_check)
    p = sp.add_parser("snapshot")
    p.add_argument("--spec", required=True); p.add_argument("--configmem", required=True)
    p.add_argument("--pips", required=True); p.add_argument("--out", required=True)
    p.add_argument("--fabulous-version", default="")
    p.add_argument("--source", default="flow/fabulous.sh + flow/nextpnr_io_overlay.py")
    p.set_defaults(fn=cmd_snapshot)
    p = sp.add_parser("summary")
    p.add_argument("post_json"); p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_summary)
    a = ap.parse_args(argv)
    try:
        a.fn(a)
    except (AsmError, BitstreamError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
