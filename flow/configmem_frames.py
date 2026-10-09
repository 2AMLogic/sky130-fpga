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


def frames(data, snap):
    a = snap["arch"]
    fbits, nfr, sel_w = a["frame_bits_per_row"], a["max_frames_per_col"], a["frame_select_width"]
    cols, rows = snap["grid"]
    _, lx, ly = f2b.logic_tile(snap)
    nbytes = (fbits + 7) // 8
    row_order = list(range(rows - 2, 0, -1))
    pos = len(bytes.fromhex(a["sync_header_hex"]))
    out = []
    while True:
        word = int.from_bytes(data[pos:pos + nbytes], "big")
        pos += nbytes
        strobe = word & ((1 << nfr) - 1)
        if strobe == 0:
            break                                  # desync word
        col, frame = word >> (fbits - sel_w), strobe.bit_length() - 1
        for i, y in enumerate(row_order):
            if (col, y) == (lx, ly):
                out.append((frame, int.from_bytes(data[pos + i * nbytes:pos + (i + 1) * nbytes], "big")))
        pos += nbytes * len(row_order)
    return out


def main(argv):
    fix = Path(argv[1])
    snap = f2b.load_snapshot(fix / "fabric_spec.json")
    for binf in sorted(list(fix.glob("*.bin")) + list((fix / "corpus").glob("*.bin"))):
        cfg = binf.with_suffix(".cfg").read_text().strip()
        assert len(cfg) == 40, binf
        print(f"S {cfg} {binf.relative_to(fix)}")
        for fr, d in frames(binf.read_bytes(), snap):
            print(f"F {fr} {d:08x}")


if __name__ == "__main__":
    main(sys.argv)
