#!/usr/bin/env python3
"""flow/lvs_sanitize_verilog.py

Work around a real `klt lvs` gate-level-verilog parsing gap
(https://github.com/2AMLogic/klayout-tools/issues/1371, filed alongside
issue #12): `klt`'s `reference.form = "gate-level-verilog"` converter
rejects a Verilog *escaped* identifier (Verilog's own convention for a name
containing characters that would otherwise be delimiters, e.g. `[`, `]`,
`.`, `/`) whenever that identifier is used as a net/instance reference --
it misreads the embedded `[N]` as an attempted bus bit-select instead of
treating the whole escaped token as one atomic name. `logic_tile`'s as-built
netlist (`klt place-and-route`'s `verilog_path`) carries exactly this shape
for every internal net/instance under the RTL's `generate` block
(`design/rtl/logic_tile.v`'s `g_slice[N].u_slice`), e.g.
`\\g_slice[0].u_slice/_01_ `.

This script performs a **name-only, connectivity-preserving** rewrite: every
backslash-escaped identifier (an internal net or instance name -- never a
top-level port name, none of which are escaped in this netlist) is replaced
by a plain identifier built by substituting each disallowed character with
`_`, de-duplicated with a numeric suffix on collision. The substitution is
applied identically everywhere the same original escaped token appears (net
declarations, instance names, and every `.PORT(<net>)` connection site), so
the netlist's device/net/pin topology -- the only thing a `klt lvs` compare
actually checks (see docs/cli/lvs.md, "Scope: schematic-equivalent,
topological compare only") -- is completely unchanged. Top-level pin names
(`clk`, `rst`, `ce`, `in`, `lut_init`, `out`, `reg_sel`) are never escaped in
this netlist and are left untouched either way.

Usage:
    lvs_sanitize_verilog.py <input.v> <output.v>
"""

import re
import sys

_ESCAPED_TOKEN_RE = re.compile(r"\\[^\s]+")
_DISALLOWED_RE = re.compile(r"[^A-Za-z0-9_$]")


def sanitize(text: str) -> str:
    mapping: dict[str, str] = {}
    used: set[str] = set()

    def _replacement(match: "re.Match[str]") -> str:
        original = match.group(0)
        if original in mapping:
            return mapping[original]
        raw = original[1:]  # strip the leading backslash
        candidate = _DISALLOWED_RE.sub("_", raw)
        if not candidate or not (candidate[0].isalpha() or candidate[0] in "_$"):
            candidate = f"n_{candidate}"
        base = candidate
        suffix = 0
        while candidate in used:
            suffix += 1
            candidate = f"{base}__{suffix}"
        used.add(candidate)
        mapping[original] = candidate
        return candidate

    return _ESCAPED_TOKEN_RE.sub(_replacement, text)


def main(argv: list) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <input.v> <output.v>", file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    with open(src, encoding="utf-8") as f:
        text = f.read()
    with open(dst, "w", encoding="utf-8") as f:
        f.write(sanitize(text))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
