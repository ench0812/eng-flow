"""Exercise real scanners and adapter, without executing dangerous payloads."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(os.environ.get('CODEX_HOOK_TEST_ROOT', Path(__file__).resolve().parents[1]))
KEY = 'AKIA' + 'FAKECODEXPROBE0000'  # obviously fake, matches AWS ID grammar


class CodexHooks(unittest.TestCase):
    def call(self, hook, data, host=True):
        command = [shutil.which('bash'), (ROOT / 'hooks' / (hook + '.sh')).as_posix()]
        if host:
            command += ['--host', 'codex']
        result = subprocess.run(command, input=json.dumps(data), text=True,
                                capture_output=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def decision(self, output):
        return output.get('hookSpecificOutput', {}).get('permissionDecision', 'allow')

    def patch(self, content, path='app.py'):
        return '*** Begin Patch\n*** Add File: ' + path + '\n' + '\n'.join(
            '+' + line for line in content.splitlines()) + '\n*** End Patch'

    def scan(self, patch):
        return self.decision(self.call('iso-scan-write', {
            'tool_name': 'apply_patch', 'tool_input': {'command': patch}}))

    def test_destructive_commands_deny(self):
        for command in ['git push --force origin main', 'git push -f',
                        'git push origin +HEAD:main', 'git reset --hard',
                        'git clean -fdx', 'git restore .']:
            with self.subTest(command=command):
                output = self.call('iso-scan-bash', {'tool_name': 'Bash', 'tool_input': {'command': command}})
                self.assertEqual(self.decision(output), 'deny')
                self.assertIn('使用者確認', output['hookSpecificOutput']['permissionDecisionReason'])

    def test_claude_ask_preserved(self):
        self.assertEqual(self.decision(self.call('iso-scan-bash', {
            'tool_input': {'command': 'git push --force'}}, host=False)), 'ask')

    def test_secret_added(self):
        self.assertEqual(self.scan(self.patch('key = "' + KEY + '"')), 'deny')

    def test_secret_in_docs_still_scanned(self):
        self.assertEqual(self.scan(self.patch(KEY, 'notes.md')), 'deny')

    def test_banned_crypto_added(self):
        for code in ['hashlib.md5(data)', 'hashlib.sha1(data)',
                     'createCipheriv("des", key, iv)', 'createCipheriv("rc4", key, iv)']:
            with self.subTest(code=code):
                self.assertEqual(self.scan(self.patch(code)), 'deny')

    def test_secret_ignore_allowed(self):
        self.assertEqual(self.scan(self.patch(KEY + ' # iso-scan:ignore fake acceptance data')), 'allow')

    def test_crypto_ignore_allowed(self):
        self.assertEqual(self.scan(self.patch('hashlib.md5(data) # iso-scan:ignore checksum only')), 'allow')

    def test_deleted_secret_not_scanned(self):
        self.assertEqual(self.scan('*** Begin Patch\n*** Update File: app.py\n@@\n-' + KEY + '\n+safe = 1\n*** End Patch'), 'allow')

    def test_context_ignore_cannot_exempt_addition(self):
        self.assertEqual(self.scan('*** Begin Patch\n*** Update File: app.py\n@@\n # iso-scan:ignore old checksum\n+' + KEY + '\n*** End Patch'), 'deny')

    def test_file_ignore_cannot_exempt_other_file(self):
        self.assertEqual(self.scan('*** Begin Patch\n*** Add File: first.py\n+# iso-scan:ignore harmless\n*** Add File: second.py\n+' + KEY + '\n*** End Patch'), 'deny')

    def test_malformed_patch_denied(self):
        self.assertEqual(self.scan('not a patch'), 'deny')

    def test_missing_command_denied(self):
        for name in ['iso-scan-write', 'iso-scan-bash']:
            with self.subTest(name=name):
                self.assertEqual(self.decision(self.call(name, {'tool_input': {}})), 'deny')

    def test_clean_patch_allowed(self):
        self.assertEqual(self.scan(self.patch('x = 1')), 'allow')

    def test_clean_shell_allowed(self):
        self.assertEqual(self.decision(self.call('iso-scan-bash', {
            'tool_name': 'Bash', 'tool_input': {'command': 'git status --short'}})), 'allow')

    def test_total_scan_timeout_blocks(self):
        # Simulate GNU timeout cancelling the entire multi-file check. The
        # wrapper must convert this status to Codex's supported blocking exit.
        with tempfile.TemporaryDirectory(prefix='codex-timeout-control-') as temp:
            timeout = Path(temp) / 'timeout'
            timeout.write_bytes(b'#!/usr/bin/env bash\nexit 124\n')
            timeout.chmod(0o755)
            # Git Bash prepends its own bin directories during startup. Apply
            # the fixture PATH from BASH_ENV after that conversion instead.
            startup = Path(temp) / 'env.sh'
            directory = Path(temp).as_posix()
            prefix = ('"$(cygpath -u \'' + directory + '\')"' if os.name == 'nt'
                      else "'" + directory + "'")
            startup.write_bytes(('export PATH=' + prefix + ':"$PATH"\n').encode())
            env = dict(os.environ, BASH_ENV=startup.as_posix())
            result = subprocess.run([shutil.which('bash'),
                                     (ROOT / 'hooks/iso-scan-bash.sh').as_posix(), '--host', 'codex'],
                                    input=json.dumps({'tool_input': {'command': 'git status'}}),
                                    text=True, capture_output=True, timeout=10, env=env)
            self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
