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
# Gate 隔離: 不可依賴「PATH 上找不到 codex」——腳本的 fallback 清單裡有 /usr/local/bin/codex,
# 那是 Linux/macOS 的常見安裝位置,一旦命中這些 case 會拿 fixture 真的送出諮詢(花錢、打 API,
# 而且要等到斷言拿不到 SKIP 才會叫)。改成確定性地在 Gate 2 擋下: login status 回非零。
GATE="$(mktemp -d)"
printf '#!/usr/bin/env bash
exit 1
' > "$GATE/codex"; chmod +x "$GATE/codex"
trap 'rm -rf "$FIX" "$GATE"' EXIT

check() {
  local desc="$1" expect="$2"; shift 2
  HOME="$FIX" PATH="$GATE:/usr/bin:/bin" CODEX_REVIEW_STATE="$FIX/state" CODEX_REVIEW_LOG="$FIX/usage.tsv" bash "$SCRIPT" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$expect" ]; then pass=$((pass+1))
  else echo "FAIL [$desc] expected exit=$expect got=$rc"; fail=$((fail+1)); fi
}

# 輪數警示行為: 警示(stderr)與環境 SKIP 同為 exit 0,須驗輸出內容區分。
# 所有案例用空 HOME + 精簡 PATH 讓 Gate 1 必定 SKIP,絕不真的呼叫 codex。
check_out() {
  local desc="$1" expect_rc="$2" pattern="$3"; shift 3
  local out rc
  out="$(HOME="$FIX" PATH="$GATE:/usr/bin:/bin" CODEX_REVIEW_STATE="$FIX/state" CODEX_REVIEW_LOG="$FIX/usage.tsv" bash "$SCRIPT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$expect_rc" ] && printf '%s\n' "$out" | grep -q "$pattern"; then pass=$((pass+1))
  else echo "FAIL [$desc] rc=$rc out=$out"; fail=$((fail+1)); fi
}

check_absent() { # 同 check_out,但 pattern 必須「不」出現
  local desc="$1" expect_rc="$2" pattern="$3"; shift 3
  local out rc
  out="$(HOME="$FIX" PATH="$GATE:/usr/bin:/bin" CODEX_REVIEW_STATE="$FIX/state" CODEX_REVIEW_LOG="$FIX/usage.tsv" bash "$SCRIPT" "$@" 2>&1)"; rc=$?
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
E2E_N=0
check_e2e() { # $1=desc $2=期望結束碼 $3=期望出現的字樣 $4=不該出現的字樣
  local desc="$1" expect_rc="$2" want="$3" unwanted="$4" out rc
  # 每個 case 都是獨立情境,不是同一條複查線的多輪 → 給各自的 ledger,否則第 2 個 case
  # 起會被「與上一輪內容完全相同」的去重攔截擋掉(那個攔截本身是對的,見腳本說明)。
  E2E_N=$((E2E_N+1))
  out="$(PATH="$STUB:$PATH" CODEX_REVIEW_STATE="$STUB/state$E2E_N"          CODEX_REVIEW_LOG="$STUB/usage.tsv"          bash "$SCRIPT" --doc "$STUB_DOC" --kind spec --severity required 2>&1)"; rc=$?
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

ok() { # $1=desc  $2..=條件(直接當指令跑)
  local desc="$1"; shift
  if "$@"; then pass=$((pass+1)); else echo "FAIL [$desc]"; fail=$((fail+1)); fi
}
has()  { printf '%s' "$2" | grep -q "$1"; }
hasnt() { ! printf '%s' "$2" | grep -q "$1"; }

# --- 成本治理: 純函式(2026-08-24 新增) ---
# 直接抽腳本裡的函式本體來測,不另抄一份以免 drift(同 is_rate_limited 的做法)。
eval "$(sed -n '/^now_ts()/,/^}$/p;/^state_key()/,/^}$/p;/^state_get()/,/^}$/p;/^trim_crosscheck_log()/,/^}$/p;/^diff_delta_per_file()/,/^}$/p' "$SCRIPT")"
for fn in now_ts state_key state_get trim_crosscheck_log diff_delta_per_file; do
  if declare -f "$fn" >/dev/null; then pass=$((pass+1))
  else echo "FAIL [抽取 $fn] sed 範圍失效,腳本結構可能已改"; fail=$((fail+1)); fi
done
# declare -f 只證明「有東西被定義」,證明不了「定義的是對的東西」。
# 實際踩過: 腳本裡的單行函式(行尾 `; }`)沒有行首 `}` 可以終止 sed range,於是下一個函式被
# 包進上一個函式的定義裡 —— state_key 變成巢狀定義、呼叫回傳空字串,而 declare -f 照樣成功。
# 所以守門必須驗行為,不能只驗存在。
NT_VAL="$(now_ts)"   # bash -c 是新行程,看不到 eval 進來的函式,所以就地取值再驗
case "$NT_VAL" in ''|*[!0-9]*) echo "FAIL [now_ts 回傳整數] got=$NT_VAL"; fail=$((fail+1)) ;;
                  *) pass=$((pass+1)) ;; esac
ok "state_key 非空"             test -n "$(state_key a b c)"
ok "state_key 單行輸出"         test "$(state_key a b c | wc -l)" -eq 1
ok "state_key 同輸入同輸出"     test "$(state_key a b c)" = "$(state_key a b c)"
ok "state_key 不同輸入不同輸出" test "$(state_key a b c)" != "$(state_key a b d)"

CG="$FIX/cg"; mkdir -p "$CG"
{ echo "# S"; echo "body-line"; echo; echo "## Cross-Check Log"
  echo "### Round 1 — a"; echo "r1"; echo "### Round 2 — b"; echo "r2"
  echo "### Round 3 — c"; echo "r3"; } > "$CG/three.md"
TRIM="$(trim_crosscheck_log "$CG/three.md")"
ok "trim: 保留最後一輪"        has "### Round 3" "$TRIM"
ok "trim: 丟掉更早的輪次"      hasnt "### Round 1" "$TRIM"
ok "trim: 本文不得被裁掉"      has "body-line" "$TRIM"
ok "trim: 標明省略了幾輪"      has "前 2 輪" "$TRIM"
{ echo "# S"; echo "## Cross-Check Log"; echo "### Round 1 — a"; echo "only"; } > "$CG/one.md"
ok "trim: 只有一輪則原樣輸出"  test "$(trim_crosscheck_log "$CG/one.md")" = "$(cat "$CG/one.md")"
ok "trim: 只有一輪不加省略註記" hasnt "已省略" "$(trim_crosscheck_log "$CG/one.md")"
printf '# S\nplain\n' > "$CG/none.md"
ok "trim: 沒有 log 小節則原樣" test "$(trim_crosscheck_log "$CG/none.md")" = "$(cat "$CG/none.md")"

printf 'diff --git a/a.py b/a.py\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/b.py b/b.py\n@@ -1 +1 @@\n-p\n+q\n' > "$CG/old.diff"
sed 's/+q/+QQ/' "$CG/old.diff" > "$CG/new.diff"
DLT="$(diff_delta_per_file "$CG/old.diff" "$CG/new.diff")"
ok "delta: 只送有變的檔案區塊" has "diff --git a/b.py" "$DLT"
ok "delta: 未變更的檔案不重送" hasnt "diff --git a/a.py" "$DLT"
ok "delta: 列出未變更檔名"     has "a.py" "$DLT"
ok "delta: 兩輪相同則無區塊"   hasnt "^diff --git" "$(diff_delta_per_file "$CG/old.diff" "$CG/old.diff")"

# --- 成本治理: 端到端(stub codex) ---
STUB2="$(mktemp -d)"
mk_stub2() { { echo '#!/usr/bin/env bash'; echo 'case "$1" in'; echo '  login) exit 0 ;;'
               echo "  exec)  $1 ;;"; echo 'esac'; echo 'exit 0'; } > "$STUB2/codex"; chmod +x "$STUB2/codex"; }
mk_stub2 'echo "無重大補充"; echo "收斂問句:無"; exit 0'
LG="$STUB2/ledger"; TSV="$STUB2/usage.tsv"
D2="$STUB2/spec.md"; printf '# F\nv1\n' > "$D2"
run2() { PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG" CODEX_REVIEW_LOG="$TSV" \
         bash "$SCRIPT" --doc "$D2" --kind spec --severity required 2>&1; }

O1="$(run2)"
ok "ledger: 首次為 round=1 且 fresh" has "fresh round=1" "$O1"
printf '# F\nv2\n' > "$D2"
O2="$(run2)"
ok "ledger: 內容有變 → round=2"      has "round=2" "$O2"
ok "ledger: resume 關閉時即使有 session id 也走 fresh" has "fresh round=2" "$O2"
O3="$(run2)"; rc3=$?
ok "去重: 內容未變 → SKIP 不送出"    has "SKIP: 送出內容與上一輪" "$O3"
ok "去重: SKIP 不阻斷(exit 0)"       test "$rc3" -eq 0

ok "遙測: TSV 已產生"                test -s "$TSV"
ok "遙測: 有表頭"                    has "cache_hit_pct" "$(head -1 "$TSV")"
ok "遙測: 每次成功各一列"            test "$(grep -c '	OK	' "$TSV")" -eq 2

# ledger 損毀 → 當 0 續跑,不得阻斷
printf '# F\nv3\n' > "$D2"
for f in "$LG"/*.state; do printf 'rounds=???\nlast_ts=abc\n' > "$f"; done
O4="$(run2)"
ok "ledger 損毀 → 當 0 續跑"         has "round=1" "$O4"

# 輪數警示: 把 ledger 直接推到警示線前一格,下一次必須印警示
printf '# F\nv4\n' > "$D2"
for f in "$LG"/*.state; do   # 不用 sed -i: BSD sed 需要備份後綴參數,在 macOS 會直接報錯
  { echo "rounds=5"; grep -v '^rounds=' "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
done
O5="$(run2)"
ok "doc 6 輪 → ledger 印警示"        has "第 6 次諮詢" "$O5"
ok "警示仍不阻斷"                    has "完成(" "$O5"

# diff 模式排除清單: 用真的 git repo 驗 pathspec 組裝(組錯 git 會直接報錯)
GR="$STUB2/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q . && git config user.email t@t.t && git config user.name t \
  && printf 'base\n' > f.txt && git add -A && git commit -qm i && git branch -M main ) >/dev/null 2>&1
printf 'changed\n' > "$GR/f.txt"; printf 'lockdata\n' > "$GR/package-lock.json"; mkdir -p "$GR/dist"; printf 'built
' > "$GR/dist/out.js"; printf 'SECRET=x
' > "$GR/.env"
( cd "$GR" && git add -N . >/dev/null 2>&1 )
O6="$(cd "$GR" && PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$STUB2/lg2" CODEX_REVIEW_LOG="$STUB2/u2.tsv" \
      bash "$SCRIPT" --severity required --base main 2>&1)"
ok "diff: 排除建置產物並回報"      has "字元未送出;其中建置產物" "$O6"
ok "diff: 排除清單點名檔案"        has "dist/out.js" "$O6"
# lockfile 不再預設排除: 它才記錄實際解析到的版本與 integrity hash,排掉等於開供應鏈盲點
ok "diff: lockfile 必須被送審"       hasnt "建置產物.*package-lock" "$O6"
# 疑似機密檔案: 不送出,但必須大聲講(安全鐵律 #1 —— secrets 不進版控)
ok "diff: 機密檔案不送出但要警示"    has "含疑似機密檔案" "$O6"
ok "diff: 警示點名機密檔案"          has "[.]env" "$O6"
ok "diff: 非排除檔仍送出"            has "fresh round=1" "$O6"
O7="$(cd "$GR" && PATH="$STUB2:$PATH" CODEX_REVIEW_EXCLUDE= CODEX_REVIEW_STATE="$STUB2/lg3" \
      CODEX_REVIEW_LOG="$STUB2/u3.tsv" bash "$SCRIPT" --severity required --base main 2>&1)"
ok "diff: 清空排除清單則不排除"      hasnt "已排除" "$O7"
ok "diff: 清空排除清單仍照常送出" has "fresh round=1" "$O7"

# diff 模式輪次警示: 協議是「一輪一次」,所以警示線比 doc 嚴(預設 3)。
# 每輪都改內容,避免被「與上一輪相同」的去重攔截擋掉。
LG6="$STUB2/lg6"; DIFF_OUT=""
for i in 1 2 3; do
  ( cd "$GR" && printf 'v%s\n' "$i" > f.txt )
  DIFF_OUT="$(cd "$GR" && PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG6" CODEX_REVIEW_LOG="$STUB2/u6.tsv" bash "$SCRIPT" --severity required --base main 2>&1)"
done
ok "diff 第 3 輪 → 印警示"           has "第 3 次諮詢" "$DIFF_OUT"
ok "diff 警示點名協議"               has "not per file or per fix" "$DIFF_OUT"
ok "diff 警示標的不重複前綴"         has "複查線(diff:main@" "$DIFF_OUT"
ok "diff 複查線含目前分支"           has "複查線(diff:main@main)" "$DIFF_OUT"

# 輪次要能重置: 沒有重置的話,一個 repo 用滿警示線之後往後每次都警示,警示就退化成雜訊。
# 這裡把 last_ts 往前推到重置門檻之外,下一次必須從第 1 輪重新起算。
for f in "$LG6"/*.state; do
  { grep -v '^last_ts=' "$f"; echo "last_ts=1"; } > "$f.tmp" && mv "$f.tmp" "$f"
done
( cd "$GR" && printf 'reset-probe
' > f.txt )
RESET_OUT="$(cd "$GR" && PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG6" CODEX_REVIEW_LOG="$STUB2/u6.tsv" bash "$SCRIPT" --severity required --base main 2>&1)"
ok "閒置超過門檻 → 輪數歸零"         has "fresh round=1" "$RESET_OUT"
ok "輪數歸零後不再警示"              hasnt "次諮詢" "$RESET_OUT"

# 換分支 = 換複查線,輪數不該沿用上一條分支的累計
( cd "$GR" && git checkout -q -b probe-branch && printf 'on-branch
' > f.txt )
BR_OUT="$(cd "$GR" && PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG6" CODEX_REVIEW_LOG="$STUB2/u6.tsv" bash "$SCRIPT" --severity required --base main 2>&1)"
ok "換分支 → 另一條複查線"           has "fresh round=1" "$BR_OUT"
( cd "$GR" && git checkout -q main )
ok "diff 警示仍不阻斷"               has "完成(" "$DIFF_OUT"

# 軟性大小警示
printf '# F\n' > "$D2"; head -c 200 /dev/zero | tr '\0' 'x' >> "$D2"
O8="$(PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$STUB2/lg4" CODEX_REVIEW_LOG="$STUB2/u4.tsv" \
      CODEX_WARN_CHARS=50 bash "$SCRIPT" --doc "$D2" --kind spec --severity required 2>&1)"
ok "軟性大小警示會觸發"              has "軟性警示線" "$O8"
ok "軟性大小警示不阻斷"              has "完成(" "$O8"

# RATE_LIMITED / FAILED 不得推進輪數(協議: 不計 round)
LG5="$STUB2/lg5"; D5="$STUB2/s5.md"; printf '# F\nv1\n' > "$D5"
run5() { PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG5" CODEX_REVIEW_LOG="$STUB2/u5.tsv" \
         bash "$SCRIPT" --doc "$D5" --kind spec --severity required 2>&1; }
mk_stub2 'echo "You'"'"'ve hit your usage limit." >&2; exit 1'
R1="$(run5)"
ok "RATE_LIMITED 仍記遙測"           has "RATE_LIMITED" "$R1"
mk_stub2 'echo "無重大補充"; echo "收斂問句:無"; exit 0'
R2="$(run5)"
ok "RATE_LIMITED 不推進輪數"         has "round=1" "$R2"
ok "遙測含 RATE_LIMITED 列"          has "RATE_LIMITED" "$(cat "$STUB2/u5.tsv")"


# review 內容與後續狀態行不得黏在同一行(-o 檔無結尾換行造成)
mk_stub2 'printf "無重大遺漏\n收斂問句:無"; exit 0'   # 刻意不給結尾換行
NL_OUT="$(PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$STUB2/lg7" CODEX_REVIEW_LOG="$STUB2/u7.tsv" \
          bash "$SCRIPT" --doc "$D2" --kind spec --severity required 2>&1)"
ok "狀態行不得黏在 review 尾巴"      hasnt "收斂問句:無\[codex-review\]" "$NL_OUT"
ok "行首完成訊息仍在"                has "^\[codex-review\] 完成(" "$NL_OUT"


# 去重必須與 resume 開關解耦: resume 預設關閉,去重仍要生效(不然關掉 resume 等於關掉去重)
mk_stub2 'echo "無重大遺漏"; echo "收斂問句:無"; exit 0'
LG8="$STUB2/lg8"; D8="$STUB2/s8.md"; printf '# F
v1
' > "$D8"
run8() { PATH="$STUB2:$PATH" CODEX_REVIEW_RESUME=0 CODEX_REVIEW_STATE="$LG8"          CODEX_REVIEW_LOG="$STUB2/u8.tsv" bash "$SCRIPT" --doc "$D8" --kind spec --severity required 2>&1; }
D8_1="$(run8)"; D8_2="$(run8)"
ok "resume 關閉時首輪照常送出"       has "fresh round=1" "$D8_1"
ok "resume 關閉時去重仍生效"         has "SKIP: 送出內容與上一輪" "$D8_2"


# --- 遙測解析鏈 + resume 分支(先前完全零覆蓋) ---
# 用會吐 JSONL 的 stub。先前的 stub 只吐純文字,所以 jnum / emit_telemetry 的欄位解析、
# cache_hit_pct 計算、thread_id 擷取、以及整條 resume 路徑一行都沒被執行過——
# 既有的三條遙測斷言(TSV 存在/有表頭/OK 列數)在 jnum 全壞、欄位全 0 時照樣會綠。
ARGV="$STUB2/argv.txt"
mk_stub_json() { # $1=thread_id $2=input $3=cached $4=output $5=reasoning
  # 忠實模擬真 codex 的 --json 行為: stdout 只有 JSONL,review 本體寫進 -o 指定的檔。
  # (先前版本把 review 印在 stdout,會被腳本正確判成「-o 落空」而 FAILED —— 那個判定是對的。)
  cat > "$STUB2/codex" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  login) exit 0 ;;
  exec)
    printf '%s
' "\$@" >> "$ARGV"
    o=""; prev=""
    for a in "\$@"; do [ "\$prev" = "-o" ] && o="\$a"; prev="\$a"; done
    [ -n "\$o" ] && printf '%s
' "無重大遺漏" "收斂問句:無" > "\$o"
    echo '{"type":"thread.started","thread_id":"$1"}'
    echo '{"type":"turn.completed","usage":{"input_tokens":$2,"cached_input_tokens":$3,"cache_write_input_tokens":0,"output_tokens":$4,"reasoning_output_tokens":$5}}'
    exit 0 ;;
esac
exit 0
STUBEOF
  chmod +x "$STUB2/codex"
}

TID="11111111-2222-3333-4444-555555555555"
LG7="$STUB2/lg7"; TSV7="$STUB2/u7.tsv"; D7="$STUB2/s7.md"
run7() { PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$LG7" CODEX_REVIEW_LOG="$TSV7" \
         env "$@" bash "$SCRIPT" --doc "$D7" --kind spec --severity required 2>&1; }

# 文件要有實際體積,delta 才會真的比全文小 —— 兩行的文件其 unified diff 比原文還長,
# 會(正確地)觸發「增量不比全文小 → 退 fresh」的守門,那樣就測不到 resume 了。
mk_doc7() { # $1=變動標記
  { echo "# Fixture spec"
    for i in $(seq 1 40); do echo "需求 $i: 系統必須在第 $i 個步驟驗證輸入並記錄稽核軌跡。"; done
    echo "變動標記: $1"
  } > "$D7"
}
mk_doc7 v1; : > "$ARGV"
mk_stub_json "$TID" 15348 9984 700 500
O_T="$(run7 IGNORE=1)"
fld() { awk -F'\t' -v c="$1" 'END{print $c}' "$TSV7"; }
ok "遙測: input_tokens 落欄"    test "$(fld 9)"  = "15348"
ok "遙測: cached 落欄"          test "$(fld 10)" = "9984"
ok "遙測: output 落欄"          test "$(fld 11)" = "700"
ok "遙測: reasoning 落欄"       test "$(fld 12)" = "500"
ok "遙測: hit rate 計算正確"    test "$(fld 13)" = "65.1"
ok "遙測: TSV 欄位數 = 17"      test "$(awk -F'\t' 'END{print NF}' "$TSV7")" -eq 17
ok "用量行印出 hit rate"        has "cache hit 65.1%" "$O_T"
ok "ledger 記下 session_id"     has "session_id=$TID" "$(cat "$LG7"/*.state)"

# resume: 內容有變 + 開關開啟 + TTL 內 → 必須走 resume,且必須明確壓 read-only sandbox。
# 那個旗標是針對 config.toml 可能有 [windows] sandbox = "elevated" 的 fail-closed 處置
# (codex exec resume 沒有 -s/--sandbox),先前只靠人工 E2E 記憶保護,有人拿掉不會有任何反應。
mk_doc7 v2; : > "$ARGV"
O_R="$(run7 CODEX_REVIEW_RESUME=1 CODEX_RESUME_TTL=9999)"
ok "resume: 走 resume 分支"          has "resume(11111111)" "$O_R"
ok "resume: 用 exec resume 子指令"   has "^resume$" "$(cat "$ARGV")"
ok "resume: 必帶 read-only sandbox"  has "^sandbox_mode=read-only$" "$(cat "$ARGV")"
ok "resume: 送 delta 不送全文"       test "$(printf '%s' "$O_R" | sed -n 's/.*delta \([0-9][0-9]*\)\/\([0-9][0-9]*\) 字元.*/\1 \2/p' | awk '{print ($1<$2)?"y":"n"}')" = "y"

# 去重與 resume 解耦的【真】命題: resume 開著時,相同內容仍要被擋
O_D="$(run7 CODEX_REVIEW_RESUME=1 CODEX_RESUME_TTL=9999)"
ok "resume 開啟時去重仍生效"         has "SKIP: 送出內容與上一輪" "$O_D"
ok "FORCE=1 可略過去重攔截"          has "完成(" "$(run7 CODEX_REVIEW_FORCE=1)"

# TTL 之外必須退回 fresh 並說明原因(resume 在窗口外比 fresh 更貴)
mk_doc7 v4; : > "$ARGV"
O_E="$(run7 CODEX_REVIEW_RESUME=1 CODEX_RESUME_TTL=0)"
ok "resume: 超出窗口 → 明講並退 fresh" has "超出快取窗口" "$O_E"
ok "resume: 退 fresh 後照常完成"       has "fresh round=" "$O_E"
ok "resume: 退 fresh 不帶 resume 子指令" hasnt "^resume$" "$(cat "$ARGV")"


# --- C1 回歸(2026-08-24 review 抓到的 Critical) ---
# 「上一輪有、本輪已還原」的檔案不會出現在本輪 diff 裡,所以 per-file delta 為空。
# 舊版拿 delta 是否為空當去重判準,於是把「照 codex 建議還原後再問一次」誤判成
# 「與上一輪完全相同」並 exit 0 —— 那正是最需要複查的一輪。去重必須直接比內容。
C1R="$STUB2/c1repo"; mkdir -p "$C1R"
( cd "$C1R" && git init -q . && git config user.email t@t.t && git config user.name t   && echo base > a.txt && echo base > b.txt && git add -A && git commit -qm i && git branch -M main ) >/dev/null 2>&1
mk_stub_json "cccccccc-0000-0000-0000-000000000000" 100 50 10 0
c1run() { ( cd "$C1R" && PATH="$STUB2:$PATH" CODEX_REVIEW_STATE="$STUB2/lgc1"             CODEX_REVIEW_LOG="$STUB2/uc1.tsv" bash "$SCRIPT" --severity required --base main 2>&1 ); }
( cd "$C1R" && echo changed > a.txt && echo changed > b.txt )
C1_1="$(c1run)"
( cd "$C1R" && echo base > b.txt )          # 還原 b.txt,a.txt 的變更還在
C1_2="$(c1run)"
( cd "$C1R" && : )                          # 什麼都不改
C1_3="$(c1run)"
ok "C1: 首輪正常送出"                 has "round=1" "$C1_1"
ok "C1: 還原某檔後仍須複查"           has "round=2" "$C1_2"
ok "C1: 還原某檔不得誤判為相同"       hasnt "完全相同" "$C1_2"
ok "C1: 真正沒改動才 SKIP"            has "SKIP: 送出內容與上一輪" "$C1_3"

rm -rf "$STUB2"

rm -rf "$STUB"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
