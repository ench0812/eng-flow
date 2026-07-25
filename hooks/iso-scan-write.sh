#!/usr/bin/env bash
# PreToolUse[Write|Edit] - block hardcoded secrets before Claude writes them.
# ISO 27001 A.8.24 (cryptography/secrets) + A.8.28 (secure coding).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=/dev/null
. "$DIR/iso-secret-lib.sh"

input="$(cat)"
JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0   # cannot parse input safely; fail open

# Self-exemption for this plugin's own scanners. Their source embeds detection
# patterns as string literals, so writing one of them whole trips the weak-hash
# rule on its own rule text. Scope of the exemption, deliberately narrow:
#   - the file must be one of the three scanners by name, AND its directory must
#     contain all three — i.e. it really is an eng-flow hooks directory. A lone
#     same-named file anywhere else is still scanned. Matching on the directory's
#     contents rather than on this hook's own path is deliberate: the copy that
#     executes (version cache) is never the copy being edited (marketplace clone
#     or dev clone), so a self-path comparison would never fire in practice.
#   - the weak-hash / banned-cipher rule only. Secret detection still runs on
#     these files, so a real credential pasted into a scanner is still blocked.
# Residual risk accepted: someone could pre-create three clean files with these
# exact names and then write a weak-hash call into one of them. Creating them
# goes through this same hook, and the payoff is a weak hash inside a file named
# after a scanner — not production code.
is_own_scanner() {
  local p="$1" d b
  [ -n "$p" ] || return 1
  # Claude Code passes Windows-style paths on Windows (C:\dir\file). basename
  # would return the whole string, so normalise separators before splitting;
  # `cd` + `pwd -P` then canonicalises C:/... to the shell's own form.
  p="${p//\\//}"
  b="$(basename "$p")"
  case "$b" in
    iso-secret-lib.sh|iso-scan-write.sh|iso-scan-bash.sh) ;;
    *) return 1 ;;
  esac
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  [ -n "$d" ] || return 1
  [ -f "$d/iso-secret-lib.sh" ] && [ -f "$d/iso-scan-write.sh" ] && [ -f "$d/iso-scan-bash.sh" ]
}

# Path first, content second. Skipped paths (docs, fixtures, lockfiles) now cost a
# single jq call instead of three plus a full scan — measured 2026-07-25: a 40KB
# markdown write went from ~550ms to ~270ms end to end.
path="$("$JQ" -r '.tool_input.file_path // ""' <<<"$input" 2>/dev/null || true)"

# Skip low-risk paths to avoid false positives (docs, examples, fixtures, lockfiles).
case "$path" in
  *.md|*.mdx|*.txt|*.lock|*.example|*.sample|*.snap|*test*|*fixture*|*mock*|*__tests__*|*spec*) exit 0 ;;
esac

# Union of content fields across Write (content) and Edit (new_string) variants,
# extracted in one jq invocation rather than three.
content="$("$JQ" -r '[.tool_input.content // "", .tool_input.new_string // "", .tool_input.file_content // ""] | join("\n")' <<<"$input" 2>/dev/null || true)"

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

if is_own_scanner "$path"; then
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
