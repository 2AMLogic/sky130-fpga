#!/usr/bin/env python3
"""Index, provenance check and corruption helper for the pin-experiment fixtures (issue #145).

EXPERIMENTAL. The fixtures under sim/bitstream/pin_experiment/ are the three
successful `variant-distinct` fan4 trials of flow/pin_experiment.py (issue #137),
exported only on request (`flow/pin_experiment.sh --export-fixtures`). They are
a separate set from the baseline routability corpus (sim/bitstream/corpus/);
no corpus expectation or fixture depends on them. No timing claim, no
ratified-fabric claim (ADR-0004/0005 remain Proposed).

Subcommands (stdlib only, no mapper needed):

  verify DIR [--snapshot-dir D]   Static replay gate. Fails on: missing/empty/
        malformed index, a case count other than 3, a case that is not
        fan4/distinct, a listed file that is absent or whose sha256 drifted, a
        stray file not in the index, a fabric_spec.json / logic4_configmem.map
        whose sha256 differs from the one recorded at export or from the
        committed sim/bitstream/ copy, a transformed netlist that no longer
        has one pin index per distinct input net, or a mapped netlist whose
        LUT INITs are not those of the transformed netlist. On success prints
        one "<stem> <oracle>" line per case (stdout) for the replay scripts.
  corrupt DIR OUT [--bel N]       Write a self-consistent scratch copy of DIR in
        which LUT INIT of BEL N (default 0) is inverted in every stream (.bin
        and .cfg rewritten, index sha256 values refreshed). The copy passes the
        static sha/provenance checks, so only the simulation oracle can catch
        it (negative test; the committed fixtures are never touched).
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
FIX_DIR = REPO / "sim" / "bitstream" / "pin_experiment"
SNAP_DIR = REPO / "sim" / "bitstream"
EXTS = (".fasm", ".mapped.json", ".bin", ".wiring", ".cfg")
SNAP_FILES = ("fabric_spec.json", "logic4_configmem.map")
INDEX = "index.json"
NETLIST = "fan4_distinct.netlist.json"
EXPECTED_CASES = 3
EXPECTED_ORACLE = "fan4"
SCHEMA = 1


class FixtureError(Exception):
    pass


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sha256_file(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def stem_for(case, policy, seed):
    return f"{case}_{policy}_s{seed}"


# ------------------------------------------------------------------ export side
def build_index(cases, snap_dir, tools, netlist_sha, baseline_sha, variant_sha, dest):
    """cases: [dict(stem, case, policy, seed, oracle)]; files already present in `dest`."""
    entries = []
    for c in sorted(cases, key=lambda c: c["stem"]):
        files = {e: sha256_file(Path(dest) / f"{c['stem']}{e}") for e in EXTS}
        entries.append(dict(c, files=files))
    return {
        "schema": SCHEMA,
        "label": "EXPERIMENTAL pin-aligned fan4 fixtures (issue #145); not baseline corpus; "
                 "no timing or ratified-fabric claim",
        "provenance": {
            "snapshot": {n: sha256_file(Path(snap_dir) / n) for n in SNAP_FILES},
            "transformed_netlist": {"file": NETLIST, "sha256": netlist_sha},
            "synthesized_baseline_json_sha256": baseline_sha,
            "variant_json_sha256": variant_sha,
            "tools": tools,
        },
        "cases": entries,
    }


# ------------------------------------------------------------------ verify side
def _read_index(d):
    p = Path(d) / INDEX
    if not p.is_file() or p.stat().st_size == 0:
        raise FixtureError(f"fixture index missing or empty: {p}")
    try:
        idx = json.loads(p.read_text())
    except ValueError as e:
        raise FixtureError(f"fixture index is not valid JSON: {e}")
    if not isinstance(idx, dict) or idx.get("schema") != SCHEMA or not isinstance(idx.get("cases"), list):
        raise FixtureError("fixture index has an unexpected schema")
    return idx


def verify(d, snap_dir=SNAP_DIR):
    """Return [(stem, oracle)] or raise FixtureError."""
    d, snap_dir = Path(d), Path(snap_dir)
    idx = _read_index(d)
    cases = idx["cases"]
    if len(cases) != EXPECTED_CASES:
        raise FixtureError(f"expected exactly {EXPECTED_CASES} cases, index lists {len(cases)}")
    prov = idx.get("provenance", {})
    want_files = {INDEX}
    seeds, out = set(), []
    for c in cases:
        try:
            stem, case, policy, seed, oracle, files = (c[k] for k in
                                                       ("stem", "case", "policy", "seed", "oracle", "files"))
        except KeyError as e:
            raise FixtureError(f"index entry lacks field {e}")
        if case != "fan4" or policy != "distinct" or oracle != EXPECTED_ORACLE:
            raise FixtureError(f"{stem}: only fan4/distinct/{EXPECTED_ORACLE} cases are valid "
                               f"(got {case}/{policy}/{oracle})")
        if stem != stem_for(case, policy, seed) or seed in seeds:
            raise FixtureError(f"{stem}: stem/seed inconsistent or duplicated")
        seeds.add(seed)
        if set(files) != set(EXTS):
            raise FixtureError(f"{stem}: index must list exactly {', '.join(EXTS)}")
        for e, sha in files.items():
            f = d / f"{stem}{e}"
            want_files.add(f.name)
            if not f.is_file() or f.stat().st_size == 0:
                raise FixtureError(f"{stem}: missing or empty fixture file {f}")
            if sha256_file(f) != sha:
                raise FixtureError(f"{stem}: sha256 drift in {f.name} (index {sha[:16]}, "
                                   f"file {sha256_file(f)[:16]})")
        out.append((stem, oracle))
    # snapshot / map provenance: recorded at export, and still the committed copies
    for n in SNAP_FILES:
        rec = prov.get("snapshot", {}).get(n)
        cur = snap_dir / n
        if not rec or not cur.is_file() or sha256_file(cur) != rec:
            raise FixtureError(f"snapshot provenance: {n} sha256 differs from the one recorded at export "
                               f"(fixtures were assembled against a different fabric spec/map)")
    nl = prov.get("transformed_netlist", {})
    nlf = d / nl.get("file", NETLIST)
    want_files.add(nlf.name)
    if not nlf.is_file() or sha256_file(nlf) != nl.get("sha256"):
        raise FixtureError(f"transformed netlist {nlf.name} missing or sha256 drift")
    stray = sorted(p.name for p in d.iterdir() if p.name not in want_files)
    if stray:
        raise FixtureError(f"stray files not in the index: {', '.join(stray)}")
    _check_netlist_relation(d, nlf, cases)
    return out


def _check_netlist_relation(d, nlf, cases):
    pe = _load("pin_experiment")
    mod = json.loads(nlf.read_text())["modules"]["top"]
    luts = pe.lut_cells(mod)
    live = pe.live_nets(mod)
    owner = {}                                    # pin index -> net
    for _, c in luts:
        for k, n in enumerate(pe.pin_nets(c, live)):
            if n is None:
                continue
            if owner.setdefault(k, n) != n:
                raise FixtureError(f"transformed netlist: pin I{k} carries different nets "
                                   f"(the distinct policy needs one pin index per input net)")
    inits = sorted(c["parameters"]["INIT"] for _, c in luts)
    for c in cases:
        mapped = json.loads((d / f"{c['stem']}.mapped.json").read_text())
        got = sorted(x["init"] for x in mapped["cells"] if x["type"] == "lut4_ff_bel")
        if got != inits:
            raise FixtureError(f"{c['stem']}: mapped netlist LUT INITs differ from the transformed netlist")


# ------------------------------------------------------------------ corrupt (negative test)
def corrupt(src, dst, bel=0, snap_dir=SNAP_DIR):
    fab = _load("fasm_to_bitstream")
    snap = fab.load_snapshot(Path(snap_dir) / "fabric_spec.json")
    src, dst = Path(src), Path(dst)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    idx = _read_index(dst)
    for c in idx["cases"]:
        stem = c["stem"]
        cfg, _ = fab.decode((dst / f"{stem}.bin").read_bytes(), snap)
        cfg ^= 0xFFFF << (17 * bel)               # invert all 16 INIT bits of the BEL
        positions = {snap["cb_pos"][cb]: 1 for cb in range(len(snap["cb_pos"])) if cfg >> cb & 1}
        (dst / f"{stem}.bin").write_bytes(fab.pack(positions, snap))
        (dst / f"{stem}.cfg").write_text(f"{cfg:040x}\n")
        for e in (".bin", ".cfg"):
            c["files"][e] = sha256_file(dst / f"{stem}{e}")
    (dst / INDEX).write_text(json.dumps(idx, indent=1, sort_keys=True) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("verify")
    p.add_argument("dir")
    p.add_argument("--snapshot-dir", default=str(SNAP_DIR))
    p = sp.add_parser("corrupt")
    p.add_argument("dir")
    p.add_argument("out")
    p.add_argument("--bel", type=int, default=0)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "verify":
            for stem, oracle in verify(a.dir, a.snapshot_dir):
                print(f"{stem} {oracle}")
        else:
            corrupt(a.dir, a.out, a.bel)
    except FixtureError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
