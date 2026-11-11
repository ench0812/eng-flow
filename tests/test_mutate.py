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
import re
import shutil
import signal
import stat
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


def same_second_write(real_write):
    """What an edit within the same second looks like to a pyc check: the bytes change, the mtime does not."""
    def write(path, data):
        st = os.stat(path)
        real_write(path, data)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
    return write


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
                                                    'RED_NONTEST', 'BASELINE_RED', 'BASELINE_NOT_RUN')]


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

    def timestamp_pyc_of_the_original(self):
        import py_compile
        cfile = importlib.util.cache_from_source(str(self.dir / 'app.py'))
        py_compile.compile(str(self.dir / 'app.py'), cfile=cfile, doraise=True)    # TIMESTAMP mode: mtime seconds + size
        return cfile

    def test_premise_python_dash_E_ignores_the_environment_and_reads_a_same_second_pyc(self):
        self.unit_project()
        self.timestamp_pyc_of_the_original()
        same_second_write(M.write_in_place)(str(self.dir / 'app.py'), APP.replace(b'a + b', b'a - b'))
        out = subprocess.run([PY, '-E', '-c', 'import app; print(app.add(2, 3))'], cwd=self.dir, capture_output=True,
                             env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONPYCACHEPREFIX=str(self.tmp))).stdout
        self.assertEqual(out.strip(), b'5', 'premise: the stale pyc was used although the source says a - b')

    def test_a_timestamp_pyc_cannot_hide_a_same_second_mutation_even_under_python_dash_E(self):
        self.unit_project()
        self.timestamp_pyc_of_the_original()
        cmd = '"%s" -E -m unittest test_app' % PY
        mut = M.Mutation('x', 'app.py', str(self.dir / 'app.py'), b'a + b', b'a - b', cmd, 'unittest', None,
                         re.compile('test_add'), 60)
        with mock.patch.object(M, 'write_in_place', same_second_write(M.write_in_place)):
            res = M.apply_and_test(mut, str(self.dir))[0]
        self.assertEqual((res.verdict, res.failed), ('RED', ['test_add (test_app.T.test_add)']), res)
        self.assertEqual((self.dir / 'app.py').read_bytes(), APP)

    def test_the_mutated_file_gets_its_own_mtime_second_and_the_original_mtime_comes_back(self):
        old = 1_000_000_000_500_000_000                              # 2001-09-09, with a fractional second
        self.scripted('open("m.log", "a").write(str(os.stat("app.py").st_mtime_ns) + " " + str(mutated) + "\\n")\n'
                      'print("RAN OK")\n', app=b'VALUE = 0\nOTHER = 0\n')
        os.utime(self.dir / 'app.py', ns=(old, old))
        self.write('m.json', json.dumps([{'file': 'app.py', 'find': 'VALUE = 0', 'replace': 'VALUE = 1'},
                                         {'file': 'app.py', 'find': 'OTHER = 0', 'replace': 'VALUE = 1\nOTHER = 5'}]))
        r = self.mutate('--spec', 'm.json', '--cmd', CHECK_CMD, *RAN)
        self.assertEqual(r.verdicts(), ['GREEN', 'GREEN'], r.out + r.err)
        rows = [ln.split() for ln in self.read('m.log').decode().splitlines()]
        self.assertEqual([row[1] for row in rows], ['False', 'True', 'True'])
        self.assertEqual(int(rows[0][0]), old)
        during = [int(row[0]) for row in rows[1:]]
        for ns in during:
            self.assertNotEqual(ns // 10 ** 9, old // 10 ** 9, 'a pyc recorded for the original must not match')
        self.assertNotEqual(during[0] // 10 ** 9, during[1] // 10 ** 9, 'nor one recorded for the previous mutation')
        self.assertEqual(os.stat(self.dir / 'app.py').st_mtime_ns, old, 'the restore puts the original mtime back')

    def test_a_cmd_that_runs_python_with_E_or_I_gets_a_warning_others_do_not(self):
        self.unit_project()
        args = ['--file', 'app.py', '--find', 'return 1', '--replace', 'return 2']
        for flags in ('-E', '-I', '-Es', '-W ignore -E', '-B -I'):
            r = self.mutate(*args, '--cmd', '"%s" %s -m unittest test_app' % (PY, flags))
            self.assertIn('warning', r.err, flags)
            self.assertIn('PYTHONPYCACHEPREFIX', r.err)
        for cmd in (UT_CMD, '"%s" -m unittest -v test_app' % PY, '"%s" -c "import sys" && echo -E -I' % PY):
            self.assertNotIn('warning', self.mutate(*args, '--cmd', cmd, '--runner', 'unittest').err, cmd)

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

    def test_nonzero_exit_without_any_failing_test_is_red_nontest_not_red(self):
        # a second command in --cmd (coverage threshold, lint, go vet) fails while every test passes
        self.unit_project()
        cmd = UT_CMD + ' && "%s" -c "import app, sys; sys.exit(app.unused() != 1)"' % PY
        r = self.mutate('--file', 'app.py', '--find', 'return 1', '--replace', 'return 2', '--cmd', cmd)
        self.assertEqual((r.rc, r.verdicts()), (1, ['RED_NONTEST']), r.out + r.err)
        self.assertIn('exit=1', r.out)
        self.assertIn('summary: RED_NONTEST=1', r.out)

    def test_a_real_failing_test_is_still_red_and_carries_no_warning_note(self):
        self.unit_project()
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD)
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED']))
        self.assertNotIn('not confirmed', r.out)
        self.assertNotIn('unverified', r.out)

    def test_verbose_shows_the_output_tail_for_a_red_too_so_the_assertion_can_be_quoted(self):
        self.unit_project()
        args = ['--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD]
        self.assertNotIn('AssertionError', self.mutate(*args).out, 'quiet by default')
        r = self.mutate(*args, '-v')
        self.assertEqual(r.verdicts(), ['RED'])
        self.assertIn('    | AssertionError: -1 != 5', r.out)               # expected and actual, as the runner printed them

    def test_a_red_the_output_cannot_confirm_is_kept_but_marked_on_the_line(self):
        self.scripted('print("RAN OK")\nsys.exit(1 if mutated else 0)\n')      # no runner: names and counts unknowable
        r = self.single()
        self.assertEqual((r.rc, r.verdicts()), (0, ['RED']))
        self.assertIn('not confirmed as a test failure', r.out)

    def test_unittest_where_every_test_is_skipped_makes_the_baseline_not_run(self):
        self.write('app.py', APP)
        self.write('test_app.py', b'import unittest\nimport app\n\n\nclass T(unittest.TestCase):\n'
                                  b'    @unittest.skip("x")\n    def test_add(self):\n        self.assertEqual(app.add(2, 3), 5)\n')
        r = self.mutate('--file', 'app.py', '--find', 'a + b', '--replace', 'a - b', '--cmd', UT_CMD)
        self.assertEqual((r.rc, r.verdicts()), (1, ['BASELINE_NOT_RUN']), r.out)

    def test_lines_judged_by_a_parser_that_was_never_checked_say_so(self):
        cases = {'vitest': ('    print(" Test Files  1 failed (1)")\n    print("      Tests  1 failed | 2 passed (3)")\n',
                            'print(" Test Files  1 passed (1)")\nprint("      Tests  3 passed (3)")\n'),
                 'jest': ('    print("Tests:       1 failed, 2 passed, 3 total")\n',
                          'print("Tests:       3 passed, 3 total")\n')}
        for name, (red, green) in cases.items():
            self.scripted('if mutated:\n' + red + '    sys.exit(1)\n' + green)
            r = self.single(cmd=CHECK_CMD + ' ' + name, runner=[])
            self.assertEqual((r.rc, r.verdicts()), (0, ['RED']), r.out + r.err)
            lines = [ln for ln in r.out.splitlines() if ln.startswith(('baseline-', 'RED'))]
            self.assertEqual(len(lines), 2, r.out)
            for ln in lines:
                self.assertIn('(unverified parser)', ln, name)

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


class WriteFailureTests(Base):
    """A target that cannot be opened for writing is a clear, separate outcome, not a traceback in exit 1."""

    def mutation(self):
        return M.Mutation('x', 'app.py', str(self.dir / 'app.py'), b'a + b', b'a - b', UT_CMD, 'unittest', None, None, 60)

    def test_read_only_target_exit_4_with_a_message_before_anything_runs(self):
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\n')
        app = self.dir / 'app.py'
        os.chmod(app, stat.S_IREAD)
        self.addCleanup(os.chmod, app, stat.S_IREAD | stat.S_IWRITE)
        if os.access(app, os.W_OK):
            self.skipTest('this user bypasses file modes (root)')
        r = self.single()
        self.assertEqual(r.rc, M.EXIT_IO, r.out + r.err)
        self.assertIn('cannot write', r.err)
        self.assertIn('app.py', r.err)
        self.assertNotIn('Traceback', r.err)
        self.assertFalse((self.dir / 'runs.log').exists(), 'no baseline run is wasted on a file we cannot mutate')

    def test_a_write_that_fails_later_is_exit_4_and_leaves_no_backup_behind(self):
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\n')
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(M, 'write_in_place', side_effect=PermissionError(13, 'locked by another program')), \
                mock.patch.object(tempfile, 'tempdir', str(self.tmp)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = M.main(['--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1', '--cmd', CHECK_CMD,
                         *RAN, '--cwd', str(self.dir)])
        self.assertEqual(rc, M.EXIT_IO, err.getvalue())
        self.assertIn('cannot write', err.getvalue())
        self.assertIn('locked by another program', err.getvalue())
        self.assertEqual(self.read('app.py'), VALUE_APP)
        self.assertEqual(self.read('runs.log'), b'x', 'only the baseline ran')
        self.assertEqual(self.backups(), [])

    def test_a_mutation_write_that_fails_part_way_restores_the_whole_original(self):
        # the write leaves a truncated mutated file whose segment and front context are intact, which
        # would otherwise look like a foreign edit; only the segment would be reversed and the
        # truncated tail kept, and the backup (the only full original) deleted
        app = b'VALUE = 0\nTAIL = "' + b'x' * 64 + b'"\n'
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\n', app=app)
        real = M.write_in_place

        def partial(path, data):
            if b'VALUE = 1' in data:
                with open(path, 'r+b') as fh:
                    fh.write(data[:len(data) - 20])
                    fh.truncate()
                raise OSError(28, 'No space left on device')
            real(path, data)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(M, 'write_in_place', partial), mock.patch.object(M.time, 'sleep'), \
                mock.patch.object(tempfile, 'tempdir', str(self.tmp)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = M.main(['--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1', '--cmd', CHECK_CMD,
                         *RAN, '--cwd', str(self.dir)])
        self.assertEqual(rc, M.EXIT_IO, err.getvalue())
        self.assertEqual(self.read('app.py'), app, 'the original comes back whole, truncated tail included')
        self.assertEqual(self.backups(), [], 'dropped only because the file is byte-identical to the original')

    def test_an_editor_saving_while_the_open_keeps_failing_is_not_overwritten(self):
        # the open fails every time, so nothing of ours was written; meanwhile an editor saves the file.
        # Writing the original back would destroy that save: refuse (exit 3), touch nothing, keep the backup.
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\n')
        real, saved = M.write_in_place, []

        def locked(path, data):
            if b'VALUE = 1' in data:
                if not saved:
                    with open(path, 'ab') as fh:
                        fh.write(b'# saved by an editor\n')
                    saved.append(1)
                raise PermissionError(13, 'locked by another program')
            real(path, data)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(M, 'write_in_place', locked), mock.patch.object(M.time, 'sleep'), \
                mock.patch.object(tempfile, 'tempdir', str(self.tmp)), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = M.main(['--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1', '--cmd', CHECK_CMD,
                         *RAN, '--cwd', str(self.dir)])
        self.assertEqual(rc, M.EXIT_RESTORE, out.getvalue() + err.getvalue())
        self.assertEqual(self.read('app.py'), VALUE_APP + b'# saved by an editor\n')
        kept = list(self.tmp.glob('mutate-backup-*/*.orig'))
        self.assertEqual([p.read_bytes() for p in kept], [VALUE_APP])

    def test_a_foreign_edit_keeps_the_backup_of_the_original(self):
        self.scripted('print("RAN OK")\nif mutated:\n    open("app.py", "ab").write(b"# someone else\\n")\n')
        r = self.single()
        self.assertEqual(r.verdicts(), ['NOT_RUN'])
        kept = list(self.tmp.glob('mutate-backup-*/*.orig'))
        self.assertEqual(len(kept), 1, r.out + r.err)
        self.assertEqual(kept[0].read_bytes(), VALUE_APP)
        self.assertIn(str(kept[0]), r.out + r.err)

    def test_restore_retries_a_transient_lock_a_few_times_and_then_succeeds(self):
        self.unit_project()
        orig = APP
        mutated = APP.replace(b'a + b', b'a - b')
        (self.dir / 'app.py').write_bytes(mutated)
        ap = M.Applied(self.mutation(), orig, sha(orig), orig.index(b'a + b'), mutated)
        calls, real = [], M.write_in_place

        def flaky(path, data):
            calls.append(path)
            if len(calls) < 3:
                raise PermissionError(13, 'locked')
            real(path, data)
        with mock.patch.object(M, 'write_in_place', flaky), mock.patch.object(M.time, 'sleep') as slept:
            M.restore(ap)
        self.assertEqual(len(calls), 3)
        self.assertEqual((self.dir / 'app.py').read_bytes(), orig)
        self.assertTrue(slept.called and all(c.args[0] <= 1 for c in slept.call_args_list), 'short waits only')

    def test_restore_that_stays_locked_is_a_restore_failure_with_the_original_saved(self):
        self.unit_project()
        mutated = APP.replace(b'a + b', b'a - b')
        (self.dir / 'app.py').write_bytes(mutated)
        ap = M.Applied(self.mutation(), APP, sha(APP), APP.index(b'a + b'), mutated)
        with mock.patch.object(M, 'write_in_place', side_effect=PermissionError(13, 'locked')), \
                mock.patch.object(M.time, 'sleep'), mock.patch.object(tempfile, 'tempdir', str(self.tmp)):
            with self.assertRaises(M.RestoreFailure) as cm:
                M.restore(ap)
        self.assertIn('locked', str(cm.exception))
        saved = [ln.split(': ', 1)[1].strip() for ln in str(cm.exception).splitlines() if 'original bytes' in ln]
        self.assertEqual(Path(saved[0]).read_bytes(), APP)


class BackupFolderTests(Base):
    """The backup is a unique folder per mutation; only files this run wrote are ever deleted."""

    def mutation(self):
        return M.Mutation('x', 'app.py', str(self.dir / 'app.py'), b'return 1', b'return 2', UT_CMD, 'unittest',
                          None, None, 60)

    def test_a_leftover_backup_folder_carrying_my_pid_survives_a_clean_run(self):
        # Windows reuses PIDs: the folder of a hard-killed earlier run can carry exactly this pid.
        # Both the old fixed name and a unique name must keep their only copy of someone's file.
        self.unit_project()
        leftovers = [self.tmp / ('mutate-backup-%d' % os.getpid()), self.tmp / ('mutate-backup-%d-left' % os.getpid())]
        for folder in leftovers:
            folder.mkdir()
            (folder / 'other.py-deadbeef.orig').write_bytes(b'ONLY COPY')
        with mock.patch.object(tempfile, 'tempdir', str(self.tmp)):
            res = M.apply_and_test(self.mutation(), str(self.dir))
        self.assertEqual(res[0].verdict, 'GREEN')
        for folder in leftovers:
            self.assertEqual((folder / 'other.py-deadbeef.orig').read_bytes(), b'ONLY COPY')
        self.assertEqual(self.backups(), sorted(f.name for f in leftovers), 'its own folder is gone after a verified restore')

    def test_discard_removes_only_its_own_files_and_the_folder_only_when_empty(self):
        self.unit_project()
        orig = (self.dir / 'app.py').read_bytes()
        ap = M.Applied(self.mutation(), orig, sha(orig), 0, orig)
        with mock.patch.object(tempfile, 'tempdir', str(self.tmp)):
            ap.backup = M.save_backup(ap)
        folder = Path(ap.backup).parent
        self.assertEqual(Path(ap.backup).read_bytes(), orig)
        (folder / 'not-ours.txt').write_bytes(b'keep me')
        M.discard_backup(ap)
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ['not-ours.txt'])
        (folder / 'not-ours.txt').unlink()
        ap2 = M.Applied(self.mutation(), orig, sha(orig), 0, orig)
        with mock.patch.object(tempfile, 'tempdir', str(self.tmp)):
            ap2.backup = M.save_backup(ap2)
        M.discard_backup(ap2)
        self.assertFalse(Path(ap2.backup).parent.exists(), 'an emptied folder is removed')


class StaleBackupTests(Base):
    """A hard kill (taskkill /F, TerminateProcess, kill -9) cannot be caught and leaves the file mutated.
    The next run must not take that broken file for the original."""

    def dead_pid(self):
        out = subprocess.run([PY, '-c', 'import os; print(os.getpid())'], capture_output=True).stdout
        pid = int(out)
        self.assertFalse(pid_alive(pid))
        return pid

    def plant(self, pid, orig, target='app.py', name='planted'):
        folder = self.tmp / ('mutate-backup-%d-%s' % (pid, name))
        folder.mkdir()
        stem = folder / ('app.py-' + sha(orig)[:12])
        (folder / (stem.name + '.orig')).write_bytes(orig)
        (folder / (stem.name + '.path.txt')).write_bytes((str(self.dir / target) + '\n' + sha(orig) + '\n').encode())
        return folder / (stem.name + '.orig')

    def project_with_edited_file(self):
        # the file on disk differs from the original the planted backup remembers
        self.scripted('open("runs.log", "a").write("x")\nprint("RAN OK")\n', app=b'VALUE = 0\nEXTRA = 5\n')

    def test_hard_killed_run_is_detected_and_the_next_run_refuses_to_start(self):
        self.scripted('print("RAN OK", flush=True)\nif mutated:\n    open("pid.txt", "w").write(str(os.getpid()))\n'
                      '    time.sleep(60)\n')
        p = subprocess.Popen([PY, str(MUTATE), '--file', 'app.py', '--find', 'VALUE = 0', '--replace', 'VALUE = 1',
                              '--cmd', CHECK_CMD, *RAN], cwd=self.dir, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=dict(os.environ, TMP=str(self.tmp), TEMP=str(self.tmp), TMPDIR=str(self.tmp)))
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not ((self.dir / 'pid.txt').exists() and (self.dir / 'pid.txt').stat().st_size):
            time.sleep(0.1)
        child = int(self.read('pid.txt'))

        def reap():                                 # the orphaned test process holds the temp dir as its cwd
            with contextlib.suppress(OSError):
                os.kill(child, signal.SIGTERM)
            deadline = time.monotonic() + 15
            while pid_alive(child) and time.monotonic() < deadline:
                time.sleep(0.1)
            time.sleep(0.5)                         # and so does the shell that was waiting for it
            p.stdout.close()
            p.stderr.close()
        self.addCleanup(reap)
        p.kill()                                    # TerminateProcess / SIGKILL: no handler, no restore
        p.wait(timeout=20)
        self.assertEqual(self.read('app.py'), b'VALUE = 1\n', 'premise: the hard kill left the file mutated')
        self.assertEqual(len(self.backups()), 1, 'premise: the backup of the original survived')

        r = self.single(find='VALUE = 1', replace='VALUE = 2')           # what the reviewer did: another mutation
        self.assertEqual(r.rc, 3, r.out + r.err)
        self.assertEqual(r.verdicts(), [], 'nothing was baselined, mutated or reported GREEN')
        self.assertNotIn('restored', r.out)
        self.assertEqual(self.read('app.py'), b'VALUE = 1\n', 'the refusal must not touch the file')
        orig = [ln.split(': ', 1)[1].strip() for ln in r.err.splitlines() if 'original bytes' in ln]
        self.assertEqual(len(orig), 1, r.err)
        self.assertEqual(Path(orig[0]).read_bytes(), VALUE_APP)
        self.assertIn('fc /b' if os.name == 'nt' else 'cmp', r.err)       # how to compare

        # the way out printed in the message works: put the original back, delete the folder, run again
        (self.dir / 'app.py').write_bytes(Path(orig[0]).read_bytes())
        shutil.rmtree(Path(orig[0]).parent)
        again = self.single(find='VALUE = 0', replace='VALUE = 2')
        self.assertEqual(again.verdicts(), ['GREEN'], again.out + again.err)

    def test_a_backup_left_by_a_dead_run_for_this_file_blocks_before_anything_runs(self):
        self.project_with_edited_file()
        orig = self.plant(self.dead_pid(), b'VALUE = 0\n')
        r = self.single()
        self.assertEqual(r.rc, 3, r.out + r.err)
        self.assertIn(str(orig), r.err)
        self.assertFalse((self.dir / 'runs.log').exists(), 'not even the baseline may run')

    def test_a_backup_whose_run_is_still_alive_is_not_stale(self):
        self.project_with_edited_file()
        self.plant(os.getpid(), b'VALUE = 0\n')                 # this test process is alive
        r = self.single()
        self.assertEqual(r.verdicts(), ['GREEN'], r.out + r.err)

    def test_a_backup_for_another_file_is_ignored(self):
        self.project_with_edited_file()
        self.plant(self.dead_pid(), b'VALUE = 0\n', target='other.py')
        self.assertEqual(self.single().verdicts(), ['GREEN'])

    def test_a_backup_that_matches_the_file_as_it_is_now_is_harmless(self):
        self.project_with_edited_file()
        self.plant(self.dead_pid(), b'VALUE = 0\nEXTRA = 5\n')    # nothing to repair: the file already equals it
        self.assertEqual(self.single().verdicts(), ['GREEN'])


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
# pytest 9.2 -q --continue-on-collection-errors, one module fails to import, the other passes
PYTEST_COLLECT_MIXED = '''\
_________________________ ERROR collecting test_b.py __________________________
test_b.py:1: in <module>
    import nonexistent_mod
E   ModuleNotFoundError: No module named 'nonexistent_mod'
=========================== short test summary info ===========================
ERROR test_b.py
1 passed, 1 error in 0.03s
'''
# pytest 9.2 -q, a fixture raises: the error names a test, so it is a failing test
PYTEST_FIXTURE_ERROR = '''\
__________________________ ERROR at setup of test_c ___________________________
E       RuntimeError: x
test_c.py:4: RuntimeError
=========================== short test summary info ===========================
ERROR test_c.py::test_c - RuntimeError: x
1 passed, 1 error in 0.05s
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
UT_ALL_SKIPPED = 's\n----------------------------------------------------------------------\nRan 1 test in 0.000s\n\nOK (skipped=1)\n'
UT_SOME_SKIPPED = 's.s\n----------------------------------------------------------------------\nRan 3 tests in 0.000s\n\nOK (skipped=2)\n'
UT_UNEXPECTED_SUCCESS = '''\
uF
======================================================================
FAIL: test_b (t_unexp.T.test_b)
----------------------------------------------------------------------
Traceback (most recent call last):
AssertionError: boom

======================================================================
UNEXPECTED SUCCESS: test_a (t_unexp.T.test_a)
----------------------------------------------------------------------
Ran 2 tests in 0.000s

FAILED (failures=1, unexpected successes=1)
'''

# Synthetic (NOT real output): written from the documented default-reporter format.
VITEST_RED = ' FAIL  src/a.test.ts > math > adds\nAssertionError\n\n Test Files  1 failed | 1 passed (2)\n      Tests  2 failed | 3 passed (5)\n'
VITEST_NO_TESTS_LINE = ' FAIL  src/a.test.ts [ src/a.test.ts ]\nError: Failed to resolve import\n\n Test Files  1 failed (1)\n'
JEST_RED = 'FAIL src/a.test.js\n  \u25cf math \u203a adds\n\n  \u25cf Console\n\nTests:       1 failed, 2 passed, 3 total\n'
JEST_NOT_RUN = 'FAIL src/a.test.js\n  \u25cf Test suite failed to run\n\nTests:       0 total\n'


class RunnerParsingTests(unittest.TestCase):
    def check(self, parser, text, ran, names):
        self.assertEqual(parser(text)[:2], (ran, names))

    def test_failure_counts_come_from_the_runners_own_summary(self):
        count = lambda parser, text: parser(text)[2]
        self.assertEqual(count(M.parse_pytest, PYTEST_RED_Q), 3)
        self.assertEqual(count(M.parse_pytest, PYTEST_GREEN), 0)
        self.assertEqual(count(M.parse_pytest, '2 passed, 1 error in 0.10s\n'), 1)      # a fixture error is a failing test
        self.assertEqual(count(M.parse_go, GO_RED), 4)                                    # 3 names + 1 failing package
        self.assertEqual(count(M.parse_go, GO_GREEN), 0)
        self.assertEqual(count(M.parse_unittest, UT_RED), 1)
        self.assertEqual(count(M.parse_unittest, UT_GREEN), 0)
        self.assertEqual(count(M.parse_unittest, UT_UNEXPECTED_SUCCESS), 2)               # failures + unexpected successes
        self.assertEqual(count(M.parse_vitest, VITEST_RED), 2)
        self.assertEqual(count(M.parse_jest, JEST_RED), 1)

    def test_a_missing_summary_means_the_count_is_unknown_not_zero(self):
        for parser, text in ((M.parse_pytest, 'no summary here\n'), (M.parse_unittest, UT_CRASH),
                             (M.parse_vitest, VITEST_NO_TESTS_LINE), (M.parse_jest, 'nothing\n')):
            self.assertIsNone(parser(text)[2], parser.__name__)

    def test_unittest_run_where_every_test_was_skipped_is_not_a_run(self):
        self.check(M.parse_unittest, UT_ALL_SKIPPED, False, [])
        self.check(M.parse_unittest, UT_SOME_SKIPPED, True, [])                   # one test really executed
        self.check(M.parse_unittest, UT_UNEXPECTED_SUCCESS, True, ['test_b (t_unexp.T.test_b)'])

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

    def test_pytest_collection_error_beside_passing_modules_is_not_a_run(self):
        # --continue-on-collection-errors: "1 passed, 1 error" must not read as a test noticing the mutation
        self.check(M.parse_pytest, PYTEST_COLLECT_MIXED, False, [])
        ran, _, nfail = M.parse_pytest(PYTEST_FIXTURE_ERROR)        # a fixture error names a test: still a run
        self.assertEqual((ran, nfail), (True, 1))

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

    def test_a_failing_second_command_with_all_tests_passing_is_red_nontest_with_real_pytest(self):
        cmd = self.cmd + ' && "%s" -c "import calc, sys; sys.exit(calc.idle() != 0)"' % self.py
        r = self.mutate('--file', 'calc.py', '--find', 'return 0', '--replace', 'return 9', '--cmd', cmd,
                        '--runner', 'pytest')
        self.assertEqual((r.rc, r.verdicts()), (1, ['RED_NONTEST']), r.out)

    def test_a_pyc_written_by_a_prior_pytest_run_cannot_hide_a_same_second_mutation(self):
        # The original trap with the real runner: pytest has just imported calc.py (pyc written by
        # that run) and a same-size edit lands within the same second. Python runs with -E, so the
        # environment protection cannot apply and only the mtime shift stands between the stale pyc
        # and a false GREEN. The same-second write is forced, so the trap is deterministic.
        cmd = '"%s" -E -m pytest -q -p no:cacheprovider' % self.py
        subprocess.run(cmd, shell=True, cwd=self.dir, capture_output=True)
        pyc = list((self.dir / '__pycache__').glob('calc.*.pyc'))
        self.assertEqual(len(pyc), 1, 'premise: the prior run left a pyc of calc.py')
        mut = M.Mutation('x', 'calc.py', str(self.dir / 'calc.py'), b'a + b', b'a - b', cmd, 'pytest', None,
                         re.compile(r'::test_add$'), 120)
        with mock.patch.object(M, 'write_in_place', same_second_write(M.write_in_place)):
            res = M.apply_and_test(mut, str(self.dir))[0]
        self.assertEqual((res.verdict, res.failed), ('RED', ['test_calc.py::test_add']), res)


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
