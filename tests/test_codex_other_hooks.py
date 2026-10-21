"""Every remaining manifest handler is exercised with Codex-shaped input."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OtherHooks(unittest.TestCase):
    def call(self, hook, data, env=None):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/codex-hook.py'),
                                 '--host', 'codex', '--hook', hook],
                                input=json.dumps(data).encode(), capture_output=True,
                                env=env, timeout=25, check=True)
        return json.loads(result.stdout)

    def test_each_shell_handler(self):
        cases = {
            'no-blind-sleep': 'sleep 300',
            'no-swallowed-exit-code': 'false | tail -1; echo $?',
            'no-heredoc-backslashes': "cat <<'EOF'\na = \\path\nEOF",
            'no-unbounded-wait': 'while true; do sleep 1; done',
        }
        for hook, command in cases.items():
            with self.subTest(hook=hook):
                result = self.call(hook, {'tool_name': 'Bash', 'tool_input': {'command': command}})
                self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')
                self.assertEqual(self.call(hook, {'tool_name': 'Bash', 'tool_input': {'command': 'echo ok'}}), {})

    def test_stop_transcript_and_no_loop(self):
        with tempfile.TemporaryDirectory(prefix='codex-stop-handler-') as temp:
            root = Path(temp)
            repo = root / 'repo'; repo.mkdir()
            def git(*args):
                subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)
            git('init'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
            (repo / 'sample').write_bytes(b'fixture\n')
            git('add', 'sample'); git('commit', '-m', 'fixture')
            transcript = root / 'session.jsonl'
            transcript.write_bytes(json.dumps({'type': 'session_meta', 'payload': {'cwd': str(repo)}}).encode())
            data = {'hook_event_name': 'Stop', 'session_id': 'codex-stop-fixture',
                    'cwd': str(root), 'transcript_path': str(transcript)}
            env = dict(os.environ, GIT_GUARD_ALLOW_TEMP='1', GIT_GUARD_STAMP_DIR=str(root / 'stamps'))
            result = self.call('git-unpushed-check', data, env)
            self.assertEqual(result['decision'], 'block')
            self.assertIn('[git-guard]', result['reason'])
            self.assertEqual(self.call('git-unpushed-check', dict(data, stop_hook_active=True), env), {})

    def test_missing_dependency_denied(self):
        with tempfile.TemporaryDirectory(prefix='codex-empty-path-') as temp:
            env = dict(os.environ, PATH=temp)
            result = self.call('iso-scan-bash', {'tool_input': {'command': 'git status'}}, env)
            self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')


if __name__ == '__main__':
    unittest.main(verbosity=2)
