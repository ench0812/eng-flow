#!/usr/bin/env bash
# Table-driven regression tests for hooks/iso-secret-lib.sh.
# Run: bash tests/iso-secret-lib.test.sh   (exit 0 = all pass)
#
# The key property under test: layer 2 (regex) runs even when layer 1 (gitleaks)
# reports clean. The canary is the AWS documentation sample key, which gitleaks
# allowlists but the regex must still catch.
set -u
LIB="$(cd "$(dirname "$0")/.." && pwd)/hooks/iso-secret-lib.sh"
bash -n "$LIB" || { echo "SYNTAX ERROR in $LIB"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

pass=0; fail=0

check_secret() {
  local desc="$1" text="$2" expect="$3"   # expect: found | clean
  local got
  if printf '%s' "$text" | find_secret >/dev/null; then got="found"; else got="clean"; fi
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1))
  else
    echo "FAIL [secret/$desc] expected=$expect got=$got"; fail=$((fail+1))
  fi
}

check_crypto() {
  local desc="$1" text="$2" expect="$3"
  local got
  if printf '%s' "$text" | find_banned_crypto >/dev/null; then got="found"; else got="clean"; fi
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1))
  else
    echo "FAIL [crypto/$desc] expected=$expect got=$got"; fail=$((fail+1))
  fi
}

if command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks: installed (both layers exercised)"
else
  echo "gitleaks: absent (layer 2 only)"
fi

# --- layer-2 canaries: gitleaks allowlists or misses these, regex must catch ---
check_secret "aws sample key (gitleaks allowlists)" \
  'cfg = {"key": "AKIAIOSFODNN7EXAMPLE"}' found
check_secret "truncated private key block" \
  '-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA' found
check_secret "openssh private key block" \
  '-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXk=' found

# --- provider key formats ---
check_secret "aws access key id"  'k = "AKIAZ3XK7QW9RTLM2BVD"' found
check_secret "google api key"     'k = "AIzaSyD3xK7qW9rTlM2bVdN8fG1hJ4kL6pQ0sX2"' found
check_secret "slack token"        'tok = "xoxb-1234567890-abcdefghij"' found
check_secret "github token"       'tok = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"' found
check_secret "stripe secret key"  'k = "sk_live_A1b2C3d4E5f6G7h8"' found

# --- generic hardcoded credential assignment ---
check_secret "php password assign"    '$password = "hunter2hunter2";' found
check_secret "yaml client_secret"     'client_secret: "s3cr3tValue123"' found

# --- must stay clean: env lookups ---
check_secret "php getenv"      '$key = getenv("AWS_KEY");' clean
check_secret "node process.env" 'const key = process.env.API_KEY;' clean
check_secret "python environ"  'password = os.environ["PW"]' clean
check_secret "shell expansion" 'api_key = "${API_KEY}"' clean

# --- must stay clean: placeholders ---
check_secret "changeme"        'password = "changeme"' clean
check_secret "your_ prefix"    'api_key = "your_api_key_here"' clean
check_secret "example value"   'secret = "example_secret_value"' clean
check_secret "redacted"        'auth_token = "redacted-for-docs"' clean

# --- must stay clean: ordinary code, no credential shape ---
check_secret "plain php"       '$user = User::find($id); return $user->name;' clean
check_secret "short value"     'pwd = "abc"' clean

# --- inline bypass ---
check_secret "iso-scan:ignore bypass" \
  '$password = "hunter2hunter2"; // iso-scan:ignore fixture' clean

# --- banned crypto (unchanged behaviour, guard against regression) ---
check_crypto "php md5"          '$h = md5($password);' found
check_crypto "python hashlib"   'h = hashlib.sha1(data)' found
check_crypto "java DES"         'Cipher.getInstance("DES/CBC/PKCS5Padding")' found
check_crypto "node createHash"  "crypto.createHash('md5')" found
check_crypto "sha256 ok"        "hash('sha256', \$x)" clean
check_crypto "aes-256-gcm ok"   "createCipheriv('aes-256-gcm', k, iv)" clean
check_crypto "crypto bypass"    '$h = md5($x); // iso-scan:ignore non-security checksum' clean

# --- layer 1 hanging must not take layer 2 down with it ---
# A stubbed gitleaks that never returns should hit find_secret's own 8s cap and
# fall through to the regex layer, rather than blocking until the hook is killed.
if command -v timeout >/dev/null 2>&1; then
  STUB="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$STUB/gitleaks"
  chmod +x "$STUB/gitleaks"
  start=$(date +%s)
  if PATH="$STUB:$PATH" find_secret >/dev/null <<< 'k = "AKIAZ3XK7QW9RTLM2BVD"'; then got=found; else got=clean; fi
  elapsed=$(( $(date +%s) - start ))
  if [ "$got" = "found" ] && [ "$elapsed" -lt 20 ]; then
    pass=$((pass+1))
  else
    echo "FAIL [layer1 hang] got=$got elapsed=${elapsed}s (want found, <20s)"; fail=$((fail+1))
  fi
  # And a clean payload must stay clean rather than failing closed on the timeout.
  if PATH="$STUB:$PATH" find_secret >/dev/null <<< '$k = getenv("AWS_KEY");'; then got=found; else got=clean; fi
  if [ "$got" = "clean" ]; then pass=$((pass+1))
  else echo "FAIL [layer1 hang, clean payload] expected clean got=$got"; fail=$((fail+1)); fi
  rm -rf "$STUB"
else
  echo "SKIP: no timeout(1) available — layer-1 cap untested"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
