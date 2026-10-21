"""Explicit Codex adapter; Claude entry points keep their original output bytes.

Hook failures must produce a supported deny, not an unsupported ask/error.
The existing scanners remain the single source for secret/crypto rules.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HOOKS = {
    'iso-scan-bash', 'iso-scan-write', 'no-blind-sleep',
    'no-swallowed-exit-code', 'no-heredoc-backslashes',
    'no-unbounded-wait', 'git-unpushed-check',
}


def deny(reason: str) -> dict:
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny', 'permissionDecisionReason': reason}}


def additions(patch: str) -> list[tuple[str, str]]:
    """Parse apply_patch framing, retaining only added lines per file.

    Context/deleted lines cannot grant an ignore exemption. Keep file boundaries
    so an exemption in one file cannot exempt another file in the same patch.
    Reject unknown shapes instead of treating them as an empty/clean write.
    """
    lines = patch.splitlines()
    if not lines or lines[0] != '*** Begin Patch' or lines[-1] != '*** End Patch':
        raise ValueError('無法辨識 apply_patch 邊界')
    result: list[tuple[str, str]] = []
    path = None
    added: list[str] = []
    mode = None
    for line in lines[1:-1]:
        if line.startswith(('*** Add File: ', '*** Update File: ', '*** Delete File: ')):
            if path is not None:
                result.append((path, '\n'.join(added)))
            mode, path = line[4:].split(': ', 1)
            if not path.strip():
                raise ValueError('空白 patch 路徑')
            added = []
        elif path is None:
            raise ValueError('patch 行沒有檔案')
        elif line.startswith('+') and mode != 'Delete File':
            added.append(line[1:])
        elif mode == 'Update File' and (line == '' or
                line.startswith((' ', '-', '@@', '*** Move to: ')) or
                line == '*** End of File'):
            continue
        else:
            raise ValueError('無法辨識 patch 行')
    if path is not None:
        result.append((path, '\n'.join(added)))
    if not result:
        raise ValueError('patch 沒有檔案')
    return result


def legacy(hook: str, data: dict) -> dict:
    if not shutil.which('bash') or not shutil.which('jq'):
        raise RuntimeError('缺少 bash 或 jq，未完成掃描')
    if hook in {'no-heredoc-backslashes', 'no-unbounded-wait'} and not shutil.which('python'):
        raise RuntimeError('缺少 python，未完成掃描')
    env = dict(os.environ)
    # Avoid locale-dependent decoding in the existing Python hook.
    env['PYTHONUTF8'] = '1'
    completed = subprocess.run([shutil.which('bash'), (ROOT / 'hooks' / (hook + '.sh')).as_posix()],
                               input=json.dumps(data, ensure_ascii=True).encode(),
                               capture_output=True, timeout=20, env=env)
    if completed.returncode or completed.stderr.strip():
        raise RuntimeError(f'{hook} 執行失敗，未完成掃描（exit {completed.returncode}）')
    if not completed.stdout.strip():
        return {}
    output = json.loads(completed.stdout)
    if not isinstance(output, dict):
        raise ValueError('hook 輸出不是物件')
    specific = output.get('hookSpecificOutput', {})
    if specific.get('permissionDecision') == 'ask':
        return deny(specific.get('permissionDecisionReason', '') +
                    ' Codex 不支援 ask；請直接向使用者確認目標與操作，勿自動重試或繞過 hook。')
    return output


def stop(data: dict) -> dict:
    """Adapt Codex transcript cwd records; never infer write authorization.

    Codex tool records are not Claude tool_use objects. Map each known cwd to
    the existing guard's read-only scope. Conservative classification preserves
    reminders without falsely granting shared-branch push authorization.
    """
    if data.get('stop_hook_active'):
        return {}
    paths = {str(data.get('cwd', ''))}
    transcript = data.get('transcript_path')
    if transcript:
        with open(transcript, encoding='utf-8') as stream:
            for line in stream:
                record = json.loads(line)
                payload = record.get('payload', {})
                if isinstance(payload, dict) and isinstance(payload.get('cwd'), str):
                    paths.add(payload['cwd'])
                if isinstance(payload, dict) and payload.get('type') == 'function_call':
                    try:
                        args = json.loads(payload.get('arguments', '{}'))
                    except ValueError:
                        continue
                    if isinstance(args, dict):
                        for key in ('workdir', 'cwd'):
                            if isinstance(args.get(key), str):
                                paths.add(args[key])
    with tempfile.TemporaryDirectory(prefix='eng-flow-codex-stop-') as tmp:
        converted = Path(tmp) / 'transcript.jsonl'
        converted.write_bytes(('\n'.join(json.dumps({'cwd': p}, separators=(',', ':'))
                                       for p in sorted(paths) if p) + '\n').encode())
        output = legacy('git-unpushed-check', dict(data, transcript_path=str(converted)))
    context = output.get('hookSpecificOutput', {}).get('additionalContext')
    if context:
        return {'decision': 'block', 'reason': context +
                '\n當前任務的使用者指示優先；使用者指定只 commit、不 push 時只回報未推送狀態。'}
    return {}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True, choices=['codex'])
    parser.add_argument('--hook', required=True, choices=sorted(HOOKS))
    args = parser.parse_args()
    try:
        data = json.loads(sys.stdin.buffer.read().decode('utf-8'))
        if not isinstance(data, dict):
            raise ValueError('hook 輸入不是物件')
        if args.hook == 'git-unpushed-check':
            output = stop(data)
        elif args.hook == 'iso-scan-write':
            tool_input = data.get('tool_input')
            if not isinstance(tool_input, dict):
                raise ValueError('缺少 tool_input')
            patch = tool_input.get('command')
            if not isinstance(patch, str):
                raise ValueError('apply_patch 缺少字串 command')
            output = {}
            for _path, content in additions(patch):
                # Scan all added content, including fixtures/docs: legacy path
                # exclusions are too broad for a multi-file patch safety gate.
                result = legacy('iso-scan-write', {'tool_input': {'content': content}})
                if result:
                    output = result
                    break
        else:
            tool_input = data.get('tool_input')
            if not isinstance(tool_input, dict) or not isinstance(tool_input.get('command'), str):
                raise ValueError('缺少字串 tool_input.command')
            output = legacy(args.hook, data)
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        # Never print payloads: a parser error can contain secret-bearing text.
        message = f'[eng-flow Codex] {args.hook} 未完成檢查（{type(error).__name__}），已阻擋；請修復依賴或輸入格式。'
        output = ({'decision': 'block', 'reason': message}
                  if args.hook == 'git-unpushed-check' else deny(message))
    print(json.dumps(output, ensure_ascii=True))


if __name__ == '__main__':
    main()
