#!/usr/bin/env bash
# Deploy the ISO 27001 project gate into the CURRENT git repo (run from project root).
# Installs .githooks/pre-commit + .github/workflows/iso-compliance.yml and points
# git at the hook. Idempotent; pass --force to overwrite existing files.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TPL="$ROOT/templates"
force=0
[ "${1:-}" = "--force" ] && force=1

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ERROR: not inside a git repo. cd to your project root first." >&2
  exit 1
}

copy() { # src dest
  if [ -f "$2" ] && [ "$force" -ne 1 ]; then
    echo "skip (exists): $2   [--force to overwrite]"
    return
  fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  echo "wrote: $2"
}

copy "$TPL/pre-commit" ".githooks/pre-commit"
chmod +x ".githooks/pre-commit" 2>/dev/null || true
copy "$TPL/iso-compliance.yml" ".github/workflows/iso-compliance.yml"

git config core.hooksPath .githooks
echo "set:   git config core.hooksPath .githooks"
echo
echo "ISO 27001 project gate deployed."
echo "  - .githooks/pre-commit          secret scan + dependency audit on every commit"
echo "  - .github/workflows/iso-*.yml   same gate in CI for every PR/push"
echo "Optional: install gitleaks for deeper local secret scanning."
echo "Commit both files so the whole team inherits the gate."
