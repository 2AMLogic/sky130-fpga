#!/usr/bin/env python3
"""RTL mutation check (issue #124): prove the sim/ testbenches can fail.

Applies a fixed, enumerated list of single-point mutations to a COPY of the
RTL in the gitignored sim/build/mutation/ dir (committed RTL is never
touched), rebuilds every testbench against each mutant with iverilog, and
requires at least one testbench to report non-PASS (kill). Mutants are run
strictly serially. Equivalent mutants must be listed, with a one-line
justification, in sim/mutation_allowlist.txt.

Invoke via `./sim/run.sh --mutation [--record]`; not part of the default path.
Exit 0 iff every non-allowlisted mutant is killed, every allowlisted mutant
really survives, and every mutation applied cleanly.
"""
import datetime
import pathlib
import subprocess
import sys

SIM = pathlib.Path(__file__).resolve().parent
ROOT = SIM.parent
RTL = ROOT / "design" / "rtl"
BUILD = SIM / "build" / "mutation"
ALLOW = SIM / "mutation_allowlist.txt"
RESULTS = SIM / "rtl_mutation_results.txt"
BS = SIM / "bitstream"

SM = "logic_tile_switch_matrix.v"
RT = "logic_tile_routed.v"
LT = "logic_tile.v"
SL = "lut4_slice.v"

# (id, file, old, new, anchor)   old must occur exactly once at/after anchor
# (anchor "" = whole file, and then old must be unique in the file).
M = [
    # ---- lut4_slice.v
    ("LUT_ADDR_SWAP_01", SL, "lut_init[in]", "lut_init[{in[3],in[2],in[0],in[1]}]", ""),
    ("LUT_ADDR_SWAP_23", SL, "lut_init[in]", "lut_init[{in[2],in[3],in[1],in[0]}]", ""),
    ("LUT_ADDR_SWAP_03", SL, "lut_init[in]", "lut_init[{in[0],in[2],in[1],in[3]}]", ""),
    ("LUT_ADDR_REVERSE", SL, "lut_init[in]", "lut_init[{in[0],in[1],in[2],in[3]}]", ""),
    ("LUT_INIT_INV_BIT0", SL, "lut_init[in];", "(in == 4'd0) ? ~lut_init[in] : lut_init[in];", ""),
    ("LUT_INIT_INV_BIT6", SL, "lut_init[in];", "(in == 4'd6) ? ~lut_init[in] : lut_init[in];", ""),
    ("LUT_INIT_INV_BIT15", SL, "lut_init[in];", "(in == 4'd15) ? ~lut_init[in] : lut_init[in];", ""),
    ("LUT_INIT_STUCK0_BIT9", SL, "lut_init[in];", "(in == 4'd9) ? 1'b0 : lut_init[in];", ""),
    ("FF_RST_POLARITY", SL, "if (rst)", "if (!rst)", ""),
    ("FF_RST_VALUE_1", SL, "ff_q <= 1'b0;", "ff_q <= 1'b1;", ""),
    ("FF_RST_IGNORED", SL, "if (rst)", "if (1'b0)", ""),
    ("FF_RST_ASYNC", SL, "always @(posedge clk) begin", "always @(posedge clk or posedge rst) begin", ""),
    ("FF_RST_GATED_BY_CE", SL, "if (rst)", "if (rst && ce)", ""),
    ("FF_CE_POLARITY", SL, "else if (ce)", "else if (!ce)", ""),
    ("FF_CE_IGNORED", SL, "else if (ce)", "else if (1'b1)", ""),
    ("FF_CLK_NEGEDGE", SL, "always @(posedge clk)", "always @(negedge clk)", ""),
    ("FF_D_INVERTED", SL, "ff_q <= lut_out;", "ff_q <= ~lut_out;", ""),
    ("REGSEL_FORCE_COMB", SL, "assign out = reg_sel ? ff_q : lut_out;", "assign out = lut_out;", ""),
    ("REGSEL_FORCE_REG", SL, "assign out = reg_sel ? ff_q : lut_out;", "assign out = ff_q;", ""),
    ("REGSEL_INVERTED", SL, "assign out = reg_sel ? ff_q : lut_out;", "assign out = reg_sel ? lut_out : ff_q;", ""),
    # ---- logic_tile.v (BEL-only tile wiring)
    ("TILE_CE_SLICE_SWAP", LT, ".ce       (ce[i]),", ".ce       (ce[3-i]),", ""),
    ("TILE_IN_SLICE_ROTATE", LT, ".in       (in[4*i +: 4]),", ".in       (in[4*((i+1)%4) +: 4]),", ""),
    ("TILE_INIT_SLICE_ROTATE", LT, ".lut_init (lut_init[16*i +: 16]),", ".lut_init (lut_init[16*((i+1)%4) +: 16]),", ""),
    ("TILE_REGSEL_SLICE_SWAP", LT, ".reg_sel  (reg_sel[i]),", ".reg_sel  (reg_sel[3-i]),", ""),
    ("TILE_RST_TIED0", LT, ".rst      (rst),", ".rst      (1'b0),", ""),
    ("TILE_OUT_SLICE_SWAP", LT, ".out      (out[i])", ".out      (out[3-i])", ""),
    # ---- logic_tile_routed.v (composition + cfg layout)
    ("RT_LUTINIT_CFG_SHIFT", RT, ".lut_init (cfg[17*i +: 16]),", ".lut_init (cfg[17*i+1 +: 16]),", ""),
    ("RT_REGSEL_CFG_IDX_SWAP", RT, ".reg_sel  (cfg[17*i + 16]),", ".reg_sel  (cfg[17*i + 15]),", ""),
    ("RT_REGSEL_CFG_TIED0", RT, ".reg_sel  (cfg[17*i + 16]),", ".reg_sel  (1'b0),", ""),
    ("RT_LUTINIT_BIT3_TIED0", RT, ".lut_init (cfg[17*i +: 16]),", ".lut_init ({cfg[17*i+15 -: 12], 1'b0, cfg[17*i+2 -: 3]}),", ""),
    ("RT_SM_CFG_OFFSET", RT, ".cfg    (cfg[157:68]),", ".cfg    (cfg[156:67]),", ""),
    ("RT_SM_CFG_BIT68_TIED0", RT, ".cfg    (cfg[157:68]),", ".cfg    ({cfg[157:69], 1'b0}),", ""),
    ("RT_SM_CFG_BIT157_TIED0", RT, ".cfg    (cfg[157:68]),", ".cfg    ({1'b0, cfg[156:68]}),", ""),
    ("RT_SM_CFG_BITS69_70_SWAP", RT, ".cfg    (cfg[157:68]),", ".cfg    ({cfg[157:71], cfg[69], cfg[70], cfg[68]}),", ""),
    ("RT_SR_SLICE_ROTATE", RT, ".rst      (bel_sr[i]),", ".rst      (bel_sr[(i+1)%4]),", ""),
    ("RT_EN_SLICE_ROTATE", RT, ".ce       (bel_en[i]),", ".ce       (bel_en[(i+1)%4]),", ""),
    ("RT_LUTIN_SLICE_ROTATE", RT, ".in       (lut_in[4*i +: 4]),", ".in       (lut_in[4*((i+1)%4) +: 4]),", ""),
    ("RT_BELO_FEEDBACK_SWAP", RT, ".LB_O (bel_o[1]), .LC_O (bel_o[2])", ".LB_O (bel_o[2]), .LC_O (bel_o[1])", ""),
    ("RT_EDGE_N_E_SWAP", RT, ".N1END0 (n_in[0])", ".N1END0 (e_in[0])", ""),
    ("RT_OUT_W0_FROM_N0", RT, ".W1BEG0 (w_out[0])", ".W1BEG0 (n_out[0])", ""),
    # ---- logic_tile_switch_matrix.v (generated; mutated copy only)
    ("SM_SELECT_FIELD_SHIFT", SM, "case (cfg[2:0])", "case (cfg[3:1])", "// N1BEG0:"),
    ("SM_SELECT_BITS_SWAP", SM, "case (cfg[5:3])", "case ({cfg[3], cfg[4], cfg[5]})", "// N1BEG1:"),
    ("SM_SELECT_BIT_TIED0", SM, "case (cfg[8:6])", "case ({cfg[8:7], 1'b0})", "// N1BEG2:"),
    ("SM_SELECT_TOPBIT89_TIED0", SM, "case (cfg[89:88])", "case ({1'b0, cfg[88]})", "// J_EN_BEG3:"),
    ("SM_SOURCE_SWAP_E_S", SM, "3'd0: N1BEG0_r = E1END0;", "3'd0: N1BEG0_r = S1END0;", "// N1BEG0:"),
    ("SM_SOURCE_LD_AS_LC", SM, "3'd6: N1BEG0_r = LD_O;", "3'd6: N1BEG0_r = LC_O;", "// N1BEG0:"),
    ("SM_DEFAULT_DRIVES_1", SM, "default: N1BEG0_r = 1'b0;", "default: N1BEG0_r = 1'b1;", "// N1BEG0:"),
    ("SM_ENABLE_SRC_W_AS_N", SM, "2'd3: J_EN_BEG3_r = W1END3;", "2'd3: J_EN_BEG3_r = N1END3;", "// J_EN_BEG3:"),
    ("SM_LAST_SOURCE_DROPPED", SM, "2'd3: J_EN_BEG3_r = W1END3;", "2'd3: J_EN_BEG3_r = 1'b0;", "// J_EN_BEG3:"),
]


def apply(mid, fname, old, new, anchor):
    text = (RTL / fname).read_text()
    start = text.index(anchor) if anchor else 0
    if anchor and text.count(anchor) != 1:
        raise SystemExit(f"{mid}: anchor {anchor!r} not unique in {fname}")
    head, tail = text[:start], text[start:]
    n = tail.count(old) if anchor else text.count(old)
    if n < 1 or (not anchor and n != 1):
        raise SystemExit(f"{mid}: pattern {old!r} found {n}x in {fname} (stale mutant list)")
    if anchor:
        tail = tail.replace(old, new, 1)
        return head + tail
    return text.replace(old, new, 1)


def run(cmd, timeout=120):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def srcs(d, names):
    return [str(d / n) for n in names]


# testbench name, rtl files, extra vvp arg-sets (list of (label, args, pass-prefix))
def bench_list():
    bs = []
    for dname, stem in (("comb", "top_io"), ("reg", "top_reg")):
        bs.append((dname, [f"+bin={BS/stem}.bin", f"+map={BS/'logic4_configmem.map'}",
                           f"+wiring={BS/(stem + '.wiring')}", f"+design={dname}", "+mutate"],
                   f"PASS: tb_logic_tile_bitstream[{dname}]"))
    return [
        ("tb_lut4_slice", [SL], [("", [], "PASS: tb_lut4_slice")]),
        ("tb_logic_tile", [SL, LT], [("", [], "PASS: tb_logic_tile")]),
        ("tb_switch_matrix", [SM], [("", [], "PASS: tb_switch_matrix")]),
        ("tb_logic_tile_routed", [SL, SM, RT], [("", [], "PASS: tb_logic_tile_routed")]),
        ("tb_logic_tile_gapfill", [SL, LT, SM, RT], [("", [], "PASS: tb_logic_tile_gapfill")]),
        ("tb_logic_tile_bitstream", [SL, SM, RT], bs),
    ]


def killer(mdir):
    """Return (killer-name or None, compile-error-text or None)."""
    for name, files, runs in bench_list():
        out = mdir / f"{name}.out"
        rc, txt = run(["iverilog", "-g2012", "-I", str(SIM), "-o", str(out)]
                      + srcs(mdir, files) + [str(SIM / f"{name}.v")])
        if rc != 0:
            return None, f"{name}: {txt.strip()[:300]}"
        for label, args, prefix in runs:
            rc, txt = run(["vvp", str(out)] + args)
            if rc != 0 or not any(l.startswith(prefix) for l in txt.splitlines()):
                return name + (f"[{label}]" if label else ""), None
    return None, None


def load_allow():
    allow = {}
    for line in ALLOW.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        mid, _, why = line.partition("|")
        if not why.strip():
            raise SystemExit(f"allowlist entry {mid.strip()!r} has no justification")
        allow[mid.strip()] = why.strip()
    return allow


def main():
    record = "--record" in sys.argv
    ids = [m[0] for m in M]
    assert len(ids) == len(set(ids)), "duplicate mutant id"
    allow = load_allow()
    for a in allow:
        if a not in ids:
            raise SystemExit(f"allowlist names unknown mutant {a}")
    BUILD.mkdir(parents=True, exist_ok=True)

    # baseline: the unmutated copy must PASS everything, else kills mean nothing
    base = BUILD / "baseline"
    base.mkdir(exist_ok=True)
    for f in (SL, LT, SM, RT):
        (base / f).write_text((RTL / f).read_text())
    k, err = killer(base)
    if k or err:
        print(f"error: baseline (unmutated copy) does not pass: {k or err}", file=sys.stderr)
        return 2

    rows, bad = [], []
    for mid, fname, old, new, anchor in M:
        mdir = BUILD / mid
        mdir.mkdir(exist_ok=True)
        for f in (SL, LT, SM, RT):
            (mdir / f).write_text((RTL / f).read_text())
        (mdir / fname).write_text(apply(mid, fname, old, new, anchor))
        k, err = killer(mdir)
        if err:
            status = "ERROR"
            bad.append(f"{mid}: mutant did not compile ({err})")
        elif k and mid in allow:
            status = "KILLED-BUT-ALLOWLISTED"
            bad.append(f"{mid}: allowlisted as equivalent but killed by {k}; remove from allowlist")
        elif k:
            status = "KILLED"
        elif mid in allow:
            status = "ALLOWLISTED"
        else:
            status = "SURVIVED"
            bad.append(f"{mid}: SURVIVED (no testbench failed) -- coverage hole")
        rows.append((mid, fname, status, k or "-"))
        print(f"{status:24s} {mid:28s} {fname:32s} {k or '-'}", flush=True)

    total = len(rows)
    killed = sum(r[2] == "KILLED" for r in rows)
    allowed = sum(r[2] == "ALLOWLISTED" for r in rows)
    summary = f"mutants: total={total} killed={killed} allowlisted={allowed} surviving={len(bad)}"
    print(summary)
    for b in bad:
        print("FAIL:", b, file=sys.stderr)
    if record:
        date = datetime.date.today().isoformat()
        with RESULTS.open("a") as fh:
            fh.write(f"\n{date}  RTL mutation check (./sim/run.sh --mutation)\n")
            fh.write(f"  {summary}\n")
            for mid, fname, status, k in rows:
                fh.write(f"  {status:12s} {mid:28s} {fname:32s} {k}\n")
            for mid, why in allow.items():
                fh.write(f"  allowlist: {mid}: {why}\n")
            fh.write("  result: " + ("PASS" if not bad else "FAIL") + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
