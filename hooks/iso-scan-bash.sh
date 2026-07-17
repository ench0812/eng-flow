#!/usr/bin/env bash
# PreToolUse[Bash] - block security-bypassing / supply-chain-risky commands.
# ISO 27001 A.8.32 (change mgmt gates) + A.8.28/A.5.21 (secure coding / supply chain).
set -uo pipefail

input="$(cat)"
JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0
cmd="$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

deny() {
  "$JQ" -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

ask() {
  "$JQ" -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
  exit 0
}

# 1) --no-verify bypasses pre-commit/pre-push security hooks.
if printf '%s' "$cmd" | grep -qE -- '(^|[[:space:]])--no-verify([[:space:]]|$)'; then
  deny "[ISO 27001 A.8.32] '--no-verify' bypasses pre-commit security gates. Forbidden - fix the gate or get an approved override."
fi

# 2) Piping remote content straight into a shell (curl|bash) - supply-chain risk.
if printf '%s' "$cmd" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)'; then
  deny "[ISO 27001 A.8.28/A.5.21] Piping remote content into a shell is forbidden. Download, inspect, verify checksum/signature, then run."
fi

# 3) Destructive git operations - irreversible/history-rewriting, require explicit user approval (ask, not deny).
if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+([^&|;]*[[:space:]])?push[^&|;]*(^|[[:space:]])(-f|--force|\+[^[:space:]]+)([[:space:]]|$)'; then
  ask "[ISO 27001 A.8.32] Force-push (incl. '+refspec' form) can overwrite remote history other people rely on. Confirm this is intended before proceeding."
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+([^&|;]*[[:space:]])?reset[^&|;]*(^|[[:space:]])--hard([[:space:]]|$)'; then
  ask "[ISO 27001 A.8.32] 'git reset --hard' discards uncommitted work irreversibly. Confirm this is intended before proceeding."
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+([^&|;]*[[:space:]])?clean[^&|;]*(^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--force)([[:space:]]|$)'; then
  ask "[ISO 27001 A.8.32] 'git clean -f' (or combined flags like -fd/-fdx) permanently deletes untracked files. Confirm this is intended before proceeding."
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+([^&|;]*[[:space:]])?branch[^&|;]*(^|[[:space:]])-D([[:space:]]|$)'; then
  ask "[ISO 27001 A.8.32] 'git branch -D' force-deletes a branch, discarding unmerged commits. Confirm this is intended before proceeding."
fi

if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])git[[:space:]]+([^&|;]*[[:space:]])?(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)'; then
  ask "[ISO 27001 A.8.32] Reverting the whole working tree discards uncommitted local changes. Confirm this is intended before proceeding."
fi

exit 0
