#!/bin/bash
# SessionStart hook: 把 mao-init 注入每個 session 的 context。
#
# Claude Code 的 SessionStart 只認 hookSpecificOutput.additionalContext
# （另有 initialUserMessage / watchPaths / sessionTitle / reloadSkills）。
# stdout 一旦是合法 JSON，就只取認得的欄位、其餘整包丟棄——舊版印的
# {"priority":..,"message":..} 兩個欄位都不認得，等於靜默 no-op。
# 無 jq 時退回純文字：SessionStart 的純文字 stdout 一樣會進 context。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$(dirname "$SCRIPT_DIR")/skills"
META_SKILL="$SKILLS_DIR/mao-init/SKILL.md"

if [ -f "$META_SKILL" ]; then
  CONTENT=$(cat "$META_SKILL")
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ctx "$CONTENT" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  else
    printf '%s\n' "$CONTENT"
  fi
fi
