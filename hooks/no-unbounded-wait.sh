#!/usr/bin/env bash
# PreToolUse(Bash): deny foreground wait loops without a total bound.
# Rationale and scope are in no-unbounded-wait.py. Keep ordinary calls cheap.
set -uo pipefail
input="$(cat)"
case "$input" in *sleep*) ;; *) exit 0 ;; esac
case "$input" in *while*|*until*) ;; *) exit 0 ;; esac
if ! command -v python >/dev/null 2>&1; then
  echo '[no-unbounded-wait] Python unavailable; wait-loop check did not run.' >&2
  exit 0
fi
DIR="$(cd "$(dirname "$0")" && pwd -P)"
printf '%s' "$input" | python "$DIR/no-unbounded-wait.py"
