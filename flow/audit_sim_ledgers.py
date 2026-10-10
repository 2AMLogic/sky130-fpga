#!/usr/bin/env python3
"""Append-only guard for the sim/ evidence ledgers (issue #183).

CLAUDE.md: "`sim/` results are append-only evidence". This check enforces it
mechanically at PR time by comparing two git trees, never the working tree:

  baseline = git merge-base <base> <head>
  head     = the PR head commit itself (NOT a synthetic checkout merge)

For every protected ledger, the baseline bytes must be a byte-for-byte prefix
of the head bytes. Editing, reordering, truncating, deleting or renaming away
an existing ledger fails; appending passes. A correction is an *appended*,
dated supersession entry naming the earlier entry; it never licenses a change
to the protected prefix (see flow/README.md).

Protection set = union of
  * LEDGERS below, as read from the baseline tree and from the head tree
    (and from this running copy), and
  * candidates discovered in the baseline tree: every sim/*results.txt and
    every sim/**/*.txt declaring an append-only evidence-record header.
So removing a LEDGERS entry or stripping a header cannot drop protection of a
ledger the baseline already had. On first introduction the guard is absent
from the baseline; that is detected as a proven absence (git ls-tree answers
"no such path"), not inferred from a failed read.

Head-side rules: every candidate discovered in the head tree must be listed in
the head's LEDGERS (an unlisted new ledger fails with its path), every LEDGERS
entry must exist in the head, and every baseline-protected ledger must still
be listed.

Any git failure (missing ref, unavailable merge base, shallow history,
unreadable object) exits 2 with a diagnostic; nothing is skipped or treated as
an empty file. Exit 1 = ledger violation, 0 = clean. stdlib only.

    python3 -I flow/audit_sim_ledgers.py --base origin/main --head HEAD
    python3 -I flow/audit_sim_ledgers.py -C <repo> --base <sha> --head <sha>
"""
import argparse
import ast
import re
import subprocess
import sys
from pathlib import Path

# The single protection table. Add a new ledger here in the same PR that
# introduces it; never remove an entry (removal fails the check).
LEDGERS = (
    "sim/configmem_fabulous_equiv.txt",
    "sim/generated_tile_replay.txt",
    "sim/logic_tile_bitstream_gate_results.txt",
    "sim/logic_tile_bitstream_results.txt",
    "sim/logic_tile_routed_gate_results.txt",
    "sim/rtl_mutation_results.txt",
    "sim/switch_matrix_fabulous_equiv.txt",
)

GUARD_PATH = "flow/audit_sim_ledgers.py"
TABLE_NAME = "LEDGERS"
HEADER_RE = re.compile(rb"append[- ]only evidence record", re.IGNORECASE)
HEADER_LINES = 10
RESULTS_RE = re.compile(r"^sim/[^/]*results\.txt$")
TXT_RE = re.compile(r"^sim/.+\.txt$")


class GitError(Exception):
    """A git query could not be answered; never a 'file is empty' signal."""


class Git:
    def __init__(self, repo):
        self.repo = str(repo)

    def run(self, *args, ok=(0,)):
        cmd = ["git", "-C", self.repo, *args]
        try:
            p = subprocess.run(cmd, capture_output=True)
        except OSError as e:
            raise GitError(f"cannot run {' '.join(cmd)}: {e}") from e
        if p.returncode not in ok:
            err = p.stderr.decode(errors="replace").strip()
            raise GitError(f"`{' '.join(cmd)}` exited {p.returncode}: {err}")
        return p

    def commit(self, rev, what):
        if not rev:
            raise GitError(f"{what} revision is empty (pass an explicit SHA)")
        p = self.run("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}",
                     ok=(0, 1))
        sha = p.stdout.decode().strip()
        if p.returncode != 0 or not sha:
            raise GitError(
                f"{what} revision {rev!r} is not available in this clone; "
                "fetch it (CI: actions/checkout fetch-depth: 0, then "
                "`git fetch origin <sha>`)")
        return sha

    def merge_base(self, a, b):
        p = self.run("rev-parse", "--is-shallow-repository")
        if p.stdout.decode().strip() == "true":
            raise GitError(
                "repository is shallow; the merge base cannot be trusted. "
                "Fetch full history (fetch-depth: 0 / git fetch --unshallow)")
        p = self.run("merge-base", a, b, ok=(0, 1))
        mb = p.stdout.decode().strip()
        if p.returncode != 0 or not mb:
            raise GitError(f"no merge base between {a} and {b}; history "
                           "unavailable or unrelated")
        return mb

    def tree(self, commit):
        """{path: blob_oid} for every blob under sim/ and the guard path."""
        p = self.run("ls-tree", "-r", "-z", commit, "--", "sim", GUARD_PATH)
        out = {}
        for rec in p.stdout.split(b"\0"):
            if not rec:
                continue
            meta, _, path = rec.partition(b"\t")
            parts = meta.split()
            if len(parts) != 3:
                raise GitError(f"unparseable ls-tree record {rec!r}")
            if parts[1] == b"blob":
                out[path.decode("utf-8", "surrogateescape")] = parts[2].decode()
        return out

    def blob(self, oid):
        return self.run("cat-file", "blob", oid).stdout


def parse_table(src, where):
    """LEDGERS tuple from a guard's source, without executing it."""
    try:
        mod = ast.parse(src)
    except SyntaxError as e:
        raise GitError(f"{where}: guard source does not parse: {e}") from e
    for node in mod.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id == TABLE_NAME):
            try:
                val = ast.literal_eval(node.value)
            except ValueError as e:
                raise GitError(f"{where}: {TABLE_NAME} is not a literal") from e
            if (not isinstance(val, (tuple, list))
                    or not all(isinstance(v, str) for v in val)):
                raise GitError(f"{where}: {TABLE_NAME} is not a list of paths")
            return set(val)
    raise GitError(f"{where}: no {TABLE_NAME} table in {GUARD_PATH}")


def declares_header(data):
    head = b"\n".join(data.split(b"\n", HEADER_LINES)[:HEADER_LINES])
    return bool(HEADER_RE.search(head))


class Snapshot:
    """One commit's ledger view: blobs, guard table, discovered candidates."""

    def __init__(self, git, commit, label):
        self.git, self.commit, self.label = git, commit, label
        self.files = git.tree(commit)
        self._cache = {}
        if GUARD_PATH in self.files:
            src = self.read(GUARD_PATH).decode("utf-8", "replace")
            self.table = parse_table(src, f"{label} {commit[:12]}")
        else:
            self.table = None  # proven absent: ls-tree succeeded without it
        self.candidates = set()
        for path in self.files:
            if RESULTS_RE.match(path):
                self.candidates.add(path)
            elif TXT_RE.match(path) and declares_header(self.read(path)):
                self.candidates.add(path)

    def read(self, path):
        if path not in self._cache:
            self._cache[path] = self.git.blob(self.files[path])
        return self._cache[path]


def first_diff(old, new):
    n = min(len(old), len(new))
    i = next((k for k in range(n) if old[k] != new[k]), n)
    return old.count(b"\n", 0, i) + 1


def compare(base, head, own_table=frozenset(LEDGERS)):
    """List of violation strings for baseline snapshot -> head snapshot."""
    failures = []
    base_table = base.table or set()
    head_table = head.table
    if base.table is not None and head_table is None:
        failures.append(f"{GUARD_PATH} (and its {TABLE_NAME} table) was "
                        "removed from the head")
    head_table = head_table or set()

    protected = sorted(p for p in (base_table | base.candidates
                                   | head_table | set(own_table))
                       if p in base.files)
    for path in protected:
        if path not in head.files:
            failures.append(f"{path}: protected ledger deleted or renamed "
                            "away in the head")
            continue
        old, new = base.read(path), head.read(path)
        if not new.startswith(old):
            if len(new) < len(old) and old.startswith(new):
                why = (f"truncated ({len(old)} -> {len(new)} bytes)")
            else:
                why = (f"existing content rewritten (first difference at "
                       f"line {first_diff(old, new)})")
            failures.append(f"{path}: not append-only: {why}; append a dated "
                            "supersession entry instead")
        if path not in head_table:
            failures.append(f"{path}: protected ledger is missing from the "
                            f"head's {TABLE_NAME} table")

    for path in sorted(head.candidates - head_table):
        failures.append(f"{path}: unlisted ledger candidate; add it to "
                        f"{TABLE_NAME} in {GUARD_PATH}")
    for path in sorted(head_table - set(head.files)):
        if path not in base.files:
            failures.append(f"{path}: listed in {TABLE_NAME} but absent from "
                            "the head")
    return failures


def check(repo, base_rev, head_rev, out=None):
    """Return exit status: 0 clean, 1 violations. Raises GitError."""
    out = out or sys.stdout
    git = Git(repo)
    base_sha = git.commit(base_rev, "base")
    head_sha = git.commit(head_rev, "head")
    mb = git.merge_base(base_sha, head_sha)
    base = Snapshot(git, mb, "baseline")
    head = Snapshot(git, head_sha, "head")
    failures = compare(base, head)
    print(f"sim ledger guard: baseline {mb[:12]} (merge-base of base "
          f"{base_sha[:12]} and head {head_sha[:12]}) -> head "
          f"{head_sha[:12]}", file=out)
    if base.table is None:
        print(f"  baseline has no {GUARD_PATH} (first introduction); "
              "protection from baseline discovery only", file=out)
    checked = sorted(p for p in (base.table or set()) | base.candidates
                     | (head.table or set()) | head.candidates)
    for p in checked:
        print(f"  ledger {p}", file=out)
    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=out)
        print(f"sim ledger guard: {len(failures)} violation(s)", file=out)
        return 1
    print(f"sim ledger guard: OK ({len(checked)} ledgers append-only)",
          file=out)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-C", dest="repo", default=".", help="repository path")
    ap.add_argument("--base", required=True,
                    help="PR base commit (CI: pull_request.base.sha)")
    ap.add_argument("--head", required=True,
                    help="PR head commit (CI: pull_request.head.sha); never "
                         "the synthetic merge checkout")
    a = ap.parse_args(argv)
    try:
        return check(Path(a.repo), a.base, a.head)
    except GitError as e:
        print(f"ERROR: sim ledger guard could not run: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
