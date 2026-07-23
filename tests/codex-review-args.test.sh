#!/usr/bin/env bash
# Table-driven arg-contract tests for scripts/codex-review.sh doc mode.
# 只測 exit-2 呼叫端合約(在 Gate 1 之前觸發,不需要 codex、不會真的跑 review)。
# 合法呼叫的正向路徑由人工 E2E 覆蓋(stub 測不出 codex flag 錯誤——歷史教訓)。
# Run: bash tests/codex-review-args.test.sh   (exit 0 = all pass)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-review.sh"
DOC="$ROOT/README.md"   # 任一存在的檔案即可
pass=0; fail=0

check() {
  local desc="$1" expect="$2"; shift 2
  bash "$SCRIPT" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect" ]; then pass=$((pass+1))
  else echo "FAIL [$desc] expected exit=$expect got=$rc"; fail=$((fail+1)); fi
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
