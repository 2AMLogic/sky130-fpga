#!/usr/bin/env python3
"""Write deliberately malformed variants of a FABulous frame stream (issue #74).

Used by sim/run.sh and flow/test_fasm_to_bitstream.py: both the python decoder
and the simulation loader (sim/tb_logic_tile_bitstream.v) must reject every
variant. Layout assumed (3x3 grid, 1 interior row): 20-byte sync header, then
for each of 3 columns x 20 frames a 4-byte frame-select word and 4 data bytes,
then a 4-byte desync word.

usage: bitstream_corrupt.py <good.bin> <outdir>
"""
import sys
from pathlib import Path

HDR, SEL, DAT = 20, 4, 4


def frame_off(col, frame):
    return HDR + (col * 20 + frame) * (SEL + DAT)


def variants(good):
    b = bytes(good)
    v = {}
    v["truncated_mid_frame"] = b[:frame_off(1, 4) + 6]
    v["truncated_no_desync"] = b[:-4]
    v["truncated_header"] = b[:10]
    v["empty"] = b""
    bad = bytearray(b); bad[0] ^= 0xFF
    v["bad_sync"] = bytes(bad)
    dup = bytearray(b)                       # frame (1,5) re-labelled as frame (1,4)
    dup[frame_off(1, 5):frame_off(1, 5) + 4] = b[frame_off(1, 4):frame_off(1, 4) + 4]
    v["duplicate_frame"] = bytes(dup)
    two = bytearray(b)                       # two strobe bits set
    two[frame_off(1, 2) + 3] |= 0b1000
    v["two_strobes"] = bytes(two)
    col = bytearray(b)                       # column out of range (col 7)
    col[frame_off(2, 0)] = 0b00111000
    v["bad_column"] = bytes(col)
    stray = bytearray(b)                     # frame 4 bit 0: not a ConfigMem bit
    stray[frame_off(1, 4) + 4 + 3] |= 0x01
    v["unmapped_bit_set"] = bytes(stray)
    tail = bytearray(b)                      # frame 7 of the logic column (unused frame)
    tail[frame_off(1, 7) + 4] |= 0x80
    v["unused_frame_bit_set"] = bytes(tail)
    cap = bytearray(b)                       # config data for a CAP column
    cap[frame_off(0, 3) + 4 + 3] |= 0x01
    v["cap_column_data"] = bytes(cap)
    v["trailing_byte"] = b + b"\x00"
    v["missing_frame"] = b[:frame_off(1, 19)] + b[frame_off(2, 0):]
    return v


if __name__ == "__main__":
    good, out = Path(sys.argv[1]).read_bytes(), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for name, data in variants(good).items():
        (out / f"{name}.bin").write_bytes(data)
    print(f"wrote {len(variants(good))} malformed variants to {out}")
