#!/usr/bin/env python3
"""flow/sdf_sanitize_names.py

Paired, name-only rewrite of the routed gate-level Verilog netlist and of the
post-route IEEE-1497 SDF, so that no identifier either file carries contains
a literal `.`, `[`, `]` or `/` (issue #213).

Why: this design's `generate`-block RTL (design/rtl/logic_tile.v's
`g_slice[N].u_slice`) flattens to instance/net names such as
`\\g_slice[0].u_slice/_08_` in the netlist and `g_slice\\[0\\]\\.u_slice\\/_08_`
in the SDF. Icarus's `$sdf_annotate` aborts `vvp` (`NULL handle passed to
vpi_scan`, klayout-tools#2897) on any INTERCONNECT entry whose escaped
identifier contains such a character. Renaming both files with ONE
deterministic map removes the trigger without touching connectivity.

The mapping is the one `flow/sta_sanitize_names.py` already uses for the
DEF/SPEF (`unescape`, then -- only for names containing `/` or `.` -- `[`,
`]`, `.` -> `_` and `/` -> `__`); it is imported, not re-implemented, so the
two cannot drift. Plain bus-indexed names (`ce[0]`, `lut_init[3]`) are left
alone, exactly as there.

Why this is a pure rename, and how that is checked rather than asserted
(`check`):
  * the map is injective over the names it rewrites AND does not collide
    with any identifier already present unrewritten in the same file;
  * applying the inverse map to the sanitized file reproduces the original
    file byte-for-byte (netlist and SDF);
  * every instance the sanitized SDF names exists in the sanitized netlist.

Usage:
    sdf_sanitize_names.py netlist <in.v> <out.v> <map.json>
    sdf_sanitize_names.py sdf     <in.sdf> <out.sdf> <map.json>
    sdf_sanitize_names.py check   <in.v> <out.v> <in.sdf> <out.sdf> \\
                                  <netlist-map.json> <sdf-map.json>

`netlist` / `sdf` write the sanitized file and a JSON map of
`{original spelling: sanitized name}`. `check` exits non-zero on any
violation of the properties above.
"""

from __future__ import annotations

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sta_sanitize_names import needs_rewrite, sanitize, unescape  # noqa: E402

# A Verilog escaped identifier: backslash, then non-whitespace, ended by
# whitespace (the whitespace is not part of the name and is left in place).
_V_ESCAPED = re.compile(r"\\(\S+)(?=\s)")
_V_PLAIN_ID = re.compile(r"(?<![\w$\\])[A-Za-z_][\w$]*(?![\w$])")
# An SDF path token: any run of escaped characters / non-delimiters.
_SDF_TOKEN = re.compile(r"(?:\\.|[^\s()\\])+")
_SDF_ESC_CHARS = "[]./"


def _split_sdf_token(token: str) -> list[str]:
    """Split on unescaped `.` (the SDF hierarchy divider), keeping escapes."""
    segments, cur, i = [], [], 0
    while i < len(token):
        if token[i] == "\\" and i + 1 < len(token):
            cur.append(token[i : i + 2])
            i += 2
        elif token[i] == ".":
            segments.append("".join(cur))
            cur = []
            i += 1
        else:
            cur.append(token[i])
            i += 1
    segments.append("".join(cur))
    return segments


def _check_injective(mapping: dict[str, str], plain_ids: set[str]) -> None:
    targets = list(mapping.values())
    if len(set(targets)) != len(targets):
        raise ValueError("name rewrite is not injective: two names map to one")
    clash = set(targets) & plain_ids
    if clash:
        raise ValueError(
            "sanitized name collides with an existing identifier: "
            + ", ".join(sorted(clash)[:5])
        )


def sanitize_netlist(text: str) -> tuple[str, dict[str, str]]:
    mapping: dict[str, str] = {}

    def repl(m: re.Match) -> str:
        plain = unescape(m.group(1))
        if not needs_rewrite(plain):
            return m.group(0)
        new = sanitize(plain)
        mapping[m.group(0)] = new
        return new

    out = _V_ESCAPED.sub(repl, text)
    plain_ids = set(_V_PLAIN_ID.findall(_V_ESCAPED.sub("", text)))
    _check_injective(mapping, plain_ids)
    return out, mapping


def unsanitize_netlist(text: str, mapping: dict[str, str]) -> str:
    inverse = {v: k for k, v in mapping.items()}
    return _V_PLAIN_ID.sub(lambda m: inverse.get(m.group(0), m.group(0)), text)


def sanitize_sdf(text: str) -> tuple[str, dict[str, str]]:
    mapping: dict[str, str] = {}
    plain_ids: set[str] = set()

    def repl(m: re.Match) -> str:
        token = m.group(0)
        if "\\" not in token:
            plain_ids.update(token.split("."))
            return token
        segs = _split_sdf_token(token)
        for i, seg in enumerate(segs):
            plain = unescape(seg)
            if "\\" in seg and needs_rewrite(plain):
                new = sanitize(plain)
                mapping[seg] = new
                segs[i] = new
            else:
                plain_ids.add(seg)
        return ".".join(segs)

    out = _SDF_TOKEN.sub(repl, text)
    _check_injective(mapping, plain_ids)
    return out, mapping


def unsanitize_sdf(text: str, mapping: dict[str, str]) -> str:
    inverse = {v: k for k, v in mapping.items()}

    def repl(m: re.Match) -> str:
        token = m.group(0)
        if "\\" in token:
            return token
        return ".".join(inverse.get(s, s) for s in token.split("."))

    return _SDF_TOKEN.sub(repl, text)


def sdf_instances(text: str) -> set[str]:
    return {t for t in re.findall(r"\(INSTANCE\s+(\S+?)\)", text) if t != "*"}


def check(
    netlist_in: str,
    netlist_out: str,
    sdf_in: str,
    sdf_out: str,
    nmap: dict[str, str],
    smap: dict[str, str],
) -> list[str]:
    """Return a list of violations (empty == the rename is a pure rename)."""
    problems = []
    if unsanitize_netlist(netlist_out, nmap) != netlist_in:
        problems.append("netlist: inverse map does not reproduce the original")
    if unsanitize_sdf(sdf_out, smap) != sdf_in:
        problems.append("sdf: inverse map does not reproduce the original")
    # Both files must use the SAME plain-name -> sanitized-name function.
    n_plain = {unescape(k[1:]): v for k, v in nmap.items()}
    s_plain = {unescape(k): v for k, v in smap.items()}
    for name in n_plain.keys() & s_plain.keys():
        if n_plain[name] != s_plain[name]:
            problems.append(f"maps disagree on {name!r}")
    for name in sdf_instances(sdf_out):
        if not re.search(r"(?<![\w$])" + re.escape(name) + r"(?![\w$])", netlist_out):
            problems.append(f"sdf instance {name!r} absent from sanitized netlist")
    leftovers = [
        t
        for t in _SDF_TOKEN.findall(sdf_out)
        if "\\" in t and any(c in unescape(t) for c in "/")
    ]
    if leftovers:
        problems.append(f"sdf: escaped '/' identifiers remain: {leftovers[:3]}")
    if _V_ESCAPED.search(netlist_out) and any(
        needs_rewrite(unescape(m)) for m in _V_ESCAPED.findall(netlist_out)
    ):
        problems.append("netlist: escaped identifiers needing rewrite remain")
    return problems


def _read(path: str) -> str:
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def _write(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode in ("netlist", "sdf") and len(argv) == 5:
            fn = sanitize_netlist if mode == "netlist" else sanitize_sdf
            out, mapping = fn(_read(argv[2]))
            _write(argv[3], out)
            _write(argv[4], json.dumps(mapping, indent=1, sort_keys=True) + "\n")
            print(f"{mode}: renamed {len(mapping)} distinct names")
            return 0
        if mode == "check" and len(argv) == 8:
            nmap = json.loads(_read(argv[6]))
            smap = json.loads(_read(argv[7]))
            problems = check(
                _read(argv[2]), _read(argv[3]), _read(argv[4]), _read(argv[5]),
                nmap, smap,
            )
            for p in problems:
                print(f"FAIL: {p}", file=sys.stderr)
            if not problems:
                print(
                    f"PASS: pure rename (netlist {len(nmap)} names, sdf "
                    f"{len(smap)} names; injective, inverse byte-identical)"
                )
            return 1 if problems else 0
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
