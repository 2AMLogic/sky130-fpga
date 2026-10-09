#!/usr/bin/env python3
"""FASM -> serialized configuration for the single-LOGIC4 harness (issue #74).

EXPERIMENTAL HARNESS COVERAGE ONLY. Targets the existing G1 harness fabric
(design/fabulous: one LOGIC4 tile + four CAP_* boundary cells, plus the scratch
pad overlay of flow/nextpnr_io_overlay.py). It makes no claim about the ratified
Wilton-class population (ADR-0004/0005 are still Proposed), about timing, or
about inter-tile routing. See sim/README.md for the format description.

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
            decoded 158-bit tile vector (.cfg).
  decode    independent frame-stream reader -> 158-bit tile vector.
  check     re-assemble every committed fixture and require byte identity.

Strictness: every FASM line must be accounted for. Logic-tile and CAP-tile
features must exist in the generated bitStreamSpec; the only FASM lines that
are dropped from the bit assembly are the overlay's zero-bit pad pips, and they
are listed, counted and cross-checked against nextpnr's routed netlist.
Unknown features, out-of-range selections, conflicting bit assignments,
duplicates and malformed lines are errors (AsmError / BitstreamError).
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


def logic_tile(snap):
    tiles = [t for t, k in snap["tile_map"].items() if k == snap["logic_type"]]
    if len(tiles) != 1:
        raise AsmError(f"expected exactly one {snap['logic_type']} tile, got {tiles}")
    m = re.fullmatch(r"X(\d+)Y(\d+)", tiles[0])
    return tiles[0], int(m.group(1)), int(m.group(2))


_WIRE = re.compile(r"^([NESW])1(BEG|END)(\d)$")
_PAD = re.compile(r"^IO([A-D])_([OI])$")


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
    ltile, lx, ly = logic_tile(snap)
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
            if tile != ltile:
                if spec[key]:
                    raise AsmError(f"line {it['line']}: unexpected config bits on {tile}.{key}")
                n_cap += 1
            else:
                n_logic += 1
            if tile != ltile and "." in key and not key.startswith(("A.", "B.", "C.", "D.")):
                p = key.split(".")
                pips.append((tile, p[0], p[1]))
            if val == 0:
                continue        # vector bit 0: feature not set (bits stay 0)
            if tile == ltile:
                m = re.match(r"^([A-D])\.(INIT(?:\[\d+\])?|FF)$", key)
                if m:
                    bel_used.add("ABCD".index(m.group(1)))
                else:
                    p = key.split(".")
                    pips.append((tile, p[0], p[1]))
                    if spec[key]:
                        sel_bits.update(cb_of_pos[q] for q in spec[key])
            for pos, bv in spec[key].items():
                prev = owner.get((tile, pos))
                if prev and prev[0] != int(bv):
                    raise AsmError(f"line {it['line']}: conflicting assignment of bit {pos} "
                                   f"by {key} and {prev[1]}")
                owner[(tile, pos)] = (int(bv), key)

    positions = {pos: v for (t, pos), (v, _) in owner.items() if t == ltile}
    stray = [pos for pos in positions if pos not in cb_of_pos]
    if stray:
        raise AsmError(f"bits {stray} are not mapped by the ConfigMem")
    cfg = 0
    for pos, v in positions.items():
        if v:
            cfg |= 1 << cb_of_pos[pos]
    wiring = None
    if mapped is not None:      # mapped=None: bit assembly only (unit tests)
        wiring = trace_wiring(pips, snap, ltile)
        check_against_mapped(items, pips, bel_used, cfg, mapped, snap, ltile, wiring)
    return dict(positions=positions, cfg=cfg, bel_used=sorted(bel_used),
                sel_bits=sorted(sel_bits), wiring=wiring, pad_lines=pad_lines,
                pad_line_nos=pad_line_nos, n_logic=n_logic, n_cap=n_cap, n_lines=len(items), ltile=(ltile, lx, ly))


def trace_wiring(pips, snap, ltile):
    """Derive pad/loopback wiring around the logic tile from the FASM pips.

    Edges come only from the FASM pips plus the generated pip model for the
    inter-tile hop of a wire pip. Every non-logic pip must belong to a traced
    path; an orphan is an error.
    """
    ext = {}
    for st, sw, dt, dw in snap["pips"]:
        if st != dt:
            ext[(st, sw)] = (dt, dw)
    internal = {}
    for t, s, d in pips:
        internal.setdefault((t, s), []).append(d)
    pred = {}
    for (t, s), (dt, dw) in ext.items():
        pred[(dt, dw)] = (t, s)
    used = set()
    ins, outs, loops = [], [], []
    for t, s, d in pips:
        if t == ltile:
            continue
        ps, pd = _PAD.match(s), _PAD.match(d)
        if ps and ps.group(2) == "O":          # pad drives a track toward the logic tile
            node = (t, d)
            hop = ext.get(node)
            if not hop or hop[0] != ltile or not _WIRE.match(hop[1]):
                raise AsmError(f"pad pip {t}.{s}.{d} does not reach the logic tile")
            used.update([(t, s, d), (t, d, hop[1])])
            m = _WIRE.match(hop[1])
            ins.append(((t, ps.group(1)), DIRS.index(m.group(1)), int(m.group(3))))
        elif pd and pd.group(2) == "I":        # track from the logic tile into a pad
            src = pred.get((t, s))
            if not src or src[0] != ltile:
                raise AsmError(f"pad pip {t}.{s}.{d} is not fed by the logic tile")
            m = _WIRE.match(src[1])
            used.update([(t, s, d), (src[0], src[1], s)])
            outs.append(((t, pd.group(1)), DIRS.index(m.group(1)), int(m.group(3))))
        elif (t, s) in ext and ext[(t, s)][1] == d:  # plain wire hop (BEG -> END)
            continue
        elif _WIRE.match(s) and _WIRE.match(d):  # CAP loopback END -> BEG
            src = pred.get((t, s))
            hop = ext.get((t, d))
            if not src or src[0] != ltile or not hop or hop[0] != ltile:
                raise AsmError(f"cap pip {t}.{s}.{d} is not a logic-tile loopback")
            a, b = _WIRE.match(src[1]), _WIRE.match(hop[1])
            used.update([(t, s, d), (src[0], src[1], s), (t, d, hop[1])])
            loops.append((DIRS.index(a.group(1)), int(a.group(3)),
                          DIRS.index(b.group(1)), int(b.group(3))))
        else:
            raise AsmError(f"unclassified non-logic pip {t}.{s}.{d}")
    for t, s, d in pips:   # wire hops must all lie on a traced path
        if (t, s) in ext and ext[(t, s)][1] == d and (t, s, d) not in used:
            raise AsmError(f"orphan wire hop {t}.{s}.{d}")
    return dict(ins=sorted(ins), outs=sorted(outs), loops=sorted(loops))


def check_against_mapped(items, pips, bel_used, cfg, mapped, snap, ltile, wiring):
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
        if f"{tile}" != ltile:
            raise AsmError(f"BEL placed on {tile}, not the logic tile")
        i = "ABCD".index(bel)
        init = int(cell["init"], 2)
        got_init = (cfg >> (17 * i)) & 0xFFFF
        got_ff = (cfg >> (17 * i + 16)) & 1
        if got_init != init or got_ff != int(cell["ff"]):
            raise AsmError(f"BEL {bel}: FASM config INIT={got_init:04x} FF={got_ff} "
                           f"!= netlist INIT={init:04x} FF={cell['ff']}")
        seen.add(i)
    if seen != set(bel_used):
        raise AsmError(f"FASM configures BELs {sorted(bel_used)}, netlist places {sorted(seen)}")
    # port <-> pad directions against the wiring derived from the FASM
    by_pad = {tuple(p["pad"]): p for p in mapped["ports"]}
    for kind, lst in (("input", wiring["ins"]), ("output", wiring["outs"])):
        for (tp, d, k) in lst:
            port = by_pad.get(tp)
            if not port:
                raise AsmError(f"pad {tp} used by FASM but unbound in the netlist")
            if port["dir"] != kind:
                raise AsmError(f"port {port['name']} is an {port['dir']} but pad {tp} is wired as {kind}")
    if len(by_pad) != len(wiring["ins"]) + len(wiring["outs"]):
        raise AsmError("netlist ports and FASM pads differ")


def named_wiring(asm, mapped):
    by_pad = {tuple(p["pad"]): p["name"] for p in mapped["ports"]}
    w = asm["wiring"]
    return ([(by_pad[tp], d, k) for tp, d, k in w["ins"]],
            [(by_pad[tp], d, k) for tp, d, k in w["outs"]], w["loops"])


def manifest_text(asm, snap, mapped):
    ins, outs, loops = named_wiring(asm, mapped)
    _, lx, ly = asm["ltile"]
    cols, rows = snap["grid"]
    out = [f"GRID {cols} {rows}", f"TILE {lx} {ly}"]
    out += [f"IN {n} {d} {k}" for n, d, k in sorted(ins)]
    out += [f"OUT {n} {d} {k}" for n, d, k in sorted(outs)]
    out += [f"LOOP {a} {b} {c} {d}" for a, b, c, d in loops]
    out += [f"BEL {i}" for i in asm["bel_used"]]
    out += [f"SEL {b}" for b in asm["sel_bits"]]
    out.append("END")
    return "\n".join(out) + "\n"


def map_text(snap):
    return "".join(f"{cb} {pos}\n" for cb, pos in enumerate(snap["cb_pos"]))


# ----------------------------------------------------------------------------
# serialization (FABulous frame stream)
# ----------------------------------------------------------------------------
def pack(positions, snap):
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    _, lx, ly = logic_tile(snap)
    nbytes = (fbits + 7) // 8
    out = bytearray.fromhex(a["sync_header_hex"])
    for col in range(cols):
        for f in range(nfr):
            out += ((col << (fbits - sel_w)) | (1 << f)).to_bytes(nbytes, "big")
            for y in range(rows - 2, 0, -1):          # interior rows, Y descending
                word = 0
                if (col, y) == (lx, ly):
                    for b in range(fbits):
                        if positions.get(f * fbits + b):
                            word |= 1 << b
                out += word.to_bytes(nbytes, "big")
    out += (1 << a["desync_bit"]).to_bytes(nbytes, "big")
    return bytes(out)


def decode(data, snap):
    """Strict frame-stream reader -> (cfg int, set of positions set)."""
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    _, lx, ly = logic_tile(snap)
    nbytes = (fbits + 7) // 8
    hdr = bytes.fromhex(a["sync_header_hex"])
    if data[:len(hdr)] != hdr:
        raise BitstreamError("bad or missing sync header")
    pos = len(hdr)
    row_order = list(range(rows - 2, 0, -1))
    mapped_pos = set(snap["cb_pos"])
    cb_of_pos = {p: cb for cb, p in enumerate(snap["cb_pos"])}
    got, cfg, bitpos = set(), 0, set()
    while True:
        if pos + nbytes > len(data):
            raise BitstreamError("truncated: missing frame-select word / desync")
        word = int.from_bytes(data[pos:pos + nbytes], "big")
        pos += nbytes
        if word >> a["desync_bit"] & 1 and word & ((1 << nfr) - 1) == 0 and word >> (fbits - sel_w) == 0:
            if word != 1 << a["desync_bit"]:
                raise BitstreamError("malformed desync word")
            if pos != len(data):
                raise BitstreamError("trailing data after desync")
            break
        col = word >> (fbits - sel_w)
        reserved = (word >> nfr) & ((1 << (fbits - sel_w - nfr)) - 1)
        strobe = word & ((1 << nfr) - 1)
        if reserved or strobe == 0 or strobe & (strobe - 1) or col >= cols:
            raise BitstreamError(f"invalid frame-select word {word:#010x}")
        frame = strobe.bit_length() - 1
        if (col, frame) in got:
            raise BitstreamError(f"duplicate frame {frame} for column {col}")
        got.add((col, frame))
        need = nbytes * len(row_order)
        if pos + need > len(data):
            raise BitstreamError("truncated frame data")
        for i, y in enumerate(row_order):
            fw = int.from_bytes(data[pos + i * nbytes: pos + (i + 1) * nbytes], "big")
            if (col, y) == (lx, ly):
                for b in range(fbits):
                    if fw >> b & 1:
                        p = frame * fbits + b
                        if p not in mapped_pos:
                            raise BitstreamError(f"set bit at unmapped frame position {p}")
                        cfg |= 1 << cb_of_pos[p]
                        bitpos.add(p)
            elif fw:
                raise BitstreamError(f"data for tile X{col}Y{y} which has no config bits")
        pos += need
    if len(got) != cols * nfr:
        raise BitstreamError(f"incomplete stream: {len(got)} of {cols * nfr} frames")
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
    Path(a.out + ".cfg").write_text(f"{asm['cfg']:040x}\n")
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
    print(f"{cfg:040x}")


def cmd_check(a):
    base = Path(a.dir)
    snap = load_snapshot(base / "fabric_spec.json")
    ok = True
    if (base / "logic4_configmem.map").read_text() != map_text(snap):
        print("DRIFT logic4_configmem.map"); ok = False
    for fasm in sorted(base.glob("*.fasm")):
        stem = fasm.with_suffix("")
        mapped = json.loads(stem.with_suffix(".mapped.json").read_text())
        asm = assemble(fasm.read_text(), snap, mapped)
        want = {".bin": pack(asm["positions"], snap),
                ".wiring": manifest_text(asm, snap, mapped).encode(),
                ".cfg": f"{asm['cfg']:040x}\n".encode()}
        for ext, blob in want.items():
            if stem.with_suffix(ext).read_bytes() != blob:
                print(f"DRIFT {stem.name}{ext}"); ok = False
        print(f"checked {fasm.name}: reproduces {', '.join(sorted(want))}")
    if not ok:
        sys.exit(1)
    print("PASS: fasm_to_bitstream fixtures reproduce")


def cmd_snapshot(a):
    prov = dict(fabulous=a.fabulous_version, source="flow/fabulous.sh + flow/nextpnr_io_overlay.py")
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
    p.set_defaults(fn=cmd_check)
    p = sp.add_parser("snapshot")
    p.add_argument("--spec", required=True); p.add_argument("--configmem", required=True)
    p.add_argument("--pips", required=True); p.add_argument("--out", required=True)
    p.add_argument("--fabulous-version", default="")
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
