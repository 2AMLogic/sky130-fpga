#!/usr/bin/env python3
"""Opt-in LUT pin-index experiment for the single-tile fanout failure (issue #137).

EXPERIMENTAL evidence for ADR-0004 item 3. Tests one hypothesis recorded in
design/fabulous/corpus/README.md: that `fan4` does not route because the
synthesized netlist puts the same signal on different LUT input pin indices
while the harness switch matrix is same-index (pin Ik sees tracks of index k).

Controlled comparison, per seed, of

  baseline  the unchanged synthesized `fan4` netlist
  variant   the same netlist after a deterministic input-pin alignment: LUT
            input connections are permuted per cell and the INIT of that cell
            is permuted by exactly the same permutation. Two policies:
            `consistent` (a net keeps one pin index in every LUT) and the
            stricter `distinct` (every input net on its own pin index)

with BEL count, logical truth tables, pad assignment (pcf), fabric model,
router, seeds and wall-clock budget held fixed. Each variant is verified for
truth-table equivalence EXHAUSTIVELY (per cell and for the whole netlist)
before it is routed. Routing outcomes reuse flow/corpus_run.py's
classification; a timeout is bounded non-convergence, never infeasibility.
Every success is assembled, byte-compared against FABulous `bit_gen
genBitstream` and simulated against the independent source-level oracle.

Nothing here changes design/fabulous/corpus/corpus.json, the corpus
expectations or any committed fixture. Results are appended (never edited)
to design/fabulous/corpus/pin_experiment_results.txt on request.

The pure transform/equivalence functions need only the stdlib (unit-tested by
flow/test_pin_experiment.py). The runner needs the flow/corpus.sh toolchain.
Usage (via flow/pin_experiment.sh):
    pin_experiment.py [--append-record FILE] [--case fan4] [--export-fixtures [DIR]]

`--export-fixtures` (issue #145, opt-in, off by default) additionally preserves the
successful `variant-distinct` trials as a separate committed experimental fixture set
(default sim/bitstream/pin_experiment/, see flow/pin_fixtures.py) replayed by
sim/run.sh and flow/gate-sim-bitstream.sh. Export is all-or-nothing and guarded: it
refuses unless the distinct variant is proven equivalent, no experiment problem
occurred, and EVERY seed's distinct trial succeeded (nextpnr route, assembly, byte
identity with FABulous bit_gen, independent oracle with all perturbations detected).
Baseline and consistent trials are never exported.
"""
import argparse
import hashlib
import importlib.util
import itertools
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MAX_PI = 16
NPINS = 4


def _load_corpus_run():
    spec = importlib.util.spec_from_file_location("corpus_run", HERE / "corpus_run.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ------------------------------------------------------------------ netlist helpers
def lut_cells(mod):
    """(name, cell) of the LUT BELs; the experiment is combinational-only."""
    out = []
    for name, c in sorted(mod["cells"].items()):
        if c["type"] == "lut4_ff_bel":
            if c["parameters"]["FF"].strip("0") != "":
                raise ValueError(f"cell {name}: registered LUT not supported by this experiment")
            out.append((name, c))
    return out


def init_bits(c):
    """INIT[i] for i in 0..15, i = {I3,I2,I1,I0}; yosys JSON stores it MSB first."""
    s = c["parameters"]["INIT"]
    if len(s) != 16 or set(s) - {"0", "1"}:
        raise ValueError(f"unexpected INIT {s!r}")
    return [int(ch) for ch in reversed(s)]


def init_str(bits):
    return "".join(str(b) for b in reversed(bits))


def live_nets(mod):
    """Nets that actually carry a signal: driven by an IO cell (primary input) or a LUT output.
    The mapper leaves dangling, undriven nets on the padded upper inputs of narrow LUTs
    (ADR-0005 replicated INIT); they are don't-care pins, exactly like unconnected ones."""
    pi, _ = io_nets(mod)
    live = set(pi)
    for _, c in lut_cells(mod):
        b = c["connections"]["O"][0]
        if isinstance(b, int):
            live.add(b)
    return live


def pin_nets(c, live=None):
    """Per pin index: the net id (int) or None for an unconnected/constant pin
    (and, when `live` is given, for an undriven dangling net)."""
    res = []
    for k in range(NPINS):
        b = c["connections"][f"I{k}"]
        if len(b) != 1:
            raise ValueError(f"pin I{k} width {len(b)}")
        res.append(b[0] if isinstance(b[0], int) and (live is None or b[0] in live) else None)
    return res


def permute_init(init, new_of_old):
    """INIT' such that the cell with pin old k moved to pin new_of_old[k] computes the same function."""
    out = [0] * 16
    for idx in range(16):                      # idx is over the NEW pin values
        old = 0
        for k in range(NPINS):
            old |= ((idx >> new_of_old[k]) & 1) << k
        out[idx] = init[old]
    return out


def net_names(mod):
    names = {}
    for n, v in mod.get("netnames", {}).items():
        for b in v["bits"]:
            if isinstance(b, int):
                names.setdefault(b, n)
    return names


# ------------------------------------------------------------------ alignment policy
def alignment_plan(mod, policy="consistent"):
    """Deterministic pin-alignment policy derived from observed net connectivity.

    Every net that feeds a LUT input gets one global pin index (a colour);
    two nets that feed the same LUT must get different indices. Nets are
    coloured greedily in order of decreasing LUT-input fanout, ties by net id,
    with the lowest free index. A net that needs an index >= 4, and any cell
    that uses one net on two pins or contains such a net, is NOT aligned: the
    cell is left unchanged and the conflict is logged.

    policy "distinct" is the stricter variant: a net first takes the lowest index
    not yet used by ANY net (every input net on its own pin index, the shape the
    `quad4` corpus case has), falling back to the "consistent" rule when none is
    left.

    Returns (plan, log): plan[cell] = new_of_old (list), log = list of strings."""
    cells = lut_cells(mod)
    live = live_nets(mod)
    names = net_names(mod)
    nm = lambda b: names.get(b, f"net{b}")
    fan, nbr = {}, {}
    for _, c in cells:
        ns = [n for n in pin_nets(c, live) if n is not None]
        for n in ns:
            fan[n] = fan.get(n, 0) + 1
            nbr.setdefault(n, set()).update(m for m in ns if m != n)
    colour, log = {}, []
    for n in sorted(fan, key=lambda b: (-fan[b], b)):
        used = {colour[m] for m in nbr[n] if m in colour}
        free = [k for k in range(NPINS) if k not in used]
        if policy == "distinct":
            fresh = [k for k in free if k not in colour.values()]
            free = fresh or free
        if free:
            colour[n] = free[0]
        else:
            log.append(f"CONFLICT net {nm(n)}: no free pin index among {NPINS}; cells using it left unchanged")
    plan = {}
    for name, c in cells:
        pins = pin_nets(c, live)
        ns = [n for n in pins if n is not None]
        ident = list(range(NPINS))
        if len(set(ns)) != len(ns):
            log.append(f"CONFLICT cell {name}: one net on several pins; left unchanged")
            plan[name] = ident
            continue
        if any(n not in colour for n in ns):
            plan[name] = ident
            log.append(f"CONFLICT cell {name}: contains an uncoloured net; left unchanged")
            continue
        new_of_old, taken = [None] * NPINS, set()
        for k, n in enumerate(pins):
            if n is not None:
                new_of_old[k] = colour[n]
                taken.add(colour[n])
        spare = iter(p for p in range(NPINS) if p not in taken)
        for k in range(NPINS):
            if new_of_old[k] is None:
                new_of_old[k] = next(spare)
        plan[name] = new_of_old
        desc = ", ".join(f"{nm(n)}:I{k}->I{new_of_old[k]}" for k, n in enumerate(pins) if n is not None)
        unc = [f"I{k}->I{new_of_old[k]}" for k, n in enumerate(pins) if n is None]
        log.append(f"cell {name}: " + ("identity (already aligned); " if new_of_old == ident else "")
                   + desc + (f"; unconnected {', '.join(unc)}" if unc else "")
                   + f"; INIT {c['parameters']['INIT']} -> "
                   + init_str(permute_init(init_bits(c), new_of_old)))
    for n in sorted(colour):
        log.append(f"net {nm(n)} (id {n}, LUT fanout {fan[n]}) -> pin index I{colour[n]}")
    return plan, log


def apply_plan(mod, plan, permute_init_too=True):
    """Return a deep copy of `mod` with each planned permutation applied.
    permute_init_too=False deliberately breaks the INIT (negative control)."""
    new = json.loads(json.dumps(mod))
    for name, c in lut_cells(new):
        p = plan[name]
        old_conn = {f"I{k}": list(c["connections"][f"I{k}"]) for k in range(NPINS)}
        old_dir = {f"I{k}": c["port_directions"][f"I{k}"] for k in range(NPINS)}
        for k in range(NPINS):
            c["connections"][f"I{p[k]}"] = old_conn[f"I{k}"]
            c["port_directions"][f"I{p[k]}"] = old_dir[f"I{k}"]
        if permute_init_too:
            c["parameters"]["INIT"] = init_str(permute_init(init_bits(c), p))
    return new


# ------------------------------------------------------------------ equivalence
def cell_function(c, live=None):
    """{net-assignment tuple -> output} over the cell's connected nets (sorted by id).
    Unconnected pins are enumerated over both values; the output must not depend on
    them (the ADR-0005 replicated-INIT contract), otherwise ValueError."""
    init = init_bits(c)
    pins = pin_nets(c, live)
    nets = sorted({n for n in pins if n is not None})
    if len(nets) != len([n for n in pins if n is not None]):
        raise ValueError("one net on several pins")
    fn = {}
    for vals in itertools.product((0, 1), repeat=len(nets)):
        val = dict(zip(nets, vals))
        outs = set()
        for dc in itertools.product((0, 1), repeat=NPINS):
            idx = sum(((val[n] if n is not None else dc[k]) & 1) << k for k, n in enumerate(pins))
            outs.add(init[idx])
        if len(outs) != 1:
            raise ValueError("output depends on an unconnected pin")
        fn[vals] = outs.pop()
    return tuple(nets), fn


def io_nets(mod):
    """(primary-input bits, primary-output bits) via the harness IO cells (as corpus_run.topology)."""
    pi, po = set(), set()
    for c in mod["cells"].values():
        if not c["type"].startswith("IO_1_"):
            continue
        for pin, bits in c["connections"].items():
            if pin == "PAD":
                continue
            for b in bits:
                if isinstance(b, int):
                    (pi if c["port_directions"][pin] == "output" else po).add(b)
    return sorted(pi), sorted(po)


def netlist_function(mod):
    """{primary-output bit -> truth-table tuple over all assignments of the sorted primary inputs}."""
    pi, po = io_nets(mod)
    if len(pi) > MAX_PI:
        raise ValueError(f"{len(pi)} primary inputs exceed the exhaustive-check cap {MAX_PI}")
    live = live_nets(mod)
    cells = [(c, init_bits(c), pin_nets(c, live)) for _, c in lut_cells(mod)]
    outs = [c["connections"]["O"][0] for c, _, _ in cells]
    tables = {b: [] for b in po}
    for vals in itertools.product((0, 1), repeat=len(pi)):
        v = dict(zip(pi, vals))
        pending = list(zip(cells, outs))
        while pending:
            rest = []
            for (c, init, pins), o in pending:
                if all(n is None or n in v for n in pins):
                    v[o] = init[sum((v[n] if n is not None else 0) << k for k, n in enumerate(pins))]
                else:
                    rest.append(((c, init, pins), o))
            if len(rest) == len(pending):
                raise ValueError("combinational loop or undriven LUT input")
            pending = rest
        for b in po:
            tables[b].append(v[b])
    return {b: tuple(t) for b, t in tables.items()}


def check_equivalence(base, var):
    """(ok, verdict string). Exhaustive per-cell and whole-netlist truth-table comparison."""
    try:
        lb, lv = live_nets(base), live_nets(var)
        bc = {n: cell_function(c, lb) for n, c in lut_cells(base)}
        vc = {n: cell_function(c, lv) for n, c in lut_cells(var)}
        if set(bc) != set(vc):
            return False, "LUT cell sets differ"
        for n in bc:
            if bc[n] != vc[n]:
                return False, f"cell {n}: truth table differs from baseline"
        bn, vn = netlist_function(base), netlist_function(var)
    except ValueError as e:
        return False, f"equivalence check could not complete: {e}"
    if bn != vn:
        bad = [b for b in bn if bn[b] != vn.get(b)]
        return False, f"netlist output(s) {bad} differ from baseline"
    pi, po = io_nets(base)
    return True, (f"EQUIVALENT: {len(bc)} cells compared over all connected-net assignments "
                  f"(unconnected/undriven pins proven don't-care); {len(po)} outputs over all 2^{len(pi)} "
                  f"input vectors")


def sha_json(mod):
    return hashlib.sha256(json.dumps(mod).encode()).hexdigest()


# ------------------------------------------------------------------ runner
def run_side(cr, side, case, seed, sd, env, model, budget, tb, snap_dir, fab_run):
    """One (side, seed) trial -> dict. Mirrors corpus_run.main's per-seed pipeline."""
    r = dict(side=side, seed=seed, outcome="tool_error", detail="", diag=[], sha={}, bels=[], sim="",
             stem=f"{case['name']}_s{seed}", dir=sd)
    rc, out = cr.nextpnr(case, seed, sd, env, model, budget)
    r["outcome"], r["detail"], r["diag"] = cr.classify(rc, out)
    if r["outcome"] != "success":
        return r
    stem = f"{case['name']}_s{seed}"
    r["bels"] = cr.occupancy(sd / f"{stem}.post.json")
    ok, why = cr.assemble(case, stem, sd, snap_dir / "fabric_spec.json", fab_run)
    if not ok:
        r["outcome"], r["detail"] = "tool_error", "assembly: " + why
        return r
    r["sha"]["fasm"] = cr.sha256(sd / f"{stem}.fasm")
    r["sha"]["bin"] = cr.sha256(sd / f"{stem}.bin")
    ok, info = cr.simulate(tb, sd / f"{stem}.bin", sd / f"{stem}.wiring", sd / f"{stem}.cfg",
                           case["oracle"], snap_dir)
    if not ok:
        r["outcome"], r["detail"] = "sim_fail", info
        return r
    r["sim"] = info
    return r


def export_fixtures(cr, case, seeds, rows, variants, problems, base_sha, versions, dest):
    """Guarded, all-or-nothing export of the variant-distinct successes. Returns (ok, message)."""
    import re
    pf = _load_pin_fixtures()
    if case["name"] != "fan4":
        return False, "fixture export is only defined for the fan4 case"
    if problems:
        return False, "experiment problems present; nothing exported"
    if "distinct" not in variants or not variants["distinct"].get("equivalent"):
        return False, "distinct variant not proven equivalent to the baseline; nothing exported"
    chosen = []
    for seed in seeds:
        row = [r for r in rows if r["side"] == "variant-distinct" and r["seed"] == seed]
        if len(row) != 1 or row[0]["outcome"] != "success":
            return False, f"variant-distinct seed {seed} is not a success; nothing exported"
        r = row[0]
        m = re.match(r"^(\d+) checks, (\d+) failures; (\d+)/(\d+) perturbations detected$", r["sim"])
        if not m or m.group(2) != "0" or int(m.group(1)) <= 0 or m.group(3) != m.group(4) or m.group(3) == "0":
            return False, f"seed {seed}: oracle verdict not clean ({r['sim']!r}); nothing exported"
        chosen.append(r)
    if len(chosen) != pf.EXPECTED_CASES:
        return False, f"{len(chosen)} distinct successes, replay requires exactly {pf.EXPECTED_CASES}"
    dest = Path(dest)
    stage = dest.with_name(dest.name + ".staging")
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir(parents=True)
    cases = []
    for r in chosen:
        stem = pf.stem_for(case["name"], "distinct", r["seed"])
        for ext in pf.EXTS:
            src = r["dir"] / f"{r['stem']}{ext}"
            if not src.is_file() or src.stat().st_size == 0:
                shutil.rmtree(stage)
                return False, f"seed {r['seed']}: expected file {src.name} missing; nothing exported"
            shutil.copyfile(src, stage / f"{stem}{ext}")
        cases.append(dict(stem=stem, case=case["name"], policy="distinct", seed=r["seed"],
                          oracle=case["oracle"]))
    var_json = json.loads((chosen[0]["dir"] / f"{case['name']}.json").read_text())
    (stage / pf.NETLIST).write_text(json.dumps(var_json, indent=1, sort_keys=True) + "\n")
    idx = pf.build_index(cases, cr.BSDIR, {"yosys": versions["yosys"], "nextpnr": versions["nextpnr"]},
                         pf.sha256_file(stage / pf.NETLIST), base_sha, variants["distinct"]["sha"], stage)
    (stage / pf.INDEX).write_text(json.dumps(idx, indent=1, sort_keys=True) + "\n")
    try:
        pf.verify(stage, cr.BSDIR)               # the replay gate must accept what we export
    except pf.FixtureError as e:
        shutil.rmtree(stage)
        return False, f"exported set failed its own replay verification: {e}"
    shutil.rmtree(dest, ignore_errors=True)
    stage.rename(dest)
    return True, f"exported {len(cases)} distinct-pin fan4 fixtures to {dest}"


def _load_pin_fixtures():
    spec = importlib.util.spec_from_file_location("pin_fixtures", HERE / "pin_fixtures.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def record(case, versions, base_sha, variants, rows, problems, expect):
    """variants: {name: dict(sha, log, verdict)}"""
    import datetime
    import subprocess
    sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, text=True,
                         stdout=subprocess.PIPE).stdout.strip()
    h = lambda p: hashlib.sha256((REPO / p).read_bytes()).hexdigest()[:16]
    L = [f"\n{datetime.date.today().isoformat()}  flow/pin_experiment.sh @ {sha}  case {case['name']}  "
         f"({'PROBLEMS' if problems else 'completed'})",
         f"  Tools   : yosys {versions['yosys']}, {versions['nextpnr']} (pins: flow/tool_versions.sh)",
         f"  Fixed   : source sha256 {h(case['src'])}, pcf sha256 {h(case['pcf'])}, router nextpnr default,"
         f" seeds/budget as corpus.json",
         f"  Baseline netlist sha256 {base_sha[:16]}"]
    for name, v in variants.items():
        L.append(f"  Variant {name}: netlist sha256 {v['sha'][:16]}")
        L.append(f"    Equivalence: {v['verdict']}")
        L.append("    Transformation log:")
        L += ["      " + l for l in v["log"]]
    for r in rows:
        L.append(f"  {r['side']:19} seed {r['seed']}: {r['outcome']}" + (f" [{r['detail']}]" if r["detail"] else "")
                 + (f"   (corpus.json recorded expectation: {expect.get(str(r['seed']))})" if r["side"] == "baseline" else ""))
        if r["bels"]:
            L.append("      BELs " + ", ".join(f"{b}={k}" for b, k in r["bels"]))
        if r["sha"]:
            L.append(f"      fasm {r['sha']['fasm'][:16]}  bin {r['sha']['bin'][:16]}")
        for d in r["diag"]:
            L.append("      diag: " + d)
        if r["sim"]:
            L.append("      functional oracle: " + r["sim"])
    for p in problems:
        L.append("  PROBLEM: " + p)
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--append-record", metavar="FILE")
    ap.add_argument("--case", default="fan4")
    ap.add_argument("--export-fixtures", nargs="?", const="", default=None, metavar="DIR",
                    help="opt-in: export the verified variant-distinct successes as the experimental "
                         "fixture set (default sim/bitstream/pin_experiment/)")
    a = ap.parse_args()
    cr = _load_corpus_run()
    BUILD = cr.BUILD
    oss = BUILD / "oss-cad-suite"
    env = dict(os.environ, PATH=f"{oss / 'bin'}:{os.environ['PATH']}")
    model, fab_run, snap_dir = BUILD / "nextpnr-run" / "io-model", BUILD / "fabulous-run", cr.BSDIR
    cfgd = json.loads((cr.CORPUS / "corpus.json").read_text())
    case = next(c for c in cfgd["cases"] if c["name"] == a.case)
    if case["mode"] != "comb":
        sys.exit("error: only combinational cases are supported")
    work = BUILD / "pin-experiment"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    regen = BUILD / "bitstream-run" / "fabric_spec.json"
    if not regen.exists() or cr.sha256(regen) != cr.sha256(snap_dir / "fabric_spec.json"):
        sys.exit("error: flow/build/bitstream-run/fabric_spec.json missing or differs from sim/bitstream/ "
                 "(run flow/pin_experiment.sh, which runs flow/bitstream.sh first)")
    versions = {}
    import re
    for t, cmd in (("yosys", ["yosys", "-V"]), ("nextpnr", ["nextpnr-generic", "--version"])):
        rc, o = cr.sh(cmd, env=env)
        versions[t] = (re.search(r"nextpnr-[0-9][^)\" ]*", o) or re.search(r"Yosys (\S+)", o) or [None])[0] \
            if rc is not None else "MISSING"
    (BUILD / "corpus-run").mkdir(parents=True, exist_ok=True)  # compile_tb's output dir
    tb, tbout = cr.compile_tb()
    if tb is None:
        sys.exit("error: testbench compile failed:\n" + tbout)

    problems = []
    base_dir = work / "baseline"
    base_dir.mkdir()
    ok, why = cr.synth(case, base_dir, env, cr.SRC)
    if not ok:
        sys.exit(f"error: synthesis failed (setup problem, not evidence): {why}")
    topo, why = cr.topology(base_dir / f"{case['name']}.json")
    if topo is None or any(topo[k] != v for k, v in case["topology"].items()):
        sys.exit(f"error: synthesized topology {topo} != intended {case['topology']}")
    base = json.loads((base_dir / f"{case['name']}.json").read_text())
    base_mod = base["modules"]["top"]
    base_sha = sha_json(base)
    sides = [("baseline", base_dir)]
    variants = {}
    all_eq = True
    for policy in ("consistent", "distinct"):
        plan, log = alignment_plan(base_mod, policy)
        var = json.loads(json.dumps(base))
        var["modules"]["top"] = apply_plan(base_mod, plan)
        ok_eq, verdict = check_equivalence(base_mod, var["modules"]["top"])
        # negative control: the same plan WITHOUT the matching INIT permutation must be rejected
        bad = apply_plan(base_mod, plan, permute_init_too=False)
        ctrl_ok, ctrl = check_equivalence(base_mod, bad)
        changed = any(p != list(range(NPINS)) for p in plan.values())
        if changed and ctrl_ok:
            problems.append(f"{policy}: negative control (wrong INIT permutation) was NOT rejected")
        log.append("negative control (permuted connections, INIT unchanged): "
                   + ("ACCEPTED (check is broken)" if changed and ctrl_ok else
                      "not applicable (plan is the identity)" if not changed else "rejected: " + ctrl))
        var_dir = work / f"variant-{policy}"
        var_dir.mkdir()
        (var_dir / f"{case['name']}.json").write_text(json.dumps(var))
        vtopo, why = cr.topology(var_dir / f"{case['name']}.json")
        if vtopo != topo:
            problems.append(f"{policy}: variant topology {vtopo} differs from baseline {topo}")
        if not ok_eq:
            problems.append(f"{policy}: variant NOT equivalent to baseline; not routed: {verdict}")
        all_eq &= ok_eq
        variants[policy] = dict(sha=sha_json(var), log=log, verdict=verdict, equivalent=ok_eq)
        sides.append((f"variant-{policy}", var_dir))
        print(f"[{policy}] equivalence: {verdict}")
        print("\n".join("  " + l for l in log))
    rows = []
    if not problems:
        budget = cfgd.get("route_budget_s", 60)
        for seed in cfgd["seeds"]:
            for side, sd in sides:
                rows.append(run_side(cr, side, case, seed, sd, env, model, budget, tb, snap_dir, fab_run))
    expect = case["expect"]
    print(f"{'side':19} {'seed':>4}  {'outcome':20} detail")
    for r in rows:
        print(f"{r['side']:19} {r['seed']:>4}  {r['outcome']:20} {r['sim'] or r['detail']}")
        if r["outcome"] not in cr.MEASURED:
            problems.append(f"{r['side']} seed {r['seed']}: {r['outcome']} ({r['detail']}) -- "
                            "setup/tool problem, not routability evidence")
    if a.append_record:
        with open(a.append_record, "a") as f:
            f.write(record(case, versions, base_sha, variants, rows, problems, expect))
    if a.export_fixtures is not None:
        dest = a.export_fixtures or str(REPO / "sim" / "bitstream" / "pin_experiment")
        ok, msg = export_fixtures(cr, case, cfgd["seeds"], rows, variants, problems, base_sha, versions, dest)
        print(("EXPORT: " if ok else "EXPORT REFUSED: ") + msg)
        if not ok:
            problems.append("fixture export refused: " + msg)
    if problems:
        print("\nEXPERIMENT PROBLEMS:")
        for p in problems:
            print("  " + p)
        return 1
    print("\nDONE: outcomes recorded; they are experimental evidence only (see "
          "design/fabulous/corpus/pin_experiment.md for the limits of the inference)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
