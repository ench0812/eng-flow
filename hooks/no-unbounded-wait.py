"""Deny foreground Bash wait loops (while/until ... sleep ... done) that have no
total bound of their own.

Why: a foreground command that outlives its tool timeout is moved to the
background by Claude Code, and after that nothing stops it. On 2026-10-16 a
subagent's `until grep -q "^EXIT=" log; do sleep 15; done` kept running for 320
minutes after being moved, until the main thread noticed. In the week of
10-11..10-18, 19 of 69 such loops (66 of them in subagents) hit the 590 s tool
timeout, and every 590 s block also outlives the 5-minute prompt cache.
AGENTS.md rule 11 already asks for bounded polling; this makes it mechanical.

Each while/until loop that contains `sleep` is judged on its own condition and
body; tokens of loops nested inside it do not count toward its bound. So a
bound elsewhere in the command does not count, a bounded loop does not excuse
an unbounded one next to it, and neither nesting direction excuses the other.
A loop is bounded when its own condition or body compares with -lt/-le/-gt/-ge,
or with < or > inside (( )). Mentioning SECONDS or `date +%s` without a
comparison (for example resetting a deadline every pass) is not a bound. While
loops whose condition runs `read` end with their input (`until read` and
`while ! read` do not). for/select loops end with their
list and are not checked. run_in_background calls are skipped: the tool's
timeout stops them. Loops detached with `&` are still denied on purpose: they
do not block, but nothing stops them either.
Escape: start the command with `CLAUDE_ALLOW_UNBOUNDED_WAIT=1;`, or set
CLAUDE_ALLOW_UNBOUNDED_WAIT=1 in the hook's environment.

Known misses, accepted: loops inside quoted strings (bash -c '...', which is
also how `timeout N bash -c` bounds a loop), eval, shell functions, scripts, a
comparison that is not really a bound (`ls -lt` in the body), `tail -f | while
read`, `done` used as a case pattern, comments on a line that continues a
multi-line quoted string, and commands shlex cannot split, which are allowed. Known false
positives, accepted: a bound counted with -eq/-ne/== or (( n-- )), and a loop
bounded by other means, such as a check command that gives up by itself; the
deny message says so and the escape covers it. This is a reliability guard,
not a shell parser.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys

ESCAPE = re.compile(r'^\s*CLAUDE_ALLOW_UNBOUNDED_WAIT=1[;\s]')
CMD_START = {None, ';', ';;', '&', '&&', '|', '||', '|&', '(', ')', '{', '}',
             '!', 'then', 'do', 'else', 'elif'}
# A lone < or > inside (( )) compares; << and >> are shifts.
BOUND = re.compile(r'(?<!\S)-(lt|le|gt|ge)(?!\S)|\(\((?:(?!\)\)).)*?(?<![<>])[<>](?![<>])')
PUNCT_ONLY = re.compile(r'[<>;&|()]+')
OPERATORS = re.compile(r'\(\(|\)\)|;;|&&|\|\||\|&|>>|<<|[;&|()<>]')


def heredoc_free_lines(command: str) -> list[str]:
    """Lines of the command outside heredoc bodies (a body is data, not code)."""
    kept: list[str] = []
    pending: list[tuple[str, bool]] = []
    for line in command.splitlines():
        if pending:
            delimiter, strip_tabs = pending[0]
            if (line.lstrip('\t') if strip_tabs else line) == delimiter:
                pending.pop(0)
            continue
        kept.append(line)
        lexer = shlex.shlex(line, posix=True, punctuation_chars='<>;&|()')
        lexer.whitespace_split = True
        try:
            tokens = list(lexer)
        except ValueError:
            continue
        for index, token in enumerate(tokens[:-1]):
            if token != '<<':
                continue
            # `$((1 << 2))` is an arithmetic shift, not a heredoc.
            before = ''.join(t for t in tokens[:index] if PUNCT_ONLY.fullmatch(t))
            if before.count('((') > before.count('))'):
                continue
            delimiter = tokens[index + 1]
            strip_tabs = delimiter.startswith('-')
            if strip_tabs:
                delimiter = delimiter[1:]
                if not delimiter and index + 2 < len(tokens):
                    delimiter = tokens[index + 2]
            if delimiter:
                pending.append((delimiter, strip_tabs))
    return kept


def strip_comment(line: str) -> str:
    """Cut a `#` comment that starts a word outside quotes (per line; quotes that span lines are not tracked)."""
    quote = None
    prev = ' '
    i = 0
    while i < len(line):
        c = line[i]
        if c == '\\' and quote != "'":
            prev = 'x'
            i += 2
            continue
        if quote:
            if c == quote:
                quote = None
        elif c in '\'"':
            quote = c
        elif c == '#' and prev.isspace():
            return line[:i]
        prev = c
        i += 1
    return line


def tokenize(command: str) -> list[str] | None:
    text = ' '.join(strip_comment(line) + ' ;' for line in heredoc_free_lines(command))
    lexer = shlex.shlex(text, posix=True, punctuation_chars='<>;&|()')
    lexer.whitespace_split = True
    lexer.commenters = ''
    try:
        raw = list(lexer)
    except ValueError:
        return None
    # shlex glues runs of punctuation (`));`, `;(`, `&&(`); split them back into operators.
    return [part for token in raw
            for part in (OPERATORS.findall(token) if PUNCT_ONLY.fullmatch(token) else [token])]


def unbounded_loops(command: str) -> list[str]:
    tokens = tokenize(command)
    if not tokens:
        return []
    open_loops: list[dict] = []
    loops: list[dict] = []
    for i, token in enumerate(tokens):
        if (tokens[i - 1] if i else None) not in CMD_START:
            continue
        if token in ('while', 'until', 'for', 'select'):
            open_loops.append({'kind': token, 'start': i, 'do': None})
        elif token == 'do':
            for loop in reversed(open_loops):
                if loop['do'] is None:
                    loop['do'] = i
                    break
        elif token == 'done' and open_loops:
            loop = open_loops.pop()
            loop['end'] = i
            loops.append(loop)
    for loop in open_loops:
        loop['end'] = len(tokens)
        loops.append(loop)
    found = []
    for loop in sorted(loops, key=lambda x: x['start']):
        if loop['kind'] not in ('while', 'until'):
            continue
        region = tokens[loop['start'] + 1:loop['end']]
        if 'sleep' not in region:
            continue
        condition = region[:loop['do'] - loop['start'] - 1] if loop['do'] else region
        nested = [(x['start'], x['end']) for x in loops
                  if loop['start'] < x['start'] and x['end'] <= loop['end'] and x is not loop]
        own = [t for j, t in enumerate(tokens[loop['start'] + 1:loop['end']], loop['start'] + 1)
               if not any(s <= j <= e for s, e in nested)]
        # `while read` ends at EOF; `until read` and `while ! read` retry forever after EOF.
        if (loop['kind'] == 'while' and 'read' in condition and '!' not in condition) or BOUND.search(' '.join(own)):
            continue
        found.append(' '.join(tokens[loop['start']:loop['end'] + 1])[:120])
    return found


def main() -> None:
    if os.environ.get('CLAUDE_ALLOW_UNBOUNDED_WAIT') == '1':
        return
    try:
        # Bytes, not the locale codec: on a cp950 console a non-ASCII command would fail to decode and be allowed.
        data = json.loads(sys.stdin.buffer.read().decode('utf-8'))
    except (ValueError, UnicodeError):
        return
    if not isinstance(data, dict) or data.get('tool_name', 'Bash') != 'Bash':
        return
    tool_input = data.get('tool_input')
    if not isinstance(tool_input, dict) or tool_input.get('run_in_background') is True:
        return
    command = tool_input.get('command')
    if not isinstance(command, str) or ESCAPE.match(command):
        return
    found = unbounded_loops(command)
    if not found:
        return
    reason = (
        '前景等待迴圈沒有自己的總上限：' + found[0] + '\n'
        '前景指令超過工具逾時會被移到背景，之後沒有任何東西會停掉它'
        '（2026-10-16 一例移到背景後又跑了 320 分鐘）；卡滿逾時的阻塞也會讓 5 分鐘的 prompt cache 失效。\n'
        '改法：\n'
        '  1) 等的是你自己要起的指令 → 用 run_in_background: true 跑那個指令本身，完成時會通知你，不要再輪詢。\n'
        '  2) 等外部狀態 → 在這個迴圈的條件裡加總上限，迴圈後再判一次、逾時回非零：\n'
        '       end=$((SECONDS+100)); until <check> || [ $SECONDS -ge $end ]; do sleep 10; done\n'
        '       <check> || { echo TIMEOUT >&2; exit 1; }\n'
        '     上限要小於這次呼叫的 timeout（預設 120 秒；要等 240 秒就同時設 timeout: 270000，不要超過 270 秒）。\n'
        '     <check> 本身也要很快返回（必要時 timeout 10 <check>），否則上限管不住。\n'
        '上限要寫在這個迴圈自己的條件或本體裡；同一條指令別處、或內層迴圈的上限都不算。\n'
        '計數上限請用 -ge／-gt 或 (( n >= N ))；-eq、== 與 (( n-- )) 不會被認成上限。\n'
        '確定要無上限（例如刻意在前景跑的守護迴圈）→ 指令開頭加 CLAUDE_ALLOW_UNBOUNDED_WAIT=1;'
    )
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': reason,
    }}, ensure_ascii=True))


if __name__ == '__main__':
    main()
