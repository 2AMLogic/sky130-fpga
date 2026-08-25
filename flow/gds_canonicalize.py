#!/usr/bin/env python3
"""flow/gds_canonicalize.py

Zero the embedded per-structure creation/modification timestamp payloads in
a GDSII stream before it is diffed or committed.

Why this exists: `klt place-and-route`'s DEF->GDS merge (KLayout's `pya`,
in-process) stamps every BGNLIB/BGNSTR record with the wall-clock time of
the merge. Two runs of the *identical* place-and-route request (same
netlist, same seed, same PDK) produce byte-identical DEF output but
NOT byte-identical GDS output -- the only difference is these timestamp
fields, confirmed by re-running `flow/layout.sh` twice and diffing (see
`layout/README.md`). Filed upstream as a klayout-tools tool gap:
https://github.com/2AMLogic/klayout-tools/issues/1367 -- this script is the
documented workaround `flow/layout.sh` uses in the meantime, so the
"regenerate from source and diff against the committed copy"
reproducibility check has a stable target rather than tripping on a
cosmetic container-format artifact on every run.

GDSII stream format: a flat sequence of records, each starting with a
4-byte header -- a big-endian uint16 record length (including this header),
a 1-byte record type, and a 1-byte data type -- followed by (length - 4)
bytes of payload. BGNLIB (record type 0x01) and BGNSTR (record type 0x05)
both carry a fixed 24-byte payload: two 12-byte date/time blocks (6 x
big-endian int16: year, month, day, hour, minute, second), the first for
creation and the second for last modification. Zeroing that payload in
place -- same record, same length, same position -- changes nothing about
the layout's actual geometry/hierarchy, only these two timestamps.

Usage:
    gds_canonicalize.py <input.gds> <output.gds>

Exit status: 0 on success; non-zero (with a message on stderr) if the input
cannot be parsed as a GDSII stream.
"""

import struct
import sys

_BGNLIB = 0x01
_BGNSTR = 0x05


def canonicalize(data: bytes) -> bytes:
    out = bytearray(data)
    n = len(data)
    pos = 0
    while pos + 4 <= n:
        (record_len,) = struct.unpack_from(">H", data, pos)
        if record_len < 4:
            raise ValueError(
                f"malformed GDSII record at byte offset {pos}: "
                f"length field {record_len} < 4"
            )
        record_type = data[pos + 2]
        if record_type in (_BGNLIB, _BGNSTR):
            for i in range(pos + 4, min(pos + record_len, n)):
                out[i] = 0
        pos += record_len
    return bytes(out)


def main(argv: list) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <input.gds> <output.gds>", file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    with open(src, "rb") as f:
        data = f.read()
    try:
        canonical = canonicalize(data)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    with open(dst, "wb") as f:
        f.write(canonical)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
