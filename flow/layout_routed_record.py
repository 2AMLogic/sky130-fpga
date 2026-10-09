#!/usr/bin/env python3
"""flow/layout_routed_record.py

Run-record writer/checker for flow/layout_routed.sh (issue #102, the
EXPERIMENTAL composed-tile physical canary). Not used by the BEL-only flow.

`write`  appends layout/experimental/run-records/<UTC>-<srchash>.json, pinning
         source sha256s, artifact sha256s, tool versions, and the observed
         synthesis / place-and-route / structural facts. Existing records are
         never modified (append-only evidence).
`check`  verifies the LATEST record's source hashes equal the current RTL and
         its artifact hashes equal the committed artifacts, i.e. the record
         still describes the committed run. Tool versions are informational.

Structural facts are computed from the as-built netlist, never assumed:
  - top-level port widths (cfg[157:0], 4x4 track ins/outs)
  - flattened-hierarchy prefixes (u_sm/ matrix, g_slice[i].u_slice/ BELs)
  - a cell-level combinational-cycle analysis (SCCs over all cell data/select
    inputs, flops cut). Any cycle found would mean OpenSTA's slack numbers were
    produced with loops broken by the tool; a count of zero only covers the
    single tile (inter-tile abutment loops are invisible here). Slack numbers
    are not a timing claim either way.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

OUT_PINS = {"X", "Y", "Q", "Q_N", "COUT", "SUM", "HI", "LO", "GCLK"}
SEQ_PREFIXES = ("sky130_fd_sc_hd__df", "sky130_fd_sc_hd__dl", "sky130_fd_sc_hd__sdf")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def analyse_netlist(text: str) -> dict:
    ports = {}
    for m in re.finditer(r"^\s*(input|output)\s*(?:\[(\d+):(\d+)\])?\s*(\S+);", text, re.M):
        d, hi, lo, name = m.groups()
        ports[name] = {"dir": d, "width": (int(hi) - int(lo) + 1) if hi else 1}
    insts = []
    for m in re.finditer(r"^\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\);", text, re.M | re.S):
        cell, name, body = m.groups()
        pins = re.findall(r"\.(\w+)\(\s*((?:\\\S+\s)|[^)\s]*(?:\[\d+\])?)\s*\)", body)
        insts.append((cell, name.lstrip("\\"), [(p, n.strip().lstrip("\\")) for p, n in pins]))
    # cell graph: driver instance -> sink instance, flops cut
    driver, sinks = {}, {}
    for i, (cell, _, pins) in enumerate(insts):
        if cell.startswith(SEQ_PREFIXES):
            for p, n in pins:
                if p in OUT_PINS:
                    driver[n] = None  # flop output: path source, no comb edge
            continue
        for p, n in pins:
            if p in OUT_PINS:
                driver[n] = i
            elif cell.startswith("sky130_fd_sc_hd__diode"):
                pass
            else:
                sinks.setdefault(n, []).append(i)
    edges = {i: set() for i in range(len(insts))}
    for net, d in driver.items():
        if d is None:
            continue
        for s in sinks.get(net, []):
            edges[d].add(s)
    # iterative Tarjan SCC
    index, low, onstk, stack, sccs, counter = {}, {}, set(), [], [], [0]
    for root in edges:
        if root in index:
            continue
        work = [(root, iter(edges[root]))]
        index[root] = low[root] = counter[0]; counter[0] += 1
        stack.append(root); onstk.add(root)
        while work:
            v, it = work[-1]
            for w in it:
                if w not in index:
                    index[w] = low[w] = counter[0]; counter[0] += 1
                    stack.append(w); onstk.add(w)
                    work.append((w, iter(edges[w])))
                    break
                elif w in onstk:
                    low[v] = min(low[v], index[w])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[v])
                if low[v] == index[v]:
                    comp = []
                    while True:
                        w = stack.pop(); onstk.discard(w); comp.append(w)
                        if w == v:
                            break
                    if len(comp) > 1 or v in edges[v]:
                        sccs.append(comp)
    prefixes = {}
    for _, name, _ in insts:
        m = re.match(r"(u_sm|g_slice\[\d\]\.u_slice)/", name)
        if m:
            prefixes[m.group(1)] = prefixes.get(m.group(1), 0) + 1
    counts = {}
    for cell, _, _ in insts:
        counts[cell] = counts.get(cell, 0) + 1
    return {
        "top_ports": ports,
        "hierarchy_prefix_instance_counts": dict(sorted(prefixes.items())),
        "instance_counts_by_cell": dict(sorted(counts.items())),
        "combinational_cycle_analysis": {
            "method": "cell-level SCC over every non-output pin of every "
                      "combinational cell (all mux data+select inputs), flops cut; "
                      "structural over ALL configurations",
            "cyclic_scc_count": len(sccs),
            "cyclic_scc_sizes": sorted((len(c) for c in sccs), reverse=True),
            "cells_in_cycles": sum(len(c) for c in sccs),
        },
    }


def latest_record(record_dir: Path):
    recs = sorted(record_dir.glob("*.json"))
    return recs[-1] if recs else None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["write", "check"])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--record-dir", required=True)
    ap.add_argument("--top", required=True)
    ap.add_argument("--clock-period-ns")
    ap.add_argument("--synth-response")
    ap.add_argument("--par-response")
    ap.add_argument("--klt")
    ap.add_argument("--openroad")
    ap.add_argument("--yosys")
    ap.add_argument("sources", nargs="+")
    a = ap.parse_args(argv[1:])
    repo, out, rdir = Path(a.repo), Path(a.out_dir), Path(a.record_dir)
    srcs = {str(Path(s).relative_to(repo)): sha(Path(s)) for s in a.sources}
    names = [f"{a.top}.{e}" for e in ("gds", "def", "v", "synth.v", "par.json")]

    if a.mode == "check":
        rec = latest_record(rdir)
        if rec is None:
            print(f"error: no run record under {rdir} -- run --update", file=sys.stderr)
            return 1
        r = json.loads(rec.read_text())
        bad = [k for k, v in srcs.items() if r["sources_sha256"].get(k) != v]
        bad += [n for n in names if r["artifacts_sha256"].get(n) != sha(out / n)]
        if bad:
            print(f"error: latest run record {rec.name} does not pin current {bad}", file=sys.stderr)
            return 1
        print(f"run record {rec.name} pins current sources and committed artifacts")
        return 0

    par = json.loads(Path(a.par_response).read_text())
    syn = json.loads(Path(a.synth_response).read_text())
    keep = ["status", "stage_reached", "seed", "die_area_um2", "core_area_um2", "utilization_pct",
            "wirelength_um", "route_drc_violation_count", "antenna_violation_count",
            "setup_violation_count", "hold_violation_count", "timing_status"]
    record = {
        "schema": "sky130-fpga.layout-routed-run-record/1",
        "issue": 102,
        "status_note": "EXPERIMENTAL: place-and-route canary of the same-index stand-in matrix "
                       "(spec/decisions/0004 Proposed). Not signoff; no timing claim.",
        "utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "top": a.top,
        "clock_period_ns_placeholder": int(a.clock_period_ns),
        "tools": {"klt": a.klt, "openroad": a.openroad, "yosys": a.yosys,
                  "pdk": par.get("provenance", {}).get("pdk")},
        "sources_sha256": srcs,
        "artifacts_sha256": {n: sha(out / n) for n in names},
        "synthesis": {k: syn.get(k) for k in ("status", "instance_count", "area_um2",
                                               "sequential_area_um2", "instance_counts_by_type")},
        "place_and_route": {k: par.get(k) for k in keep},
        "place_and_route_slack_estimates_ns": {
            k: par.get(k) for k in ("worst_slack_ns", "worst_setup_slack_ns", "worst_hold_slack_ns")},
        "slack_estimates_caveat": "OpenROAD estimates against a placeholder clock with no I/O delay "
                                  "constraints (port-to-register and port-to-port paths are not "
                                  "characterized) -- not a timing claim. cyclic_scc_count==0 "
                                  "because matrix LUT-input muxes select only from the 16 track "
                                  "inputs and BEL outputs only reach track outputs: loops exist "
                                  "only across tile abutment, which a single-tile run cannot see.",
        "structure": analyse_netlist((out / f"{a.top}.v").read_text()),
    }
    rdir.mkdir(parents=True, exist_ok=True)
    stamp = record["utc"].replace(":", "").replace("-", "")
    name = f"{stamp}-{hashlib.sha256(json.dumps(srcs, sort_keys=True).encode()).hexdigest()[:7]}.json"
    path = rdir / name
    if path.exists():
        print(f"error: {path} exists (append-only)", file=sys.stderr)
        return 1
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    print(f"=== run record {path} ===")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
