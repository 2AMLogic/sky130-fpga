#!/usr/bin/env bash
# signoff/verify-pins.sh
#
# Re-verify, against the LIVE bytes of every artifact they pin, the
# content-hash citations signoff/block-manifest.json makes -- the proof
# half of "a manifest citing an artifact that has since changed fails
# rather than rotting" (issue #52).
#
# `klt signoff --manifest` itself grades each citation against the cited
# *envelope's* own `provenance.input.content_hash` (so a regenerated report
# against a changed input renders `stale_evidence`), but it cannot see the
# case where the INPUT artifact changed and the envelope was simply never
# re-run: the committed envelope still pins last week's hash and the two
# agree with each other. This script closes exactly that gap -- it hashes
# the pin's source artifact directly and fails naming the drift.
#
# Pins this repo's manifest makes today, and what each one means:
#
#   item 3  layout/logic_tile.drc.json    GDS  (layout/logic_tile.gds)
#   item 4  layout/logic_tile.lvs.json    as-built gate-level reference
#                                         netlist (regenerated + hashed by
#                                         flow/lvs.sh every run; not a
#                                         committed file -- freshness is the
#                                         lvs report's own input pin plus
#                                         its layout_gds_sha256 cross-tie
#                                         below)
#   item 5  measurements/timing-
#           characterization/
#           logic_tile.sta.json           the DEF `klt sta` actually analysed:
#                                         the name-sanitized derivative of
#                                         layout/logic_tile.def that
#                                         flow/sta-sweep.sh writes to scratch
#                                         (flow/build/, not committed). This
#                                         script regenerates it from the
#                                         committed DEF with the same
#                                         flow/sta_sanitize_names.py and
#                                         requires its hash to equal both the
#                                         envelope's provenance.input pin and
#                                         the manifest pin; it also ties the
#                                         envelope's layout_def_sha256 /
#                                         layout_gds_sha256 / spef_sha256 to
#                                         the committed DEF, GDS and SPEF
#                                         (measurements/timing-characterization/
#                                         logic_tile.spef), and re-runs
#                                         flow/sta_envelope_check.py (exact
#                                         ratified 18-corner set, constrained,
#                                         non-negative setup/hold, complete
#                                         annotation, agreement with the
#                                         committed per-corner SPEF reports)
#   item 8  signoff/characterization-
#           evidence.json                 generated characterization record
#                                         (measurements/characterization-
#                                         summary.md)
#   item 11 layout/logic_tile.erc.json    GDS + supply spec (flow/erc_supply_
#                                         spec.json -- the spec pin lives in
#                                         the erc report's own provenance
#                                         block, verified here)
#   item 11 layout/logic_tile.par.json   synthesized input netlist (its
#                                         provenance.input pin; regenerated
#                                         with the flow)
#
#   items 1, 2, 9, 10  artifact-anchored generic envelopes (signoff/item-N-*.json,
#                                         klayout-tools#2718). Each names its
#                                         audited artifact in provenance.input.path
#                                         (resolved beside the envelope) and pins its
#                                         hash; the envelope, the manifest and the live
#                                         artifact bytes must all agree:
#                                           1  design/netlist/logic_tile_netlist.v
#                                           2  layout/logic_tile.gds
#                                           9  measurements/claim-traceability.md
#                                           10 .github/workflows/signoff.yml
#
# Usage: ./signoff/verify-pins.sh          (from the repo root -- paths are
#                                          repo-root-relative)
#
# Exit status: 0 iff every pin matches the live artifact bytes. Any mismatch
# names the pin, the live artifact, and the regeneration command that
# reconciles them; non-zero otherwise.
#
# Requires: python3 (for JSON + sha256). Requires no klt, no PDK, no network:
# the whole pin set resolves from the committed tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
import sys

repo = sys.argv[1]
failures = []

def sha256_of(rel):
    with open(f"{repo}/{rel}", "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()

def check(label, expected, actual, remedy):
    ok = expected == actual
    print(f"  {'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        print(f"       manifest pins   {expected}")
        print(f"       live artifact   {actual}")
        print(f"       fix: {remedy}")
        failures.append(label)

manifest = json.load(open(f"{repo}/signoff/block-manifest.json"))
ev = manifest.get("evidence", {})
gds_live = sha256_of("layout/logic_tile.gds")
erc = json.load(open(f"{repo}/layout/logic_tile.erc.json"))
lvs = json.load(open(f"{repo}/layout/logic_tile.lvs.json"))
par = json.load(open(f"{repo}/layout/logic_tile.par.json"))
char_env = json.load(open(f"{repo}/signoff/characterization-evidence.json"))

print("item 3 (DRC): pinned layout GDS")
drc = json.load(open(f"{repo}/layout/logic_tile.drc.json"))
check("  drc envelope input pin == committed GDS",
      drc["provenance"]["input"]["content_hash"], gds_live,
      "re-run ./flow/drc.sh --update (layout changed without a DRC re-run)")
if "3" in ev:
    check("  manifest item-3 pin == committed GDS",
          ev["3"].get("content_hash"), gds_live,
          "update signoff/block-manifest.json item 3's content_hash after ./flow/drc.sh --update")

print("item 4 (LVS): pinned as-built reference netlist + layout cross-tie")
if "4" in ev:
    check("  manifest item-4 pin == lvs envelope input pin",
          ev["4"].get("content_hash"),
          lvs["provenance"]["input"]["content_hash"],
          "re-run ./flow/lvs.sh --update and update the manifest pin")
check("  lvs layout_gds_sha256 == committed GDS",
      lvs.get("layout_gds_sha256"), gds_live,
      "LVS report is against a different layout -- re-run ./flow/lvs.sh --update")

print("item 5 (multi-corner STA): analysed DEF, committed layout/parasitics, timing gate")
import subprocess
import tempfile
sta_rel = "measurements/timing-characterization/logic_tile.sta.json"
sta_env = json.load(open(f"{repo}/{sta_rel}"))
sta_input_pin = (sta_env.get("provenance") or {}).get("input", {}).get("content_hash")
with tempfile.TemporaryDirectory() as scratch:
    regenerated = f"{scratch}/logic_tile.sanitized.def"
    rc = subprocess.run(
        [sys.executable, f"{repo}/flow/sta_sanitize_names.py", "def-sanitize",
         f"{repo}/layout/logic_tile.def", regenerated]).returncode
    if rc == 0:
        with open(regenerated, "rb") as f:
            sanitized_live = "sha256:" + hashlib.sha256(f.read()).hexdigest()
    else:
        sanitized_live = f"<flow/sta_sanitize_names.py def-sanitize exited {rc}>"
check("  sta envelope input pin == sanitized DEF regenerated from committed DEF",
      sta_input_pin, sanitized_live,
      "the committed DEF (or flow/sta_sanitize_names.py) changed without a re-sweep -- "
      "re-run ./flow/sta-sweep.sh --update and update the manifest's item-5 pin")
check("  sta envelope layout_def_sha256 == committed DEF",
      sta_env.get("layout_def_sha256"), sha256_of("layout/logic_tile.def"),
      "re-run ./flow/sta-sweep.sh --update (layout DEF changed without a re-sweep)")
check("  sta envelope layout_gds_sha256 == committed GDS",
      sta_env.get("layout_gds_sha256"), gds_live,
      "re-run ./flow/sta-sweep.sh --update (layout GDS changed without a re-extraction)")
check("  sta envelope spef_sha256 == committed SPEF",
      sta_env.get("spef_sha256"),
      sha256_of("measurements/timing-characterization/logic_tile.spef"),
      "re-run ./flow/sta-sweep.sh --update (it rewrites the envelope and the SPEF together)")
if "5" in ev:
    check("  manifest item-5 cites the multi-corner envelope",
          sta_rel, ev["5"].get("file"),
          f"point signoff/block-manifest.json item 5 at {sta_rel}")
    check("  manifest item-5 pin == sta envelope input pin",
          ev["5"].get("content_hash"), sta_input_pin,
          "update signoff/block-manifest.json item 5's content_hash after ./flow/sta-sweep.sh --update")
else:
    check("  manifest cites item 5", "cited", "missing",
          "add item 5 to signoff/block-manifest.json")
gate = subprocess.run(
    [sys.executable, f"{repo}/flow/sta_envelope_check.py", f"{repo}/{sta_rel}",
     "--cross-check", f"{repo}/measurements/timing-characterization/corners"],
    capture_output=True, text=True)
check("  sta envelope passes flow/sta_envelope_check.py (18 ratified corners, "
      "constrained, setup/hold >= 0, annotation complete, matches per-corner reports)",
      0, gate.returncode,
      "the envelope fails the item-5 gate: " + (gate.stderr.strip().replace("\n", " | ") or gate.stdout.strip()))

print("item 8 (characterization): pinned generated summary")
charsum_live = sha256_of("measurements/characterization-summary.md")
check("  generic envelope input pin == live summary",
      char_env["provenance"]["input"]["content_hash"], charsum_live,
      "regenerate: python3 measurements/generate-characterization-summary.py, "
      "then update signoff/characterization-evidence.json and the manifest pin")
if "8" in ev:
    check("  manifest item-8 pin == live summary",
          ev["8"].get("content_hash"), charsum_live,
          "update signoff/block-manifest.json item 8's content_hash "
          "(and tier-report.json) after the summary regenerates")

print("item 11 (power delivery, structural): erc + lvs + place-and-route")
check("  erc envelope input pin == committed GDS",
      erc["provenance"]["input"]["content_hash"], gds_live,
      "re-run ./flow/erc.sh --update (layout changed without an ERC re-run)")
check("  erc envelope spec pin == live supply spec",
      erc["provenance"]["spec"]["content_hash"],
      sha256_of("flow/erc_supply_spec.json"),
      "supply spec changed -- re-run ./flow/erc.sh --update")
if "11" in ev:
    parts = {p.get("file"): p for p in ev["11"]}
    erc_part = parts.get("layout/logic_tile.erc.json", {})
    lvs_part = parts.get("layout/logic_tile.lvs.json", {})
    par_part = parts.get("layout/logic_tile.par.json", {})
    check("  manifest item-11 erc pin == committed GDS",
          erc_part.get("content_hash"), gds_live,
          "update the manifest's item-11 erc content_hash after ./flow/erc.sh --update")
    check("  manifest item-11 lvs pin == lvs envelope input pin",
          lvs_part.get("content_hash"),
          lvs["provenance"]["input"]["content_hash"],
          "update the manifest's item-11 lvs content_hash after ./flow/lvs.sh --update")
    check("  manifest item-11 par pin == par envelope input pin",
          par_part.get("content_hash"),
          par["provenance"]["input"]["content_hash"],
          "update the manifest's item-11 par content_hash after ./flow/lvs.sh --update "
          "(the P&R report regenerates together with the LVS inputs)")

print("items 1, 2, 9, 10 (artifact-anchored generic envelopes): live audited bytes")
import os
bound = [
    ("1", "signoff/item-1-design-sources.json", "design/netlist/logic_tile_netlist.v",
     "regenerate the netlist with ./flow/layout.sh, then"),
    ("2", "signoff/item-2-layout.json", "layout/logic_tile.gds",
     "after re-running the flow (./flow/drc.sh --update etc.),"),
    ("9", "signoff/item-9-testbenches.json", "measurements/claim-traceability.md",
     "re-run ./flow/audit-evidence.sh and re-audit the file, then"),
    ("10", "signoff/item-10-repo-hygiene.json", ".github/workflows/signoff.yml",
     "re-inspect README, spec and LICENSE, then"),
]
for item, env_rel, art_rel, pre in bound:
    remedy = (f"{pre} update {env_rel}'s provenance.input.content_hash and the "
              f"manifest's item-{item} content_hash to the live hash, then regenerate "
              "signoff/tier-report.json")
    env = json.load(open(f"{repo}/{env_rel}"))
    live = sha256_of(art_rel)
    inp = env["provenance"]["input"]
    resolved = os.path.normpath(os.path.join(os.path.dirname(f"{repo}/{env_rel}"), inp["path"]))
    check(f"  item-{item} envelope names {art_rel}",
          os.path.realpath(f"{repo}/{art_rel}"), os.path.realpath(resolved),
          f"point {env_rel} provenance.input.path at ../{art_rel}")
    check(f"  item-{item} envelope declares t1_item {item}",
          item, str(env.get("t1_item")), f"set t1_item in {env_rel}")
    check(f"  item-{item} envelope input pin == live {art_rel}",
          inp["content_hash"], live, remedy)
    if item in ev:
        check(f"  manifest item-{item} pin == live {art_rel}",
              ev[item].get("content_hash"), live, remedy)
    else:
        check(f"  manifest cites item {item}", "cited", "missing",
              f"add item {item} to signoff/block-manifest.json")

print()
if failures:
    print(f"pin verification FAILED ({len(failures)} mismatch(es)): "
          + ", ".join(failures))
    print("the manifest is citing artifacts that have changed -- reconcile the")
    print("pins above rather than letting the signoff record claim stale evidence.")
    sys.exit(1)
print("pin verification clean: every manifest citation matches its live artifact")
PY
