#!/usr/bin/env bash
# Table-driven regression tests for hooks/iso-scan-write.sh.
# Run: bash tests/iso-scan-write.test.sh   (exit 0 = all pass)
#
# Focus: the self-exemption must cover exactly the three scanner files in the
# hooks directory and nothing else. A same-named file in any other directory,
# and a real secret inside an exempted file, must both still be blocked.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/iso-scan-write.sh"
HOOKS_DIR="$ROOT/hooks"
pass=0; fail=0

bash -n "$HOOK" || { echo "SYNTAX ERROR in $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

check() {
  local desc="$1" path="$2" content="$3" expect="$4"   # expect: deny | allow
  local out decision
  out="$(jq -n --arg p "$path" --arg c "$content" \
        '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | bash "$HOOK")"
  if [ -z "$out" ]; then
    decision="allow"
  else
    decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
  fi
  if [ "$decision" = "$expect" ]; then
    pass=$((pass+1))
  else
    echo "FAIL [$desc] path='$path' expected=$expect got=$decision"; fail=$((fail+1))
  fi
}

WEAK='$h = md5($password);'
CRED='$cfg = ["api_key" => "AKIAZ3XK7QW9RTLM2BVD"];'

# --- self-exemption applies: the plugin's own scanners, in the hooks dir ---
check "own lib, weak-hash literal"    "$HOOKS_DIR/iso-secret-lib.sh"  "$WEAK" allow
check "own write hook, weak-hash"     "$HOOKS_DIR/iso-scan-write.sh"  "$WEAK" allow
check "own bash hook, weak-hash"      "$HOOKS_DIR/iso-scan-bash.sh"   "$WEAK" allow
check "own lib, real file content"    "$HOOKS_DIR/iso-secret-lib.sh"  "$(cat "$ROOT/hooks/iso-secret-lib.sh")" allow

# --- Windows-style paths: what Claude Code actually sends on Windows ---
# HOOKS_DIR is /c/... here; build the C:\dir\file form the tool really passes.
WIN_HOOKS="$(printf '%s' "$HOOKS_DIR" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
WIN_HOOKS="${WIN_HOOKS//\//\\}"
check "win path, own lib"             "$WIN_HOOKS\\iso-secret-lib.sh"  "$WEAK" allow
check "win path, own write hook"      "$WIN_HOOKS\\iso-scan-write.sh"  "$WEAK" allow
check "win path, secret in own lib"   "$WIN_HOOKS\\iso-secret-lib.sh"  "$CRED" deny
check "win path, other file"          "$WIN_HOOKS\\helper.sh"          "$WEAK" deny
# Same name, Windows form, in a directory that really exists -> still scanned.
WIN_ROOT="$(printf '%s' "$ROOT" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
WIN_ROOT="${WIN_ROOT//\//\\}"
check "win path, same name elsewhere" "$WIN_ROOT\\iso-secret-lib.sh"   "$WEAK" deny
check "win path, sibling dir"         "$WIN_ROOT\\skills\\iso-secret-lib.sh" "$WEAK" deny

# --- self-exemption must NOT be abusable ---
check "same name, /tmp"               "/tmp/iso-secret-lib.sh"        "$WEAK" deny
check "same name, sibling dir"        "$ROOT/skills/iso-secret-lib.sh" "$WEAK" deny
check "same name, parent dir"         "$ROOT/iso-secret-lib.sh"       "$WEAK" deny
check "other file in hooks dir"       "$HOOKS_DIR/helper.sh"          "$WEAK" deny
check "nonexistent dir, same name"    "/no/such/dir/iso-secret-lib.sh" "$WEAK" deny
check "empty path"                    ""                              "$WEAK" deny

# A directory holding only SOME of the three scanners is not a hooks dir.
PARTIAL="$(mktemp -d)"
: > "$PARTIAL/iso-secret-lib.sh"
check "partial dir, 1 of 3"           "$PARTIAL/iso-secret-lib.sh"    "$WEAK" deny
: > "$PARTIAL/iso-scan-write.sh"
check "partial dir, 2 of 3"           "$PARTIAL/iso-secret-lib.sh"    "$WEAK" deny
: > "$PARTIAL/iso-scan-bash.sh"
check "complete dir, 3 of 3"          "$PARTIAL/iso-secret-lib.sh"    "$WEAK" allow
check "complete dir, secret still caught" "$PARTIAL/iso-secret-lib.sh" "$CRED" deny
rm -rf "$PARTIAL"

# --- the copies that actually exist on this machine: all must be exempt ---
for d in "$ROOT/../../local/eng-flow/hooks" "$ROOT/../../cache/ench0812-plugins/eng-flow"/*/hooks; do
  [ -d "$d" ] || continue
  [ -f "$d/iso-scan-bash.sh" ] || continue
  check "installed copy $(basename "$(dirname "$d")")" "$d/iso-secret-lib.sh" "$WEAK" allow
done

# --- exemption is scoped to the crypto rule only: secrets still blocked ---
check "secret inside own lib"         "$HOOKS_DIR/iso-secret-lib.sh"  "$CRED" deny
check "secret inside own write hook"  "$HOOKS_DIR/iso-scan-write.sh"  "$CRED" deny

# --- ordinary files: no regression ---
check "php hardcoded aws key"         "/proj/src/cfg.php"             "$CRED" deny
check "php weak hash"                 "/proj/src/auth.php"            "$WEAK" deny
check "php clean"                     "/proj/src/ok.php"  '$k = getenv("AWS_KEY");' allow
check "php env placeholder"           "/proj/src/ok.php"  '$pw = "changeme";'       allow

# --- low-risk paths stay skipped (pre-existing behaviour) ---
check "markdown doc"                  "/proj/README.md"               "$CRED" allow
check "test fixture path"             "/proj/tests/fixture.php"       "$CRED" allow
check "lockfile"                      "/proj/composer.lock"           "$CRED" allow

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
