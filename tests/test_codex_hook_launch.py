"""Exercise manifest commands with Windows' WSL launcher before Git Bash."""
import json
import importlib.util
import io
import os
import runpy
import shutil
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


class LauncherUnit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('codex_hook_launch', ROOT/'scripts/codex_hook_launch.py')
        cls.launch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.launch)

    def test_windows_ignores_wsl_bash_and_finds_git_install(self):
        target = Path('D:/Portable/Git/bin/bash.exe')
        with mock.patch.object(self.launch, 'WINDOWS', True), \
             mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(self.launch.shutil, 'which', return_value='D:/Portable/Git/cmd/git.exe') as which, \
             mock.patch.object(Path, 'resolve', lambda path: path), \
             mock.patch.object(Path, 'is_file', lambda path: path == target):
            self.assertEqual(self.launch.find_bash(), target)
            which.assert_called_once_with('git')

    def test_posix_uses_native_bash(self):
        with mock.patch.object(self.launch, 'WINDOWS', False), \
             mock.patch.object(self.launch.shutil, 'which', return_value='/usr/bin/bash'):
            self.assertEqual(self.launch.find_bash(), Path('/usr/bin/bash'))

    def invoke(self, bash, result=None, error=None, finder_error=None):
        payload = b'{"tool_input":{"command":"fake private payload"}}'
        errors = io.StringIO()
        errors.buffer = io.BytesIO()
        with mock.patch.object(self.launch, 'find_bash', return_value=bash, side_effect=finder_error), \
             mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(payload))), \
             mock.patch.object(sys, 'stdout', SimpleNamespace(buffer=io.BytesIO())), \
             mock.patch.object(sys, 'stderr', errors), \
             mock.patch.object(sys, 'argv', ['launcher', '--host', 'codex', '--hook', 'iso-scan-write']), \
             mock.patch.object(self.launch.subprocess, 'run', return_value=result, side_effect=error) as run:
            code = self.launch.main()
            self.assertNotIn('fake private payload', errors.getvalue())
            return code, run, payload

    def test_missing_native_shell_blocks_without_launching_wsl(self):
        code, run, _ = self.invoke(None)
        self.assertEqual(code, 2)
        run.assert_not_called()

    def test_unexpected_finder_exception_blocks(self):
        for exception in (RuntimeError, ValueError, MemoryError, TypeError):
            with self.subTest(exception=exception.__name__):
                try:
                    actual = self.invoke(None, finder_error=exception('fake private payload'))[0]
                except Exception as error:
                    actual = ('uncaught', type(error).__name__)
                self.assertEqual(actual, 2)

    def test_annotations_are_deferred(self):
        self.assertIsInstance(self.launch.find_bash.__annotations__['return'], str)

    def test_child_failures_block(self):
        for error in (OSError('fixture'), subprocess.TimeoutExpired('fixture', 27)):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.invoke(Path('D:/Git/bin/bash.exe'), error=error)[0], 2)
        for status in (1, 2, 124):
            with self.subTest(status=status):
                self.assertEqual(self.invoke(Path('D:/Git/bin/bash.exe'),
                    result=subprocess.CompletedProcess([], status))[0], 2)

    def test_input_arguments_and_process_local_path_preserved(self):
        original = os.environ.get('PATH')
        bash = Path('D:/Git/bin/bash.exe')
        code, run, payload = self.invoke(bash, result=subprocess.CompletedProcess([], 0, b'{}', b''))
        self.assertEqual(code, 0)
        args, kwargs = run.call_args
        self.assertEqual(args[0], [str(bash), (ROOT/'scripts/codex-hook.sh').as_posix(),
                                  '--host', 'codex', '--hook', 'iso-scan-write'])
        self.assertEqual(kwargs['input'], payload)
        self.assertEqual(kwargs['timeout'], 27)
        self.assertEqual(kwargs['env']['PATH'].split(os.pathsep)[0], str(bash.parent))
        self.assertEqual(os.environ.get('PATH'), original)


class EntryBoundary(unittest.TestCase):
    def test_normal_completion_keeps_successful_exit(self):
        with mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))), \
             mock.patch.object(sys, 'stdout', SimpleNamespace(buffer=io.BytesIO())), \
             mock.patch.object(sys, 'stderr', SimpleNamespace(buffer=io.BytesIO())), \
             mock.patch.object(sys, 'argv', ['launcher', '--host', 'codex', '--hook', 'iso-scan-bash']), \
             mock.patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, b'{}', b'')):
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(ROOT/'scripts/codex_hook_launch.py'), run_name='__main__')
        self.assertEqual(result.exception.code, 0)

    def test_interruptions_and_early_exit_block(self):
        for error in (KeyboardInterrupt('fake private payload'),
                      GeneratorExit('fake private payload'), SystemExit(0), SystemExit(1)):
            with self.subTest(error=type(error).__name__, args=error.args):
                errors = io.StringIO()
                output = io.StringIO()
                with mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))), \
                     mock.patch.object(sys, 'stdout', output), \
                     mock.patch.object(sys, 'stderr', errors), \
                     mock.patch('shutil.which', side_effect=error):
                    try:
                        runpy.run_path(str(ROOT/'scripts/codex_hook_launch.py'), run_name='__main__')
                        actual = ('returned', None)
                    except SystemExit as result:
                        actual = ('exit', result.code)
                    except BaseException as result:
                        actual = ('uncaught', type(result).__name__)
                self.assertEqual(actual, ('exit', 0))
                self.assertEqual(json.loads(output.getvalue())['hookSpecificOutput']['permissionDecision'], 'deny')
                self.assertNotIn('fake private payload', errors.getvalue())
                self.assertNotIn('Traceback', errors.getvalue())


class HostProtocolBoundary(unittest.TestCase):
    def test_failed_child_cannot_leak_partial_output(self):
        with tempfile.TemporaryDirectory(prefix='r3-child-') as temp:
            scripts = Path(temp)/'scripts'
            scripts.mkdir()
            (scripts/'codex-hook.sh').write_bytes(b'import sys\nprint("FAKE_PRIVATE_CHILD")\nprint("FAKE_PRIVATE_CHILD", file=sys.stderr)\nsys.exit(1)\n')
            wrapper = Path(temp)/'probe.py'
            wrapper.write_bytes(('import importlib.util, sys\nfrom pathlib import Path\n'
                'spec = importlib.util.spec_from_file_location("launcher", '+repr(str(ROOT/'scripts/codex_hook_launch.py'))+')\n'
                'launch = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(launch)\n'
                'launch.__file__ = '+repr(str(scripts/'launcher.py'))+'\n'
                'launch.find_bash = lambda: Path(sys.executable)\n'
                'sys.exit(launch.main())\n').encode())
            result = subprocess.run([sys.executable, str(wrapper)], input=b'{}', capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(b'FAKE_PRIVATE_CHILD', result.stdout+result.stderr)
            self.assertEqual(result.stdout, b'')

    def test_successful_child_must_return_a_json_object(self):
        spec = importlib.util.spec_from_file_location('launcher_output', ROOT/'scripts/codex_hook_launch.py')
        launch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launch)
        for output in (b'', b'partial {', b'null', b'[]'):
            errors = io.StringIO()
            errors.buffer = io.BytesIO()
            with self.subTest(output=output), \
                 mock.patch.object(launch, 'find_bash', return_value=Path(sys.executable)), \
                 mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'{}'))), \
                 mock.patch.object(sys, 'stdout', SimpleNamespace(buffer=io.BytesIO())), \
                 mock.patch.object(sys, 'stderr', errors), \
                 mock.patch.object(launch.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, b'')):
                self.assertEqual(launch.main(), 2)

    def test_stop_failure_allows_with_warning(self):
        spec = importlib.util.spec_from_file_location('launcher_stop', ROOT/'scripts/codex_hook_launch.py')
        launch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launch)
        for active in (False, True):
            for failure in ('missing-bash', 'timeout', 'child-exit', 'runtime', 'interrupt', 'early-exit'):
                output, errors = io.StringIO(), io.StringIO()
                finder_error = {'runtime': RuntimeError('fake private payload'),
                                'interrupt': KeyboardInterrupt('fake private payload'),
                                'early-exit': SystemExit(0)}.get(failure)
                child_error = subprocess.TimeoutExpired('fixture', 27) if failure == 'timeout' else None
                with self.subTest(active=active, failure=failure), \
                     mock.patch.object(launch, 'find_bash', return_value=None if failure == 'missing-bash'
                                       else Path('fixture-bash'), side_effect=finder_error), \
                     mock.patch.object(launch.subprocess, 'run', side_effect=child_error,
                                       return_value=subprocess.CompletedProcess([], 124)), \
                     mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(json.dumps({'stop_hook_active': active}).encode()))), \
                     mock.patch.object(sys, 'argv', ['launcher', '--host', 'codex', '--hook', 'git-unpushed-check']), \
                     mock.patch.object(sys, 'stdout', output), mock.patch.object(sys, 'stderr', errors):
                    try:
                        status = launch.run()
                    except BaseException as error:
                        status = ('uncaught', type(error).__name__)
                self.assertEqual(status, 0)
                self.assertEqual(json.loads(output.getvalue()), {})
                self.assertIn('git-unpushed-check', errors.getvalue())
                self.assertIn('skipped', errors.getvalue())
                self.assertNotIn('fake private payload', errors.getvalue())

    @unittest.skipUnless(os.name == 'nt', 'PowerShell native exit status regression')
    def test_powershell_receives_failure_protocol_for_all_hooks(self):
        shell = shutil.which('pwsh') or shutil.which('powershell')
        self.assertIsNotNone(shell)
        with tempfile.TemporaryDirectory(prefix='r3-powershell-') as temp:
            wrapper = Path(temp)/'inject.py'
            wrapper.write_bytes(('import shutil, runpy\n'
                'def fail(*args, **kwargs): raise RuntimeError("fake private payload")\n'
                'shutil.which = fail\n'
                'runpy.run_path('+repr(str(ROOT/'scripts/codex_hook_launch.py'))+', run_name="__main__")\n').encode())
            manifest = json.loads((ROOT/'.codex-plugin/plugin.json').read_bytes())
            hooks = [handler['command'].split('--hook ')[1]
                     for groups in manifest['hooks']['hooks'].values()
                     for group in groups for handler in group['hooks']]
            self.assertEqual(len(hooks), 7)
            for hook in hooks:
                with self.subTest(hook=hook):
                    command = '& '+"'"+sys.executable.replace("'", "''")+"' '"+str(wrapper).replace("'", "''")+"' --host codex --hook "+hook
                    result = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-Command', command],
                                            input=b'{}', capture_output=True, timeout=15)
                    output = json.loads(result.stdout) if result.stdout.strip() else {}
                    self.assertEqual(result.returncode, 0)
                    if hook == 'git-unpushed-check':
                        self.assertEqual(output, {})
                        self.assertIn(b'reminder skipped', result.stderr)
                    else:
                        self.assertEqual(output.get('hookSpecificOutput', {}).get('permissionDecision'), 'deny')
                    self.assertNotIn(b'fake private payload', result.stdout+result.stderr)


class ManifestLaunch(unittest.TestCase):
    @unittest.skipUnless(os.name == 'nt', 'Windows executable search order regression')
    def test_commands_work_with_system_bash_first(self):
        manifest = json.loads((ROOT / '.codex-plugin/plugin.json').read_bytes())
        environment = dict(os.environ)
        # Restore the normal Windows search order even when another test runner
        # prepends Git Bash. The system32 bash.exe is the WSL entry point.
        system32 = str(Path(os.environ['SystemRoot']) / 'System32')
        environment['PATH'] = system32 + os.pathsep + environment['PATH']
        for event, matchers in manifest['hooks']['hooks'].items():
            for matcher in matchers:
                for handler in matcher['hooks']:
                    command = handler['command'].replace('${PLUGIN_ROOT}', str(ROOT))
                    with self.subTest(command=command):
                        data = ({'hook_event_name': 'Stop', 'stop_hook_active': True}
                                if event == 'Stop' else {
                                    'hook_event_name': 'PreToolUse',
                                    'tool_name': 'apply_patch' if matcher['matcher']=='Write|Edit' else 'Bash',
                                    'tool_input': {'command': '*** Begin Patch\n*** Add File: clean.py\n+x = 1\n*** End Patch'
                                                   if matcher['matcher']=='Write|Edit' else 'git status --short'}})
                        result = subprocess.run(command, shell=True, input=json.dumps(data).encode(),
                                                capture_output=True, env=environment, timeout=30)
                        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))
                        self.assertEqual(json.loads(result.stdout), {})
                        self.assertEqual(result.stderr, b'')


if __name__ == '__main__':
    unittest.main(verbosity=2)
