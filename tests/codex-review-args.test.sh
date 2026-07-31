#!/usr/bin/env bash
# Table-driven tests for scripts/codex-review.sh doc mode.
# 測三類離線可驗證的行為(不需要 codex、不會真的跑 review):
#   1. exit-2 呼叫端合約
#   2. doc 模式次數上限 gate(Cross-Check Log 滿 4 次 → STOP + exit 0)
#   3. rate limit 判定(直接抽腳本裡的 pattern 與函式來測,不另抄一份以免 drift)
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

make_doc "$FIX/r5.md" 5
make_doc "$FIX/r4.md" 4
make_doc "$FIX/r3.md" 3
make_doc "$FIX/r0.md" 0
check_out "4 次達上限 → STOP"      0 "STOP:"  --doc "$FIX/r4.md" --kind spec --severity required
check_out "5 次超上限 → STOP"      0 "STOP:"  --doc "$FIX/r5.md" --kind plan --severity critical
check_out "3 次未達上限 → 續跑"    0 "SKIP:"  --doc "$FIX/r3.md" --kind spec --severity required
check_out "無 Round 紀錄 → 續跑"   0 "SKIP:"  --doc "$FIX/r0.md" --kind plan --severity required

# --- rate limit 判定 ---
# 從腳本抽出 pattern 常數與 is_rate_limited 本體,測的是實際生效的邏輯。
eval "$(sed -n '/^RATE_PAT_STRICT=/,/^}$/p' "$SCRIPT")"
if ! declare -f is_rate_limited >/dev/null; then
  echo "FAIL [抽取 is_rate_limited] sed 範圍失效,腳本結構可能已改"; fail=$((fail+1))
fi

check_rl() { # $1=desc $2=expect(yes|no) $3=rc $4=stderr內容 $5=stdout內容
  local desc="$1" expect="$2" rc="$3"
  printf '%s\n' "$4" > "$FIX/e.txt"; printf '%s\n' "$5" > "$FIX/o.txt"
  local got="no"
  is_rate_limited "$rc" "$FIX/e.txt" "$FIX/o.txt" && got="yes"
  if [ "$got" = "$expect" ]; then pass=$((pass+1))
  else echo "FAIL [rl/$desc] expected=$expect got=$got"; fail=$((fail+1)); fi
}

# 命中: codex 0.144.x binary 內實際的使用者可見字串
check_rl "hit usage limit (stderr)"    yes 1 "You've hit your usage limit." ""
check_rl "reached usage limit"         yes 1 "You've reached your usage limit." ""
check_rl "upgrade 變體"                yes 1 "You've hit your usage limit. Upgrade to Pro" ""
check_rl "workspace 沒額度"            yes 1 "Your workspace is out of credits." ""
check_rl "quota exceeded"              yes 1 "Quota exceeded" ""
check_rl "429 in stderr + 非零 rc"     yes 1 "HTTP 429 Too Many Requests" ""
check_rl "限制訊息落在 stdout"         yes 0 "" "You've hit your usage limit."

# 不命中: 接近上限、額度查詢、偏好設定,以及 review 內容裡的數字
check_rl "approaching(仍可用)"          no  0 "Approaching rate limits" ""
check_rl "額度查詢字樣"                 no  0 "Remaining usage on the daily usage limit" ""
check_rl "提醒偏好設定"                 no  0 "Hide future rate limit reminders" ""
check_rl "review 提到行號 429"          no  0 "" "src/app.php:429 needs a null check"
check_rl "stdout 有 429 且 rc 非零"     no  1 "" "line 429: too many requests handled here"
check_rl "429 但 codex 正常結束"        no  0 "429" ""
check_rl "一般失敗非 rate limit"        no  1 "connection refused" ""
check_rl "正常完成"                     no  0 "" "無重大遺漏"

# --- rate limit 端到端(stub codex) ---
# 這裡的 stub 只驗「腳本收到 rate limit 訊息後怎麼分流」,不驗 codex flag 是否正確
# ——後者 stub 永遠測不出來(歷史教訓),仍由人工 E2E 覆蓋。
STUB="$(mktemp -d)"
STUB_DOC="$STUB/spec.md"; printf '# Fixture\n\ncontent\n' > "$STUB_DOC"
mk_stub() { # $1 = exec 分支要跑的 shell 片段
  { echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    echo '  login) exit 0 ;;'
    echo "  exec)  $1 ;;"
    echo 'esac'
    echo 'exit 0'
  } > "$STUB/codex"
  chmod +x "$STUB/codex"
}
check_e2e() { # $1=desc $2=期望結束碼 $3=期望出現的字樣 $4=不該出現的字樣
  local desc="$1" expect_rc="$2" want="$3" unwanted="$4" out rc
  out="$(PATH="$STUB:$PATH" bash "$SCRIPT" --doc "$STUB_DOC" --kind spec --severity required 2>&1)"; rc=$?
  if [ "$rc" -eq "$expect_rc" ] && printf '%s' "$out" | grep -q "$want" \
     && ! printf '%s' "$out" | grep -q "$unwanted"; then
    pass=$((pass+1))
  else
    echo "FAIL [e2e/$desc] rc=$rc(expect $expect_rc) out=$out"; fail=$((fail+1))
  fi
}

mk_stub 'echo "You'"'"'ve hit your usage limit. Upgrade to Pro" >&2; exit 1'
check_e2e "用量上限 → RATE_LIMITED" 0 "RATE_LIMITED" "完成("
mk_stub 'echo "Your workspace is out of credits." >&2; exit 1'
check_e2e "工作區沒額度 → RATE_LIMITED" 0 "RATE_LIMITED" "完成("
mk_stub 'echo "無重大補充"; exit 0'
check_e2e "正常回覆 → 完成且輸出有串流" 0 "無重大補充" "RATE_LIMITED"
mk_stub 'echo "src/app.php:429 too many requests handled here"; exit 0'
check_e2e "review 提到 429 → 不誤判" 0 "完成(" "RATE_LIMITED"
mk_stub 'echo "Approaching rate limits" >&2; echo "無重大補充"; exit 0'
check_e2e "接近上限提醒 → 不誤判" 0 "完成(" "RATE_LIMITED"

# --- 靜默失效: 諮詢沒發生卻印「完成」(本組是本腳本最重要的斷言) ---
# 這四種舊版全部會印「完成(...)」並 exit 0,呼叫端因此以為第二意見已經取得。
# 第一種取自 codex 0.144.5 實測輸出(非信任目錄),不是想像的情境。
mk_stub 'echo "Not inside a trusted directory and --skip-git-repo-check was not specified." >&2; exit 1'
check_e2e "拒跑(非信任目錄) → FAILED" 1 "FAILED:" "完成("
mk_stub 'exit 0'
check_e2e "exit 0 但零輸出 → FAILED"   1 "FAILED:" "完成("
mk_stub 'printf "  \n \n"; exit 0'
check_e2e "只有空白輸出 → FAILED"       1 "FAILED:" "完成("
mk_stub 'echo "半份 review"; exit 3'
check_e2e "有輸出但非正常結束 → FAILED" 1 "FAILED:" "完成("

# 非信任目錄要給出針對性提示,不能只丟一句 FAILED
mk_stub 'echo "Not inside a trusted directory and --skip-git-repo-check was not specified." >&2; exit 1'
check_e2e "非信任目錄附具體處置" 1 "非信任目錄" "完成("

# 串流留存仍完整: stderr 內容要能被 rate limit 判定看到(fd 調度改寫後的回歸點)
mk_stub 'echo "progress line" >&2; echo "You'"'"'ve hit your usage limit." >&2; exit 1'
check_e2e "stderr 多行仍能判定 RATE_LIMITED" 0 "RATE_LIMITED" "FAILED:"
rm -rf "$STUB"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
