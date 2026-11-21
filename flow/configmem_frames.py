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

    Framing and completeness are shared with the strict reader
    fasm_to_bitstream.frame_records() (header, select-word shape, one-hot
    strobe, column range, duplicates, full payload, exact desync word, no
    trailing data, every column x frame present, non-logic-tile rows zero);
    the configuration map (cb_pos) is deliberately not consulted, so the raw
    stimulus reaches the bench unchanged. The shared reader's BitstreamError
    is translated at this boundary: the adapter's contract is
    FrameStreamError.
    """
    _, lx, ly = f2b.logic_tile(snap)
    try:
        recs = f2b.frame_records(data, snap)
    except f2b.BitstreamError as e:
        raise FrameStreamError(str(e)) from None
    return [(frame, w) for col, row, frame, w in recs if (col, row) == (lx, ly)]


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
