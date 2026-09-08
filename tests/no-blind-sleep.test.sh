#!/usr/bin/env bash
# no-blind-sleep.sh 的行為測試（離線，不需要 Claude Code）。
#
# 測三類：
#   1. 該擋的擋（含單位換算與 PowerShell 語法）
#   2. 不該擋的放行（短睡、迴圈內短睡、無關指令）—— 誤殺比漏報昂貴，這一組是重點
#   3. 門檻與繞道開關真的有作用
#
# Run: bash tests/no-blind-sleep.test.sh   (exit 0 = all pass)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/no-blind-sleep.sh"
pass=0; fail=0

command -v jq >/dev/null 2>&1 || { echo "SKIP: 需要 jq"; exit 0; }
bash -n "$HOOK" || { echo "SYNTAX ERROR in $HOOK"; exit 1; }

# 回傳 deny / allow。hook 放行時不輸出任何東西，用 // "allow" 收斂成兩種值。
# 放行時 hook 【完全不輸出】，不是輸出一個 allow 的 JSON。所以不能只靠 jq 的
# `// "allow"` 補預設——那只在「有 JSON 但缺欄位」時生效，對空輸入 jq 直接不產出，
# 結果會是空字串而非 allow（第一版就是這樣寫的，13 條假紅）。空輸出要自己判成 allow。
# jq -Rsc（不是 -Rc）：-R 逐行讀，多行指令會變成多個 JSON 物件，harness 就【表達不出】
# heredoc、註解行這類多行案例——而那正是誤殺最容易發生的形態。-s 把整份 stdin 收成
# 一個字串，多行案例才寫得出來。
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

echo "== 該擋的 =="
want deny 'sleep 500; tail -3 out.txt'
want deny 'sleep 61'
want deny 'sleep 10m'                     # 單位換算：600s
want deny 'sleep 1h'                      # 3600s
want deny 'Start-Sleep -Seconds 300'
want deny 'Start-Sleep 300'
want deny 'x=1 && sleep 500'
want deny 'echo a; sleep 120; echo b'
# 取最大值，不是第一個：短睡在前不得掩護後面的長睡
want deny 'sleep 5; do_work; sleep 900'

echo "== 不該擋的（誤殺比漏報昂貴，這組是重點）=="
want allow 'sleep 5'
want allow 'sleep 59'                     # 門檻邊界（<=60 放行）
# 小數：0.5 對「有沒有捨去」零鑑別力（捨不捨去都 < 60，任何實作都會 allow）。
# 用這兩條才驗得到：90.5 捨去成 90 要擋；0.9m = 54 秒要放。
want deny  'sleep 90.5'
want allow 'sleep 0.9m'
# 【codex 複查抓到】換算順序：原本先砍小數再乘倍率，`sleep 0.5h` 變成 0×3600=0 而放行
# ——1800 秒的等待整個溜過去。0.9m（54s）那條單獨看無法分辨「算對」與「算成 0」，
# 必須配這兩條超過門檻的小數單位案例才有鑑別力。
want deny 'sleep 0.5h'                    # 1800s
want deny 'sleep 1.5m'                    # 90s
want allow 'sleep 0.5m'                   # 30s，正確換算才會放行
want allow 'npm test'
want allow 'git status'
# 這正是要引導模型改成的寫法，絕不能擋
want allow 'for i in $(seq 1 60); do grep -q DONE o && break; sleep 5; done'
want allow 'while kill -0 $pid 2>/dev/null; do sleep 5; done'
want allow 'sleep500'                     # 不是 sleep 指令
want allow 'grep "sleep 500" file'        # 字串內容，不是真的要睡
want allow "grep 'sleep 500' file"

# 【複查抓到的誤殺，五種都實測過】前綴原本含 [[:space:]]，於是「散文位置」的 sleep
# 也被當成指令。這幾種正好是這個 repo 接下來最常打的：講到這支 hook 的 commit message、
# 寫一支等待腳本、以及容器保活（睡的是容器不是本機，根本不阻塞使用者）。
# 收緊到「指令位置」（行首 / ; / & / | / ( / 反引號 / do-then-else 之後）即全部放行。
want allow 'git commit -m "fix flaky test that used sleep 300"'
want allow 'echo remember do not sleep 300 next time'
want allow 'docker run -d x sleep 3600'
want allow 'kubectl exec p -- sleep 300'
want allow "$(printf 'cat > w.sh <<EOF\nsleep 300\nEOF')"      # heredoc 內容
want allow "$(printf '# sleep 300 was here\nnpm test')"        # 註解行（^ 是逐行錨點）
# 【codex 複查抓到】引號【內】的括號與分號一樣長得像指令分隔符，前綴收緊擋不住它們。
# 這兩條實測都曾被誤殺，而兩者都沒有真的等待。
want allow 'git commit -m "fix: remove (sleep 300)"'
want allow 'echo "done; sleep 300"'

echo "== 數值解析的 fail-open 缺口（複查抓到，全部實測過）=="
# 前導零走八進位：`sleep 08m` 原本讓 $(( )) 報 "value too great for base" 而整條放行。
want deny 'sleep 08m'
want deny 'sleep 09h'
want deny 'sleep 010m'                    # 八進位會算成 480s（真值 600s），仍須擋
# 20 位數原本讓 [ ] 報 "integer expected"、worst 停在 0 → 放行
want deny 'sleep 99999999999999999999'
# PowerShell 毫秒：600000ms = 10 分鐘，原本完全不看
want deny 'Start-Sleep -Milliseconds 600000'
want allow 'Start-Sleep -Milliseconds 500'
# 【codex 第三輪抓到】早退條件原本寫 *[sS]leep*，只容忍首字母大小寫，於是全大寫的
# PowerShell 寫法在早退那一關就被放行，後面的 grep -i 根本沒機會跑。
# 早退是效能優化，不該順手改變判定結果。
want deny  'START-SLEEP -SECONDS 300'
want deny  'SLEEP 300'
want allow 'Start-Sleep -MILLISECONDS 500'   # 大寫毫秒也要正確換算，不可誤當秒

echo "== 門檻與繞道 =="
# 【逃生口必須真的可用】(複查抓到)：deny 訊息教模型加 inline 前綴，但 hook 讀的是自己
# process 的環境變數，inline 前綴要等指令真的執行才存在——照著做會再次被擋而陷入迴圈。
want allow 'CLAUDE_ALLOW_LONG_SLEEP=1 sleep 500'
want deny  'sleep 500'                    # 對照組：沒有前綴時仍要擋
want allow 'sleep 500' 'CLAUDE_ALLOW_LONG_SLEEP=1'
want allow 'sleep 500' 'CLAUDE_MAX_SLEEP_SECONDS=600'
want deny  'sleep 500' 'CLAUDE_MAX_SLEEP_SECONDS=100'
# 門檻是壞值時要退回預設 60，不可變成 0（那會擋掉所有 sleep）或無限大（形同關閉）
want deny  'sleep 500' 'CLAUDE_MAX_SLEEP_SECONDS=abc'
want allow 'sleep 5'   'CLAUDE_MAX_SLEEP_SECONDS=abc'

echo "== 異常輸入不得出錯 =="
printf '' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "空輸入" "exit 非 0"
printf 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "壞輸入" "exit 非 0"
printf '{"tool_input":{}}' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok || ng "無 command 欄位" "exit 非 0"
# 輸出必須符合 PreToolUse schema，否則 Claude Code 會忽略整個判定
out="$(decide 'sleep 500')"
[ "$out" = "deny" ] && ok || ng "deny 的 schema" "取不到 permissionDecision"
raw="$(printf '%s' 'sleep 500' | jq -Rc '{tool_input:{command:.}}' | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$raw" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then ok
else ng "hookEventName 正確" "不是 PreToolUse"; fi
# 訊息要真的給出替代寫法——只說「不准」而不說「改成什麼」的攔截會被繞過而非被學會
if printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'run_in_background'; then ok
else ng "deny 訊息含替代方案" "訊息沒有指出正確做法"; fi

echo
echo "結果: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
