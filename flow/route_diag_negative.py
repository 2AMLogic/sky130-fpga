#!/usr/bin/env python3
"""Negative-control streams for the route diagnostics at gate level (issue #189).

EXPERIMENTAL, DIAGNOSTIC ONLY. Makes a scratch copy of one generated route
diagnostic suite directory (flow/route_diag.py, flow/ctrl_route.py or
flow/output_route.py output) in which exactly ONE case's FASM has its route
under test re-pointed to a DIFFERENT LEGAL source of the same sink, then
re-assembles that case's .bin/.cfg through the existing assembler
(flow/fasm_to_bitstream.py). The case list -- and therefore the bench's
identifier-derived oracle -- is copied unchanged, so the replay must give a
completed functional FAIL on exactly that case, with the loaded cfg equal to
the decode of the altered stream. A stream that does not assemble, or a
replacement that is not a pip of the frozen fabric model, is a setup error of
this helper (nonzero exit), never a detected defect.

Usage:
  flow/route_diag_negative.py <src dir> <dst dir> <case> <old feature> <new feature>
                              [--snapshot sim/bitstream/fabric_spec.json]
Features are FASM pip lines, e.g. X1Y1.E1END2.LC_I2 -> X1Y1.S1END2.LC_I2.
"""
import argparse
import importlib.util
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


F = _load("fasm_to_bitstream", REPO / "flow" / "fasm_to_bitstream.py")


class NegError(Exception):
    pass


def split_pip(feature):
    parts = feature.split(".")
    if len(parts) != 3 or not all(parts):
        raise NegError(f"not a FASM pip feature: {feature!r}")
    return tuple(parts)


def alter(src, dst, case, old, new, snap_path):
    """-> (n_changed_cfg_bits, original cfg, altered cfg) after writing <dst>."""
    src, dst = Path(src), Path(dst)
    snap = F.load_snapshot(snap_path)
    ids = [ln.split()[0] for ln in (src / "cases.txt").read_text().splitlines() if ln.strip()]
    if ids.count(case) != 1:
        raise NegError(f"case {case} appears {ids.count(case)} times in {src}/cases.txt (need exactly 1)")
    ot, osrc, osink = split_pip(old)
    nt, nsrc, nsink = split_pip(new)
    if (ot, osink) != (nt, nsink) or osrc == nsrc:
        raise NegError("the replacement must select a different source of the same sink on the same tile")
    model = {(st, sw, dw) for st, sw, dt, dw in snap["pips"] if st == dt}
    for t, s, d in ((ot, osrc, osink), (nt, nsrc, nsink)):
        if (t, s, d) not in model:
            raise NegError(f"pip {t}.{s}.{d} is not in the frozen fabric model (not a legal source)")
    lines = (src / f"{case}.fasm").read_text().splitlines()
    if lines.count(old) != 1:
        raise NegError(f"{case}.fasm contains {lines.count(old)} lines == {old!r} (need exactly 1)")
    if new in lines:
        raise NegError(f"{case}.fasm already contains {new!r}")
    text = "\n".join(new if ln == old else ln for ln in lines) + "\n"
    asm = F.assemble(text, snap, None)
    data = F.pack(asm["positions"], snap)
    cfg, _ = F.decode(data, snap)
    if cfg != asm["cfg"]:
        raise NegError(f"{case}: decode(pack()) != assembled cfg")
    orig = int((src / f"{case}.cfg").read_text().strip(), 16)
    if cfg == orig:
        raise NegError(f"{case}: altered stream assembles to the original configuration")
    if dst.exists():
        raise NegError(f"{dst} already exists")
    shutil.copytree(src, dst)
    (dst / f"{case}.fasm").write_text(text)
    (dst / f"{case}.bin").write_bytes(data)
    (dst / f"{case}.cfg").write_text(f"{cfg:040x}\n")
    return bin(cfg ^ orig).count("1"), orig, cfg


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("case")
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--snapshot", default=str(REPO / "sim" / "bitstream" / "fabric_spec.json"))
    a = ap.parse_args(argv)
    try:
        n, _, _ = alter(a.src, a.dst, a.case, a.old, a.new, a.snapshot)
    except (NegError, F.AsmError, F.BitstreamError, OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"route_diag_negative: case {a.case}: {a.old} -> {a.new} (legal source of the same sink; "
          f"{n} cfg bits changed; case list and oracle unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
