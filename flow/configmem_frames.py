#!/usr/bin/env python3
"""Simulation-only adapter for the ConfigMem differential bench (issue #136).

Unpacks committed baseline frame streams (sim/bitstream/*.bin and corpus/*.bin)
into per-frame write transactions for design/fabulous/tb_configmem_equiv.v.
It only slices the serialized words (sync header, frame-select word, one data
word per interior row); it does NOT use the configuration map, so the bench's
comparison against the recorded .cfg vectors still exercises the generated
storage HDL.  It is not a hardware stream receiver.

Output (stdout), one stream after another:
    S <expected cfg, 40 hex digits> <name>
    F <frame> <32-bit FrameData hex>     (stream order)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fasm_to_bitstream as f2b  # noqa: E402


class FrameStreamError(ValueError):
    """A frame stream is structurally malformed (rejected before any output)."""


def frames(data, snap):
    """Validate the whole stream structurally, then return the LOGIC4 tile's
    (frame, FrameData) writes in stream order.

    Checks mirror the strict reader in fasm_to_bitstream.decode() as structural
    rules only (header, select-word shape, one-hot strobe, column range,
    duplicates, full payload, exact desync word, no trailing data, every
    column x frame present, non-logic-tile rows zero); the configuration map
    (cb_pos) is deliberately not consulted.
    """
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    _, lx, ly = f2b.logic_tile(snap)
    nbytes = (fbits + 7) // 8
    row_order = list(range(rows - 2, 0, -1))
    hdr = bytes.fromhex(a["sync_header_hex"])
    if data[:len(hdr)] != hdr:
        raise FrameStreamError("bad or missing sync header")
    pos = len(hdr)
    seen, out = set(), []
    while True:
        if pos + nbytes > len(data):
            raise FrameStreamError("truncated: missing frame-select word / desync word")
        word = int.from_bytes(data[pos:pos + nbytes], "big")
        pos += nbytes
        strobe = word & ((1 << nfr) - 1)
        if strobe == 0:                            # must be the exact desync word
            if word != 1 << a["desync_bit"]:
                raise FrameStreamError(f"malformed desync word {word:#010x}")
            if pos != len(data):
                raise FrameStreamError("trailing data after desync word")
            break
        col, frame = word >> (fbits - sel_w), strobe.bit_length() - 1
        reserved = (word >> nfr) & ((1 << (fbits - sel_w - nfr)) - 1)
        if reserved or strobe & (strobe - 1) or col >= cols:
            raise FrameStreamError(f"invalid frame-select word {word:#010x}")
        if (col, frame) in seen:
            raise FrameStreamError(f"duplicate frame {frame} for column {col}")
        seen.add((col, frame))
        need = nbytes * len(row_order)
        if pos + need > len(data):
            raise FrameStreamError("truncated frame data")
        for i, y in enumerate(row_order):
            w = int.from_bytes(data[pos + i * nbytes:pos + (i + 1) * nbytes], "big")
            if (col, y) == (lx, ly):
                out.append((frame, w))
            elif w:
                raise FrameStreamError(f"data for tile X{col}Y{y} which has no config bits")
        pos += need
    if len(seen) != cols * nfr:
        raise FrameStreamError(f"incomplete stream: {len(seen)} of {cols * nfr} frames")
    return out


def main(argv):
    fix = Path(argv[1])
    snap = f2b.load_snapshot(fix / "fabric_spec.json")
    chunks = []                                    # buffer: nothing is printed for a rejected set
    for binf in sorted(list(fix.glob("*.bin")) + list((fix / "corpus").glob("*.bin"))):
        cfg = binf.with_suffix(".cfg").read_text().strip()
        assert len(cfg) == 40, binf
        name = binf.relative_to(fix)
        try:
            fr = frames(binf.read_bytes(), snap)
        except FrameStreamError as e:
            print(f"error: {name}: {e}", file=sys.stderr)
            return 1
        chunks.append(f"S {cfg} {name}\n" + "".join(f"F {f} {d:08x}\n" for f, d in fr))
    sys.stdout.write("".join(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
