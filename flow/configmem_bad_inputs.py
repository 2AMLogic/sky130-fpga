#!/usr/bin/env python3
"""Malformed-input cases for the ConfigMem differential bench (issue #200).

Derives broken vector / map files from a VALID vector file (the output of
flow/configmem_frames.py) and the committed map, for driver-level regressions
of design/fabulous/tb_configmem_equiv.v against the unmodified generated
ConfigMem. Every "bad" case must end in a setup ERROR with no terminal summary
(classified INFRA, never a kill); every "good" case is a positive control the
bench must still accept (completed PASS on the unmodified ConfigMem).

Usage: configmem_bad_inputs.py <valid vectors> <valid map> <out dir>
Prints one line per case: "<expect> <kind> <name> <vector file> <map file>"
with expect in {bad, good} and kind in {vec, map}.
"""
import sys
from pathlib import Path


def streams(lines):
    """Split vector lines into [S line, F lines...] groups."""
    out = []
    for ln in lines:
        if ln.startswith("S "):
            out.append([ln])
        else:
            out[-1].append(ln)
    return out


def join(lines, eol=True):
    return "\n".join(lines) + ("\n" if eol else "")


def main(argv):
    vec, mapf, outd = Path(argv[1]), Path(argv[2]), Path(argv[3])
    outd.mkdir(parents=True, exist_ok=True)
    vtext, mtext = vec.read_text(), mapf.read_text()
    vl, ml = vtext.splitlines(), mtext.splitlines()
    st = streams(vl)
    assert len(st) >= 3 and all(len(s) == 21 for s in st), "need >= 3 complete 20-frame streams"
    s1, s2, s3 = st[0], st[1], st[2]
    two = s1 + s2                                   # two complete streams (valid alone)
    S2, F2 = s2[0], s2[1:]
    f_first = F2[0].split()                         # ['F', frame, data]

    def F(frame, data):
        return f"F {frame} {data}"

    vec_cases = {
        # acceptance reproducer: valid first stream, truncated second stream
        "truncated-2nd-stream": s1 + [S2] + F2[:2],
        "truncated-mid-stream": s1 + [S2] + F2[:10] + s3,
        "short-S-no-name": s1 + [" ".join(S2.split()[:2])] + F2,
        "short-S-tag-only": s1 + ["S"] + F2,
        "short-F-no-data": s1 + [S2, f"F {f_first[1]}"] + F2[1:],
        "short-F-tag-only": s1 + [S2, "F"] + F2[1:],
        "extra-field-F": s1 + [S2, F2[0] + " 0"] + F2[1:],
        "extra-field-S": s1 + [S2 + " extra"] + F2,
        "unknown-tag": s1 + [S2, "X 1 2"] + F2,
        "lowercase-tag": s1 + [S2, "f" + F2[0][1:]] + F2[1:],
        "bad-hex-F": s1 + [S2, F(f_first[1], "0000zz00")] + F2[1:],
        "short-hex-F": s1 + [S2, F(f_first[1], f_first[2][1:])] + F2[1:],
        "long-hex-F": s1 + [S2, F(f_first[1], "0" + f_first[2])] + F2[1:],
        "bad-hex-S": s1 + ["S " + "g" * 40 + " x"] + F2,
        "short-hex-S": s1 + ["S " + S2.split()[1][1:] + " x"] + F2,
        "S-bits-beyond-width": s1 + ["S 4" + S2.split()[1][1:] + " x"] + F2,
        "bad-frame-number": s1 + [S2, F("x" + f_first[1], f_first[2])] + F2[1:],
        "negative-frame": s1 + [S2, F("-1", f_first[2])] + F2[1:],
        "frame-out-of-range": s1 + [S2, F(20, f_first[2])] + F2[1:],
        "F-before-S": [F(0, "00000000")] + two,
        "missing-frame": s1 + [S2] + F2[:5] + F2[6:] + s3,
        "duplicate-frame": s1 + [S2] + F2[:5] + [F(F2[4].split()[1], F2[5].split()[2])] + F2[6:],
        "extra-duplicate-frame": s1 + [S2] + F2 + [F2[0]],
        "trailing-garbage": two + ["garbage"],
        "trailing-short-F": two + ["F 0"],
        "trailing-S-header": two + [S2],
        "trailing-blank-line": two + [""],
        "blank-line-mid": s1 + [""] + s2,
        "double-space": s1 + [S2, F2[0].replace(" ", "  ", 1)] + F2[1:],
        "trailing-space": s1 + [S2, F2[0] + " "] + F2[1:],
        "tab-separator": s1 + [S2, F2[0].replace(" ", "\t")] + F2[1:],
        "crlf": [ln + "\r" for ln in two],
        "line-too-long": s1 + [S2[:2] + "0" * 300 + " x"] + F2,
    }
    map_cases = {
        "duplicate-cb-index": [ml[0], "0 " + ml[1].split()[1]] + ml[2:],
        "missing-cb-index": ml[:-1],
        "duplicate-position": ml[:-1] + [ml[-1].split()[0] + " " + ml[0].split()[1]],
        "cb-index-out-of-range": ml[:-1] + ["158 " + ml[-1].split()[1]],
        "position-out-of-range": ml[:-1] + [ml[-1].split()[0] + " 640"],
        "malformed-row": ml[:5] + [ml[5].split()[0] + " x"] + ml[6:],
        "short-row": ml[:5] + [ml[5].split()[0]] + ml[6:],
        "extra-field-row": ml[:5] + [ml[5] + " 7"] + ml[6:],
        "negative-index": ml[:5] + ["-1 " + ml[5].split()[1]] + ml[6:],
        "hex-row": ml[:5] + ["0x5 " + ml[5].split()[1]] + ml[6:],
        "trailing-garbage": ml + ["garbage"],
        "trailing-extra-row": ml + [ml[0]],
        "trailing-blank-line": ml + [""],
        "blank-line-mid": ml[:5] + [""] + ml[5:],
    }
    good_vec = {
        # positive controls: transaction order inside a stream is not restricted,
        # and a missing final newline is still a clean EOF
        "reordered-frames": [ln for s in st for ln in [s[0]] + s[1:][::-1]],
        "no-final-newline": None,
    }
    rows = []
    for name, lines in vec_cases.items():
        p = outd / f"vec_{name}.txt"
        p.write_text(join(lines))
        assert p.read_text() != vtext, name
        rows.append(("bad", "vec", name, p, mapf))
    for name, lines in map_cases.items():
        p = outd / f"map_{name}.txt"
        p.write_text(join(lines))
        assert p.read_text() != mtext, name
        rows.append(("bad", "map", name, vec, p))
    for name, lines in good_vec.items():
        p = outd / f"vec_good_{name}.txt"
        p.write_text(vtext.rstrip("\n") if lines is None else join(lines))
        assert p.read_text() != vtext, name
        rows.append(("good", "vec", name, p, mapf))
    p = outd / "map_good_no-final-newline.txt"
    p.write_text(mtext.rstrip("\n"))
    rows.append(("good", "map", "no-final-newline", vec, p))
    for r in rows:
        print(" ".join(str(x) for x in r))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
