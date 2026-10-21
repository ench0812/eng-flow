"""Exercise manifest commands with Windows' WSL launcher before Git Bash."""
import json
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
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

    def invoke(self, bash, result=None, error=None):
        payload = b'{"tool_input":{"command":"fake private payload"}}'
        errors = io.StringIO()
        with mock.patch.object(self.launch, 'find_bash', return_value=bash), \
             mock.patch.object(sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(payload))), \
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
        code, run, payload = self.invoke(bash, result=subprocess.CompletedProcess([], 0))
        self.assertEqual(code, 0)
        args, kwargs = run.call_args
        self.assertEqual(args[0], [str(bash), (ROOT/'scripts/codex-hook.sh').as_posix(),
                                  '--host', 'codex', '--hook', 'iso-scan-write'])
        self.assertEqual(kwargs['input'], payload)
        self.assertEqual(kwargs['timeout'], 27)
        self.assertEqual(kwargs['env']['PATH'].split(os.pathsep)[0], str(bash.parent))
        self.assertEqual(os.environ.get('PATH'), original)


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
