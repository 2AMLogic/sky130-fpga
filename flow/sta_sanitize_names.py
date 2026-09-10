#!/usr/bin/env python3
"""flow/sta_sanitize_names.py

Connectivity-preserving, name-only rewrites of a routed DEF and of a `klt
extract --parasitics --spef` SPEF, so that a real, SPEF-annotated OpenSTA
run is possible for this design. Sibling of `flow/lvs_sanitize_verilog.py`,
which does the analogous thing for `klt lvs`'s Verilog reference netlist
and for the same underlying reason.

Why this is needed (both halves are filed upstream -- see flow/README.md's
"Friction encountered" note for `flow/sta-sweep.sh`):

  This design's `generate`-block RTL (design/rtl/logic_tile.v's
  `g_slice[N].u_slice`) makes the flattened, as-built design carry
  net/instance names that are Verilog *escaped* identifiers containing
  `[`, `]`, `.` and `/` -- e.g. the net `g_slice[0].u_slice/_08_` driven by
  the instance `g_slice[0].u_slice/_17_`. Two separate things break on
  those names:

  1. `klt extract --def-net-connections <def>` matches the DEF's own net
     names against the extraction's net names *literally*. A routed DEF
     spells an escaped identifier `g_slice\\[0\\].u_slice/_08_` (DEF keeps
     the Verilog backslashes), while `--def-net-names` recovers the same
     net from the layout as `g_slice[0].u_slice/_08_`. The two never
     compare equal, so every hierarchical net silently gets **no `*CONN`
     block** in the emitted SPEF -- a `*D_NET` whose R/C network has no pin
     node at all, and therefore contributes nothing to any delay.

  2. Even with `*CONN` present, OpenSTA's SPEF reader cannot resolve a flat
     net/instance name that itself contains the SPEF divider character
     (`/`) -- it reports `net ... not found` / `instance ... not found` and
     drops the annotation, whether the identifier is SPEF-escaped or not.

  The combined effect is the failure mode `klt sta`'s `spef_annotation`
  block exists to prevent, arrived at from a direction that block does not
  check: `annotation_complete` is reported `true` (its correlation probe
  uses `get_nets`, which *does* resolve these names), while the annotated
  parasitics reach `report_power_metric` but not the delay calculator, so
  every setup/hold number comes out bit-identical to the unannotated run.

The rewrite: unescape the identifier, then -- only for names that actually
contain `/` or `.`, i.e. exactly the ones OpenSTA cannot resolve -- map
`[`, `]` and `.` to `_` and `/` to `__`. Plain bus-indexed top-level ports
(`lut_init[0]`, `in[15]`) are deliberately left alone: OpenSTA resolves
those correctly, and rewriting them would only desynchronize the DEF from
the SPEF.

**Why this cannot change a timing verdict.** The rewrite touches
identifiers only. Cell placements, routing geometry, layer assignment,
instance master cells, and every net's membership set are untouched, and
the same pure function is applied to the DEF and to the SPEF, so the two
stay mutually consistent. Static timing analysis is a function of geometry,
connectivity and the liberty deck -- not of what the nets are called.
`flow/sta-sweep.sh` does not take this on trust: at *every* corner it runs
an unannotated `klt sta` on the committed DEF and an unannotated `klt sta`
on the sanitized DEF and fails the sweep unless every reported metric is
identical, so the name rewrite is proven timing-neutral in the same run
that uses it.

Injectivity is asserted per file: if two distinct source identifiers ever
mapped to the same rewritten name the rewrite would merge two nets, so this
script exits non-zero rather than emit a silently-wrong file.

Usage:
    sta_sanitize_names.py def-unescape <in.def> <out.def>
    sta_sanitize_names.py def-sanitize <in.def> <out.def>
    sta_sanitize_names.py spef-sanitize <in.spef> <out.spef>

`def-unescape` removes the DEF's Verilog backslash escapes but keeps the
names otherwise intact -- that is the form `klt extract
--def-net-connections` needs in order to match the extraction's own net
names (gap 1 above). `def-sanitize` produces the `/`- and `.`-free form
`klt sta` needs (gap 2). `spef-sanitize` applies the identical mapping to
the SPEF emitted from the unescaped DEF.
"""

import sys


def unescape(token: str) -> str:
    """Drop backslash escapes from a DEF/SPEF identifier token."""
    out = []
    i = 0
    while i < len(token):
        if token[i] == "\\" and i + 1 < len(token):
            out.append(token[i + 1])
            i += 2
        else:
            out.append(token[i])
            i += 1
    return "".join(out)


def needs_rewrite(plain: str) -> bool:
    """True for names OpenSTA's SPEF reader cannot resolve as flat names."""
    return "/" in plain or "." in plain


def sanitize(plain: str) -> str:
    """Map an unresolvable flat name to a `/`- and `.`-free equivalent."""
    return (
        plain.replace("[", "_").replace("]", "_").replace(".", "_").replace("/", "__")
    )


def _rewrite(text: str, map_token) -> str:
    """Apply `map_token` to every whitespace-delimited token carrying a
    backslash escape, leaving all other tokens (and every line with no
    escape in it at all) byte-identical."""
    mapping = {}
    for token in set(text.split()):
        if "\\" not in token:
            continue
        rewritten = map_token(token)
        if rewritten is not None and rewritten != token:
            mapping[token] = rewritten
    if len(set(mapping.values())) != len(mapping):
        raise ValueError(
            "name rewrite is not injective -- two distinct identifiers map to "
            "the same rewritten name, which would merge two nets"
        )
    lines = []
    for line in text.split("\n"):
        if "\\" in line:
            lines.append(" ".join(mapping.get(t, t) for t in line.split()))
        else:
            lines.append(line)
    return "\n".join(lines)


def def_unescape(text: str) -> str:
    return _rewrite(text, lambda token: unescape(token))


def def_sanitize(text: str) -> str:
    def map_token(token: str):
        plain = unescape(token)
        return sanitize(plain) if needs_rewrite(plain) else plain

    return _rewrite(text, map_token)


_CANONICAL_SPEF_DATE = '*DATE "canonicalized (see flow/sta_sanitize_names.py)"'


def spef_sanitize(text: str) -> str:
    """Same mapping as `def_sanitize`, but aware of SPEF's `:` delimiter --
    an `*I <inst>:<pin>` or `<net>:<node>` token has a suffix that is not
    part of the name being resolved and must be preserved verbatim.

    Also canonicalizes the SPEF header's `*DATE` line. `klt extract --spef`
    stamps it with the wall-clock time of the extraction, so two runs of
    the identical extraction against the identical GDS produce SPEFs that
    differ in exactly that one line -- which would make the
    `spef_sha256` provenance `flow/sta_report_trim.py` records
    non-reproducible, and so make `flow/sta-sweep.sh`'s check mode fail on
    every run for no design reason. Verified live: a re-extraction diffs to
    that single line and nothing else. Same class of tool gap as the GDS
    merge timestamp `flow/gds_canonicalize.py` already zeroes
    (klayout-tools#1367); filed as klayout-tools#1627.
    """

    def map_token(token: str):
        plain = unescape(token)
        head, sep, tail = plain.rpartition(":")
        if sep:
            return sanitize(head) + ":" + tail if needs_rewrite(head) else token
        return sanitize(plain) if needs_rewrite(plain) else token

    lines = [
        _CANONICAL_SPEF_DATE if line.startswith("*DATE ") else line
        for line in text.split("\n")
    ]
    return _rewrite("\n".join(lines), map_token)


_MODES = {
    "def-unescape": def_unescape,
    "def-sanitize": def_sanitize,
    "spef-sanitize": spef_sanitize,
}


def main(argv: list) -> int:
    if len(argv) != 4 or argv[1] not in _MODES:
        print(
            f"usage: {argv[0]} {{{'|'.join(_MODES)}}} <input> <output>",
            file=sys.stderr,
        )
        return 2
    with open(argv[2], encoding="utf-8") as f:
        text = f.read()
    try:
        rewritten = _MODES[argv[1]](text)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    with open(argv[3], "w", encoding="utf-8") as f:
        f.write(rewritten)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
