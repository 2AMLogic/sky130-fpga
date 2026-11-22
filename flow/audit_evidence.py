#!/usr/bin/env python3
"""flow/audit_evidence.py

Re-derive the claim -> harness -> pinned-PDK audit that
`measurements/claim-traceability.md` publishes, from the committed tree.

Why this exists (issue #34, T1 checklist item 9 of
`docs/design-evidence-tiers.md` in `2AMLogic/klayout-tools`): item 9 requires
that **every claimed measurement** has a committed testbench/harness and a
pinned PDK version. A one-off audit answers that for the day it was written
and then silently rots -- a new record, a new report type, or an edit to a
harness a record already pinned by hash would all go unnoticed. This script
is the re-runnable form of that audit, in the same "regenerate and diff on
every invocation" shape as the rest of `flow/`.

What it checks, all against committed files only (no `klt`, no PDK install,
no network):

1. **Every characterization record is traceable.** For each record under
   `measurements/*/records/*.md`, its `record-meta` header must name a
   `harness` that exists in the tree, must pin `provenance.pdk.version`, and
   that version must equal the repo's single pinned source
   (`RECORDED_PDK_VERSION` in `flow/tool_versions.sh`, passed in via
   `--recorded-pdk`).
2. **Every hash a *current* record pins still describes the committed
   file.** Each `provenance.inputs[]` entry's `content_hash` is recomputed.
   A mismatch is a FAIL unless either (a) the record has been **superseded**
   -- some other record's `record-meta` names it in `supersedes`, and the
   supersession graph is structurally valid (see `_build_supersession`:
   unique ids, no self-edges, no cycles, no unknown targets, one successor
   per record, chain ends in a surviving current record) -- or (b)
   it is in `ALLOWED_INPUT_DRIFT` below, an explicit, commit-cited allowance
   for a change already reviewed as method-neutral. An input whose `role`
   marks it as not committed (regenerated scratch) is allowed to be absent,
   but is FAIL if it is absent without saying so.

   The supersession carve-out is what makes the append-only rule usable.
   Records are never edited, so when the tree's geometry legitimately
   changes (issue #41 added a power delivery network, moving
   `layout/logic_tile.def`'s and `logic_tile.gds`'s hashes), the record
   written against the *old* geometry can only be answered by writing a
   successor -- which is exactly what this script's own failure message
   tells you to do. Without this carve-out that instruction was
   unfollowable: the superseded record's pinned hashes kept FAILing
   forever, and the only way to silence them was an `ALLOWED_INPUT_DRIFT`
   entry claiming the change "cannot move this record's numbers" -- a claim
   that is false precisely when a successor was needed. A superseded record
   pins the tree *as it was*; its successor pins the tree as it is, and is
   still checked in full.
3. **Every committed evidence report pins the same PDK.** Any report JSON
   under `layout/` (including nested directories such as
   `layout/experimental/`, issue #149) or `measurements/` carrying `provenance.pdk` must name
   exactly the pinned revision. A report whose `provenance.pdk` is `null`
   is FAIL unless it is in `PDK_NULL_UPSTREAM_GAP`. Since the klt build
   carrying the klayout-tools#1901 fix, `klt drc` / `klt lvs` write a real
   `provenance.pdk` -- `layout/logic_tile.drc.json` / `.lvs.json` have
   pinned it in-artifact since the 2026-09-21 re-stamp (issue #41, PR #55)
   -- so the only live null gap is `layout/logic_tile.erc.json`
   (klayout-tools#2036); the drc/lvs entries are retained there as
   regression guards, not live gaps. Listing entries explicitly is what
   stops a *new* PDK-less report type from quietly joining them.

Records are append-only (`measurements/README.md`), so this script never
edits anything -- there is no `--update` mode. When a check fails, the fix
is either to correct the tree or, for a deliberate and reviewed change, to
add an entry to one of the two tables below with its rationale.

Usage:
    audit_evidence.py --recorded-pdk "<version>" [--repo-root <path>]

Exit status: 0 iff every check passes.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# (record_id, input path) -> why the committed file no longer hashes to the
# value that record pinned, and the commit that changed it. Records are
# append-only, so a harness edit made after a record was written can never be
# fixed by rewriting the record -- it is accounted for here instead, and only
# after confirming the change cannot move the record's numbers.
ALLOWED_INPUT_DRIFT = {
    ("20260909-225431-86f71d2", "flow/sta-sweep.sh"): (
        "f38523e (PR #25, issue #23) added the flow/tool_versions.sh banner "
        "and one extra check-mode error line. Diff is print-only: no change "
        "to the extraction, the corner list, the SDC, the report trimming or "
        "the diff logic, so it cannot move this record's numbers."
    ),
    ("20261008-234741-dc615b4", "flow/sta-sweep.sh"): (
        "issue #113 added an opt-in --routed target (experimental composed tile) to the script. Default (BEL-only) target is unchanged: same "
        "paths, requests, sanitizer mode and gate. Verified by re-running the "
        "default check mode: every per-corner metric reproduced; the only "
        "diffs are the SPEF *VERSION header / spef_sha256 from the installed "
        "klt build, which predate this change (toolchain drift)."
    ),
    ("20261008-234741-dc615b4", "flow/sta_sanitize_names.py"): (
        "issue #113 added a def-sanitize-hier mode used only by --routed. Default (BEL-only) target is unchanged: same "
        "paths, requests, sanitizer mode and gate. Verified by re-running the "
        "default check mode: every per-corner metric reproduced; the only "
        "diffs are the SPEF *VERSION header / spef_sha256 from the installed "
        "klt build, which predate this change (toolchain drift)."
    ),
    ("20261008-234741-dc615b4", "flow/sta_envelope_check.py"): (
        "issue #113 added an opt-in --observation flag used only by --routed. Default (BEL-only) target is unchanged: same "
        "paths, requests, sanitizer mode and gate. Verified by re-running the "
        "default check mode: every per-corner metric reproduced; the only "
        "diffs are the SPEF *VERSION header / spef_sha256 from the installed "
        "klt build, which predate this change (toolchain drift)."
    ),
    ("20261027-201500-9111a08", "flow/sta-sweep.sh"): (
        "Two reviewed harness edits, neither able to move this record's "
        "numbers. db5c038 (PR #279, issue #265) replaced the three inline "
        "sha256:$(python3 -c ...) hash substitutions with sha256_of from "
        "the new flow/report_check.sh, and added the (inert) source line "
        "for it -- parse_update_mode is not called here; the script keeps "
        "its own multi-mode parse. sha256_of returns byte-for-byte the "
        "same sha256:<hex> string, verified by the full 18-corner "
        "main-vs-branch run recorded in PR #279: 51,436 lines each, only "
        "diffs were the klt extract wall-clock floats, with the "
        "=== extracted parasitics from sha256:... -> SPEF sha256:... === "
        "banner byte-identical; the failure path matches too (the hash "
        "command is sha256_of's last command, so an existing-but-unreadable "
        "input aborts the driver under set -e, rc=1, no sha256: line, "
        "exactly as the inline form did -- pinned by "
        "flow/test_report_check.sh in the flow-evidence workflow). "
        "Issue #259 then generalized the opt-in target selection to "
        "--target <dir> (strictly read-only: refuses --update, skips every "
        "committed-copy diff, writes only into flow/build/sta_target/) and "
        "guarded the committed-evidence references behind it; --routed "
        "still selects the experimental tile (--target "
        "<repo>/layout/experimental is its exact alias). Default "
        "(BEL-only) target is unchanged: same paths, requests, sanitizer "
        "mode and gate. Verified by re-running the default check mode "
        "under the record's own toolchain (klt 0.8.0, "
        "OpenROAD 26Q3-1510-g6cb3f2b704, PDK open_pdks c6d73a35): exit 0 "
        "with every committed per-corner report, the multi-corner "
        "envelope and the SPEF reproduced byte-identically -- no drift at "
        "all. The default-path klt argv and cwd equality is additionally "
        "asserted mechanically by flow/test_signoff_target.sh's committed "
        "fixture."
    ),
    ("20261107-213000-9e83907", "flow/layout.sh"): (
        "Two reviewed harness edits, neither able to move this record's "
        "numbers. 20a9fc62 (PR #277, issue #261) single-sourced two pieces "
        "this script carried inline: resolve_klt_artifact() moved verbatim "
        "into flow/klt_artifact.sh (now sourced), and the hand-written "
        "klt.synthesize.request heredoc was replaced by a call to "
        "flow/synth_request.py, which writes the same request document "
        "(identical schema/engine/sources/toplevel/pdk/corner/clock-period "
        "fields and values; only JSON line-wrapping differs, and klt parses "
        "the file) -- verified in the PR's before/after regeneration under "
        "one toolchain: GDS 2478d036..., DEF 149bb479... and synth netlist "
        "09777dce... byte-identical; the par report identical modulo the "
        "pre-existing per-run run_id path volatility (random per klt "
        "invocation, stamped on both sides of the refactor). db5c038 (PR "
        "#279, issue #265) then replaced the 12-line --update/check MODE "
        "case block with parse_update_mode from the new flow/report_check.sh "
        "-- parse-only, no change to any MODE == \"update\" body or to the "
        "klt openroad loop; byte-identical by construction and its negative "
        "path verified in PR #279 (bad first argument -> same usage line, "
        "rc=1). The post-synthesize stages were not re-run end to end on the "
        "shared worker (klt synthesize cap), so what PR #279 attests is the "
        "parse equivalence -- the only thing that commit changed in the "
        "harness the record runs."
    ),
    ("20261114-043307-515714f", "flow/layout.sh"): (
        "The same two harness edits already accounted for "
        "20261107-213000-9e83907 above: 20a9fc62 (PR #277, issue #261) "
        "single-sourced resolve_klt_artifact() into flow/klt_artifact.sh "
        "(now sourced) and replaced the synthesize-request heredoc with "
        "flow/synth_request.py writing the same request document (identical "
        "fields and values; only JSON line-wrapping differs), verified "
        "byte-identical in the PR's before/after regeneration under one "
        "toolchain; db5c038 (PR #279, issue #265) replaced the --update/check "
        "MODE case block with parse_update_mode from flow/report_check.sh -- "
        "parse-only, no change to any MODE == \"update\" body or to the klt "
        "openroad loop, byte-identical by construction with the negative "
        "path verified in PR #279. No change to what the script submits to "
        "klt, how it resolves stage artifacts, or how it parses its own "
        "arguments, so this reproducibility run cannot come out different."
    ),
    ("20261008-233733-23e6b5e", "flow/sdf-resim.sh"): (
        "20a9fc62 (PR #277, issue #261) single-sourced two pieces this script "
        "carried inline: resolve_klt_artifact() moved verbatim into "
        "flow/klt_artifact.sh (now sourced), and the hand-written "
        "klt.synthesize.request heredoc was replaced by a call to "
        "flow/synth_request.py, which writes the same request document "
        "(identical schema/engine/sources/toplevel/pdk/corner/clock-period "
        "fields and values; only JSON line-wrapping differs, and klt parses "
        "the file). The synthesize netlist sdf-resim consumes is therefore "
        "unchanged, so this record's resim timing numbers cannot move. "
        "Verified in the PR's before/after regeneration under one toolchain: "
        "regenerated DEF 149bb479... byte-identical to layout.sh's DEF and "
        "synth netlist 09777dce... unchanged; the DEF byte-diff gate fires "
        "at the same place with the same verdict on both sides."
    ),
    ("20261017-sdf-sanitize-d811bcd", "flow/sdf-resim.sh"): (
        "20a9fc62 (PR #277, issue #261), the same harness edit already "
        "accounted for 20261008-233733-23e6b5e above: resolve_klt_artifact() "
        "moved verbatim into flow/klt_artifact.sh (now sourced) and the "
        "synthesize-request heredoc was replaced by flow/synth_request.py "
        "writing the same request document (identical fields and values; "
        "only JSON line-wrapping differs). This record's run drives "
        "sdf-resim unmodified and stops at its DEF gate; the DEF gate "
        "verdict and the netlist/SDF pair feeding the sanitize experiment "
        "are unchanged by the refactor -- regenerated DEF 149bb479... "
        "byte-identical and netlist 09777dce... unchanged in the PR's "
        "before/after regeneration under one toolchain."
    ),
    ("20261114-sdf-port-interconnect-564db73", "sim/sdf_port_interconnect/run.sh"): (
        "789bc21 (issue #269) relaxed only the harness's PDK-model "
        "resolution so CI can run it: after the four path-pinned candidates "
        "(unchanged list, unchanged acceptance) miss, a flat-layout model "
        "directory is accepted only when sky130_fd_sc_hd.v and primitives.v "
        "sha256-match the recorded values in flow/tool_versions.sh -- i.e. "
        "byte-identical model inputs by construction -- and any other "
        "directory still exits non-zero with the named pinned-revision "
        "error before a simulation starts. Nothing downstream of resolution "
        "changed, and this record's own run resolved through a pinned path, "
        "so every input it pins is unchanged. Verified in the PR: with only "
        "a hash-matching flat layout present, the guard re-runs to exit 0 "
        "reproducing every verdict, rejected-entry count and the "
        "committed-SDF 28-rejection prediction, byte-identical across two "
        "consecutive runs; a one-byte-corrupted primitives.v is refused "
        "with the named error."
    ),
    ("20261121-183351-787c7ca", "flow/tile-functional-verification.sh"): (
        "Two reviewed harness edits, neither able to move this record's "
        "numbers. 5aa9873 (issue #375) single-sourced the harness's inline "
        "`klt pdk find` candidate into flow/pdk_root.sh's "
        "sky130_cell_models_from_klt (now sourced). Method-neutral by "
        "construction: the candidate ORDER ($PDK_ROOT first, then klt) is "
        "unchanged, and the only behavioural difference is that the second "
        "candidate is now the <libs_ref>/sky130_fd_sc_hd/verilog directory "
        "the find result's assets.libs_ref actually names, instead of the "
        "bare root it printed before -- a root under which -f "
        "sky130_fd_sc_hd.v was always false, so the pre-#375 klt fallback "
        "was a dead candidate that could never have produced this record's "
        "runs (they resolved through $PDK_ROOT). The strict "
        "RECORDED_PDK_MODELS_SHA256 / RECORDED_PDK_PRIMITIVES_SHA256 gate, "
        "the request pair, both klt invocations, the envelope gating and "
        "trimming are byte-identical; verified in the PR: with $PDK_ROOT "
        "unset the harness now reaches the hash gate on the klt candidate "
        "and refuses the installed non-matching models with the unchanged "
        "pinned-digest error, while the PDK_ROOT path it actually used for "
        "the record is untouched. Issue #382 then appended the SDF "
        "settle-time probe pair, because this record's own Result 4 is a "
        "scratch probe the committed suite cannot observe: the four named "
        "checks pass identically with the SDF stripped of every delay. The "
        "model gate and this record's two request documents are written "
        "exactly as before (the probe requests are derived by re-reading "
        "those two files and swapping only testbench.module), run_klt and "
        "both of this record's invocations are untouched, and load_trim_gate "
        "gained two parameters -- expected test names, and an optional probe "
        "run directory -- that leave every gate check and every "
        "normalisation of this record's two envelopes as they were (only "
        "the test-names mismatch message is reworded). The two probe runs, "
        "their gate and the delta gate run after this record's legs, and a "
        "refused probe gate exits before the --update / check block. "
        "Verified in the PR under the record's toolchain (klt 0.9.1, Icarus "
        "13.0, cocotb 2.1.0): check mode reproduced both committed "
        "envelopes byte for byte, and an --update run that rewrote them "
        "left their sha256 equal to the values pinned above "
        "(f4dced97... / 5f644edf...)."
    ),
}

# Committed reports whose `provenance.pdk` may be null without failing
# audit check 3. Two classes, and the difference matters:
#
# * A **live null gap** -- `layout/logic_tile.erc.json`. `klt erc` writes no
#   provenance block at all and reads no PDK install (klayout-tools#2036),
#   so this report's PDK pin is genuinely inherited from
#   flow/tool_versions.sh's RECORDED_PDK_VERSION banner.
#
# * A **regression guard kept by deliberate design** -- the `klt drc` /
#   `klt lvs` entries. The committed drc/lvs reports pin the PDK
#   in-artifact (klayout-tools#1901 was fixed upstream before klt 0.5.0;
#   both reports have carried `provenance.pdk.{name,version}` since the
#   2026-09-21 re-stamp, issue #41 / PR #55), so these entries do not
#   describe today's committed bytes. They are retained, with corrected
#   text, so a pre-fix klt build re-stamping those reports (or an upstream
#   regression re-introducing the null) is audited as a named, explained
#   fallback-to-banner state rather than an unknown-PDK FAIL -- the
#   tolerance `measurements/claim-traceability.md` G-1 records ("the
#   entries stay for as long as a null-era report could be re-stamped by a
#   pre-fix klt build"). The alternative -- deleting the entries, making
#   any future null a FAIL -- was considered and rejected in favor of that
#   recorded intent (issue #49).
PDK_NULL_UPSTREAM_GAP = {
    "layout/logic_tile.drc.json": (
        "retained as a regression guard, not a live gap: klt drc writes a "
        "real provenance.pdk on builds after the klayout-tools#1901 fix, "
        "and this committed report has pinned it in-artifact since the "
        "2026-09-21 re-stamp (issue #41, PR #55); only a pre-fix build's "
        "re-stamp would write null again, inheriting the pin from "
        "flow/drc.sh's banner instead."
    ),
    "layout/logic_tile.lvs.json": (
        "retained as a regression guard, not a live gap: klt lvs writes a "
        "real provenance.pdk on builds after the klayout-tools#1901 fix, "
        "and this committed report has pinned it in-artifact since the "
        "2026-09-21 re-stamp (issue #41, PR #55); only a pre-fix build's "
        "re-stamp would write null again, inheriting the pin from "
        "flow/lvs.sh's banner instead."
    ),
    "layout/experimental/logic_tile_routed.erc.json": (
        "same producer and method as layout/logic_tile.erc.json (issue "
        "#149): flow/routed_checks.sh runs klt erc on the experimental "
        "composed tile's GDS against the same flow/erc_supply_spec.json, "
        "klt writes no provenance block (klayout-tools#2036), and "
        "flow/erc_report_trim.py synthesizes the null-PDK block. Its "
        "provenance.input.content_hash pins layout/experimental/"
        "logic_tile_routed.gds, whose sibling drc/lvs/par reports pin the "
        "PDK in-artifact. Scoped to this one path: other experimental "
        "reports get no exemption."
    ),
    "layout/logic_tile.erc.json": (
        "klt erc writes no provenance block at all (klayout-tools#2036) "
        "and reads no PDK install -- it is a pure geometry connectivity "
        "pass over the committed GDS plus this repo's own supply spec "
        "JSON (flow/erc.sh passes --pdk sky130 solely to select klt's "
        "built-in antenna-ratio table; the connectivity model opens no "
        "PDK file). flow/erc_report_trim.py therefore synthesizes the "
        "drc-shaped provenance block this report carries, content-hash-"
        "pinning both of its actual inputs -- provenance.input."
        "content_hash (the committed layout/logic_tile.gds, whose own "
        "PDK pin claim #4 carries) and provenance.spec.content_hash -- "
        "plus the producing klt_version, and flow/erc.sh re-verifies both "
        "hashes against the committed files on every run."
    ),
}

_RECORD_META_RE = re.compile(r"<!--\s*record-meta\s*(\{.*?\})\s*-->", re.DOTALL)


class Audit:
    def __init__(self, root: Path, recorded_pdk: str):
        self.root = root
        self.recorded_pdk = recorded_pdk
        self.failures = []
        # record_id -> record_id of the successor that declared it superseded.
        self.superseded_by: dict = {}

    def ok(self, msg: str) -> None:
        print(f"  ok    {msg}")

    def fail(self, msg: str) -> None:
        print(f"  FAIL  {msg}")
        self.failures.append(msg)

    def note(self, msg: str) -> None:
        print(f"  note  {msg}")

    # --- 1 + 2. records ---------------------------------------------------

    def audit_records(self) -> None:
        records = sorted(self.root.glob("measurements/*/records/*.md"))
        print(f"=== records: {len(records)} under measurements/*/records/ ===")
        if not records:
            self.fail("no characterization records found at all")
            return
        # Pass 1: validate identities and the supersession graph, then derive
        # exemptions from the structurally valid part only, so a record's
        # disposition does not depend on sort order and malformed metadata
        # can never exempt anything.
        self._build_supersession(records)
        # Pass 2: audit.
        for record in records:
            self._audit_record(record)

    def _build_supersession(self, records: list) -> None:
        """Populate self.superseded_by from a validated supersession graph.

        Policy (issue #150). An old record is exempt from input-hash drift
        only if following its successors reaches a *surviving current record*
        (one no record supersedes) through well-formed declarations. Defects
        are FAILs with record-specific messages and exempt nothing:

        * missing / non-string / empty `record_id` in an otherwise readable
          header;
        * duplicate `record_id` (every claimant is reported; ambiguous ids
          take no part in the graph);
        * `supersedes` that is not a string or list of strings, or has an
          empty entry;
        * self-supersession;
        * a `supersedes` target that is no record's id;
        * conflicting declarations: several records superseding the same old
          record. Resolved deterministically by rejection, not by last-write
          -wins: all declarers are named (sorted) and the old record gets no
          exemption until the metadata is reconciled;
        * cycles (no surviving current record in the chain).

        No timestamp ordering is applied and no record is ever rewritten.
        """
        claimed: dict = {}  # record_id -> [rel paths]
        declared: list = []  # (rel, record_id, [targets])
        for record in records:
            rel = record.relative_to(self.root).as_posix()
            meta = self._read_meta(record)
            if not isinstance(meta, dict):
                continue  # reported by _audit_record
            rid = meta.get("record_id")
            if not isinstance(rid, str) or not rid.strip():
                self.fail(f"{rel}: record-meta has a missing or invalid record_id -- "
                          f"supersession identity is undefined")
                continue
            claimed.setdefault(rid, []).append(rel)
            sup = meta.get("supersedes")
            if sup is None or sup == [] or sup == "":
                targets = []
            elif isinstance(sup, str):
                targets = [sup]
            elif isinstance(sup, list) and all(isinstance(t, str) and t.strip() for t in sup):
                targets = list(sup)
            else:
                self.fail(f"{rel}: record {rid}: `supersedes` must be a record_id string or a "
                          f"list of non-empty record_id strings, got {sup!r}")
                continue
            declared.append((rel, rid, targets))

        ambiguous = set()
        for rid, rels in sorted(claimed.items()):
            if len(rels) > 1:
                ambiguous.add(rid)
                self.fail(f"duplicate record_id {rid!r} claimed by {', '.join(sorted(rels))}")

        by_old: dict = {}  # old id -> sorted list of declaring successor ids
        for rel, rid, targets in declared:
            if rid in ambiguous:
                continue
            for old in targets:
                if old == rid:
                    self.fail(f"{rel}: record {rid} supersedes itself")
                elif old not in claimed:
                    self.fail(f"{rel}: record {rid} supersedes unknown record_id {old!r}")
                elif old in ambiguous:
                    self.fail(f"{rel}: record {rid} supersedes {old!r}, whose record_id is "
                              f"duplicated -- target is ambiguous")
                else:
                    by_old.setdefault(old, []).append(rid)

        unique: dict = {}
        for old, succs in sorted(by_old.items()):
            succs = sorted(set(succs))
            if len(succs) > 1:
                self.fail(f"conflicting supersession of {old!r}: declared by "
                          f"{', '.join(succs)} -- reconcile so exactly one record supersedes it")
            else:
                unique[old] = succs[0]

        for old in sorted(unique):
            seen = [old]
            cur = unique[old]
            while cur in unique and cur not in seen:
                seen.append(cur)
                cur = unique[cur]
            if cur in seen:
                cycle = seen[seen.index(cur):] + [cur]
                self.fail(f"supersession cycle {' -> '.join(cycle)}: no surviving current "
                          f"record; {old!r} is not exempted")
                continue
            if cur in by_old:  # head itself has a conflicted successor
                continue
            self.superseded_by[old] = unique[old]

    def _read_meta(self, record: Path):
        match = _RECORD_META_RE.search(record.read_text())
        if not match:
            return None
        try:
            return json.loads(match.group(1))
        except json.JSONDecodeError:
            return None

    def _audit_record(self, record: Path) -> None:
        rel = record.relative_to(self.root).as_posix()
        match = _RECORD_META_RE.search(record.read_text())
        if not match:
            self.fail(f"{rel}: no record-meta header -- claim is untraceable")
            return
        try:
            meta = json.loads(match.group(1))
        except json.JSONDecodeError as exc:
            self.fail(f"{rel}: record-meta is not valid JSON ({exc})")
            return

        record_id = meta.get("record_id")
        if not isinstance(record_id, str) or not record_id.strip():
            record_id = rel  # identity failure already reported in pass 1
        successor = self.superseded_by.get(record_id)
        print(f"--- {rel}{f'  [superseded by {successor}]' if successor else ''}")

        harness = meta.get("harness")
        if not harness:
            self.fail(f"{record_id}: record-meta names no harness")
        elif not (self.root / harness).exists():
            self.fail(f"{record_id}: harness {harness} does not exist in the tree")
        else:
            self.ok(f"{record_id}: harness {harness} committed")

        pdk = (meta.get("provenance") or {}).get("pdk") or {}
        version = pdk.get("version")
        if not version:
            self.fail(f"{record_id}: record-meta pins no PDK version")
        elif version != self.recorded_pdk:
            self.fail(
                f"{record_id}: pinned PDK {version!r} != flow/tool_versions.sh's "
                f"RECORDED_PDK_VERSION {self.recorded_pdk!r}"
            )
        else:
            self.ok(f"{record_id}: PDK pinned, {version}")

        for entry in (meta.get("provenance") or {}).get("inputs", []):
            self._audit_input(record_id, entry)

    def _audit_input(self, record_id: str, entry: dict) -> None:
        path = entry.get("path", "<unnamed>")
        expected = entry.get("content_hash", "")
        role = entry.get("role", "")
        target = self.root / path

        if not target.exists():
            if "not committed" in role:
                self.note(f"{record_id}: {path} not committed (regenerated), as its role states")
            else:
                self.fail(f"{record_id}: pinned input {path} is missing from the tree")
            return

        actual = "sha256:" + hashlib.sha256(target.read_bytes()).hexdigest()
        if actual == expected:
            self.ok(f"{record_id}: {path} matches its pinned hash")
            return

        successor = self.superseded_by.get(record_id)
        allowance = ALLOWED_INPUT_DRIFT.get((record_id, path))
        if successor:
            self.note(
                f"{record_id}: {path} drifted from its pinned hash "
                f"({expected} -> {actual}) -- expected: this record is superseded by "
                f"{successor}, which pins the current tree. A superseded record pins "
                f"the tree as it was."
            )
        elif allowance:
            self.note(f"{record_id}: {path} drifted from its pinned hash -- allowed: {allowance}")
        else:
            self.fail(
                f"{record_id}: {path} no longer hashes to the value this record pins "
                f"({expected} -> {actual}). If the change is deliberate and cannot move the "
                f"record's numbers, add it to ALLOWED_INPUT_DRIFT with the commit and why; "
                f"otherwise the record needs a successor, not an edit."
            )

    # --- 3. committed report JSONs ---------------------------------------

    def audit_report_pdk_pins(self) -> None:
        reports = sorted(
            set(self.root.glob("layout/**/*.json")) | set(self.root.glob("measurements/**/*.json"))
        )
        print(f"=== committed report JSONs: {len(reports)} under layout/** + measurements/** ===")
        pinned = 0
        for report in reports:
            rel = report.relative_to(self.root).as_posix()
            try:
                doc = json.loads(report.read_text())
            except json.JSONDecodeError as exc:
                self.fail(f"{rel}: not valid JSON ({exc})")
                continue
            if not isinstance(doc, dict) or "provenance" not in doc:
                self.note(f"{rel}: no provenance block (not a klt report)")
                continue
            pdk = (doc.get("provenance") or {}).get("pdk")
            if isinstance(pdk, dict):
                if pdk.get("version") != self.recorded_pdk:
                    self.fail(
                        f"{rel}: provenance.pdk.version {pdk.get('version')!r} != "
                        f"RECORDED_PDK_VERSION {self.recorded_pdk!r}"
                    )
                else:
                    pinned += 1
            elif rel in PDK_NULL_UPSTREAM_GAP:
                self.note(f"{rel}: provenance.pdk is null -- {PDK_NULL_UPSTREAM_GAP[rel]}")
            else:
                self.fail(
                    f"{rel}: provenance.pdk is null and is not a known upstream gap -- "
                    f"this claim records no PDK revision (T1 item 9)"
                )
        if pinned:
            self.ok(f"{pinned} report(s) pin {self.recorded_pdk}")


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recorded-pdk", required=True)
    parser.add_argument("--repo-root", default=None)
    args = parser.parse_args(argv[1:])

    root = Path(args.repo_root) if args.repo_root else Path(__file__).resolve().parent.parent
    audit = Audit(root.resolve(), args.recorded_pdk)

    audit.audit_records()
    audit.audit_report_pdk_pins()

    print()
    if audit.failures:
        print(f"=== evidence audit FAILED -- {len(audit.failures)} problem(s) ===")
        for failure in audit.failures:
            print(f"  - {failure}")
        return 1
    print("=== evidence audit clean: every record traceable, every claim PDK-pinned ===")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
