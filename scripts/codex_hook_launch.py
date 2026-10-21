"""Start Codex hooks with native Git Bash on Windows, never the WSL shim."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
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
        result = subprocess.run([str(bash), (ROOT/'scripts/codex-hook.sh').as_posix(), *sys.argv[1:]],
                                input=payload, env=env, timeout=27)
    except (OSError, subprocess.TimeoutExpired):
        print('[eng-flow Codex] 原生 Bash 啟動失敗或逾時，已阻擋；請修復執行環境。', file=sys.stderr)
        return 2
    return 0 if result.returncode == 0 else 2


if __name__ == '__main__':
    sys.exit(main())
