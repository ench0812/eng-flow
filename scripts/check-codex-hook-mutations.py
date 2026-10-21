"""Run bounded negative controls on disposable copies; never edit the checkout."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MUTANTS = {
    'ask-conversion-removed': ("if specific.get('permissionDecision') == 'ask':", 'if False:'),
    'patch-scan-removed': ('for _path, content in additions(patch):', 'for _path, content in []:'),
    'crypto-scan-removed': None,
    'ignore-removed': None,
    'file-boundary-removed': ('for _path, content in additions(patch):',
                            'for _path, content in [("all", "\\n".join(c for _, c in additions(patch))) ]:'),
    'validation-deny-removed': ('else deny(message))', 'else {})'),
    'total-deadline-removed': ('timeout --kill-after=1s 24s python', 'python'),
}


def suite(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(ROOT / 'tests/test_codex_hooks.py')],
                          env=dict(os.environ, CODEX_HOOK_TEST_ROOT=str(root)),
                          capture_output=True, timeout=120)


def main() -> int:
    for label, change in MUTANTS.items():
        with tempfile.TemporaryDirectory(prefix='eng-flow-mutant-') as temp:
            root = Path(temp)
            for name in ('hooks', 'scripts', 'tests'):
                shutil.copytree(ROOT / name, root / name, ignore=shutil.ignore_patterns('__pycache__'))
            if change:
                path = root / ('scripts/codex-hook.sh' if label == 'total-deadline-removed'
                               else 'scripts/codex-hook.py')
                old, new = change
            elif label == 'crypto-scan-removed':
                path = root / 'hooks/iso-scan-write.sh'
                old = 'if reason="$(printf \'%s\' "$content" | find_banned_crypto)"; then'
                new = 'if false; then'
            else:
                path = root / 'hooks/iso-secret-lib.sh'
                old = 'if _ci_match "$text" \'iso-scan:[[:blank:]]*ignore\'; then'
                new = 'if false; then'
            source = path.read_text(encoding='utf-8')
            if old not in source:
                raise RuntimeError('mutation anchor drift: ' + label)
            path.write_bytes(source.replace(old, new).encode())
            result = suite(root)
            output = result.stdout + result.stderr
            completed = b'Ran 15 tests' in output and b'FAILED (' in output
            print(f'{label}: exit={result.returncode} completed={completed}', flush=True)
            if result.returncode != 1 or not completed:
                sys.stderr.buffer.write(output)
                return 1
    green = suite(ROOT)
    output = green.stdout + green.stderr
    completed = b'Ran 15 tests' in output and b'OK' in output
    print(f'restored: exit={green.returncode} completed={completed}', flush=True)
    return 0 if green.returncode == 0 and completed else 1


if __name__ == '__main__':
    sys.exit(main())
