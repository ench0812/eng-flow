#!/usr/bin/env bash
# Codex-only boundary. Exit 2 is a supported blocking response even if Python
# cannot start. Never use this wrapper on the default Claude path.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
if ! command -v python >/dev/null 2>&1; then
  cat >/dev/null
  printf '%s\n' '[eng-flow Codex] 缺少 python，安全檢查未執行，已阻擋。' >&2
  exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
  cat >/dev/null
  printf '%s\n' '[eng-flow Codex] 缺少 timeout，無法保證總檢查上限，已阻擋。' >&2
  exit 2
fi
# Bound the whole scan, not each file separately: many individually bounded
# scans can exceed Codex's 30s hook timeout and be cancelled by the host.
# Reserve time for wrapper startup and the blocking exit after cancellation.
PYTHONUTF8=1 timeout --kill-after=1s 24s python "$DIR/codex-hook.py" "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '[eng-flow Codex] 轉接程式未正常完成，已阻擋；請修復，勿繞過。' >&2
  exit 2
fi
