#!/usr/bin/env bash
# Table-driven tests for scripts/codex-review.sh doc mode.
# 測兩類離線可驗證的行為(皆在 Gate 1 之前觸發,不需要 codex、不會真的跑 review):
#   1. exit-2 呼叫端合約
#   2. 共議輪數上限 gate(Cross-Check Log 滿 3 輪 → STOP + exit 0)
# 合法呼叫的正向路徑由人工 E2E 覆蓋(stub 測不出 codex flag 錯誤——歷史教訓)。
# Run: bash tests/codex-review-args.test.sh   (exit 0 = all pass)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review.sh"
DOC="$ROOT/README.md"   # 任一存在的檔案即可
pass=0; fail=0
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

check() {
  local desc="$1" expect="$2"; shift 2
  bash "$SCRIPT" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect" ]; then pass=$((pass+1))
  else echo "FAIL [$desc] expected exit=$expect got=$rc"; fail=$((fail+1)); fi
}

# 輪數上限 gate: STOP 與環境 SKIP 同為 exit 0,須驗輸出內容區分。
# 未達上限的案例用空 HOME + 精簡 PATH 讓 Gate 1 必定 SKIP,絕不真的呼叫 codex。
check_out() {
  local desc="$1" expect_rc="$2" pattern="$3"; shift 3
  local out rc
  out="$(HOME="$FIX" PATH="/usr/bin:/bin" bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$expect_rc" ] && printf '%s\n' "$out" | grep -q "$pattern"; then pass=$((pass+1))
  else echo "FAIL [$desc] rc=$rc out=$out"; fail=$((fail+1)); fi
}

make_doc() { # $1=path $2=rounds
  local p="$1" n="$2" i=1
  { echo "# Fixture spec"; echo; echo "## Cross-Check Log"; } > "$p"
  while [ "$i" -le "$n" ]; do echo "### Round $i — 2026-07-23（sol/high）" >> "$p"; i=$((i+1)); done
}

bash -n "$SCRIPT" || { echo "SYNTAX ERROR in $SCRIPT"; exit 1; }

check "doc 檔不存在"        2 --doc "$ROOT/no-such-file.md" --kind spec --severity required
check "有 doc 缺 kind"      2 --doc "$DOC" --severity required
check "kind 非法值"         2 --doc "$DOC" --kind design --severity required
check "有 kind 缺 doc"      2 --kind spec --severity required
check "doc 與 base 互斥"    2 --doc "$DOC" --kind spec --base main --severity required
check "未知參數"            2 --bogus
check "--doc 缺值"          2 --doc
check "--kind 缺值"         2 --doc "$DOC" --kind
check "--severity 缺值"     2 --severity
check "help"                0 -h

make_doc "$FIX/r4.md" 4
make_doc "$FIX/r3.md" 3
make_doc "$FIX/r2.md" 2
make_doc "$FIX/r0.md" 0
check_out "3 輪達上限 → STOP"      0 "STOP:"  --doc "$FIX/r3.md" --kind spec --severity required
check_out "4 輪超上限 → STOP"      0 "STOP:"  --doc "$FIX/r4.md" --kind plan --severity critical
check_out "2 輪未達上限 → 續跑"    0 "SKIP:"  --doc "$FIX/r2.md" --kind spec --severity required
check_out "無 Round 紀錄 → 續跑"   0 "SKIP:"  --doc "$FIX/r0.md" --kind plan --severity required

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
