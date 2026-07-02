#!/usr/bin/env bash
# PreToolUse[Write|Edit] - block hardcoded secrets before Claude writes them.
# ISO 27001 A.8.24 (cryptography/secrets) + A.8.28 (secure coding).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/iso-secret-lib.sh"

input="$(cat)"
JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0   # cannot parse input safely; fail open

get() { printf '%s' "$input" | "$JQ" -r "$1 // \"\"" 2>/dev/null || true; }

path="$(get '.tool_input.file_path')"
# Union of content fields across Write (content) and Edit (new_string) variants.
content="$(get '.tool_input.content')
$(get '.tool_input.new_string')
$(get '.tool_input.file_content')"

# Skip low-risk paths to avoid false positives (docs, examples, fixtures, lockfiles).
case "$path" in
  *.md|*.mdx|*.txt|*.lock|*.example|*.sample|*.snap|*test*|*fixture*|*mock*|*__tests__*|*spec*) exit 0 ;;
esac

if reason="$(printf '%s' "$content" | find_secret)"; then
  "$JQ" -cn --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("[ISO 27001 A.8.24/A.8.28] Likely hardcoded secret blocked (" + $r + "). Use a secrets manager or env var. If this is a false positive, add an \"iso-scan:ignore\" comment on that line.")
    }
  }'
  exit 0
fi

if reason="$(printf '%s' "$content" | find_banned_crypto)"; then
  "$JQ" -cn --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("[ISO 27001 A.8.24] Banned crypto blocked (" + $r + "). Use SHA-256+/bcrypt/argon2 for hashing, AES-256-GCM for encryption. Non-security checksum? Add an \"iso-scan:ignore\" comment with justification.")
    }
  }'
  exit 0
fi
exit 0
