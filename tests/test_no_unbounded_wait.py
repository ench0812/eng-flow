"""Send actual hook JSON; assert denied and allowed wait loops, without running payloads."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = Path(os.environ.get('UNBOUNDED_WAIT_HOOK_UNDER_TEST', ROOT / 'hooks/no-unbounded-wait.py'))
WRAPPER = Path(os.environ.get('UNBOUNDED_WAIT_WRAPPER_UNDER_TEST', ROOT / 'hooks/no-unbounded-wait.sh'))


class UnboundedWaitTests(unittest.TestCase):
    def invoke(self, payload: object) -> dict:
        result = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def decision(self, command: str, **extra) -> str:
        result = self.invoke({'tool_name': 'Bash', 'tool_input': {'command': command, **extra}})
        return result.get('hookSpecificOutput', {}).get('permissionDecision', 'allow')

    def test_original_incident(self):
        # 2026-10-16: moved to the background at the 590 s timeout, then ran 320 more minutes.
        command = 'until grep -q "^EXIT=" /d/Temp/manual-capture.log; do sleep 15; done; tail -12 /d/Temp/manual-capture.log'
        self.assertEqual(self.decision(command, timeout=590000), 'deny')

    def test_unbounded_loops(self):
        commands = [
            'while true; do curl -s localhost:3000 && break; sleep 5; done',
            'while [ ! -f done.txt ]; do sleep 2; done',
            'until grep -q DONE out.txt\ndo\n  sleep 5\ndone',
            'n=0; until grep -q X f; do ((n++)); sleep 1; done',
            # A bound elsewhere in the command does not bound this loop.
            'echo $SECONDS; until grep -q X f; do sleep 5; done',
            'timeout 5 curl -s x; until grep -q X f; do sleep 5; done',
            'for i in $(seq 1 3); do echo $i; done; until grep -q X f; do sleep 1; done',
            # A bounded outer loop does not bound an unbounded inner loop, and vice versa.
            'end=$((SECONDS+60)); until [ $SECONDS -ge $end ]; do until grep -q X f; do sleep 1; done; done',
            'while true; do n=0; until curl -sf x || [ $n -ge 5 ]; do n=$((n+1)); sleep 1; done; sleep 10; done',
            'while true; do end=$((SECONDS+5)); until [ $SECONDS -ge $end ]; do sleep 1; done; done',
            # Loops at every command position the lexer has to recognise.
            'cd /x && until grep -q X f; do sleep 1; done',
            'false || while true; do sleep 1; done',
            'ls & until grep -q X f; do sleep 1; done',
            'x=$(until grep -q X f; do sleep 1; done; echo ok)',
            'if true; then until grep -q X f; do sleep 1; done; fi',
            'if x; then :; else until grep -q X f; do sleep 1; done; fi',
            '{ until grep -q X f; do sleep 1; done; }',
            # shlex glues punctuation runs; the loop after them must still be found.
            'cd /x;(until grep -q X f; do sleep 1; done)',
            'true&&(while true; do sleep 1; done)',
            # A variable whose name merely contains SECONDS is not a bound.
            'until grep -q X f; do sleep "$POLL_SECONDS"; done',
            # A comment inside the loop must not supply a bound.
            'until grep -q X f; do\n  sleep 1  # retry -lt 5\ndone',
            "until grep -q X f; do sleep 1; done # don't care",
            'until grep -q X f; do\n  sleep 1  # stop at "-ge 30"\ndone',
            # A `#` inside quotes is not a comment, so the loop after it is still seen.
            'git commit -m "fix #12"; until grep -q X f; do sleep 1; done',
            # `until read` retries forever after EOF; only `while read` ends with its input.
            'until read -r l; do sleep 1; done < /dev/null',
            'while ! read -r l; do sleep 1; done < /dev/null',
            # An arithmetic shift is not a heredoc; the lines after it are still code.
            'while true; do\n  n=$((1 << 2))\n  sleep 1\ndone',
            "cat <<'EOF' > a.txt\nplain\nEOF\nuntil grep -q X f; do sleep 1; done",
            'until grep -q X f; do sleep 1; done # waits for -lt',
            # An apostrophe in a comment line must not make the command unparsable, which would allow it.
            "# don't wait forever\nuntil grep -q X f; do sleep 1; done",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.decision(command), 'deny')

    def test_bounded_or_not_a_wait_loop(self):
        commands = [
            'end=$((SECONDS+240)); until grep -q X f || [ $SECONDS -ge $end ]; do sleep 10; done',
            'for i in $(seq 1 60); do grep -q DONE out && break; sleep 5; done',
            'n=0; until grep -q X f; do n=$((n+1)); [ $n -ge 30 ] && break; sleep 2; done',
            'while [ "$(date +%s)" -lt "$target" ]; do sleep 5; done',
            'end=$(( $(date +%s) + 60 )); until (( $(date +%s) > end )); do sleep 5; done',
            'n=0; while (( n < 30 )); do n=$((n+1)); sleep 1; done',
            'while IFS= read -r l; do echo "$l"; sleep 0.1; done < list.txt',
            "timeout 300 bash -c 'until grep -q X f; do sleep 5; done'",
            'git commit -m "until done; do sleep 5; done"',
            "cat > wait.sh <<'EOF'\nuntil grep -q X f; do sleep 5; done\nEOF",
            'grep -n while f.txt; sleep 2',
            '# until x; do sleep 1; done\necho ok',
            '# old way; until grep -q X f; do sleep 1; done\necho ok',
            'while read -r p; do kill -0 "$p"; done < pids.txt',
            'CLAUDE_ALLOW_UNBOUNDED_WAIT=1; while true; do sleep 5; done',
            "echo 'unbalanced",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.decision(command), 'allow')

    def test_background_calls_are_left_to_the_tool_timeout(self):
        self.assertEqual(self.decision('while true; do sleep 5; done', run_in_background=True), 'allow')
        self.assertEqual(self.decision('while true; do sleep 5; done', run_in_background=False), 'deny')

    def test_non_bash_and_malformed_payload(self):
        for payload in [None, [], {}, {'tool_input': None}, {'tool_input': {'command': 1}},
                        {'tool_name': 'PowerShell', 'tool_input': {'command': 'while true; do sleep 5; done'}}]:
            with self.subTest(payload=payload):
                self.assertEqual(self.invoke(payload), {})

    def test_deny_message_names_the_loop_and_the_fix(self):
        out = self.invoke({'tool_name': 'Bash', 'tool_input': {'command': 'while true; do sleep 5; done'}})
        reason = out['hookSpecificOutput']['permissionDecisionReason']
        self.assertIn('while true', reason)
        self.assertIn('run_in_background', reason)
        self.assertIn('SECONDS', reason)
        # The suggested fix must itself pass the hook.
        fix = 'end=$((SECONDS+100)); until grep -q X f || [ $SECONDS -ge $end ]; do sleep 10; done'
        self.assertIn(fix.split(';')[0], reason)
        self.assertEqual(self.decision(fix), 'allow')

    def test_non_ascii_command_is_decoded_as_utf8(self):
        payload = json.dumps({'tool_name': 'Bash', 'tool_input': {
            'command': 'echo "等待中"; until grep -q X f; do sleep 1; done'}}, ensure_ascii=False).encode('utf-8')
        env = {k: v for k, v in os.environ.items() if k not in ('PYTHONIOENCODING', 'PYTHONUTF8')}
        result = subprocess.run([sys.executable, str(HOOK)], input=payload, capture_output=True, check=True, env=env)
        self.assertIn(b'"deny"', result.stdout, result.stderr)

    def test_environment_escape(self):
        payload = json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'while true; do sleep 5; done'}})
        result = subprocess.run([sys.executable, str(HOOK)], input=payload, text=True, capture_output=True,
                                check=True, env=dict(os.environ, CLAUDE_ALLOW_UNBOUNDED_WAIT='1'))
        self.assertEqual(result.stdout.strip(), '')

    def test_registered_shell_entrypoint(self):
        # On Windows, Python's `bash` resolves to WSL bash, which cannot see this path; use Git Bash.
        git_bash = Path('C:/Program Files/Git/bin/bash.exe')
        bash = str(git_bash) if os.name == 'nt' and git_bash.exists() else 'bash'
        wrapper = WRAPPER
        for command, expected in [('until grep -q X f; do sleep 1; done', 'deny'),
                                  ('while true; do sleep 1; done', 'deny'),
                                  ('while read -r l; do echo "$l"; done < f', 'allow'),
                                  ('grep -n until f; sleep 2', 'allow'),
                                  ('ls -la', 'allow')]:
            with self.subTest(command=command):
                result = subprocess.run([bash, str(wrapper)], text=True, capture_output=True, check=True,
                                        input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}}))
                data = json.loads(result.stdout) if result.stdout.strip() else {}
                self.assertEqual(data.get('hookSpecificOutput', {}).get('permissionDecision', 'allow'),
                                 expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
