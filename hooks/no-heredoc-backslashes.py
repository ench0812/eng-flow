"""Reject backslashes in literal heredoc bodies before Windows Bash execution.

Recognizes ordinary <<WORD, <<'WORD', <<"WORD", <<-WORD and multiple
heredocs on one line. Does not interpret nested shell strings, substitutions,
or multiline quoted headers. This is a reliability guard, not shell security.
"""
from __future__ import annotations

import json
import shlex
import sys


def risky_heredoc(command: str) -> bool:
    pending: list[tuple[str, bool]] = []
    for line in command.splitlines():
        if pending:
            delimiter, strip_tabs = pending[0]
            body = line.lstrip('\t') if strip_tabs else line
            if body == delimiter:
                pending.pop(0)
            elif '\\' in body:
                return True
            continue
        lexer = shlex.shlex(line, posix=True, punctuation_chars='<>;&|()')
        lexer.whitespace_split = True
        try:
            tokens = list(lexer)
        except ValueError:
            continue
        for index, token in enumerate(tokens[:-1]):
            if token != '<<':  # <<< is a here-string, not a heredoc.
                continue
            delimiter = tokens[index + 1]
            strip_tabs = delimiter.startswith('-')
            if strip_tabs:
                delimiter = delimiter[1:]
                if not delimiter and index + 2 < len(tokens):
                    delimiter = tokens[index + 2]
            if delimiter:
                pending.append((delimiter, strip_tabs))
    return False


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (ValueError, UnicodeError):
        return
    if not isinstance(data, dict) or data.get('tool_name', 'Bash') != 'Bash':
        return
    tool_input = data.get('tool_input')
    command = tool_input.get('command') if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not risky_heredoc(command):
        return
    reason = (
        'Windows Bash heredoc 正文含反斜線，曾反覆在工具傳遞／多層跳脫時變形。'
        '停止這個寫法：修改現有檔案用 Edit；新程式用 Write 寫成 .py/.sql/.jq 等檔案，'
        '再用 Bash 執行檔案。Codex 可用 apply_patch。'
        '不要增加反斜線、改 quoted heredoc 或改塞進 python -c 重試。'
        '這是已知風險攔截，不代表本次內容已被證實損壞。'
    )
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': reason,
    }}, ensure_ascii=True))


if __name__ == '__main__':
    main()
