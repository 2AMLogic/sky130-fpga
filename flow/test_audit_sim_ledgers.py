#!/usr/bin/env python3
"""Unit tests for flow/audit_sim_ledgers.py (issue #183): the sim/ ledger
append-only guard, on disposable git repositories, plus a trigger regression
check of .github/workflows/flow-evidence.yml. stdlib only; no committed
evidence file is touched (the real repository is only read).

    python3 -I flow/test_audit_sim_ledgers.py
"""
import importlib.util
import io
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location(
    "audit_sim_ledgers", REPO / "flow" / "audit_sim_ledgers.py")
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)

WORKFLOW = REPO / ".github" / "workflows" / "flow-evidence.yml"
HDR = "# Append-only evidence record (issue #0). Add new dated entries below.\n"
LEDGER = HDR + "2026-10-01  run A\n  PASS 10/10\n2026-10-02  run B\n  PASS 4/4\n"
OTHER = HDR + "2026-10-01  equiv\n  PASS\n"
GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
SEVEN = {
    "sim/configmem_fabulous_equiv.txt",
    "sim/generated_tile_replay.txt",
    "sim/logic_tile_bitstream_gate_results.txt",
    "sim/logic_tile_bitstream_results.txt",
    "sim/logic_tile_routed_gate_results.txt",
    "sim/rtl_mutation_results.txt",
    "sim/switch_matrix_fabulous_equiv.txt",
}


def table_src(*paths):
    body = "".join(f"    {p!r},\n" for p in paths)
    return f'"""stand-in guard"""\nLEDGERS = (\n{body})\n'


class Repo:
    def __init__(self, root):
        self.root = root
        root.mkdir(parents=True)
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        env = dict(os.environ, **GIT_ENV)
        p = subprocess.run(["git", "-C", str(self.root), *args], env=env,
                           capture_output=True, text=True)
        if p.returncode:
            raise AssertionError(f"git {args}: {p.stderr}")
        return p.stdout.strip()

    def write(self, path, text):
        f = self.root / path
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)

    def rm(self, path):
        self.git("rm", "-q", path)

    def commit(self, msg="c"):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD")


class GuardBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.r = Repo(self.tmp / "repo")

    def run_guard(self, base, head, repo=None):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = L.main(["-C", str(repo or self.r.root),
                         "--base", base, "--head", head])
        self.out = out.getvalue() + err.getvalue()
        return rc

    def assertPass(self, base, head):
        self.assertEqual(self.run_guard(base, head), 0, self.out)

    def assertFail(self, base, head, *needles, rc=1):
        self.assertEqual(self.run_guard(base, head), rc, self.out)
        for n in needles:
            self.assertIn(n, self.out)


class AppendOnly(GuardBase):
    """Baseline already carries the guard and two listed ledgers."""

    def setUp(self):
        super().setUp()
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt",
                                             "sim/b_equiv.txt"))
        self.r.write("sim/a_results.txt", LEDGER)
        self.r.write("sim/b_equiv.txt", OTHER)
        self.r.write("sim/allowlist.txt", "# id | why\nX | unobservable\n")
        self.r.write("sim/corpus/index.txt", "q1 quad\n")
        self.base = self.r.commit("base")
        self.r.git("checkout", "-q", "-b", "pr")

    def test_unchanged_passes(self):
        self.assertPass(self.base, self.r.commit("noop"))
        self.assertIn("ledger sim/a_results.txt", self.out)
        self.assertNotIn("allowlist", self.out)
        self.assertNotIn("index.txt", self.out)

    def test_append_passes(self):
        self.r.write("sim/a_results.txt", LEDGER + "2026-10-03  run C\n  PASS\n")
        self.assertPass(self.base, self.r.commit())

    def test_supersession_append_passes(self):
        self.r.write("sim/a_results.txt", LEDGER +
                     "2026-10-03  SUPERSEDES 2026-10-02 run B: count was 4/5,"
                     " not 4/4 (miscounted); corrected entry follows\n"
                     "  PASS 4/5\n")
        self.assertPass(self.base, self.r.commit())

    def test_edit_fails(self):
        self.r.write("sim/a_results.txt", LEDGER.replace("PASS 4/4", "PASS 5/5"))
        self.assertFail(self.base, self.r.commit(), "sim/a_results.txt",
                        "not append-only", "line 5")

    def test_fail_to_pass_flip_fails(self):
        self.r.write("sim/b_equiv.txt", OTHER.replace("PASS", "FAIL"))
        self.r.commit()
        self.r.write("sim/b_equiv.txt", OTHER)
        self.assertPass(self.base, self.r.commit())  # net no-op is fine
        self.r.write("sim/b_equiv.txt", OTHER.replace("  PASS", "  PASS!"))
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt")

    def test_prefix_edit_with_supersession_still_fails(self):
        self.r.write("sim/a_results.txt",
                     LEDGER.replace("PASS 4/4", "PASS 4/5") +
                     "2026-10-03  SUPERSEDES 2026-10-02 run B: 4/5 not 4/4\n")
        self.assertFail(self.base, self.r.commit(), "not append-only")

    def test_reorder_fails(self):
        lines = LEDGER.splitlines(keepends=True)
        self.r.write("sim/a_results.txt",
                     "".join(lines[:1] + lines[3:] + lines[1:3]))
        self.assertFail(self.base, self.r.commit(), "not append-only")

    def test_truncate_fails(self):
        self.r.write("sim/a_results.txt", LEDGER[:-10])
        self.assertFail(self.base, self.r.commit(), "truncated")

    def test_empty_fails(self):
        self.r.write("sim/a_results.txt", "")
        self.assertFail(self.base, self.r.commit(), "truncated")

    def test_delete_fails(self):
        self.r.rm("sim/a_results.txt")
        self.assertFail(self.base, self.r.commit(), "sim/a_results.txt",
                        "deleted or renamed away")

    def test_rename_away_fails(self):
        (self.r.root / "sim/old").mkdir()
        self.r.git("mv", "sim/b_equiv.txt", "sim/old/b_equiv.txt")
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt",
                                             "sim/old/b_equiv.txt"))
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt",
                        "deleted or renamed away")

    def test_new_listed_ledgers_pass(self):
        self.r.write(L.GUARD_PATH, table_src(
            "sim/a_results.txt", "sim/b_equiv.txt", "sim/c_results.txt",
            "sim/deep/new_record.txt"))
        self.r.write("sim/c_results.txt", "2026-10-03  new\n")
        self.r.write("sim/deep/new_record.txt", OTHER)
        self.assertPass(self.base, self.r.commit())
        self.assertIn("ledger sim/deep/new_record.txt", self.out)

    def test_unlisted_results_fails(self):
        self.r.write("sim/c_results.txt", "2026-10-03  new\n")
        self.assertFail(self.base, self.r.commit(), "sim/c_results.txt",
                        "unlisted ledger candidate")

    def test_unlisted_declared_ledger_fails(self):
        self.r.write("sim/deep/new_record.txt", OTHER)
        self.assertFail(self.base, self.r.commit(), "sim/deep/new_record.txt",
                        "unlisted ledger candidate")

    def test_listed_but_missing_fails(self):
        self.r.write(L.GUARD_PATH, table_src(
            "sim/a_results.txt", "sim/b_equiv.txt", "sim/ghost_results.txt"))
        self.assertFail(self.base, self.r.commit(), "sim/ghost_results.txt",
                        "absent from the head")

    def test_table_removal_fails(self):
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt"))
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt",
                        "missing from the head's LEDGERS")

    def test_table_removal_and_header_strip_fails(self):
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt"))
        self.r.write("sim/b_equiv.txt", OTHER.replace(HDR, "# notes\n"))
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt",
                        "not append-only", "missing from the head's LEDGERS")

    def test_guard_removed_fails(self):
        self.r.rm(L.GUARD_PATH)
        self.assertFail(self.base, self.r.commit(), "was removed from the head")

    def test_unparseable_head_table_is_error(self):
        self.r.write(L.GUARD_PATH, "LEDGERS = tuple(x for x in ())\n")
        self.assertFail(self.base, self.r.commit(), "not a literal", rc=2)


class FirstIntroduction(GuardBase):
    """The baseline predates the guard: protection comes from discovery."""

    def setUp(self):
        super().setUp()
        self.r.write("sim/a_results.txt", LEDGER)
        self.r.write("sim/b_equiv.txt", OTHER)
        self.base = self.r.commit("base")
        self.r.git("checkout", "-q", "-b", "pr")

    def test_introduction_listing_all_passes(self):
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt",
                                             "sim/b_equiv.txt"))
        self.assertPass(self.base, self.r.commit())
        self.assertIn("first introduction", self.out)

    def test_introduction_omitting_one_fails(self):
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt"))
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt")

    def test_introduction_with_edit_fails(self):
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt",
                                             "sim/b_equiv.txt"))
        self.r.write("sim/b_equiv.txt", "# notes\n2026-10-01 equiv\n  PASS\n")
        self.assertFail(self.base, self.r.commit(), "sim/b_equiv.txt",
                        "not append-only")


class Baseline(GuardBase):
    def setUp(self):
        super().setUp()
        self.r.write(L.GUARD_PATH, table_src("sim/a_results.txt"))
        self.r.write("sim/a_results.txt", LEDGER)
        self.fork = self.r.commit("fork")
        # base branch moves on after the fork
        self.r.write("sim/a_results.txt", LEDGER + "2026-10-05  main-side run\n")
        self.base = self.r.commit("main appends")
        self.r.git("checkout", "-q", "-b", "pr", self.fork)

    def test_divergent_append_compares_merge_base(self):
        self.r.write("sim/a_results.txt", LEDGER + "2026-10-04  pr-side run\n")
        head = self.r.commit("pr appends")
        # base tip vs head would look like a rewrite; merge base vs head is fine
        self.assertPass(self.base, head)
        self.assertIn(f"baseline {self.fork[:12]}", self.out)

    def test_divergent_edit_fails(self):
        self.r.write("sim/a_results.txt", LEDGER.replace("run A", "run Z"))
        self.assertFail(self.base, self.r.commit(), "not append-only")

    def test_synthetic_merge_cannot_stand_in_for_head(self):
        self.r.write("sim/a_results.txt", LEDGER.replace("run A", "run Z"))
        head = self.r.commit("pr rewrites")
        # Emulate actions/checkout: HEAD is a merge of head into base whose
        # tree (strategy ours) hides the head's rewrite.
        self.r.git("checkout", "-q", "--detach", self.base)
        self.r.git("merge", "-q", "-s", "ours", "--no-edit", head)
        merge = self.r.git("rev-parse", "HEAD")
        self.assertNotEqual(merge, head)
        self.assertEqual(self.run_guard(self.base, merge), 0, self.out)
        self.assertFail(self.base, head, "not append-only")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            L.main(["-C", str(self.r.root), "--base", self.base])

    def test_missing_ref_is_error(self):
        self.assertFail(self.base, "0" * 40, "head revision", "not available",
                        rc=2)
        self.assertFail("", self.base, "base revision is empty", rc=2)

    def test_unrelated_history_is_error(self):
        self.r.git("checkout", "-q", "--orphan", "lonely")
        head = self.r.commit("orphan")
        self.assertFail(self.base, head, "no merge base", rc=2)

    def test_shallow_clone_is_error(self):
        clone = self.tmp / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--no-local",
                        "-b", "main", f"file://{self.r.root}", str(clone)],
                       env=dict(os.environ, **GIT_ENV), check=True,
                       capture_output=True)
        rc = self.run_guard(self.base, self.base, repo=clone)
        self.assertEqual(rc, 2, self.out)
        self.assertIn("shallow", self.out)
        rc = self.run_guard(self.base, self.fork, repo=clone)
        self.assertEqual(rc, 2, self.out)
        self.assertIn("not available", self.out)

    def test_failed_blob_read_is_error_not_empty(self):
        self.r.write("sim/a_results.txt", LEDGER + "2026-10-04  pr-side\n")
        head = self.r.commit()
        oid = self.r.git("rev-parse", f"{self.fork}:sim/a_results.txt")
        obj = self.r.root / ".git" / "objects" / oid[:2] / oid[2:]
        self.assertTrue(obj.exists(), "test expects loose objects")
        obj.unlink()
        self.assertFail(self.base, head, "could not run", rc=2)

    def test_not_a_repository_is_error(self):
        (self.tmp / "plain").mkdir()
        rc = self.run_guard(self.base, self.base, repo=self.tmp / "plain")
        self.assertEqual(rc, 2, self.out)


class RealRepository(unittest.TestCase):
    """Read-only: the committed table covers every committed ledger."""

    def test_table_is_the_seven_ledgers(self):
        self.assertEqual(set(L.LEDGERS), SEVEN)
        self.assertEqual(len(L.LEDGERS), len(SEVEN))

    def test_head_candidates_are_listed(self):
        git = L.Git(REPO)
        try:
            snap = L.Snapshot(git, git.commit("HEAD", "head"), "head")
        except L.GitError as e:
            self.skipTest(f"no readable git checkout: {e}")
        self.assertEqual(snap.candidates - set(L.LEDGERS), set())
        self.assertNotIn("sim/mutation_allowlist.txt", snap.candidates)
        self.assertNotIn("sim/bitstream/corpus/index.txt", snap.candidates)


def gh_glob(pattern):
    """GitHub Actions paths filter glob -> regex (** crosses '/', * not)."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def workflow_paths(text):
    m = re.search(r"^  pull_request:\n    paths:\n((?:      - .*\n)+)", text,
                  re.MULTILINE)
    if not m:
        raise AssertionError("pull_request.paths block not found")
    return [line.split("- ", 1)[1].strip().strip("'\"")
            for line in m.group(1).splitlines()]


class WorkflowTrigger(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.pats = [gh_glob(p) for p in workflow_paths(self.text)]

    def selects(self, path):
        return any(p.match(path) for p in self.pats)

    def test_selected_paths(self):
        for path in sorted(SEVEN) + [
                "sim/new_thing_results.txt",           # new unlisted results
                "sim/deep/dir/new_record.txt",         # new declared ledger
                "sim/README.md",
                "flow/audit_sim_ledgers.py",
                "flow/test_audit_sim_ledgers.py",
                ".github/workflows/flow-evidence.yml"]:
            self.assertTrue(self.selects(path), path)

    def test_glob_sanity(self):
        self.assertFalse(gh_glob("sim/*.txt").match("sim/a/b.txt"))
        self.assertTrue(gh_glob("sim/**").match("sim/a/b.txt"))
        self.assertFalse(self.selects("design/rtl/lut4_slice.v"))

    def test_full_history_and_env_shas(self):
        self.assertRegex(self.text, r"actions/checkout@v4\n\s+with:\n\s+"
                                    r"fetch-depth: 0\n")
        self.assertIn("LEDGER_BASE_SHA: ${{ github.event.pull_request.base.sha }}",
                      self.text)
        self.assertIn("LEDGER_HEAD_SHA: ${{ github.event.pull_request.head.sha }}",
                      self.text)
        self.assertIn('--base "$LEDGER_BASE_SHA" --head "$LEDGER_HEAD_SHA"',
                      self.text)
        self.assertIn("python3 -I flow/test_audit_sim_ledgers.py", self.text)

    def test_no_expression_interpolated_into_run(self):
        for block in re.findall(r"run: \|\n((?:          .*\n|\s*\n)+)",
                                self.text):
            self.assertNotIn("${{", block)


if __name__ == "__main__":
    unittest.main(verbosity=1)
