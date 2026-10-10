#!/usr/bin/env python3
"""Bounded single-tile routability corpus driver (issue #115).

EXPERIMENTAL evidence for ADR-0004 item 3. Runs the cases of
design/fabulous/corpus/corpus.json through the pinned yosys + nextpnr path
(flow/nextpnr.sh set it up under flow/build/) for every recorded seed, and
classifies each (case, seed) as exactly one of

  success            routed; a real bitstream is assembled, byte-compared with
                     FABulous `bit_gen genBitstream`, and simulated against an
                     independent source-level oracle
  route_fail         nextpnr packed and placed the design but reported it unroutable
  route_nonconvergent  the router had unrouted arcs left when a fixed wall-clock budget
                     expired (nextpnr's router1 has no iteration cap and rips up
                     forever): bounded-effort evidence only, not a proof
  capacity_packing   nextpnr could not pack/place (resource or pad limits)
  synthesis_error    yosys failed                           } setup problems,
  topology_mismatch  synthesized netlist is not the intended } NOT measured
  tool_error         missing tool, crash, unrecognised error } routability

The last three always fail the run: a missing tool or a crash is an
unsuccessful execution, never evidence of unroutability. route_fail and
capacity_packing are measured outcomes and are accepted only when they match
the recorded `expect` entry; ANY deviation (a recorded failure that now routes
or a recorded success that now fails) fails the run with an evidence-review
message. Baseline cases must succeed, so an all-failed corpus cannot pass.

No bitstream or PASS is ever produced for a non-success case.
Usage (via flow/corpus.sh, which prepares PATH and the model):
    corpus_run.py [--update] [--append-record FILE] [--cases a,b]
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "flow" / "build"
SRC = REPO / "design" / "fabulous" / "nextpnr"
CORPUS = REPO / "design" / "fabulous" / "corpus"
FIXDIR = REPO / "sim" / "bitstream" / "corpus"
BSDIR = REPO / "sim" / "bitstream"
TOOL = REPO / "flow" / "fasm_to_bitstream.py"
RTL = REPO / "design" / "rtl"
MEASURED = ("success", "route_fail", "route_nonconvergent", "capacity_packing")
FIX_EXT = (".fasm", ".mapped.json", ".bin", ".wiring", ".cfg")


class Run:  # one (case, seed) result
    def __init__(self, case, seed):
        self.case, self.seed = case, seed
        self.outcome = "tool_error"
        self.detail = ""
        self.diag = []
        self.topo = {}
        self.bels = []        # (bel, kind) occupancy after placement
        self.sha = {}
        self.sim = ""


def sha256(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def sh(cmd, env=None, cwd=None, log=None, timeout=None):
    """Run; returns (rc, combined output). rc None if the binary is missing,
    "timeout" if the wall-clock budget expired (the process is killed)."""
    try:
        p = subprocess.run([str(c) for c in cmd], env=env, cwd=cwd, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except FileNotFoundError as e:
        return None, str(e)
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        out = out.decode(errors="replace") if isinstance(out, bytes) else out
        if log:
            Path(log).write_text(out)
        return "timeout", out
    if log:
        Path(log).write_text(p.stdout)
    return p.returncode, p.stdout


def topology(json_path):
    """Intended-shape metrics of the synthesized (pre-placement) netlist.

    IO cells (harness pad BELs) are transparent: an input net is a net driven
    by a pad cell, and fanout counts LUT-BEL sinks only."""
    m = json.loads(Path(json_path).read_text())["modules"]["top"]
    in_bits, lut_drv, sinks = set(), set(), {}
    luts = ffs = 0
    for c in m["cells"].values():
        is_io = c["type"].startswith("IO_1_")
        if not is_io and c["type"] != "lut4_ff_bel":
            return None, f"unexpected cell type {c['type']}"
        if not is_io:
            if c["parameters"]["FF"].strip("0") == "":
                luts += 1
            else:
                ffs += 1
        for pin, bits in c["connections"].items():
            if pin == "PAD":
                continue
            for b in bits:
                if not isinstance(b, int):
                    continue  # unconnected ("x") or constant pin
                if c["port_directions"][pin] == "output":
                    (in_bits if is_io else lut_drv).add(b)
                elif not is_io:
                    sinks.setdefault(b, []).append(c)
    internal = [b for b in lut_drv if b in sinks]
    return dict(
        luts=luts, ffs=ffs, internal_nets=len(internal),
        max_internal_fanout=max([len(sinks[b]) for b in internal], default=0),
        max_input_fanout=max([len(sinks.get(b, [])) for b in in_bits], default=0)), ""


def synth(case, seed_dir, env, io_prims_dir):
    mode = case["mode"]
    name = case["name"]
    raw = seed_dir / f"{name}.raw.json"
    final = seed_dir / f"{name}.json"
    args = ["yosys", "-q", "-p",
            ("synth_fabulous -top top "
             + ("-ff $_SDFFE_PP0P_ x " if mode == "reg" else "")
             + f"-extra-plib {SRC}/prims.v -extra-plib {SRC}/io_prims.v -extra-map {SRC}/io_map.v "
             + (f"-extra-map {SRC}/ff_map.v " if mode == "reg" else "")
             + f"-cells-map {SRC}/cells_map.v -json {raw}"),
            REPO / case["src"]]
    rc, out = sh(args, env=env)
    if rc != 0:
        return False, f"yosys rc={rc}: {out.strip()[-300:]}"
    d = json.loads(raw.read_text())
    if mode == "reg":  # clk is the implicit UserCLK: strip the unconnected port
        mod = d["modules"]["top"]
        bits = set(mod["ports"]["clk"]["bits"])
        if any(bits & set(b) for c in mod["cells"].values() for b in c["connections"].values()):
            return False, "clk is connected to a cell"
        del mod["ports"]["clk"]
    final.write_text(json.dumps(d))
    return True, ""


ROUTE_RE = re.compile(r"Failed to find a route|Routing design failed|[Rr]outing failed")
PROGRESS_RE = re.compile(r"^Info:\s+(\d+) \|\s+\d+\s+\d+ \|\s+\d+\s+\d+ \|\s+(\d+)\|", re.M)
PACK_RE = re.compile(r"must be PAD|[Uu]nable to place|[Ff]ailed to place|[Cc]annot place|"
                     r"[Nn]o (?:free|available|valid) BEL|[Tt]oo many|exceeds|[Ii]llegal|"
                     r"placement failed|[Pp]acking failed|[Cc]ould not (?:pack|place)")


def norm_diag(text):
    out = []
    for l in text.splitlines():
        if "iteration #" in l or re.match(r"Info: .*([Tt]ime|Checksum)", l):
            continue
        if l.startswith(("ERROR", "FATAL")) or "Failed to find a route" in l:
            l = l.replace(str(REPO), "<repo>").replace(str(BUILD), "<build>")
            out.append(l.strip())
    return out[:6]


def nextpnr(case, seed, seed_dir, env, model, budget):
    name, stem = case["name"], f"{case['name']}_s{seed}"
    cmd = ["nextpnr-generic", "--uarch", "fabulous", "--json", seed_dir / f"{name}.json",
           "-o", f"pcf={REPO / case['pcf']}", "-o", f"fasm={seed_dir / (stem + '.fasm')}",
           "--write", seed_dir / f"{stem}.post.json", "--seed", str(seed)]
    e = dict(env, FAB_ROOT=str(model))
    rc, out = sh(cmd, env=e, log=seed_dir / f"{stem}.nextpnr.log", timeout=budget)
    return rc, out


def classify(rc, out):
    # nextpnr exits 125 after a logged ERROR; a signal death is rc<0 (or 128+n via a shell)
    if rc is None:
        return "tool_error", "nextpnr-generic not found", []
    diag = norm_diag(out)
    if rc == "timeout":
        prog = PROGRESS_RE.findall(out)
        if "Routing.." in out and prog and int(prog[-1][1]) > 0:
            # nextpnr's default router has no iteration cap: an unroutable arc set is
            # ripped up and re-routed forever. Not a proof of infeasibility.
            return ("route_nonconvergent", f"router did not converge within the wall-clock budget; "
                    f"{prog[-1][1]} arcs still unrouted at the last progress report", diag)
        return "tool_error", "nextpnr exceeded the wall-clock budget outside the router", diag
    if rc == 0 and "Routing complete" not in out and "Program finished normally" not in out:
        return "tool_error", "rc=0 but no completion marker", diag
    if rc == 0:
        return "success", "", diag
    if rc < 0 or rc in (134, 136, 138, 139) or "terminate called" in out or "Traceback" in out or "Segmentation" in out:
        return "tool_error", f"nextpnr crashed (rc={rc})", diag
    if ROUTE_RE.search(out):
        return "route_fail", "", diag
    if PACK_RE.search(out):
        return "capacity_packing", "", diag
    return "tool_error", f"unrecognised nextpnr failure rc={rc}", diag


def occupancy(post_json):
    m = json.loads(Path(post_json).read_text())["modules"]["top"]
    return sorted((c["attributes"]["NEXTPNR_BEL"], "FF" if c["parameters"]["FF"].strip("0") else "LUT")
                  for c in m["cells"].values() if c["type"] == "lut4_ff_bel")


def assemble(case, stem, seed_dir, snap, fab_run):
    py = BUILD / "fab-venv" / "bin" / "python"
    post = seed_dir / f"{stem}.post.json"
    ok = []
    for cmd in (
        [sys.executable, TOOL, "summary", post, "--out", seed_dir / f"{stem}.mapped.json"],
        [sys.executable, TOOL, "assemble", "--fasm", seed_dir / f"{stem}.fasm", "--snapshot", snap,
         "--mapped", seed_dir / f"{stem}.mapped.json", "--out", seed_dir / stem,
         "--filtered-fasm", seed_dir / f"{stem}.logic.fasm"],
        [BUILD / "fab-venv" / "bin" / "bit_gen", "genBitstream", seed_dir / f"{stem}.logic.fasm",
         fab_run / ".FABulous" / "bitStreamSpec.bin", seed_dir / f"{stem}.fabulous.bin"],
    ):
        rc, out = sh(cmd, cwd=seed_dir)
        if rc != 0:
            return False, f"{Path(str(cmd[1])).name}: rc={rc} {out.strip()[-200:]}"
    if (seed_dir / f"{stem}.bin").read_bytes() != (seed_dir / f"{stem}.fabulous.bin").read_bytes():
        return False, "assembler stream differs from FABulous bit_gen output"
    return True, ""


def compile_tb():
    """Simulation uses the host Icarus (iverilog + vvp from the same install, as sim/run.sh)."""
    env = None
    out = BUILD / "corpus-run" / "tb.out"
    rc, o = sh(["iverilog", "-g2012", "-Wall", "-I", REPO / "sim", "-o", out,
                RTL / "lut4_slice.v", RTL / "logic_tile_switch_matrix.v", RTL / "logic_tile_routed.v",
                REPO / "sim" / "tb_logic_tile_bitstream.v"], env=env)
    return (out if rc == 0 else None), o


def simulate(tb, binf, wiring, cfgf, oracle, snap_dir):
    """Run the unmodified-loader testbench with perturbation checks + cfg cross-check."""
    rc, out = sh(["vvp", tb, f"+bin={binf}", f"+map={snap_dir / 'logic4_configmem.map'}",
                  f"+wiring={wiring}", f"+design={oracle}", "+mutate"])
    if rc is None:
        return False, "vvp not found"
    m = re.search(r"^PASS: tb_logic_tile_bitstream\[\w+\] \((.*)\)$", out, re.M)
    cfg = re.search(r"^CFG=([0-9a-f]+)", out, re.M)
    if rc != 0 or not m or not cfg:
        return False, "simulation did not PASS: " + out.strip().splitlines()[-1][:200]
    rc2, py_cfg = sh([sys.executable, TOOL, "decode", binf, "--snapshot", snap_dir / "fabric_spec.json"])
    if cfg.group(1) != py_cfg.strip() or cfg.group(1) != Path(cfgf).read_text().strip():
        return False, "cfg cross-check mismatch (sim loader / python decoder / recorded)"
    return True, m.group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true", help="rewrite sim/bitstream/corpus fixtures")
    ap.add_argument("--append-record", metavar="FILE", help="append a dated result record to FILE")
    ap.add_argument("--cases", help="comma-separated subset (baseline still required)")
    a = ap.parse_args()

    oss = BUILD / "oss-cad-suite"
    env = dict(os.environ, PATH=f"{oss / 'bin'}:{os.environ['PATH']}")
    model = BUILD / "nextpnr-run" / "io-model"
    fab_run = BUILD / "fabulous-run"
    snap_dir = BSDIR
    cfgd = json.loads((CORPUS / "corpus.json").read_text())
    work = BUILD / "corpus-run"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    # the fabric model this run maps against must be the one the committed spec snapshot describes
    regen_snap = BUILD / "bitstream-run" / "fabric_spec.json"
    if not regen_snap.exists() or sha256(regen_snap) != sha256(snap_dir / "fabric_spec.json"):
        sys.exit("error: flow/build/bitstream-run/fabric_spec.json missing or differs from sim/bitstream/ "
                 "(run flow/corpus.sh, which runs flow/bitstream.sh first)")

    versions = {}
    for t, cmd in (("yosys", ["yosys", "-V"]), ("nextpnr", ["nextpnr-generic", "--version"])):
        rc, o = sh(cmd, env=env)
        versions[t] = (re.search(r"nextpnr-[0-9][^)\" ]*", o) or re.search(r"Yosys (\S+)", o) or [None])[0] \
            if rc is not None else "MISSING"
    tb, tbout = compile_tb()
    if tb is None:
        sys.exit("error: testbench compile failed (Icarus Verilog missing?):\n" + tbout)

    runs, problems = [], []
    want = set(a.cases.split(",")) if a.cases else None
    for case in cfgd["cases"]:
        if want and case["name"] not in want and not case.get("baseline"):
            continue
        for seed in case.get("seeds", cfgd["seeds"]):
            r = Run(case["name"], seed)
            runs.append(r)
            sd = work / f"{case['name']}_s{seed}"
            sd.mkdir()
            stem = f"{case['name']}_s{seed}"
            r.sha["source"] = sha256(REPO / case["src"])
            r.sha["pcf"] = sha256(REPO / case["pcf"])
            ok, why = synth(case, sd, env, SRC)
            if not ok:
                r.outcome, r.detail = "synthesis_error", why
                continue
            topo, why = topology(sd / f"{case['name']}.json")
            r.topo = topo or {}
            if topo is None or any(topo[k] != v for k, v in case["topology"].items()):
                r.outcome = "topology_mismatch"
                r.detail = why or f"observed {topo} != intended {case['topology']}"
                continue
            rc, out = nextpnr(case, seed, sd, env, model, cfgd.get("route_budget_s", 60))
            r.outcome, r.detail, r.diag = classify(rc, out)
            if r.outcome != "success":
                continue
            r.bels = occupancy(sd / f"{stem}.post.json")
            want_pl = case.get("placement")
            if want_pl is not None and dict(r.bels) != want_pl:
                # a case that pins BEL placement must land exactly there (issue #156)
                r.outcome = "tool_error"
                r.detail = f"placement {dict(r.bels)} != required {want_pl}"
                continue
            ok, why = assemble(case, stem, sd, snap_dir / "fabric_spec.json", fab_run)
            if not ok:
                r.outcome, r.detail = "tool_error", "assembly: " + why
                continue
            r.sha["fasm"] = sha256(sd / f"{stem}.fasm")
            r.sha["bin"] = sha256(sd / f"{stem}.bin")
            ok, info = simulate(tb, sd / f"{stem}.bin", sd / f"{stem}.wiring", sd / f"{stem}.cfg",
                                case["oracle"], snap_dir)
            if not ok:
                r.outcome, r.detail = "sim_fail", info
                continue
            r.sim = info
            # committed fixtures: baseline cases must reproduce sim/bitstream/<stem>.*,
            # corpus cases sim/bitstream/corpus/<case>.s<seed>.*
            if "fixture" in case:
                fx = REPO / case["fixture"]
                pairs = [(sd / f"{stem}{e}", Path(str(fx) + e)) for e in FIX_EXT]
            else:
                pairs = [(sd / f"{stem}{e}", FIXDIR / f"{stem}{e}") for e in FIX_EXT]
            if a.update and "fixture" not in case:
                FIXDIR.mkdir(parents=True, exist_ok=True)
                for src, dst in pairs:
                    shutil.copyfile(src, dst)
            else:
                for src, dst in pairs:
                    if not dst.exists() or src.read_bytes() != dst.read_bytes():
                        problems.append(f"{case['name']} seed {seed}: DRIFT {dst.relative_to(REPO)}")

    # ------------------------------------------------------------ verdicts
    print(f"{'case':10} {'seed':>4}  {'outcome':17} {'expected':17} BELs / detail")
    for r in runs:
        case = next(c for c in cfgd["cases"] if c["name"] == r.case)
        exp = case["expect"].get(str(r.seed))
        r.exp = exp
        bel = ",".join(f"{b.split('/')[1]}:{k}" for b, k in r.bels)
        print(f"{r.case:10} {r.seed:>4}  {r.outcome:17} {str(exp):17} {bel or r.detail}")
        for d in r.diag:
            print(f"{'':34}{d}")
        if r.outcome not in MEASURED:
            problems.append(f"{r.case} seed {r.seed}: {r.outcome} ({r.detail}) -- setup/tool problem, "
                            "not routability evidence")
        elif r.outcome != exp:
            problems.append(f"{r.case} seed {r.seed}: observed {r.outcome}, recorded expectation {exp}: "
                            "EVIDENCE REVIEW required (update corpus.json expect, the decision table and "
                            "append a new result record; do not edit old records)")
    for c in cfgd["cases"]:
        if c.get("baseline") and not any(r.case == c["name"] and r.outcome == "success" for r in runs):
            problems.append(f"baseline case {c['name']} did not succeed: corpus is not useful verification")
    if a.update:
        idx = FIXDIR / "index.txt"
        lines = [f"{r.case}_s{r.seed} {next(c for c in cfgd['cases'] if c['name'] == r.case)['oracle']}"
                 for r in runs if r.outcome == "success" and "fixture" not in
                 next(c for c in cfgd["cases"] if c["name"] == r.case)]
        idx.write_text("\n".join(lines) + "\n")

    if a.append_record:
        with open(a.append_record, "a") as f:
            f.write(record(runs, versions, problems))
    if problems:
        print("\nCORPUS FAILED:")
        for p in problems:
            print("  " + p)
        return 1
    n_ok = sum(r.outcome == "success" for r in runs)
    print(f"\nPASS: corpus ({len(runs)} runs: {n_ok} success verified end-to-end, "
          f"{len(runs) - n_ok} recorded measured failures matching expectation)")
    return 0


def record(runs, versions, problems):
    import datetime
    sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, text=True,
                         stdout=subprocess.PIPE).stdout.strip()
    L = [f"\n{datetime.date.today().isoformat()}  flow/corpus.sh @ {sha}  "
         f"({'FAILED' if problems else 'all outcomes match recorded expectations'})",
         f"  Tools   : yosys {versions['yosys']}, {versions['nextpnr']} (pins: flow/tool_versions.sh)"]
    for r in runs:
        L.append(f"  {r.case:9} seed {r.seed}: {r.outcome}"
                 + (f" [{r.detail}]" if r.detail else ""))
        L.append(f"      source sha256 {r.sha.get('source', '-')[:16]}  pcf {r.sha.get('pcf', '-')[:16]}"
                 + (f"  fasm {r.sha['fasm'][:16]}  bin {r.sha['bin'][:16]}" if "bin" in r.sha else ""))
        if r.topo:
            L.append("      topology " + " ".join(f"{k}={v}" for k, v in r.topo.items()))
        if r.bels:
            L.append("      BELs " + ", ".join(f"{b}={k}" for b, k in r.bels))
        for d in r.diag:
            L.append("      diag: " + d)
        if r.sim:
            L.append("      sim: " + r.sim)
    for p in problems:
        L.append("  PROBLEM: " + p)
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    sys.exit(main())
