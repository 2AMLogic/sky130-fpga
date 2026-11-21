"""Regression checks for recovery of the committed logic_tile netlist."""

import re
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

FLOW = Path(__file__).resolve().parent
ROOT = FLOW.parent
DEF = ROOT / "layout/logic_tile.def"
NETLIST = ROOT / "layout/logic_tile.asbuilt.v"
SDF = ROOT / "measurements/timing-characterization/logic_tile_route.sdf"


def generate(*args):
    return subprocess.run(
        [sys.executable, "-I", FLOW / "def_to_netlist.py", *args],
        capture_output=True,
        text=True,
        check=False,
    )


class DefToNetlistTest(unittest.TestCase):
    def test_check_detects_drift_without_touching_output(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "tile.v"
            result = generate("--output", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_bytes(), NETLIST.read_bytes())
            self.assertEqual(generate("--output", output, "--check").returncode, 0)
            changed = output.read_bytes().replace(b".S1(in[1])", b".S1(in[0])", 1)
            self.assertNotEqual(changed, output.read_bytes())
            output.write_bytes(changed)
            result = generate("--output", output, "--check")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("drift", result.stderr)
            self.assertEqual(output.read_bytes(), changed)

    def test_sdf_and_def_match_emitted_cells(self):
        netlist = NETLIST.read_text()
        emitted = Counter(
            (name.removeprefix("\\"), cell)
            for cell, name in re.findall(
                r"^\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\(", netlist, re.MULTILINE
            )
        )
        sdf = SDF.read_text()
        cells = re.findall(
            r'\(CELL\s+\(CELLTYPE "(\w+)"\)\s+\(INSTANCE\s*([^)]*)\)', sdf
        )
        self.assertEqual(len(cells), sdf.count("(CELLTYPE"))
        self.assertEqual([cell for cell, name in cells if not name], ["logic_tile"])
        self.assertRegex(netlist, r"\bmodule logic_tile\s*\(")
        named = Counter((name.replace("\\", ""), cell) for cell, name in cells if name)
        self.assertEqual(len(named), 47)
        self.assertEqual(sum(named.values()), 47)
        self.assertEqual(emitted, named)
        components = (
            DEF.read_text().split("COMPONENTS 212 ;")[1].split("END COMPONENTS")[0]
        )
        physical = Counter()
        logical = Counter()
        for name, cell in re.findall(r"^\s*- (\S+) (\S+)", components, re.MULTILINE):
            if re.fullmatch(r"sky130_fd_sc_hd__fill_\d+", cell):
                physical["filler"] += 1
            elif cell == "sky130_fd_sc_hd__tapvpwrvgnd_1":
                physical["tap"] += 1
            else:
                logical[name.replace("\\", ""), cell] += 1
        self.assertEqual(physical, {"filler": 149, "tap": 16})
        self.assertEqual(logical, emitted)

    def test_ports_and_named_connections(self):
        netlist = NETLIST.read_text()
        declarations = re.findall(
            r"^\s*(input|output|inout)\s+([^;]+);", netlist, re.MULTILINE
        )
        self.assertCountEqual(
            declarations,
            [
                ("input", "clk"),
                ("input", "rst"),
                ("input", "[3:0] ce"),
                ("input", "[15:0] in"),
                ("input", "[63:0] lut_init"),
                ("input", "[3:0] reg_sel"),
                ("output", "[3:0] out"),
            ],
        )
        mux = re.search(
            r"sky130_fd_sc_hd__mux4_2\s+\\g_slice\[3\]\.u_slice/_12_\s+\((.*?)\);",
            netlist,
            re.DOTALL,
        )
        self.assertIsNotNone(mux)
        self.assertEqual(
            dict(re.findall(r"\.(\w+)\((\S+?)\s*\)", mux[1])),
            {
                "A0": "lut_init[60]",
                "A1": "lut_init[61]",
                "A2": "lut_init[62]",
                "A3": "lut_init[63]",
                "S0": "in[12]",
                "S1": "in[13]",
                "X": r"\g_slice[3].u_slice/_04_",
            },
        )

    def test_changed_def_endpoint_reaches_verilog(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = Path(scratch) / "tile.def"
            output = Path(scratch) / "tile.v"
            # Swap two LUT data pins while keeping both nets and pins present.
            text = DEF.read_text()
            old = r"g_slice\[3\].u_slice/_12_ A"
            source.write_text(
                text.replace(old + "2 ", old + "TMP ")
                .replace(old + "3 ", old + "2 ")
                .replace(old + "TMP ", old + "3 ")
            )
            result = generate("--def", source, "--output", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(".A2(lut_init[63])", output.read_text())
            self.assertIn(".A3(lut_init[62])", output.read_text())

    def test_refuses_unaccounted_special_connection(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = Path(scratch) / "tile.def"
            output = Path(scratch) / "tile.v"
            source.write_text(DEF.read_text().replace("( * VPB )", "( * VNB )"))
            result = generate("--def", source, "--output", output)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected supply connections: VPWR", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
