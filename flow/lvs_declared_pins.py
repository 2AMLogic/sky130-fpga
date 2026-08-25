#!/usr/bin/env python3
"""flow/lvs_declared_pins.py

Derive the `--pins`/`declared_pins` list `klt extract` needs (see
docs/cli/extract.md, "`--pins`") from a `klt place-and-route` `verilog_path`
netlist's own port declarations, instead of hand-maintaining a separate,
driftable copy of `logic_tile`'s port list in `flow/lvs.sh`.

Why this is needed: `klt extract`'s flat extraction promotes *every* named
net to a top-level pin by default (see docs/cli/extract.md), including the
hundreds of internal, DEF-recovered hierarchical net names
(`--def-net-names`) this design's `generate`-block RTL produces (see
`flow/lvs_sanitize_verilog.py`'s header comment) -- so a `klt lvs
reference.form=gate-level-verilog` compare against the reference's genuine
94 top-level pins (`clk`, `rst`, `ce[3:0]`, `in[15:0]`, `lut_init[63:0]`,
`out[3:0]`, `reg_sel[3:0]`) fails outright (94 reference pins vs 137+
over-promoted layout pins). `--pins` restricts promotion to exactly the
named set; this script derives that set directly from the same as-built
netlist `flow/lvs.sh` already reads as the LVS reference, so the pin list
can never silently drift out of sync with the design's actual ports.

Only the narrow declaration shape `verilog_netlist.py` itself accepts is
parsed here (`input`/`output`/`inout` statements, optionally `[msb:lsb]`
ranged) -- this script is a thin, disposable pre-processing convenience for
`flow/lvs.sh`, not a general Verilog parser.

Usage:
    lvs_declared_pins.py <netlist.v>

Prints a comma-joined pin list (bit-expanded, e.g. `in[15],in[14],...`) to
stdout, suitable for `klt extract --pins`.
"""

import re
import sys

_DIRECTION_STMT_RE = re.compile(
    r"^(?:input|output|inout)\s+(?:wire\s+|reg\s+)?"
    r"(?:\[\s*(?P<msb>-?\d+)\s*:\s*(?P<lsb>-?\d+)\s*\]\s*)?"
    r"(?P<names>[A-Za-z_$][A-Za-z0-9_$]*(?:\s*,\s*[A-Za-z_$][A-Za-z0-9_$]*)*)$"
)


def declared_pins(text: str) -> list:
    pins: list = []
    for statement in text.split(";"):
        statement = statement.strip()
        match = _DIRECTION_STMT_RE.match(statement)
        if match is None:
            continue
        names = [n.strip() for n in match.group("names").split(",")]
        if match.group("msb") is not None:
            msb = int(match.group("msb"))
            lsb = int(match.group("lsb"))
            step = -1 if msb >= lsb else 1
            for name in names:
                for bit in range(msb, lsb + step, step):
                    pins.append(f"{name}[{bit}]")
        else:
            pins.extend(names)
    return pins


def main(argv: list) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <netlist.v>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        text = f.read()
    pins = declared_pins(text)
    if not pins:
        print(f"error: no port declarations found in {argv[1]!r}", file=sys.stderr)
        return 1
    print(",".join(pins))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
