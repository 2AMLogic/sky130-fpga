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
   -- some other record's `record-meta` names it in `supersedes` -- or (b)
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
   under `layout/` or `measurements/` carrying `provenance.pdk` must name
   exactly the pinned revision. A report whose `provenance.pdk` is `null`
   is FAIL unless it is in `PDK_NULL_UPSTREAM_GAP` -- the reports produced
   by `klt drc` / `klt lvs`, which emit `provenance.pdk: null` even when
   invoked with `--pdk sky130A` (klayout-tools#1901) and are therefore
   pinned by `flow/tool_versions.sh`'s run-time banner instead. Listing
   them explicitly is what stops a *new* PDK-less report type from quietly
   joining them.

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
}

# Committed reports whose `provenance.pdk` is null for a filed upstream
# reason rather than because nobody pinned the PDK. These inherit their pin
# from flow/tool_versions.sh's RECORDED_PDK_VERSION banner, printed by
# flow/drc.sh and flow/lvs.sh at run time.
PDK_NULL_UPSTREAM_GAP = {
    "layout/logic_tile.drc.json": (
        "klt drc writes provenance.pdk: null even when given --pdk sky130A "
        "(klayout-tools#1901); pinned by flow/drc.sh's banner instead."
    ),
    "layout/logic_tile.lvs.json": (
        "klt lvs writes provenance.pdk: null (klayout-tools#1901); pinned by "
        "flow/lvs.sh's banner instead."
    ),
    "layout/logic_tile.erc.json": (
        "klt erc writes no provenance block at all (klayout-tools#2036); "
        "flow/erc_report_trim.py synthesizes the drc-shaped one this report "
        "carries, and flow/erc.sh's banner pins the PDK."
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
        # Pass 1: build the supersession map, so a record's disposition does
        # not depend on whether its successor sorts before or after it.
        for record in records:
            meta = self._read_meta(record)
            if not meta:
                continue
            successor = meta.get("record_id")
            supersedes = meta.get("supersedes")
            for old in [supersedes] if isinstance(supersedes, str) else (supersedes or []):
                if old:
                    self.superseded_by[old] = successor
        # Pass 2: audit.
        for record in records:
            self._audit_record(record)

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

        record_id = meta.get("record_id", rel)
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
            set(self.root.glob("layout/*.json")) | set(self.root.glob("measurements/**/*.json"))
        )
        print(f"=== committed report JSONs: {len(reports)} under layout/ + measurements/ ===")
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
