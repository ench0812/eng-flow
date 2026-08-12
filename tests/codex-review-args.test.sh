#!/usr/bin/env bash
# Table-driven tests for scripts/codex-review.sh doc mode.
# 測三類離線可驗證的行為(不需要 codex、不會真的跑 review):
#   1. exit-2 呼叫端合約
#   2. doc 模式輪數警示(無硬上限;>= 警示線印「警示」但照常續跑,絕不 STOP)
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

# 輪數警示行為: 警示(stderr)與環境 SKIP 同為 exit 0,須驗輸出內容區分。
# 所有案例用空 HOME + 精簡 PATH 讓 Gate 1 必定 SKIP,絕不真的呼叫 codex。
check_out() {
  local desc="$1" expect_rc="$2" pattern="$3"; shift 3
  local out rc
  out="$(HOME="$FIX" PATH="/usr/bin:/bin" bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$expect_rc" ] && printf '%s\n' "$out" | grep -q "$pattern"; then pass=$((pass+1))
  else echo "FAIL [$desc] rc=$rc out=$out"; fail=$((fail+1)); fi
}

check_absent() { # 同 check_out,但 pattern 必須「不」出現
  local desc="$1" expect_rc="$2" pattern="$3"; shift 3
  local out rc
  out="$(HOME="$FIX" PATH="/usr/bin:/bin" bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$expect_rc" ] && ! printf '%s\n' "$out" | grep -q "$pattern"; then pass=$((pass+1))
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

make_doc "$FIX/r9.md" 9
make_doc "$FIX/r6.md" 6
make_doc "$FIX/r5.md" 5
make_doc "$FIX/r0.md" 0
check_out    "6 輪達警示線 → 印警示"     0 "警示"   --doc "$FIX/r6.md" --kind spec --severity required
check_out    "6 輪達警示線 → 仍續跑"     0 "SKIP:"  --doc "$FIX/r6.md" --kind spec --severity required
check_absent "6 輪 → 絕不 STOP"          0 "STOP:"  --doc "$FIX/r6.md" --kind spec --severity required
check_out    "9 輪遠超警示線 → 仍只警示" 0 "警示"   --doc "$FIX/r9.md" --kind plan --severity critical
check_out    "5 輪未達警示線 → 續跑"     0 "SKIP:"  --doc "$FIX/r5.md" --kind spec --severity required
check_absent "5 輪未達警示線 → 無警示"   0 "警示"   --doc "$FIX/r5.md" --kind spec --severity required
check_out    "無 Round 紀錄 → 續跑"      0 "SKIP:"  --doc "$FIX/r0.md" --kind plan --severity required

# 警示必須走 stderr——stdout 是 review 內容串流,污染即插入雜訊(fd 調度回歸點)
w_out="$(HOME="$FIX" PATH="/usr/bin:/bin" bash "$SCRIPT" --doc "$FIX/r6.md" --kind spec --severity required 2>/dev/null)"
if printf '%s\n' "$w_out" | grep -q "警示"; then echo "FAIL [警示不得進 stdout] out=$w_out"; fail=$((fail+1)); else pass=$((pass+1)); fi
w_err="$(HOME="$FIX" PATH="/usr/bin:/bin" bash "$SCRIPT" --doc "$FIX/r6.md" --kind spec --severity required 2>&1 1>/dev/null)"
if printf '%s\n' "$w_err" | grep -q "警示"; then pass=$((pass+1)); else echo "FAIL [警示必須在 stderr] err=$w_err"; fail=$((fail+1)); fi

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
check_rl "stdout 限制字樣 + rc 非零"   yes 1 "" "You've hit your usage limit."
check_rl "限制訊息落在 stdout(極短)"   yes 0 "" "You've hit your usage limit."

# 不命中: 接近上限、額度查詢、偏好設定,以及 review 內容裡的數字。
# 成功短路: rc=0 且 stdout >= 200 非空白字元且「尾端 1000 bytes 乾淨」(transcript
# 回顯 payload 的情境,2026-08-04 dogfood 兩次實測誤判)→ 含限制字樣也不得判為被擋。
PAD="$(printf 'x%.0s' $(seq 1 1200))"
check_rl "stdout 回顯限制字樣但諮詢成功" no 0 "" "You've hit your usage limit. $PAD"
check_rl "stderr 回顯限制字樣但諮詢成功" no 0 "You've hit your usage limit." "$PAD"
# 但書: 長回顯「之後」才被擋(訊息落在尾端)→ 仍要判為被擋(round 3 共議)
check_rl "長回顯後才被擋(訊息在尾端)"   yes 0 "" "$PAD You've hit your usage limit."
# 短版有效回覆(有合約行)+stderr 回顯限制字樣 → 不得誤判(round 4 共議)
check_rl "短回覆有合約行+stderr 回顯限制字樣" no 0 "diff: You've hit your usage limit." $'無重大遺漏\n收斂問句:無'
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

# 收斂問句指示必須送達 codex——硬 gate 已移除,prompt 裡這一行是收斂協議唯一的機制載體
mk_stub 'printf "%s\n" "$@" > "'"$STUB"'/args.txt"; echo "無重大補充"'
check_e2e "prompt 送達且回覆正常" 0 "無重大補充" "RATE_LIMITED"
if grep -q "收斂問句" "$STUB/args.txt" 2>/dev/null; then pass=$((pass+1))
else echo "FAIL [prompt 缺收斂問句指示]"; fail=$((fail+1)); fi

# 收斂問句在場檢查: 有行首行 → 不印注意;缺 → 注意但仍完成(不是 FAILED,findings 仍有效)
mk_stub 'printf "有一個發現\n收斂問句:無\n"; exit 0'
check_e2e "帶收斂問句 → 完成且無注意" 0 "完成(" "未附行首"
mk_stub 'echo "無重大補充"; exit 0'
check_e2e "缺收斂問句行 → 注意但完成" 0 "未附行首" "FAILED:"

# transcript 回顯 prompt(內含行中「收斂問句」字樣)不得騙過在場檢查——需行首才算
mk_stub 'printf "%s\n" "${!#}"; echo "無重大補充"; exit 0'
check_e2e "回顯 prompt 但缺行首收斂問句 → 注意" 0 "未附行首" "FAILED:"
mk_stub 'printf "%s\n" "${!#}"; echo "收斂問句:無"; exit 0'
check_e2e "回顯 prompt 且有行首收斂問句 → 無注意" 0 "完成(" "未附行首"

# transcript 回顯含限制字樣且 rc=0、輸出量大且尾端乾淨(=諮詢成功)→ 不得誤判
# RATE_LIMITED(2026-08-04 dogfood 實測回歸;成功短路=200 非空白字元+尾端 1000 bytes)
mk_stub 'echo "quoted fixture: You have hit your usage limit."; for i in $(seq 1 50); do echo "review line $i padding-padding-padding"; done; echo "收斂問句:無"; exit 0'
check_e2e "回顯限制字樣但諮詢成功 → 不誤判" 0 "完成(" "RATE_LIMITED"

# 行首有「收斂問句」但缺冒號 → 不算合約行,仍要印注意
mk_stub 'printf "有發現\n收斂問句說明 這不是合約行\n"; exit 0'
check_e2e "行首收斂問句但缺冒號 → 注意" 0 "未附行首" "FAILED:"

# 冒號後空值 → 不算合約行(round 4 共議)
mk_stub 'printf "有發現\n收斂問句:\n"; exit 0'
check_e2e "收斂問句冒號後空值 → 注意" 0 "未附行首" "FAILED:"

# 短版有效回覆 + stderr 回顯 diff 中的限制字樣 → 不得誤判 RATE_LIMITED(round 4 共議)
mk_stub 'echo "diff 回顯: You have hit your usage limit." >&2; printf "無重大遺漏\n收斂問句:無\n"; exit 0'
check_e2e "短回覆+stderr 回顯限制字樣 → 不誤判" 0 "完成(" "RATE_LIMITED"
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
# --- 輸入過長(2026-08-12 實測誤判後新增) ---
# 背景: codex 0.144.x 把 transcript(含被回顯的整份 diff)寫到 stderr,而舊版的寬鬆 429 規則
# 對整份 stderr 比對,於是 diff 裡一行 hunk header `@@ -303,18 +429,23 @@` 就把
# input_too_large 誤判成 RATE_LIMITED——呼叫端因此以為「只是額度、等等再說」,實際上是
# 「這份 diff 永遠不會被複查」。兩者的處置相反,誤分類等於放行未複查的變更。
mk_stub 'echo "@@ -303,18 +429,23 @@ function f() {" >&2; echo "Error: turn/start failed: Input exceeds the maximum length of 1048576 characters. (code -32602), data: {\"input_error_code\":\"input_too_large\"}" >&2; exit 1'
check_e2e "input_too_large → FAILED(非 RATE_LIMITED)" 1 "FAILED:" "RATE_LIMITED"
mk_stub 'echo "@@ -303,18 +429,23 @@ function f() {" >&2; echo "Error: turn/start failed: Input exceeds the maximum length of 1048576 characters." >&2; exit 1'
check_e2e "input_too_large 附具體處置" 1 "縮小" "RATE_LIMITED"

# 負控組: diff 裡出現 429 但 codex 正常回覆,不可誤判成 RATE_LIMITED
mk_stub 'echo "@@ -1,5 +429,7 @@" >&2; echo "無重大遺漏"; echo "收斂問句:無"; exit 0'
check_e2e "diff 內的 429 不觸發 RATE_LIMITED" 0 "完成(" "RATE_LIMITED"

# 負控組: 真正的 429 出現在錯誤行上,仍必須判為 RATE_LIMITED(收窄不可改壞既有行為)
mk_stub 'echo "ERROR: request failed with status 429 Too Many Requests" >&2; exit 1'
check_e2e "錯誤行上的 429 仍判 RATE_LIMITED" 0 "RATE_LIMITED" "FAILED:"

rm -rf "$STUB"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
