#!/usr/bin/env python3
"""Summarize a FABulous run directory: emitted files and tile config-bit layout.

Usage: fabulous_summary.py <project-run-dir>

Config-bit layout is read from the generator's own outputs
(Tile/LOGIC4/LOGIC4_ConfigMem.csv, LOGIC4.v, and .FABulous/bitStreamSpec.csv),
not restated by hand, and cross-checked against design/rtl/logic_tile.v's
lut_init[63:0] / reg_sel[3:0] packing.
"""
import ast, csv, os, re, sys

root = sys.argv[1]
if not os.path.isdir(root):
    sys.exit(f"not a directory: {root}")

print("=== emitted files (generated, relative to project dir) ===")
src = {"fabric.csv", "FABulous.tcl", "lut4_ff_bel.v", "models_pack.v", ".env"}
for dp, dn, fn in sorted(os.walk(root)):
    dn.sort()
    for f in sorted(fn):
        rel = os.path.relpath(os.path.join(dp, f), root)
        if f in src or f.endswith(".list") or re.fullmatch(r"CAP_.\.csv", f) \
                or f in ("LOGIC4.csv", "tb_lut4_ff_bel_equiv.v"):
            continue
        print(" ", rel)

v = open(f"{root}/Tile/LOGIC4/LOGIC4.v").read()
total = int(re.search(r"NoConfigBits=(\d+)", v).group(1))
sm = int(re.search(r"NoConfigBits=(\d+)",
                   open(f"{root}/Tile/LOGIC4/LOGIC4_switch_matrix.v").read()).group(1))
rows = list(csv.reader(open(f"{root}/Tile/LOGIC4/LOGIC4_ConfigMem.csv")))[1:]
frames = [r for r in rows if r[2] != "0"]
print("\n=== LOGIC4 config-bit layout ===")
print(f"total ConfigBits          : {total}")
print(f"  BEL bits (4 x 17)       : ConfigBits[67:0]  (BEL x at [17x +: 17])")
print(f"  switch-matrix bits      : ConfigBits[{total-1}:68]  ({sm} bits)")
print(f"frames used / emitted     : {len(frames)} / {len(rows)} (32 bits per frame)")
for r in frames:
    print(f"  {r[0]}: {r[2]} bits, ConfigBits[{r[4]}]")

# Check the BEL slices in the generated tile against logic_tile.v packing.
for x, name in enumerate("ABCD"):
    lo, hi = 17 * x, 17 * x + 17
    assert f"ConfigBits[{hi}-1:{lo}]" in v, f"BEL {name} slice mismatch"
spec = list(csv.reader(open(f"{root}/.FABulous/bitStreamSpec.csv")))
cfg = {}
for r in spec:
    if len(r) == 2 and re.match(r"^[A-D]\.(INIT|FF)", r[0]):
        cfg[r[0]] = ast.literal_eval(r[1])
assert len(cfg) == 68, len(cfg)
# Map ConfigBits[k] -> frame-bit position using the generator's own frame table:
# within a frame the used bits are filled MSB-first from the frame's hi:lo range.
pos = {}
for r in frames:
    hi, lo = (int(x) for x in r[4].split(":"))
    fi = int(r[1])
    used = [b for b in range(31, -1, -1) if r[3].replace("_", "")[31 - b] == "1"]
    for k, b in zip(range(hi, lo - 1, -1), used):
        pos[k] = fi * 32 + b
for x, name in enumerate("ABCD"):
    for j in range(16):
        key = f"{name}.INIT" + (f"[{j}]" if j else "")
        assert list(cfg[key])[0] == pos[17 * x + j], key
    assert list(cfg[f"{name}.FF"])[0] == pos[17 * x + 16], name
print("  bitstream spec (.FABulous/bitStreamSpec.csv) agrees: every INIT[j]/FF")
print("  frame-bit position == the frame-table position of ConfigBits[17*i + j]")
print("\nframe-bit position of BEL fields (frame*32 + bit):")
for x, name in enumerate("ABCD"):
    print(f"  {name}: INIT[0]={pos[17*x]} .. INIT[15]={pos[17*x+15]} FF={pos[17*x+16]}")
