#!/usr/bin/env bash
# Windows Bash-tool transport has repeatedly damaged backslashes in heredocs.
# Keep ordinary calls cheap; this guard is not a general shell parser.
set -uo pipefail
input="$(cat)"
case "${OS:-}:$OSTYPE" in Windows_NT:*|*:msys*|*:cygwin*) ;; *) exit 0 ;; esac
case "$input" in *'<<'*) ;; *) exit 0 ;; esac
if ! command -v python >/dev/null 2>&1; then
  echo '[no-heredoc-backslashes] Python unavailable; heredoc check did not run.' >&2
  exit 0
fi
DIR="$(cd "$(dirname "$0")" && pwd -P)"
printf '%s' "$input" | python "$DIR/no-heredoc-backslashes.py"
