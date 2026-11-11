"""Behavior tests for scripts/mutate.py (the negative-control runner).

Run: python tests/test_mutate.py   (or python -m unittest tests.test_mutate / pytest)

Each safeguard in the script has at least one test named after it. Runner parsing is
tested against REAL captured output (pytest 9.2.0, go 1.26.7, Python 3.11.9 unittest,
captured on Windows) except vitest and jest, whose fixtures are synthetic, written from
the documented format: those two are NOT verified against real output.
Integration tests that need pytest or go skip when the tool is not installed
(point MUTATE_TEST_PYTEST_PYTHON at a Python that has pytest).
"""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
MUTATE = ROOT / 'scripts' / 'mutate.py'
PY = sys.executable
_spec = importlib.util.spec_from_file_location('mutate_under_test', MUTATE)
M = importlib.util.module_from_spec(_spec)
sys.modules['mutate_under_test'] = M          # dataclasses resolves string annotations through sys.modules
_spec.loader.exec_module(M)

APP = b'def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n\n\ndef unused():\n    return 1\n'
TEST_APP = (b'import unittest\nimport app\n\n\nclass T(unittest.TestCase):\n'
            b'    def test_add(self):\n        self.assertEqual(app.add(2, 3), 5)\n\n'
            b'    def test_sub(self):\n        self.assertEqual(app.sub(5, 3), 2)\n')
UT_CMD = '"%s" -m unittest test_app' % PY
VALUE_APP = b'VALUE = 0\n'                      # the fixture of the scripted-check tests
CHECK_CMD = '"%s" check.py' % PY
RAN = ['--runner', 'none', '--ran-pattern', 'RAN OK']


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pid_alive(pid: int) -> bool:
    if os.name == 'nt':                          # os.kill(pid, 0) would TERMINATE on Windows
        out = subprocess.run(['tasklist', '/FI', 'PID eq %d' % pid, '/NH'], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def pytest_python():
    for cand in (os.environ.get('MUTATE_TEST_PYTEST_PYTHON'), sys.executable):
        if cand and subprocess.run([cand, '-m', 'pytest', '--version'], capture_output=True).returncode == 0:
            return cand
    return None


class Run:
    def __init__(self, cp):
        self.rc = cp.returncode
        self.out = cp.stdout.decode('utf-8', 'replace')
        self.err = cp.stderr.decode('utf-8', 'replace')

    def verdicts(self):
        return [ln.split()[0] for ln in self.out.splitlines()
                if ln.split() and ln.split()[0] in ('RED', 'GREEN', 'RED_WRONG', 'NOT_RUN',
                                                    'BASELINE_RED', 'BASELINE_NOT_RUN')]


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix='mutate-test-')
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        # the script's temp dir (backups, pyc prefixes) is private to each test, so one test's
        # leftovers can never be seen by another and the real temp dir is never touched
        self._scratch = tempfile.TemporaryDirectory(prefix='mutate-test-tmp-')
        self.addCleanup(self._scratch.cleanup)
        self.tmp = Path(self._scratch.name)

    def backups(self):
        return sorted(p.name for p in self.tmp.glob('mutate-backup-*'))

    def write(self, name, data):
        path = self.dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode('utf-8'))
        return path

    def read(self, name):
        return (self.dir / name).read_bytes()

    def mutate(self, *args, env=None, timeout=180):
        e = dict(os.environ, TMP=str(self.tmp), TEMP=str(self.tmp), TMPDIR=str(self.tmp), **(env or {}))
        return Run(subprocess.run([PY, str(MUTATE), *args], cwd=self.dir, env=e,
                                  capture_output=True, timeout=timeout))

    def unit_project(self):
        self.write('app.py', APP)
        self.write('test_app.py', TEST_APP)

    def scripted(self, body, app=VALUE_APP):
        """check.py: `mutated` is True while app.py contains the mutation (VALUE = 1)."""
        self.write('app.py', app)
        self.write('check.py', 'import os, sys, time\nsrc = open("app.py", "rb").read()\n'
                               'mutated = b"VALUE = 1" in src\n' + textwrap.dedent(body))

    def single(self, *extra, find='VALUE = 0', replace='VALUE = 1', cmd=CHECK_CMD, runner=RAN, **kw):
        return self.mutate('--file', 'app.py', '--find', find, '--replace', replace, '--cmd', cmd,
                           *runner, *extra, **kw)


# --------------------------------------------------------------------------- 1. locate

class LocateTests(Base):
    def test_zero_matches_exit2_and_file_untouched(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'a * b', '--replace', 'x', '--cmd', UT_CMD)
        self.assertEqual((r.rc, self.read('app.py')), (2, APP))
        self.assertIn('no match', r.err)

    def test_multiple_matches_exit2_names_lines_and_runs_nothing(self):
        self.write('app.py', b'X = 1\nY = 2\nX = 1\n')
        self.write('check.py', 'open("ran.log", "a").write("x")\nprint("RAN OK")\n')
        r = self.mutate('--file', 'app.py', '--find', 'X = 1', '--replace', 'X = 9', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(r.rc, 2)
        self.assertIn('2 times', r.err)
        self.assertIn('lines 1, 3', r.err)
        self.assertFalse((self.dir / 'ran.log').exists(), 'no test command may run before the locate passes')
        self.assertEqual(self.read('app.py'), b'X = 1\nY = 2\nX = 1\n')

    def test_overlapping_matches_are_ambiguous(self):
        self.write('app.py', b'aaa\n')
        self.write('check.py', 'print("RAN OK")\n')
        r = self.mutate('--file', 'app.py', '--find', 'aa', '--replace', 'bb', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(r.rc, 2)       # bytes.count() would say 1; positions 0 and 1 both match

    def test_match_is_byte_exact_line_endings_included(self):
        self.write('app.py', b'A = 1\r\nB = 2\r\n')
        self.write('check.py', 'print("RAN OK")\n')
        lf = self.mutate('--file', 'app.py', '--find', 'A = 1\nB = 2', '--replace', 'A = 9', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(lf.rc, 2)      # an LF-only needle must not match a CRLF file
        crlf = self.mutate('--file', 'app.py', '--find', 'A = 1\r\nB = 2', '--replace', 'A = 9', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(crlf.rc, 1)    # located and run (GREEN: check.py never fails)
        self.assertEqual(crlf.verdicts(), ['GREEN'])
        self.assertEqual(self.read('app.py'), b'A = 1\r\nB = 2\r\n')

    def test_noop_empty_and_missing_inputs_are_usage_errors(self):
        self.unit_project()
        base = ['--file', 'app.py', '--cmd', UT_CMD]
        for extra in (['--find', 'a + b', '--replace', 'a + b'], ['--find', '', '--replace', 'x'],
                      ['--find', 'a + b'], ['--replace', 'x']):
            self.assertEqual(self.mutate(*base, *extra).rc, 2, extra)
        self.assertEqual(self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b').rc, 2)  # no --cmd
        self.assertEqual(self.read('app.py'), APP)


# --------------------------------------------------------------------------- 2. byte fidelity

class ByteFidelityTests(Base):
    PROBE = 'import shutil; shutil.copyfile("app.py", "probe.bin"); print("RAN OK")\n'

    def test_lf_file_stays_lf_while_mutated_and_after(self):
        self.write('app.py', b'ONE = 1\nTWO = 2\nTHREE = 3\n')
        self.write('check.py', self.PROBE)
        r = self.mutate('--file', 'app.py', '--find', 'TWO = 2', '--replace', 'TWO = 7', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(self.read('probe.bin'), b'ONE = 1\nTWO = 7\nTHREE = 3\n')   # no CRLF crept in
        self.assertEqual(self.read('app.py'), b'ONE = 1\nTWO = 2\nTHREE = 3\n')
        self.assertEqual(r.verdicts(), ['GREEN'])

    def test_crlf_bom_lone_cr_and_invalid_utf8_survive_byte_for_byte(self):
        orig = b'\xef\xbb\xbfONE = 1\r\nTWO = 2\r\nLONE\rCR = \xff\xfe\r\nTHREE = 3\n'
        self.write('app.py', orig)
        self.write('check.py', self.PROBE)
        self.mutate('--file', 'app.py', '--find', 'TWO = 2', '--replace', 'TWO = 22', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(self.read('probe.bin'), orig.replace(b'TWO = 2', b'TWO = 22'))
        self.assertEqual(self.read('app.py'), orig)

    def test_non_ascii_find_and_replace_are_utf8_bytes(self):
        orig = 'LABEL = "\u6e2c\u8a66"\n'.encode('utf-8')
        self.write('app.py', orig)
        self.write('check.py', self.PROBE)
        self.mutate('--file', 'app.py', '--find', '\u6e2c\u8a66', '--replace', '\u58de', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(self.read('probe.bin'), 'LABEL = "\u58de"\n'.encode('utf-8'))
        self.assertEqual(self.read('app.py'), orig)


# --------------------------------------------------------------------------- 3. python bytecode cache

class BytecodeCacheTests(Base):
    def plant_unchecked_pyc(self):
        """A pyc of the ORIGINAL code that Python trusts without looking at the source."""
        import importlib.util as iu
        import py_compile
        cfile = iu.cache_from_source(str(self.dir / 'app.py'))
        py_compile.compile(str(self.dir / 'app.py'), cfile=cfile,
                           invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
        return cfile

    def test_premise_dontwritebytecode_alone_still_reads_an_old_pyc(self):
        self.unit_project()
        self.plant_unchecked_pyc()
        (self.dir / 'app.py').write_bytes(APP.replace(b'a + b', b'a - b'))    # mutate by hand, same size
        out = subprocess.run([PY, '-c', 'import app; print(app.add(2, 3))'], cwd=self.dir, capture_output=True,
                             env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1')).stdout
        self.assertEqual(out.strip(), b'5', 'premise: the stale pyc was read although the source says a - b')

    def test_planted_stale_pyc_does_not_hide_the_mutation(self):
        self.unit_project()
        self.plant_unchecked_pyc()
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD,
                        '--expect-fail', 'test_add')
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED']), r.out + r.err)

    def test_every_run_gets_its_own_empty_pycache_prefix_and_no_bytecode_is_written(self):
        self.unit_project()
        self.write('check.py', 'import os\nprint("RAN OK")\n'
                               'open("env.log", "a").write(os.environ["PYTHONPYCACHEPREFIX"] + "|"'
                               ' + os.environ["PYTHONDONTWRITEBYTECODE"] + "|" + str(os.listdir(os.environ["PYTHONPYCACHEPREFIX"])) + "\\n")\n')
        spec = [{'file': 'app.py', 'find': 'a + b', 'replace': 'a * b'},
                {'file': 'app.py', 'find': 'a - b', 'replace': 'a * b'}]
        self.write('m.json', json.dumps(spec))
        r = self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN, env={'PYTHONPYCACHEPREFIX': 'user-value'})
        rows = [ln.split('|') for ln in self.read('env.log').decode().splitlines()]
        self.assertEqual(len(rows), 3)                                  # baseline + 2 mutations
        self.assertEqual(len({row[0] for row in rows}), 3, 'a fresh prefix per run')
        for prefix, dont_write, listing in rows:
            self.assertNotEqual(prefix, 'user-value')
            self.assertEqual((dont_write, listing), ('1', '[]'))
            self.assertFalse(os.path.exists(prefix), 'prefix removed after the run')
        self.assertFalse((self.dir / '__pycache__').exists())
        self.assertEqual(r.verdicts(), ['GREEN', 'GREEN'])

    def test_same_size_mutations_run_back_to_back_each_report_their_own_failure(self):
        self.unit_project()
        spec = [{'label': 'add', 'file': 'app.py', 'find': 'a + b', 'replace': 'a - b', 'expect_fail': r'test_add\b'},
                {'label': 'sub', 'file': 'app.py', 'find': 'a - b', 'replace': 'a + b', 'expect_fail': r'test_sub\b'}]
        self.write('m.json', json.dumps(spec))
        r = self.mutate('--spec', 'm.json', '--cmd', UT_CMD)
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED', 'RED']), r.out + r.err)
        self.assertEqual(self.read('app.py'), APP)


# --------------------------------------------------------------------------- 4. baseline first

class BaselineTests(Base):
    def test_red_baseline_aborts_that_mutation_and_never_mutates(self):
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\nsys.exit(1)\n')
        r = self.single()
        self.assertEqual((r.rc, r.verdicts()), (1, ['BASELINE_RED']))
        self.assertEqual(self.read('runs.log'), b'x', 'only the baseline ran')
        self.assertEqual(self.read('app.py'), VALUE_APP)

    def test_baseline_that_did_not_run_aborts(self):
        self.scripted('open("runs.log", "a").write("x")\n')                 # exit 0 but no RAN OK
        r = self.single()
        self.assertEqual((r.rc, r.verdicts()), (1, ['BASELINE_NOT_RUN']))
        self.assertEqual(self.read('runs.log'), b'x')

    def test_baseline_runs_once_per_distinct_command(self):
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\nsys.exit(1 if mutated else 0)\n',
                      app=b'VALUE = 0\nOTHER = 0\n')
        self.write('m.json', json.dumps([{'file': 'app.py', 'find': 'VALUE = 0', 'replace': 'VALUE = 1'},
                                         {'file': 'app.py', 'find': 'OTHER = 0', 'replace': 'VALUE = 1\nOTHER = 5'}]))
        r = self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(self.read('runs.log'), b'xxx')                       # 1 baseline + 2 mutations
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED', 'RED']))


# --------------------------------------------------------------------------- 5. two-stage verdict

class VerdictTests(Base):
    def test_green_when_tests_pass_with_the_mutation_applied(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'return 1', '--replace', 'return 2', '--cmd', UT_CMD)
        self.assertEqual((r.rc, r.verdicts()), (1, ['GREEN']))

    def test_red_exit_zero_when_every_mutation_is_red(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD)
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED']))
        self.assertIn('test_add', r.out)

    def test_syntax_error_mutation_is_not_run_although_exit_code_is_nonzero(self):
        self.unit_project()
        for cmd in (UT_CMD, '"%s" -m unittest discover -p "test_*.py"' % PY):   # crash form + _FailedTest form
            r = self.mutate('--file', 'app.py', '--find', 'return a + b', '--replace', 'return a +', '--cmd', cmd)
            self.assertEqual((r.rc, r.verdicts()), (1, ['NOT_RUN']), cmd + r.out)
            self.assertIn('exit=1', r.out)

    def test_exit_zero_without_any_sign_of_a_run_is_not_run(self):
        self.scripted('print("RAN OK" if not mutated else "silent")\n')
        r = self.single()
        self.assertEqual((r.rc, r.verdicts()), (1, ['NOT_RUN']))

    def test_ran_pattern_replaces_the_runner_check(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD,
                        '--ran-pattern', 'NEVER_PRINTED')
        self.assertEqual(r.verdicts(), ['BASELINE_NOT_RUN'])

    def test_timeout_is_not_run_and_the_process_tree_is_killed(self):
        self.scripted('print("RAN OK")\nif mutated:\n    open("pid.txt", "w").write(str(os.getpid()))\n'
                      '    time.sleep(60)\n')
        t0 = time.monotonic()
        r = self.single('--timeout', '3')
        self.assertLess(time.monotonic() - t0, 40)
        self.assertEqual((r.rc, r.verdicts()), (1, ['NOT_RUN']))
        self.assertIn('timed out', r.out)
        pid = int(self.read('pid.txt'))
        time.sleep(0.5)
        self.assertFalse(pid_alive(pid), 'grandchild must not outlive the timeout')
        self.assertEqual(self.read('app.py'), VALUE_APP)


# --------------------------------------------------------------------------- 6. red for the right reason

class ExpectFailTests(Base):
    def test_red_wrong_when_the_expected_test_did_not_fail(self):
        self.unit_project()
        args = ['--file', 'app.py', '--find', 'a - b', '--replace', 'a + b', '--cmd', UT_CMD]
        wrong = self.mutate(*args, '--expect-fail', 'test_add')          # the sub mutation breaks test_sub only
        self.assertEqual((wrong.rc, wrong.verdicts()), (1, ['RED_WRONG']))
        self.assertIn('test_sub', wrong.out)
        right = self.mutate(*args, '--expect-fail', 'test_sub')
        self.assertEqual((right.rc, right.verdicts()), (0, ['RED']))

    def test_expect_fail_needs_a_runner_that_can_name_failures(self):
        self.scripted('print("RAN OK")\n')
        self.assertEqual(self.single('--expect-fail', 'x').rc, 2)

    def test_runner_must_be_known_or_a_ran_pattern_given(self):
        self.scripted('print("RAN OK")\n')
        self.assertEqual(self.single(runner=[]).rc, 2)                    # "check.py" tells nothing
        two = self.single(runner=[], cmd='"%s" -m pytest && go test' % PY)
        self.assertEqual(two.rc, 2)
        self.assertIn('--runner', two.err)

    def test_invalid_regexes_are_usage_errors(self):
        self.unit_project()
        for flag in ('--expect-fail', '--ran-pattern'):
            r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD, flag, '(')
            self.assertEqual(r.rc, 2, flag)


# --------------------------------------------------------------------------- 7. restore

class RestoreTests(Base):
    def test_restore_is_sha256_identical_and_the_hash_is_printed(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD)
        self.assertEqual(self.read('app.py'), APP)
        self.assertIn('restored app.py sha256=' + sha(APP), r.out)

    @unittest.skipUnless(shutil.which('git'), 'git not installed')
    def test_uncommitted_edit_in_the_same_file_survives_where_git_checkout_would_eat_it(self):
        self.unit_project()
        git = lambda *a: subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@t', *a],
                                        cwd=self.dir, check=True, capture_output=True)
        git('init', '-q')
        git('add', '.')
        git('commit', '-q', '-m', 'init')
        edited = APP + b'\n\ndef formal_fix():\n    return "uncommitted"\n'
        self.write('app.py', edited)                                    # the not-yet-committed formal fix
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD)
        self.assertEqual(r.verdicts(), ['RED'])
        self.assertEqual(self.read('app.py'), edited)                   # git checkout would give back APP

    def test_foreign_append_during_run_is_kept_and_only_the_segment_is_reversed(self):
        self.scripted('print("RAN OK")\nif mutated:\n    open("app.py", "ab").write(b"# someone else\\n")\n')
        r = self.single()
        self.assertEqual(self.read('app.py'), VALUE_APP + b'# someone else\n')
        self.assertEqual((r.rc, r.verdicts()), (1, ['NOT_RUN']))
        self.assertIn('someone else', r.out)
        self.assertIn('not comparable', r.out)

    def test_segment_that_now_appears_twice_is_not_guessed_exit3(self):
        # someone else copies the mutated line, so "which one is ours" is ambiguous: refuse
        self.scripted('print("RAN OK")\nif mutated:\n    open("app.py", "ab").write(b"VALUE = 1\\n")\n')
        r = self.single()
        self.assertEqual(r.rc, 3, r.out + r.err)
        self.assertEqual(self.read('app.py'), b'VALUE = 1\nVALUE = 1\n')
        for ln in r.err.splitlines():
            if 'saved at' in ln:
                shutil.rmtree(Path(ln.split(': ', 1)[1].strip()).parent, ignore_errors=True)

    def test_unreversible_foreign_rewrite_exit3_and_saves_both_byte_strings(self):
        self.scripted('print("RAN OK")\nif mutated:\n    open("app.py", "wb").write(b"garbage\\n")\n')
        r = self.single()
        self.assertEqual(r.rc, 3, r.out + r.err)
        self.assertIn('RESTORE FAILED', r.err)
        saved = [ln.split(': ', 1)[1].strip() for ln in r.err.splitlines() if 'saved at' in ln]
        self.assertEqual(len(saved), 2, r.err)
        try:
            by_suffix = {Path(p).suffix: Path(p).read_bytes() for p in saved}
            self.assertEqual(by_suffix['.orig'], VALUE_APP)
            self.assertEqual(by_suffix['.current'], b'garbage\n')
            self.assertEqual(self.read('app.py'), b'garbage\n', 'a failed restore must not guess')
        finally:
            for p in saved:
                shutil.rmtree(Path(p).parent, ignore_errors=True)

    def test_file_deleted_during_run_exit3(self):
        self.scripted('print("RAN OK")\nif mutated:\n    os.remove("app.py")\n')
        r = self.single()
        self.assertEqual(r.rc, 3)
        for ln in r.err.splitlines():
            if 'saved at' in ln:
                shutil.rmtree(Path(ln.split(': ', 1)[1].strip()).parent, ignore_errors=True)

    def test_restore_failure_stops_the_remaining_mutations(self):
        self.scripted('print("RAN OK")\nif mutated:\n    open("app.py", "wb").write(b"garbage\\n")\n',
                      app=b'VALUE = 0\nOTHER = 0\n')
        self.write('m.json', json.dumps([{'file': 'app.py', 'find': 'VALUE = 0', 'replace': 'VALUE = 1'},
                                         {'file': 'app.py', 'find': 'OTHER = 0', 'replace': 'OTHER = 1'}]))
        r = self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(r.rc, 3)
        self.assertEqual(self.read('app.py'), b'garbage\n')
        for ln in r.err.splitlines():
            if 'saved at' in ln:
                shutil.rmtree(Path(ln.split(': ', 1)[1].strip()).parent, ignore_errors=True)


# --------------------------------------------------------------------------- 8. interrupts

class InterruptTests(Base):
    def run_and_interrupt(self, sig):
        self.scripted('print("RAN OK", flush=True)\nif mutated:\n    open("pid.txt", "w").write(str(os.getpid()))\n'
                      '    time.sleep(60)\n')
        kw = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt' else {}
        p = subprocess.Popen([PY, str(MUTATE), '--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1',
                              '--cmd', CHECK_CMD, *RAN], cwd=self.dir, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE,
                             env=dict(os.environ, TMP=str(self.tmp), TEMP=str(self.tmp), TMPDIR=str(self.tmp)), **kw)
        try:
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline and not ((self.dir / 'pid.txt').exists()
                                                       and (self.dir / 'pid.txt').stat().st_size):
                time.sleep(0.1)
            self.assertEqual(self.read('app.py'), b'VALUE = 1\n', 'the mutation must be live when we interrupt')
            pid = int(self.read('pid.txt'))
            p.send_signal(sig)
            out, err = p.communicate(timeout=40)
        finally:
            if p.poll() is None:
                p.kill()
        self.assertEqual(self.read('app.py'), VALUE_APP, 'interrupted run must restore the file')
        self.assertGreaterEqual(p.returncode, 128, (out, err))
        self.assertIn(b'interrupted', err)
        time.sleep(0.5)
        self.assertFalse(pid_alive(pid), 'the test process tree must be killed too')

    def test_terminate_signal_restores_the_file_and_kills_the_child_tree(self):
        self.run_and_interrupt(signal.CTRL_BREAK_EVENT if os.name == 'nt' else signal.SIGTERM)

    @unittest.skipIf(os.name == 'nt', 'SIGINT is disabled for a new process group on Windows; Ctrl+Break covers it')
    def test_sigint_restores_the_file(self):
        self.run_and_interrupt(signal.SIGINT)


class DeferredInterruptTests(unittest.TestCase):
    """The signal handler's bookkeeping, driven directly (no real signal is sent)."""

    def setUp(self):
        saved = dict(M._STATE)
        self.addCleanup(lambda: (M._STATE.clear(), M._STATE.update(saved)))
        M._STATE.update({'critical': 0, 'pending': None, 'fired': False})

    def test_a_signal_inside_critical_is_deferred_until_the_block_exits(self):
        reached_end = False
        with self.assertRaises(M.Interrupted) as cm:
            with M.critical():
                M._on_signal(signal.SIGINT, None)           # must not raise in here
                reached_end = True
        self.assertTrue(reached_end, 'the write/restore inside the block must run to completion')
        self.assertEqual(cm.exception.signum, signal.SIGINT)

    def test_nested_critical_blocks_raise_only_when_the_outermost_one_exits(self):
        inner_exited = False
        with self.assertRaises(M.Interrupted):
            with M.critical():
                with M.critical():
                    M._on_signal(signal.SIGTERM, None)
                inner_exited = True                            # still inside the outer block: no raise yet
        self.assertTrue(inner_exited)

    def test_a_signal_outside_critical_raises_at_once(self):
        with self.assertRaises(M.Interrupted):
            M._on_signal(signal.SIGTERM, None)

    def test_after_the_first_interrupt_later_signals_are_only_recorded_never_raised(self):
        with self.assertRaises(M.Interrupted):
            M._on_signal(signal.SIGINT, None)
        M._on_signal(signal.SIGTERM, None)                     # the cleanup after the first one must not be aborted
        with M.critical():
            M._on_signal(signal.SIGINT, None)
        # reaching this line means neither a bare signal nor a deferred one raised a second time


class InterruptReportTests(Base):
    """main() must check the bytes before it claims the interrupt left nothing behind."""

    def run_main_with_interrupt(self, leave):
        self.scripted('print("RAN OK")\n')
        out, err = io.StringIO(), io.StringIO()

        def interrupted_apply(mut, cwd):
            (self.dir / 'app.py').write_bytes(leave)
            raise M.Interrupted(signal.SIGINT)

        with mock.patch.object(M, 'apply_and_test', interrupted_apply), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = M.main(['--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1', '--cmd', CHECK_CMD,
                         *RAN, '--cwd', str(self.dir)])
        return rc, err.getvalue()

    def test_interrupt_with_the_file_restored_says_so_and_exits_128_plus_signum(self):
        rc, err = self.run_main_with_interrupt(VALUE_APP)
        self.assertEqual(rc, 128 + signal.SIGINT)
        self.assertIn('every touched file was restored', err)

    def test_interrupt_that_leaves_the_file_changed_is_not_reported_as_restored(self):
        rc, err = self.run_main_with_interrupt(b'VALUE = 1\n')
        self.assertEqual(rc, M.EXIT_RESTORE)
        self.assertNotIn('every touched file was restored', err)
        self.assertIn('app.py', err)


# --------------------------------------------------------------------------- 9. only the target changes

class ScopeTests(Base):
    def test_only_the_mutation_target_differs_while_the_tests_run(self):
        snap = (
            'import hashlib, json, os\nroot = os.getcwd()\nout = {}\n'
            'for d, _, fs in os.walk(root):\n    for f in fs:\n        p = os.path.join(d, f)\n'
            '        out[os.path.relpath(p, root)] = hashlib.sha256(open(p, "rb").read()).hexdigest()\n'
            'open(os.environ["SNAPS"], "a").write(json.dumps(out) + "\\n")\nprint("RAN OK")\n')
        self.write('app.py', VALUE_APP)
        self.write('check.py', snap)
        self.write('other/data.txt', b'untouched')
        snaps = self.dir.parent / (self.dir.name + '-snaps.jsonl')
        self.addCleanup(lambda: snaps.unlink() if snaps.exists() else None)
        r = self.single(env={'SNAPS': str(snaps)})
        base, mutated = [json.loads(ln) for ln in snaps.read_text().splitlines()]
        self.assertEqual({k for k in base if base[k] != mutated.get(k)}, {'app.py'})
        self.assertEqual(set(base), set(mutated), 'no file created or deleted by the tool')
        self.assertEqual(r.verdicts(), ['GREEN'])

    def test_a_test_file_as_target_is_refused_unless_allowed(self):
        self.unit_project()
        self.write('tests/helper.py', b'X = 1\n')
        for name in ('test_app.py', 'tests/helper.py'):
            r = self.mutate('--file', name, '--find', 'X = 1' if 'helper' in name else 'assertEqual',
                            '--replace', 'X = 2' if 'helper' in name else 'assertNotEqual', '--cmd', UT_CMD)
            self.assertEqual(r.rc, 2, name)
            self.assertIn('looks like a test file', r.err)
        ok = self.mutate('--file', 'test_app.py', '--find', 'assertEqual(app.add', '--replace', 'assertNotEqual(app.add',
                         '--cmd', UT_CMD, '--allow-test-file')
        self.assertEqual(ok.verdicts(), ['RED'])


# --------------------------------------------------------------------------- spec, exit codes, usage

class SpecTests(Base):
    def test_spec_runs_each_mutation_from_the_original_and_exit_code_reflects_the_worst(self):
        self.unit_project()
        spec = {'cmd': UT_CMD, 'mutations': [
            {'label': 'red-one', 'file': 'app.py', 'find': 'a + b', 'replace': 'a - b'},
            {'label': 'green-one', 'file': 'app.py', 'find': 'return 1', 'replace': 'return 3'},
            {'label': 'wrong-one', 'file': 'app.py', 'find': 'a - b', 'replace': 'a + b', 'expect_fail': 'test_add'}]}
        self.write('m.json', json.dumps(spec))
        r = self.mutate('--spec', 'm.json')
        self.assertEqual((r.rc, r.verdicts()), (1, ['RED', 'GREEN', 'RED_WRONG']))
        self.assertEqual(self.read('app.py'), APP)
        self.assertIn('summary: GREEN=1 RED=1 RED_WRONG=1', r.out)

    def test_cli_flags_fill_what_the_spec_omits_and_the_entry_wins(self):
        self.unit_project()
        self.write('m.json', json.dumps([{'file': 'app.py', 'find': 'a + b', 'replace': 'a - b'},
                                         {'file': 'app.py', 'find': 'return 1', 'replace': 'return 5', 'runner': 'none',
                                          'ran_pattern': 'OK'}]))
        r = self.mutate('--spec', 'm.json', '--cmd', UT_CMD)
        self.assertEqual(r.verdicts(), ['RED', 'GREEN'])

    def test_json_strings_carry_newlines_and_backslashes(self):
        self.write('app.py', b'P = "C:\\\\x"\nQ = 1\n')
        self.write('check.py', 'import shutil; shutil.copyfile("app.py", "probe.bin"); print("RAN OK")\n')
        self.write('m.json', json.dumps([{'file': 'app.py', 'find': 'C:\\\\x"\nQ = 1', 'replace': 'D:\\\\y"\nQ = 2'}]))
        self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(self.read('probe.bin'), b'P = "D:\\\\y"\nQ = 2\n')

    def test_spec_errors_are_exit2_before_anything_runs(self):
        self.unit_project()
        self.write('check.py', 'open("ran.log", "a").write("x")\nprint("RAN OK")\n')
        good = {'file': 'app.py', 'find': 'a + b', 'replace': 'a - b'}
        bad_specs = [
            [dict(good, expect_failure='x')],                                  # unknown key (typo)
            [dict(good), dict(good, find='a - b', label='app.py:2')],          # duplicate (default) label
            [good, {'file': 'app.py', 'find': 'zzz', 'replace': 'y'}],          # second one has no match
            {'mutations': [good], 'bogus': 1},
            {'mutations': []},
            [{'file': 'app.py', 'find': 'a + b'}],                              # missing replace
            [dict(good, timeout=-1)],
        ]
        for spec in bad_specs:
            self.write('m.json', json.dumps(spec))
            r = self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN)
            self.assertEqual(r.rc, 2, spec)
        self.assertFalse((self.dir / 'ran.log').exists())
        self.assertEqual(self.mutate('--spec', 'nope.json', '--cmd', CHECK_CMD, *RAN).rc, 2)
        self.write('m.json', json.dumps([good]))
        self.assertEqual(self.mutate('--spec', 'm.json', '--file', 'app.py', '--cmd', CHECK_CMD, *RAN).rc, 2)
        self.assertEqual(self.read('app.py'), APP)

    def test_help_and_unknown_flags(self):
        self.assertEqual(self.mutate('--help').rc, 0)
        self.assertIn('Exit code', self.mutate('--help').out)
        self.assertEqual(self.mutate('--frobnicate').rc, 2)


# --------------------------------------------------------------------------- runner parsing: real output

PYTEST_RED_Q = '''\
....                                                                     [100%]
================================== FAILURES ===================================
__________________________________ test_add ___________________________________
>       assert add(2, 3) == 5
E       assert -1 == 5
test_calc.py:6: AssertionError
=========================== short test summary info ===========================
FAILED test_calc.py::test_add - assert -1 == 5
FAILED test_calc.py::test_add_param[1-1-2] - assert 0 == 2
FAILED test_calc.py::test_add_param[2-2-4] - assert 0 == 4
3 failed, 1 passed in 0.03s
'''
PYTEST_GREEN = '''\
============================= test session starts =============================
platform win32 -- Python 3.11.9, pytest-9.2.0, pluggy-1.7.0
collected 4 items

test_calc.py ....                                                        [100%]

============================== 4 passed in 0.01s ==============================
'''
PYTEST_GREEN_Q = '....                                                                     [100%]\n4 passed in 0.00s\n'
PYTEST_COLLECT_ERROR = '''\
test_calc.py:2: in <module>
    from calc import add, sub
E     File "calc.py", line 2
E       return a +
E                 ^
E   SyntaxError: invalid syntax
=========================== short test summary info ===========================
ERROR test_calc.py
!!!!!!!!!!!!!!!!!!! Interrupted: 1 error during collection !!!!!!!!!!!!!!!!!!!!
============================== 1 error in 0.10s ===============================
'''
PYTEST_NO_FILE = '''\
ERROR: file or directory not found: nonexistent_dir

============================= test session starts =============================
collected 0 items

============================ no tests ran in 0.00s ============================
'''
PYTEST_X = '''\
F
=========================== short test summary info ===========================
FAILED test_calc.py::test_add - assert -1 == 5
!!!!!!!!!!!!!!!!!!!!!!!!!! stopping after 1 failures !!!!!!!!!!!!!!!!!!!!!!!!!!
1 failed in 0.03s
'''
PYTEST_V_FAILED = 'test_calc.py::test_add FAILED                                           [ 25%]\n3 failed, 1 passed in 0.03s\n'

GO_GREEN = 'ok  \tcapgo/calc\t0.009s\nok  \tcapgo/other\t0.010s\n'
GO_CACHED = 'ok  \tcapgo/calc\t(cached)\n'
GO_RED = '''\
--- FAIL: TestSub (0.00s)
    --- FAIL: TestSub/basic (0.00s)
        calc_test.go:16: got 8 want 2
    --- FAIL: TestSub/zero (0.00s)
        calc_test.go:16: got 2 want 0
FAIL
FAIL\tcapgo/calc\t0.012s
ok  \tcapgo/other\t0.011s
FAIL
'''
GO_BUILD_FAILED = '''\
# capgo/calc [capgo/calc.test]
calc\\calc.go:4:6: syntax error: unexpected name Sub, expected (
FAIL\tcapgo/calc [build failed]
ok  \tcapgo/other\t0.011s
FAIL
'''
GO_SETUP_FAILED = '# ./nonexist\nstat nonexist: directory not found\nFAIL\t./nonexist [setup failed]\nFAIL\n'
GO_NO_TEST_FILES = '?   \tcapgo/empty\t[no test files]\n'
GO_NO_TESTS_TO_RUN = 'ok  \tcapgo/calc\t0.010s [no tests to run]\n'

UT_GREEN = '..\n----------------------------------------------------------------------\nRan 2 tests in 0.000s\n\nOK\n'
UT_RED = '''\
F.
======================================================================
FAIL: test_add (test_app.T.test_add)
----------------------------------------------------------------------
Traceback (most recent call last):
AssertionError: -1 != 5

----------------------------------------------------------------------
Ran 2 tests in 0.000s

FAILED (failures=1)
'''
UT_LOAD_ERROR = '''\
E
======================================================================
ERROR: test_nope (unittest.loader._FailedTest.test_nope)
----------------------------------------------------------------------
ImportError: Failed to import test module: test_nope

----------------------------------------------------------------------
Ran 1 test in 0.000s

FAILED (errors=1)
'''
UT_CRASH = 'Traceback (most recent call last):\n  File "app.py", line 2\n    return a +\nSyntaxError: invalid syntax\n'

# Synthetic (NOT real output): written from the documented default-reporter format.
VITEST_RED = ' FAIL  src/a.test.ts > math > adds\nAssertionError\n\n Test Files  1 failed | 1 passed (2)\n      Tests  2 failed | 3 passed (5)\n'
VITEST_NO_TESTS_LINE = ' FAIL  src/a.test.ts [ src/a.test.ts ]\nError: Failed to resolve import\n\n Test Files  1 failed (1)\n'
JEST_RED = 'FAIL src/a.test.js\n  \u25cf math \u203a adds\n\n  \u25cf Console\n\nTests:       1 failed, 2 passed, 3 total\n'
JEST_NOT_RUN = 'FAIL src/a.test.js\n  \u25cf Test suite failed to run\n\nTests:       0 total\n'


class RunnerParsingTests(unittest.TestCase):
    def check(self, parser, text, ran, names):
        self.assertEqual(parser(text), (ran, names))

    def test_pytest_real_output(self):
        p = M.parse_pytest
        self.check(p, PYTEST_GREEN, True, [])
        self.check(p, PYTEST_GREEN_Q, True, [])
        self.check(p, PYTEST_RED_Q, True, ['test_calc.py::test_add', 'test_calc.py::test_add_param[1-1-2]',
                                           'test_calc.py::test_add_param[2-2-4]'])
        self.check(p, PYTEST_X, True, ['test_calc.py::test_add'])
        self.check(p, PYTEST_V_FAILED, True, ['test_calc.py::test_add'])

    def test_pytest_collection_error_and_no_tests_are_not_runs(self):
        self.check(M.parse_pytest, PYTEST_COLLECT_ERROR, False, [])
        self.check(M.parse_pytest, PYTEST_NO_FILE, False, [])
        self.check(M.parse_pytest, '3 skipped in 0.01s\n', False, [])

    def test_go_real_output(self):
        p = M.parse_go
        self.check(p, GO_GREEN, True, [])
        self.check(p, GO_CACHED, True, [])
        self.check(p, GO_RED, True, ['TestSub', 'TestSub/basic', 'TestSub/zero'])       # subtests are indented lines

    def test_go_build_setup_no_files_no_tests_are_not_runs(self):
        for text in (GO_BUILD_FAILED, GO_SETUP_FAILED, GO_NO_TEST_FILES, GO_NO_TESTS_TO_RUN):
            self.check(M.parse_go, text, False, [])

    def test_unittest_real_output(self):
        p = M.parse_unittest
        self.check(p, UT_GREEN, True, [])
        self.check(p, UT_RED, True, ['test_add (test_app.T.test_add)'])
        self.check(p, UT_LOAD_ERROR, False, ['test_nope (unittest.loader._FailedTest.test_nope)'])   # "Ran 1 test" lies
        self.check(p, UT_CRASH, False, [])

    def test_vitest_and_jest_synthetic_NOT_verified_against_real_output(self):
        self.check(M.parse_vitest, VITEST_RED, True, ['src/a.test.ts > math > adds'])
        self.check(M.parse_vitest, VITEST_NO_TESTS_LINE, False, ['src/a.test.ts'])
        self.check(M.parse_jest, JEST_RED, True, ['math \u203a adds'])
        self.check(M.parse_jest, JEST_NOT_RUN, False, [])

    def test_ansi_colors_do_not_hide_a_summary(self):
        text = M.clean_output(b'\x1b[31m3 failed\x1b[0m, \x1b[32m1 passed\x1b[0m in 0.03s\r\n')
        self.check(M.parse_pytest, text, True, [])

    def test_detect_runner(self):
        d = M.detect_runner
        self.assertEqual(d('python -m pytest -q tests'), 'pytest')
        self.assertEqual(d('cd x && go test -count=1 ./...'), 'go')
        self.assertEqual(d('npx vitest run'), 'vitest')
        self.assertEqual(d('npx jest --ci'), 'jest')
        self.assertEqual(d('python -m unittest test_app'), 'unittest')
        self.assertIsNone(d('npm test'))
        self.assertIsNone(d('python tests/test_unittest_helpers.py'))       # a word inside a file name
        with self.assertRaises(M.UsageError):
            d('pytest && go test ./...')


# --------------------------------------------------------------------------- real runners end to end

@unittest.skipUnless(pytest_python(), 'pytest not installed (set MUTATE_TEST_PYTEST_PYTHON)')
class RealPytestTests(Base):
    def setUp(self):
        super().setUp()
        self.py = pytest_python()
        self.write('calc.py', b'def add(a, b):\n    return a + b\n\n\ndef sub(a, b):\n    return a - b\n\n\ndef idle():\n    return 0\n')
        self.write('test_calc.py', b'from calc import add, sub\n\n\ndef test_add():\n    assert add(2, 3) == 5\n\n\n'
                                   b'def test_sub():\n    assert sub(5, 3) == 2\n')
        self.cmd = '"%s" -m pytest -q' % self.py

    def mutate_calc(self, find, replace, *extra):
        return self.mutate('--file', 'calc.py', '--find', find, '--replace', replace, '--cmd', self.cmd, *extra)

    def test_green_red_red_wrong_not_run_with_real_pytest(self):
        green = self.mutate_calc('return 0', 'return 9')
        self.assertEqual((green.rc, green.verdicts()), (1, ['GREEN']), green.out)
        red = self.mutate_calc('a + b', 'a - b', '--expect-fail', r'::test_add$')
        self.assertEqual((red.rc, red.verdicts()), (0, ['RED']), red.out)
        self.assertIn('test_calc.py::test_add', red.out)
        wrong = self.mutate_calc('a + b', 'a - b', '--expect-fail', 'test_sub')
        self.assertEqual((wrong.rc, wrong.verdicts()), (1, ['RED_WRONG']), wrong.out)
        broken = self.mutate_calc('return a + b', 'return a +')
        self.assertEqual((broken.rc, broken.verdicts()), (1, ['NOT_RUN']), broken.out)
        self.assertIn('exit=2', broken.out)                 # pytest exit 2 = interrupted by the collection error
        self.assertTrue((self.dir / 'calc.py').read_bytes().startswith(b'def add'))

    def test_pyc_staleness_from_a_prior_pytest_run_cannot_flip_the_result(self):
        # Reproduces the original trap: pytest has just imported calc.py (pyc written), and a
        # same-size edit lands within the same second.
        subprocess.run([self.py, '-m', 'pytest', '-q'], cwd=self.dir, capture_output=True)
        r = self.mutate_calc('a + b', 'a - b')
        self.assertEqual(r.verdicts(), ['RED'], r.out)


@unittest.skipUnless(shutil.which('go'), 'go not installed')
class RealGoTests(Base):
    def setUp(self):
        super().setUp()
        self.write('go.mod', b'module capgo\n\ngo 1.21\n')
        self.write('calc/calc.go', b'package calc\n\nfunc Add(a, b int) int { return a + b }\nfunc Sub(a, b int) int { return a - b }\n')
        self.write('calc/calc_test.go', b'package calc\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n'
                                        b'\tif Add(2, 3) != 5 {\n\t\tt.Fatal("add")\n\t}\n}\n\n'
                                        b'func TestSub(t *testing.T) {\n\tt.Run("basic", func(t *testing.T) {\n'
                                        b'\t\tif Sub(5, 3) != 2 {\n\t\t\tt.Error("sub")\n\t\t}\n\t})\n}\n')
        self.cmd = 'go test -count=1 ./...'

    def mutate_calc(self, find, replace, *extra, cmd=None):
        return self.mutate('--file', 'calc/calc.go', '--find', find, '--replace', replace,
                           '--cmd', cmd or self.cmd, *extra)

    def test_red_with_subtest_names_red_wrong_and_build_failure_with_real_go(self):
        red = self.mutate_calc('a - b', 'a + b', '--expect-fail', r'^TestSub/basic$')
        self.assertEqual((red.rc, red.verdicts()), (0, ['RED']), red.out)
        self.assertIn('TestSub/basic', red.out)
        wrong = self.mutate_calc('a - b', 'a + b', '--expect-fail', 'TestAdd')
        self.assertEqual((wrong.rc, wrong.verdicts()), (1, ['RED_WRONG']), wrong.out)
        broken = self.mutate_calc('{ return a - b }', '{ return a - }')
        self.assertEqual((broken.rc, broken.verdicts()), (1, ['NOT_RUN']), broken.out)
        self.assertIn('exit=1', broken.out)                 # go test exits 1 on a build failure too
        self.assertIn(b'return a - b', self.read('calc/calc.go'))

    def test_a_run_filter_that_selects_nothing_is_a_baseline_not_run(self):
        r = self.mutate_calc('a - b', 'a + b', cmd='go test -count=1 -run NoSuchTest ./...')
        self.assertEqual((r.rc, r.verdicts()), (1, ['BASELINE_NOT_RUN']), r.out)


if __name__ == '__main__':
    unittest.main()
