#!/usr/bin/env bash
# output-audit.sh 的回歸測試 — 在隔離的 HOME 下用合成 transcript 驗證。
#
# 標 [regression] 的是實測踩到過的缺陷，不可移除——每一條都對應一個曾經
# 讓報表靜默失真的真實缺陷（憑證外洩、事件漏算、型別記成 0 B、跨 session 錯配）。
# Run: bash tests/output-audit.test.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
AUDIT="$ROOT/scripts/output-audit.sh"
[ -f "$AUDIT" ] || { echo "找不到 $AUDIT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "需要 jq" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
TR_DIR="$SANDBOX/.claude/projects/testproj"
mkdir -p "$TR_DIR"
TR="$TR_DIR/session.jsonl"
TODAY="$(date -u +%Y-%m-%d)"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
ng(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "$2"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) ng "$3" "輸出中找不到「$1」" ;; esac; }
hasnt(){ case "$2" in *"$1"*) ng "$3" "輸出中不該出現「$1」" ;; *) ok "$3" ;; esac; }
# 斷言「Bash 最耗 context」表格的**程式欄**確實是某個值。
# 不能只搜尋整份報表：該表格還有「指令預覽」欄，指令本身就含 npm/pytest 字樣，
# 於是歸因即使退化成 cd 或 FOO=1 也會通過——那是假通過（codex 第二輪指出）。
hasprog(){
  if printf '%s\n' "$2" | grep -qE "^  $1[[:space:]]"; then ok "$3"
  else ng "$3" "Bash 表格的程式欄不是「$1」"; fi
}

# pair <id> <tool> <cmd> <result>
pair(){
  jq -cn --arg ts "${TODAY}T01:00:00Z" --arg id "$1" --arg t "$2" --arg c "$3" \
    '{timestamp:$ts, sessionId:"s1", type:"assistant",
      message:{content:[{type:"tool_use", id:$id, name:$t, input:{command:$c}}]}}' >> "$TR"
  jq -cn --arg ts "${TODAY}T01:00:01Z" --arg id "$1" --arg r "$4" \
    '{timestamp:$ts, sessionId:"s1", type:"user",
      message:{content:[{type:"tool_result", tool_use_id:$id, is_error:false, content:$r}]}}' >> "$TR"
}
run(){ HOME="$SANDBOX" bash "$AUDIT" --days 3 2>&1; }

echo "== 空資料 =="
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "沒有資料時不報錯" || ng "沒有資料時不報錯" "exit=$rc"

echo "== 基本彙總 =="
pair t1 Bash 'npm test' 'aaaaaaaaaa'
pair t2 Bash 'git status' 'bbbbb'
out="$(run)"
has "tool_result 筆數   2" "$out" "配對筆數正確"
has "15 B" "$out" "總量精確（10+5 bytes）"

echo "== 程式名歸因 =="
: > "$TR"
pair p1 Bash 'cd /some/dir && npm run build' 'x'
out="$(run)"
hasprog "npm" "$out" "[regression] cd X && npm → 歸給 npm 而非 cd"
: > "$TR"
pair p2 Bash 'FOO=1 BAR=2 pytest -q' 'x'
out="$(run)"
hasprog "pytest" "$out" "跳過變數賦值取真正程式名"
: > "$TR"
pair p3 Bash 'cd /tmp' 'x'
out="$(run)"
hasprog "cd" "$out" "整條只有 cd 時仍歸給 cd（不可為空）"

echo "== 內容分類 =="
: > "$TR"
# [regression] 舊版用多行 ^ 錨點，任何一行以 [ 開頭就判成 json，
# 於是 `[INFO] ...` 建置 log 被歸成 json，污染整份分類資料。
pair c1 Bash 'npm run build' '[INFO] building module 1
[INFO] building module 2'
out="$(run)"
has "log" "$out" "[regression] [INFO] log 不可判成 json"
: > "$TR"
pair c2 Bash 'jq .' '{"a":1}'
out="$(run)"
has "json" "$out" "真正的 JSON 判成 json"

echo "== 安全：預覽必須遮罩 =="
: > "$TR"
pair s1 Bash 'curl -H "Authorization: Bearer sk-abcdef0123456789" https://api.example.com' 'ok'
out="$(run)"
hasnt "sk-abcdef0123456789" "$out" "Bearer token 不得出現在報表"
has "redacted" "$out" "有實際做遮罩"

# [regression] 引號包覆的值曾整段外洩：字元類只以空白與雙引號為界時，
# `API_KEY="sk-xxx"` 只會替換掉 `API_KEY=`，`"sk-xxx"` 原樣留在預覽裡。
: > "$TR"
pair s2 Bash 'API_KEY="sk-doublequoted999" node run.js' 'ok'
out="$(run)"
hasnt "sk-doublequoted999" "$out" "[regression] 雙引號包覆的 secret 不得外洩"

: > "$TR"
pair s3 Bash "TOKEN='sk-singlequoted888' node run.js" 'ok'
out="$(run)"
hasnt "sk-singlequoted888" "$out" "[regression] 單引號包覆的 secret 不得外洩"

: > "$TR"
pair s4 Bash 'PASSWORD=plainsecret777 ./deploy.sh' 'ok'
out="$(run)"
hasnt "plainsecret777" "$out" "未加引號的 secret 不得外洩"

echo "== 健壯性 =="
# [regression] .message.content 為 null 的記錄真實存在；只在 select 判斷式用
# // [] 而迭代原值，會讓 jq 整份中止（Cannot iterate over null）。
: > "$TR"
jq -cn --arg ts "${TODAY}T01:00:00Z" '{timestamp:$ts, sessionId:"s1", type:"summary", message:{content:null}}' >> "$TR"
pair n1 Bash 'echo ok' 'fine'
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "[regression] message.content 為 null 不中止" || ng "[regression] message.content 為 null 不中止" "exit=$rc"
has "tool_result 筆數   1" "$out" "null 記錄被略過但其餘仍統計"

# [regression] jq 的 "" | split("\n") 回傳 []，取 [0] 得 null，gsub 對 null 會炸。
: > "$TR"
jq -cn --arg ts "${TODAY}T01:00:00Z" \
  '{timestamp:$ts, sessionId:"s1", type:"assistant",
    message:{content:[{type:"tool_use", id:"e1", name:"Read", input:{}}]}}' >> "$TR"
jq -cn --arg ts "${TODAY}T01:00:01Z" \
  '{timestamp:$ts, sessionId:"s1", type:"user",
    message:{content:[{type:"tool_result", tool_use_id:"e1", is_error:false, content:"x"}]}}' >> "$TR"
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "[regression] 空指令字串不中止" || ng "[regression] 空指令字串不中止" "exit=$rc"

# [regression] 壞行之後的合法事件必須仍被統計。
# 舊測試只驗證整支腳本 exit 0 —— 那是假通過：jq 讀到無法解析的行會中止該檔，
# 壞行「之後」的所有合法事件都被靜默漏算，而腳本仍然 exit 0。
: > "$TR"
printf 'this is not json at all\n' >> "$TR"
pair g1 Bash 'echo ok' 'fine'
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "transcript 含壞行不中止" || ng "transcript 含壞行不中止" "exit=$rc"
has "tool_result 筆數   1" "$out" "[regression] 壞行之後的合法事件仍被統計"
has "無法解析" "$out" "[regression] 略過的行數有回報而非靜默吞掉"

# [regression] 「合法 JSON 但欄位型別不對」會讓 jq 執行期錯誤而中止該檔，
# 損失的是那一筆之後的**全部**事件。型別防護必須擋在前面。
: > "$TR"
jq -cn '{timestamp:123, sessionId:"s1", type:"assistant", message:{content:[]}}' >> "$TR"
pair t9 Bash 'echo after-anomaly' 'fine'
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && ok "[regression] 型別異常記錄不中止" || ng "[regression] 型別異常記錄不中止" "exit=$rc"
has "tool_result 筆數   1" "$out" "[regression] 型別異常之後的合法事件仍被統計"

echo "== content 為 block 陣列（MCP／多模態）=="
# [regression] 舊版只認字串型 content，陣列型一律記成 0 B，
# 嚴重低估 MCP 工具的輸出量，違反「模型實際收到多少 bytes」的定義。
: > "$TR"
jq -cn --arg ts "${TODAY}T01:00:00Z" \
  '{timestamp:$ts, sessionId:"s1", type:"assistant",
    message:{content:[{type:"tool_use", id:"a1", name:"Bash", input:{command:"echo hi"}}]}}' >> "$TR"
jq -cn --arg ts "${TODAY}T01:00:01Z" \
  '{timestamp:$ts, sessionId:"s1", type:"user",
    message:{content:[{type:"tool_result", tool_use_id:"a1", is_error:false,
                       content:[{type:"text", text:"abcde"}, {type:"image"}]}]}}' >> "$TR"
out="$(run)"
has "5 B" "$out" "[regression] 陣列型 content 有計入 bytes"
has "非文字 block  1 個" "$out" "非文字 block 有被揭露而非當成 0"

echo "== 跨 session 的 tool_use id 不可錯配 =="
# [regression] 配對鍵原本只用 id；不同 session 重複使用同一個 id 會把結果
# 接到別的指令上。加入 sid 後兩者必須各自獨立配對。
: > "$TR"
for s in sA sB; do
  jq -cn --arg ts "${TODAY}T01:00:00Z" --arg s "$s" --arg c "cmd-$s" \
    '{timestamp:$ts, sessionId:$s, type:"assistant",
      message:{content:[{type:"tool_use", id:"dup1", name:"Bash", input:{command:$c}}]}}' >> "$TR"
  jq -cn --arg ts "${TODAY}T01:00:01Z" --arg s "$s" \
    '{timestamp:$ts, sessionId:$s, type:"user",
      message:{content:[{type:"tool_result", tool_use_id:"dup1", is_error:false, content:"xx"}]}}' >> "$TR"
done
out="$(run)"
has "tool_result 筆數   2" "$out" "[regression] 相同 id 跨 session 各自配對，不互相吃掉"

echo "== 參數驗證 =="
HOME="$SANDBOX" bash "$AUDIT" --days abc >/dev/null 2>&1
[ $? -eq 2 ] && ok "--days 非數字 → exit 2" || ng "--days 非數字 → exit 2" "結束碼不是 2"
HOME="$SANDBOX" bash "$AUDIT" --days >/dev/null 2>&1
[ $? -eq 2 ] && ok "--days 缺值 → exit 2" || ng "--days 缺值 → exit 2" "結束碼不是 2"
HOME="$SANDBOX" bash "$AUDIT" --bogus >/dev/null 2>&1
[ $? -eq 2 ] && ok "未知參數 → exit 2" || ng "未知參數 → exit 2" "結束碼不是 2"
# bytes-per-token 是除數：0 會讓 token 換算爆掉，非數字會吐出未整理的 jq 錯誤。
HOME="$SANDBOX" bash "$AUDIT" --bytes-per-token 0 >/dev/null 2>&1
[ $? -eq 2 ] && ok "--bytes-per-token 0 → exit 2" || ng "--bytes-per-token 0 → exit 2" "結束碼不是 2"
HOME="$SANDBOX" bash "$AUDIT" --bytes-per-token abc >/dev/null 2>&1
[ $? -eq 2 ] && ok "--bytes-per-token 非數字 → exit 2" || ng "--bytes-per-token 非數字 → exit 2" "結束碼不是 2"
HOME="$SANDBOX" bash "$AUDIT" --top 0 >/dev/null 2>&1
[ $? -eq 2 ] && ok "--top 0 → exit 2" || ng "--top 0 → exit 2" "結束碼不是 2"

echo
echo "結果: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
