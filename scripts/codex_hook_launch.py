"""Start Codex hooks with native Git Bash on Windows, never the WSL shim."""
from __future__ import annotations

from pathlib import Path
import json
import os
import shutil
import subprocess
import sys

WINDOWS = os.name == 'nt'


def find_bash() -> Path | None:
    if not WINDOWS:
        executable = shutil.which('bash')
        return Path(executable) if executable else None
    roots = []
    git = shutil.which('git')
    if git:
        executable = Path(git).resolve()
        roots.extend((executable.parent.parent, executable.parent.parent.parent))
    for variable in ('ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)'):
        if os.environ.get(variable):
            roots.append(Path(os.environ[variable]) / 'Git')
    if os.environ.get('LOCALAPPDATA'):
        roots.append(Path(os.environ['LOCALAPPDATA']) / 'Programs/Git')
    for root in roots:
        candidate = root / 'bin/bash.exe'
        if candidate.is_file():
            return candidate.resolve()
    return None


def main() -> int:
    try:
        root = Path(__file__).resolve().parents[1]
        # Drain the host's input even when dependencies are missing, so a broken
        # stdin pipe cannot replace the intentional blocking status.
        payload = sys.stdin.buffer.read()
        bash = find_bash()
        if bash is None:
            print('[eng-flow Codex] 找不到可用的原生 Bash；Windows 需要 Git Bash，已阻擋。', file=sys.stderr)
            return 2
        env = dict(os.environ, PYTHONUTF8='1')
        # The inner adapter also resolves bash. Keep it on this same native shell;
        # do not mutate the user's PATH or config.toml.
        env['PATH'] = str(bash.parent) + os.pathsep + env.get('PATH', '')
        result = subprocess.run([str(bash), (root/'scripts/codex-hook.sh').as_posix(), *sys.argv[1:]],
                                input=payload, env=env, timeout=27, capture_output=True)
        # Do not let a failed child corrupt the fallback JSON or expose its input.
        if result.returncode != 0:
            return 2
        if not isinstance(json.loads(result.stdout), dict):
            return 2
        sys.stdout.buffer.write(result.stdout)
        sys.stderr.buffer.write(result.stderr)
        return 0
    except Exception:
        print('[eng-flow Codex] 原生 Bash 啟動失敗或逾時，已阻擋；請修復執行環境。', file=sys.stderr)
        return 2


def run() -> int:
    try:
        status = main()
    except BaseException:
        status = 2
    if status != 0:
        # PowerShell -Command normalizes native exit 2 to 1. Use the same JSON
        # decision protocol for PreToolUse; a failed Stop reminder must not loop.
        if 'git-unpushed-check' in sys.argv[1:]:
            sys.stdout.write('{}\n')
            print('[eng-flow Codex] git-unpushed-check launcher failed; reminder skipped.', file=sys.stderr)
        else:
            sys.stdout.write('{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
                             '"permissionDecision":"deny","permissionDecisionReason":'
                             '"[eng-flow Codex] launcher check failed; blocked."}}\n')
        return 0
    return status


if __name__ == '__main__':
    try:
        exit_code = run()
    except BaseException:
        # If even the blocking output cannot be delivered, avoid a traceback.
        # The host must still be able to launch us and receive our output.
        exit_code = 2
    sys.exit(exit_code)
