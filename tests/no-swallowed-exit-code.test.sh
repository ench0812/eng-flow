#!/usr/bin/env bash
# no-swallowed-exit-code.sh 的行為測試（離線，不需要 Claude Code）。
#
# 測四類：
#   1. 該擋的擋（本週與上週五次實際事故的原句都在裡面）
#   2. 不該擋的放行 —— 誤殺比漏報昂貴，這一組是重點
#   3. 繞道與「已經處理過管線離開碼」的寫法真的有作用
#   4. 異常輸入不得出錯，deny 的 schema 與訊息內容要合格
#
# Run: bash tests/no-swallowed-exit-code.test.sh   (exit 0 = all pass)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/no-swallowed-exit-code.sh"
pass=0; fail=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: 需要 jq"; exit 0; }
bash -n "$HOOK" || { echo "SYNTAX ERROR in $HOOK"; exit 1; }

# 放行時 hook 【完全不輸出】，不是輸出一個 allow 的 JSON。空輸出要自己判成 allow，
# 不能只靠 jq 的 `// "allow"`——那只在「有 JSON 但缺欄位」時生效（no-blind-sleep
# 的第一版就是這樣寫出 13 條假紅的）。
# jq -Rsc（不是 -Rc）：-s 把整份 stdin 收成一個字串，多行案例才表達得出來。
decide() {
  local out
  out="$(printf '%s' "$1" | jq -Rsc '{tool_input:{command:.}}' \
        | env "${2:-IGNORE=1}" bash "$HOOK" 2>/dev/null)"
  if [ -z "$out" ]; then printf 'allow'; return 0; fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null
}
ok(){ pass=$((pass+1)); }
ng(){ echo "  FAIL  $1"; echo "        $2"; fail=$((fail+1)); }
want(){ # want <期望> <指令> [env]
  local got; got="$(decide "$2" "${3:-}")"
  [ "$got" = "$1" ] && ok || ng "$2" "期望 $1，實得 ${got:-<空>}"
}

echo "== 該擋的（前四條是 09-10～09-19 五次事故的原句形狀）=="
want deny 'memory audit 2>&1 | tail -40; echo "EXIT=$?"'          # 09-12、09-14
want deny 'python ~/.claude/scripts/dream-guard.py --verify | tail -15; echo $?'  # 09-11
want deny 'memory rules list --status flagged | tail -20; echo "RC=$?"'           # 09-19
want deny './gradlew assembleRelease | tail -30; echo "EXIT=$?"'                  # 09-10
want deny 'cmd | tail -3 && rc=$?'                                # && 也是下一個語句
want deny 'cmd|tail;echo $?'                                      # 無空白
want deny 'cmd | head -5; [ $? -eq 0 ] && echo ok'
want deny 'cmd | cat > f.txt; rc=$?'
want deny 'cmd | tee log.txt; echo $?'
want deny 'cmd | sort; exit $?'
# 換行分隔的語句與 `;` 語意相同，不能因為換行就漏掉
want deny "$(printf 'cmd 2>&1 | tail -40\necho "EXIT=$?"')"

echo "== 不該擋的（誤殺比漏報昂貴，這組是重點）=="
# 正解本身絕對不能被擋——擋掉它等於沒有逃生口
want allow 'cmd > out.txt 2>&1; rc=$?; tail -40 out.txt; echo "EXIT=$rc"'
want allow 'cmd 2>&1 | tail -40; echo "EXIT=${PIPESTATUS[0]}"'
want allow 'set -o pipefail; cmd 2>&1 | tail -40; echo "EXIT=$?"'
# 這些過濾器的離開碼【有】判定意義，刻意不列入清單
want allow 'cmd | grep -q DONE; [ $? -eq 0 ] && echo found'
want allow 'cmd | jq -e .ok; echo $?'
want allow 'cmd | wc -l; echo $?'
want allow 'cmd | sed -n 1p; echo $?'
want allow 'cmd | awk "{print}"; echo $?'
# $? 屬於中間那個語句，不是過濾器的——這是正確寫法
want allow 'cmd | tail -5; ls x; echo $?'
# 前綴相同但不是同一個指令
want allow 'cmd | tailscale status; echo $?'
want allow 'cmd | headers.sh; echo $?'
# 沒有管線就沒有這個問題
want allow 'cmd; echo $?'
want allow 'rc=$?; echo $rc'
# 有管線但沒讀 $?
want allow 'cmd | tail -40'
want allow 'npm test | tail -20 > log.txt'
# 單引號內是字面資料，`$?` 在裡面不展開
want allow "grep 'cmd | tail -3; echo \$?' notes.md"
# heredoc 內容是資料不是指令
want allow "$(printf 'cat > w.sh <<EOF\ncmd | tail -3; echo $?\nEOF')"

echo "== 繞道 =="
# 【逃生口必須真的可用】hook 讀的是自己 process 的環境變數，inline 前綴要等指令
# 真的執行才存在——不在 hook 裡認它，照 deny 訊息做會再次被擋而陷入迴圈。
want allow 'CLAUDE_ALLOW_PIPED_EXIT=1 cmd | tail -40; echo "EXIT=$?"'
want deny  'cmd | tail -40; echo "EXIT=$?"'                       # 對照組：沒前綴仍要擋
want allow 'cmd | tail -40; echo "EXIT=$?"' 'CLAUDE_ALLOW_PIPED_EXIT=1'
want deny  'cmd | tail -40; echo "EXIT=$?"' 'CLAUDE_ALLOW_PIPED_EXIT=0'

echo "== 異常輸入不得出錯 =="
printf '' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "空輸入" "exit 非 0"
printf 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "壞輸入" "exit 非 0"
printf '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "無 command 欄位" "exit 非 0"

echo "== deny 的 schema 與訊息 =="
raw="$(printf '%s' 'cmd | tail -40; echo "EXIT=$?"' | jq -Rsc '{tool_input:{command:.}}' | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$raw" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then ok
else ng "hookEventName 正確" "不是 PreToolUse"; fi
# 訊息要真的給出替代寫法——只說「不准」而不說「改成什麼」的攔截會被繞過而非被學會
if printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'PIPESTATUS'; then ok
else ng "deny 訊息含替代方案" "訊息沒有指出正確做法"; fi
# 訊息要指名命中的是哪個過濾器，否則使用者得自己回去找
if printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '| tail'; then ok
else ng "deny 訊息指名過濾器" "訊息沒有帶出 tail"; fi

echo
echo "結果: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
