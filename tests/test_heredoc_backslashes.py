"""Send actual hook JSON; assert denied and allowed paths, without running payloads."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = Path(os.environ.get('HEREDOC_HOOK_UNDER_TEST', ROOT / 'hooks/no-heredoc-backslashes.py'))


class HeredocGuardTests(unittest.TestCase):
    def invoke(self, payload: object) -> dict:
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def decision(self, command: str) -> str:
        result = self.invoke({'tool_name': 'Bash', 'tool_input': {'command': command}})
        return result.get('hookSpecificOutput', {}).get('permissionDecision', 'allow')

    def test_risky_bodies(self):
        commands = [
            "python <<'PY'\nx = '\\\\'\nPY",
            "python3 - <<PY\nx = '\\\\'\nPY",
            'cat > fix.py <<"PY"\nx = "\\\\"\nPY',
            "python - <<-'PY'\n\tx = '\\\\'\n\tPY",
            "python - <<- 'PY'\n\tx = '\\\\'\n\tPY",
            "cat <<A <<'B'\nplain\nA\n\\s\nB",
            "echo ready\npython <<'PY'\nx = r'\\s'\nPY",
            "cat <<'SQL'\nSELECT E'\\\\s';\nSQL",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.decision(command), 'deny')

    def test_safe_alternatives_and_false_positives(self):
        commands = [
            'python fix.py',
            "python <<'PY'\nprint(1)\nPY",
            'cat <<EOF\nordinary text\nEOF',
            "echo 'python <<PY \\\\'",
            '# python <<PY\necho "\\\\"',
            "cat <<'EOF'\nEOF\nprintf '%s' '\\\\'",
            'python <<PY\nprint(1)\nPY\nprintf "%s" "\\\\"',
            "cat <<'EOF'; echo done\nplain\nEOF\nprintf '%s' '\\\\'",
            "cat <<< '\\\\'",
            'echo $((1 << 2))',
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.decision(command), 'allow')

    def test_non_bash_and_malformed_payload(self):
        for payload in [None, [], {}, {'tool_input': None}, {'tool_input': {'command': 1}},
                        {'tool_name': 'PowerShell', 'tool_input': {'command': "cat <<PY\n\\\nPY"}}]:
            with self.subTest(payload=payload):
                self.assertEqual(self.invoke(payload), {})

    def test_actionable_deny_schema(self):
        response = self.invoke({'tool_input': {'command': "python <<PY\n'\\\\'\nPY"}})
        output = response['hookSpecificOutput']
        self.assertEqual(output['hookEventName'], 'PreToolUse')
        self.assertEqual(output['permissionDecision'], 'deny')
        self.assertIn('Edit', output['permissionDecisionReason'])
        self.assertIn('Write', output['permissionDecisionReason'])

    @unittest.skipUnless(os.name == 'nt', 'Windows Bash transport guard')
    def test_registered_shell_entrypoint(self):
        wrapper = ROOT / 'hooks/no-heredoc-backslashes.sh'
        for command, expected in [("python <<'PY'\nx='\\\\'\nPY", 'deny'),
                                  ('python fix.py', 'allow')]:
            result = subprocess.run(
                ['C:/Program Files/Git/bin/bash.exe', str(wrapper)],
                input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}}),
                text=True, capture_output=True, check=True,
                env=dict(os.environ, OS='Windows_NT'),
            )
            data = json.loads(result.stdout) if result.stdout.strip() else {}
            self.assertEqual(data.get('hookSpecificOutput', {}).get('permissionDecision', 'allow'),
                             expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
