#!/usr/bin/env python3
"""Harness-only pad model for the nextpnr run (ADR-0005, issue #92).

Copies the generated nextpnr model (<src>/bel.v3.txt, <src>/pips.txt, the
FABulous output of flow/fabulous.sh) to <dst> and appends a pad model:
four IO_1_bidirectional_frame_config_pass BELs (A-D) on each of the CAP_N
(X1Y0) and CAP_S (X1Y2) boundary tiles, each pad able to drive / be driven
by any of that cap's four single-length tracks.

This is a test-side model of the *outside world*, not a tile: it is applied
to a scratch copy, the FABulous description under design/fabulous/ and the
ratified spec are untouched, the LOGIC4 BELs and switch matrix are
unchanged, and the pads carry no configuration bits (no bitstream bit is
added, removed or moved). Usage: nextpnr_io_overlay.py <src .FABulous> <dst>
"""
import shutil
import sys

CAPS = {  # tile -> (pad->fabric track prefix, fabric->pad track prefix)
    "X1Y0": ("S1BEG", "N1END"),   # CAP_N
    "X1Y2": ("N1BEG", "S1END"),   # CAP_S
}
PADS = "ABCD"


def bel_block(tile, n):
    p = f"IO{n}_"
    return [f"BelBegin,{tile},{n},IO_1_bidirectional_frame_config_pass,{p}",
            f"I,I,{tile}.{p}I", f"I,T,{tile}.{p}T",
            f"O,O,{tile}.{p}O", f"O,Q,{tile}.{p}Q",
            "GlobalClk,1.0", "BelEnd"]


def main(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    path = f"{dst}/bel.v3.txt"
    out = []
    for line in open(path).read().split("\n"):
        out.append(line)
        if line.startswith("#Tile_") and line[6:] in CAPS:
            for n in PADS:
                out += bel_block(line[6:], n)
    open(path, "w").write("\n".join(out))
    path = f"{dst}/pips.txt"
    out = []
    for line in open(path).read().split("\n"):
        out.append(line)
        if line.startswith("#Tile-internal pips on tile "):
            t = line.split()[-1].rstrip(":")
            if t in CAPS:
                to_fab, from_fab = CAPS[t]
                for n in PADS:
                    for i in range(4):
                        out.append(f"{t},IO{n}_O,{t},{to_fab}{i},8,IO{n}_O.{to_fab}{i}")
                        out.append(f"{t},{from_fab}{i},{t},IO{n}_I,8,{from_fab}{i}.IO{n}_I")
    open(path, "w").write("\n".join(out))


if __name__ == "__main__":
    main(*sys.argv[1:3])
