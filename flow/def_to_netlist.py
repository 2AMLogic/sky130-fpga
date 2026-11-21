#!/usr/bin/env python3
"""Recover the signal-only Verilog reference from the routed logic_tile DEF.

Reads the OpenROAD DEF subset used by layout/logic_tile.def. Boundary pins
name their nets and indexed pins form contiguous, descending Verilog buses.
Only the sky130 HD fillers, taps and two wildcard supply nets are omitted.
No cell library, SDF or place-and-route tool is needed.
"""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path
from tempfile import TemporaryDirectory

FLOW = Path(__file__).resolve().parent
sys.path.insert(0, str(FLOW))
from sta_sanitize_names import unescape

VERSION = "1"
LAYOUT = FLOW.parent / "layout"
PLAIN_NAME = r"[A-Za-z_][A-Za-z0-9_$]*"
PORT_NAME = re.compile(rf"({PLAIN_NAME})(?:\[(\d+)\])?")
PHYSICAL_CELL = re.compile(r"sky130_fd_sc_hd__(?:fill_\d+|tapvpwrvgnd_1)")
# The four supply/well pins are implicit in the logical cell models.
SUPPLIES = {"VGND": ("GROUND", "VNB"), "VPWR": ("POWER", "VPB")}


def records(text, section):
    """Read counted, semicolon-terminated DEF records, including wrapped lines."""
    match = re.search(
        rf"^{section}\s+(\d+)\s*;(.*?)^END {section}$", text, re.MULTILINE | re.DOTALL
    )
    if not match:
        raise ValueError(f"missing {section} section")
    entries = {}
    for record in match[2].strip().split(";"):
        if not record.strip():
            continue
        dash, name, rest = record.split(None, 2)
        if dash != "-" or name in entries:
            raise ValueError(f"invalid or duplicate {section} record: {name}")
        entries[name] = rest.strip()
    if len(entries) != int(match[1]):
        raise ValueError(
            f"{section}: expected {match[1]} records, found {len(entries)}"
        )
    return entries


def attribute(record, key):
    match = re.search(rf"\+\s+{key}\s+(\S+)", record)
    if not match:
        raise ValueError(f"missing {key} in {record.splitlines()[0]}")
    return match[1]


def endpoints(record):
    """Only the connection list before the first '+' contains pin tuples."""
    members = record.split("+", 1)[0].split()
    if len(members) % 4:
        raise ValueError(f"malformed endpoints: {members}")
    for start in range(0, len(members), 4):
        left, instance, pin, right = members[start : start + 4]
        if (left, right) != ("(", ")"):
            raise ValueError(f"malformed endpoints: {members}")
        yield instance, pin


def signal_pins(text):
    pins = records(text, "PINS")
    special = records(text, "SPECIALNETS")
    if special.keys() != SUPPLIES.keys():
        raise ValueError("expected VGND and VPWR special nets")
    for name, (use, well) in SUPPLIES.items():
        pin = pins.pop(name)
        if (
            attribute(pin, "NET"),
            attribute(pin, "DIRECTION"),
            attribute(pin, "USE"),
        ) != (name, "INOUT", use):
            raise ValueError(f"unexpected supply pin: {name}")
        if attribute(special[name], "USE") != use or sorted(
            endpoints(special[name])
        ) != sorted([("PIN", name), ("*", name), ("*", well)]):
            raise ValueError(f"unexpected supply connections: {name}")
    directions = {}
    for name, pin in pins.items():
        direction = attribute(pin, "DIRECTION")
        if attribute(pin, "NET") != name or direction not in {
            "INPUT",
            "OUTPUT",
            "INOUT",
        }:
            raise ValueError(f"unsupported boundary pin: {name}")
        directions[name] = direction.lower()
    return directions


def port_declarations(pins):
    groups = defaultdict(list)
    for name, direction in pins.items():
        match = PORT_NAME.fullmatch(name)
        if not match:
            raise ValueError(f"unsupported port name: {name}")
        groups[match[1]].append((direction, int(match[2]) if match[2] else None))

    declarations = {}
    for port, bits in sorted(groups.items()):
        indices = [index for _, index in bits]
        width = ""
        directions = {direction for direction, _ in bits}
        if len(directions) != 1:
            raise ValueError(f"inconsistent direction on {port}")
        direction = directions.pop()
        if indices != [None]:
            if None in indices or len(set(indices)) != max(indices) - min(indices) + 1:
                raise ValueError(f"incomplete or mixed bus: {port}")
            width = f"[{max(indices)}:{min(indices)}] "
        declarations[port] = f"{direction} {width}{port};"
    return declarations


def identifier(token):
    plain = unescape(token)
    return plain if re.fullmatch(PLAIN_NAME, plain) else f"\\{plain} "


def render(text):
    design = re.search(r"^DESIGN\s+(\S+)\s*;", text, re.MULTILINE)
    if not design or design[1] != "logic_tile":
        raise ValueError("expected DESIGN logic_tile")
    cells = {
        name: rest.split()[0] for name, rest in records(text, "COMPONENTS").items()
    }
    pins = signal_pins(text)
    ports = port_declarations(pins)
    nets = records(text, "NETS")
    connections = defaultdict(dict)
    boundary = set()
    for net, record in nets.items():
        if net in SUPPLIES:
            raise ValueError(f"supply {net} also present in signal nets")
        signal = net if net in pins else identifier(net)
        for instance, pin in endpoints(record):
            if instance == "PIN":
                if pin not in pins or pin != net or pin in boundary:
                    raise ValueError(f"unexpected boundary connection {pin} on {net}")
                boundary.add(pin)
            else:
                if instance not in cells or pin in connections[instance]:
                    raise ValueError(
                        f"unknown instance or repeated endpoint: {instance} {pin}"
                    )
                connections[instance][pin] = signal
    if boundary != pins.keys():
        raise ValueError(
            f"missing boundary connections: {sorted(pins.keys() - boundary)}"
        )

    lines = [
        f"// Generated by flow/def_to_netlist.py v{VERSION} from the routed DEF.",
        f"module {design[1]} ({', '.join(ports)});",
        *(f"  {decl}" for decl in ports.values()),
        "",
        *(f"  wire {identifier(net)};" for net in sorted(nets.keys() - pins.keys())),
    ]
    for name, cell in sorted(cells.items()):
        terms = connections[name]
        if PHYSICAL_CELL.fullmatch(cell):
            if terms:
                raise ValueError(f"physical-only cell {name} has signal connections")
            continue
        if not terms:
            raise ValueError(f"logical cell {name} has no signal connections")
        lines.append(f"\n  {cell} {identifier(name)} (")
        lines.append(
            ",\n".join(f"    .{pin}({signal})" for pin, signal in sorted(terms.items()))
        )
        lines.append("  );")
    return "\n".join([*lines, "endmodule", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--def", dest="source", type=Path, default=LAYOUT / "logic_tile.def"
    )
    parser.add_argument("--output", type=Path, default=LAYOUT / "logic_tile.asbuilt.v")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument(
        "--check", action="store_true", help="regenerate in scratch and compare bytes"
    )
    args = parser.parse_args()
    try:
        data = render(args.source.read_text(encoding="utf-8")).encode("utf-8")
        if args.check:
            with TemporaryDirectory() as scratch:
                generated = Path(scratch) / "logic_tile.v"
                generated.write_bytes(data)
                if generated.read_bytes() != args.output.read_bytes():
                    raise ValueError(f"netlist drift: {args.output}")
            print(f"byte match: {args.output}")
        else:
            args.output.write_bytes(data)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f"{parser.prog}: {exc}\n")


if __name__ == "__main__":
    main()
