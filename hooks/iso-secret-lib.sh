#!/usr/bin/env bash
# iso-secret-lib.sh - shared secret detection for eng-flow ISO 27001 hooks.
# gitleaks-first, regex-fallback. Sourced by iso-scan-write.sh / iso-scan-bash.sh.
#
# find_secret  : reads text on stdin. Prints a reason and returns 0 if a likely
#                secret is found; returns 1 if clean.

find_secret() {
  local text
  text="$(cat)"

  # Inline bypass for confirmed false positives.
  if printf '%s' "$text" | grep -qiE 'iso-scan:[[:space:]]*ignore'; then
    return 1
  fi

  # Prefer gitleaks when installed (broad, low-FP rule set).
  if command -v gitleaks >/dev/null 2>&1; then
    local tmp rc=0
    tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/iso-$$.tmp")"
    printf '%s' "$text" > "$tmp"
    gitleaks detect --no-git --redact -s "$tmp" >/dev/null 2>&1 || rc=1
    rm -f "$tmp"
    if [ "$rc" -eq 1 ]; then
      echo "gitleaks: secret detected"
      return 0
    fi
    return 1
  fi

  # Regex fallback (high-precision, value-oriented).
  if printf '%s' "$text" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    echo "private key block"; return 0
  fi
  if printf '%s' "$text" | grep -qE 'AKIA[0-9A-Z]{16}'; then echo "AWS access key id"; return 0; fi
  if printf '%s' "$text" | grep -qE 'AIza[0-9A-Za-z_-]{35}'; then echo "Google API key"; return 0; fi
  if printf '%s' "$text" | grep -qE 'xox[baprs]-[0-9A-Za-z-]{10,}'; then echo "Slack token"; return 0; fi
  if printf '%s' "$text" | grep -qE 'gh[pousr]_[0-9A-Za-z]{36,}'; then echo "GitHub token"; return 0; fi
  if printf '%s' "$text" | grep -qE 'github_pat_[0-9A-Za-z_]{60,}'; then echo "GitHub PAT"; return 0; fi
  if printf '%s' "$text" | grep -qE '[sr]k_(live|test)_[0-9A-Za-z]{16,}'; then echo "Stripe secret key"; return 0; fi

  # Generic "<secret-keyword> = <quoted value>" assignment, minus obvious placeholders.
  local Q NQ PREFIX pat hits
  Q='["'"'"']'        # ["']
  NQ='[^"'"'"']'      # [^"']
  PREFIX='(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)[[:space:]]*[:=][[:space:]]*'
  pat="${PREFIX}${Q}${NQ}{8,}${Q}"
  hits="$(printf '%s\n' "$text" \
    | grep -iE "$pat" 2>/dev/null \
    | grep -ivE 'process\.env|os\.environ|getenv|ENV\[|System\.getenv|\$\{|\$\(|<[^>]+>|example|placeholder|changeme|your[_-]|xxxx|\*\*\*|dummy|sample|redacted|fake|todo' 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "hardcoded credential assignment"; return 0
  fi

  return 1
}
