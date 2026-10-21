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
PYTHONUTF8=1 python "$DIR/codex-hook.py" "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '[eng-flow Codex] 轉接程式未正常完成，已阻擋；請修復，勿繞過。' >&2
  exit 2
fi
