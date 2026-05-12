#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$(dirname "$SCRIPT_DIR")/skills"
META_SKILL="$SKILLS_DIR/mao-init/SKILL.md"

if [ -f "$META_SKILL" ]; then
  CONTENT=$(cat "$META_SKILL")
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg message "$CONTENT" '{priority: "IMPORTANT", message: $message}'
  else
    echo "{\"priority\": \"IMPORTANT\", \"message\": \"eng-flow loaded. Invoke skills via Skill tool with eng-flow: prefix.\"}"
  fi
else
  echo '{"priority": "INFO", "message": "eng-flow: mao-init skill not found."}'
fi
