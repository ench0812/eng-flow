#!/usr/bin/env bash
# PreToolUse(Bash) — 擋下「管線吃掉離開碼，下一句卻去讀 $?」。
#
# 要解決的問題：想確認一個指令成不成功，又想順便看它的輸出，於是寫成
#     memory audit 2>&1 | tail -40; echo "EXIT=$?"
# `$?` 拿到的是 `tail` 的離開碼，而 `tail` 只要讀得到 stdin 就回 0。於是**無論受測
# 指令成功或失敗，印出來的永遠是 0**——這個檢查對它宣稱要驗的事情零鑑別力，
# 但外表和一個真的通過的檢查完全一樣。比沒有檢查更糟，因為它會讓人停止懷疑。
#
# 為什麼是 hook 而不是規則：記憶 `pipeline-swallows-exit-code` 已經存在、當事人
# 剛寫過它，2026-09-10 起仍在 09-10（gradle BUILD FAILED 卻 EXIT=0）、09-11
# （dream-guard 取離開碼）、09-12（memory audit）、09-14（memory audit，同一句）、
# 09-19（memory rules list）連踩五次。規則靠自覺，而這個錯誤有完全明確的機械形狀。
#
# 判定刻意窄，只認一種形狀：**管線末段是「離開碼沒有判定意義」的純輸出工具，
# 而緊接著的下一個語句讀 `$?`**。
#
# 【刻意不列入過濾器清單】grep / jq / wc / sed / awk / test —— `cmd | grep -q x; [ $? -eq 0 ]`
# 是正當寫法，那裡要的就是 grep 自己的狀態。把它們加進來擋到的全是正確程式碼，
# 而被誤殺的規則會被整個關掉，那比漏報糟得多（同 no-blind-sleep.sh 的取捨）。
#
# 【刻意只掛 Bash，不掛 PowerShell】PowerShell 的 $LASTEXITCODE 是最後一個**原生程式**
# 的離開碼，把輸出接進 cmdlet 不會改變它。在那邊套同一條判定純粹是誤殺。
#
# 【已知誤殺，刻意接受】雙引號內容不剝除，所以
#     echo "跑 cmd | tail -3; rc=$? 會踩到這個坑"
# 這種「在字串裡談論這個形態」會被擋。不能剝雙引號的理由是主要形態
# `echo "EXIT=$?"` 本身就住在雙引號裡——剝掉它，整支 hook 就失去判定能力。
# 單引號照剝（單引號內 `$?` 不展開，本來就不是在讀離開碼）。
#
# 繞道：CLAUDE_ALLOW_PIPED_EXIT=1（env 或 inline 前綴皆可）。指令本身含 pipefail
# 或 PIPESTATUS 時直接放行——主要危害在那裡已經消失。
set -uo pipefail

# 【stdin 必須先讀完再做任何早退】同 no-blind-sleep.sh：在 cat 之前 exit 會讓上游
# 拿到 EPIPE，Windows 上表現成 jq 的常駐噪音。
input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# 早退：絕大多數指令根本沒有 `$?`，不值得付 jq 的成本。字串比對是 bash 內建，不開子行程。
case "$input" in *'$?'*) ;; *) exit 0 ;; esac

[ "${CLAUDE_ALLOW_PIPED_EXIT:-0}" = "1" ] && exit 0

JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0

cmd="$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# 【inline 前綴也要認】deny 訊息會教「這次呼叫前面加 CLAUDE_ALLOW_PIPED_EXIT=1」，
# 但 hook 讀的是自己 process 的環境變數，inline 前綴要等指令真的執行才存在。
# 不在這裡認它，照訊息做會再次被擋 → 迴圈。no-blind-sleep 已經踩過這個坑。
case "$cmd" in
  CLAUDE_ALLOW_PIPED_EXIT=1[[:space:]]*) exit 0 ;;
esac

# 開了 pipefail 的指令直接放行——整條管線的失敗會傳出來，主要危害已經消失。
#
# 【PIPESTATUS 不在這裡放行】2026-09-27 回顧重播一週 7,638 次 Bash 呼叫：夢境第 0 階段
# 連六晚寫 `memory doctor 2>&1 | tail -20; echo "rc=$?"; ...; echo "smoke_rc=${PIPESTATUS[0]}"`，
# 第一句是這個坑、後一句才是正解，而舊版只要整條字串出現 PIPESTATUS 就整條放行。
# 正確寫法 `${PIPESTATUS[0]}` 本身不含 `$?`，下面的判定原本就不會命中它，不需要特別放行。
case "$cmd" in
  *pipefail*) exit 0 ;;
esac

# 【heredoc 內容是資料，不是要執行的指令】剝掉 heredoc 正文，**終止行之後照常掃**。
# 舊版只掃第一個 `<<` 之前，於是 heredoc 結束之後的指令全部不檢查——同一次重播裡
# `python - <<PY ... PY` 之後緊接 `go build ./... 2>&1 | head -5; echo "exit=$?"` 漏了 7 次。
# `<<<` 是 here-string、不開正文，先換掉再認 heredoc。一行可有多個 heredoc，正文依序消耗。
# 分隔符照 bash 的規則取：整個 word（`<<\EOF`、`<<'EOF'`、`<<"EOF"`、`<<END-1` 都合法），
# 引號內可含空白（`<<'END WORD'`），再做引號移除，終止行必須與它逐字相同。
# 已知限制：單引號字串裡的 `<<WORD` 也會被當成 heredoc 開頭，其後內容被當正文略過——
# 誤差方向是漏報不是誤殺，刻意接受。
scan="$(printf '%s\n' "$cmd" | awk '
  {
    if (n > 0) {
      # 只有 `<<-` 會剝終止行的前導 tab；一般 `<<` 的 `\tEOF` 仍是正文。
      line = $0; if (t[h]) sub(/^\t+/, "", line)
      if (line == q[h]) { h++; if (h > n) { n = 0; h = 1 } }
      next
    }
    print
    rest = $0; gsub(/<<</, "", rest)
    while (match(rest, /<<-?[ \t]*('"'"'[^'"'"']*'"'"'|"[^"]*"|[A-Za-z_\\"'"'"'][^ \t;&|<>()]*)/)) {
      d = substr(rest, RSTART, RLENGTH)
      t[n + 1] = (substr(d, 3, 1) == "-")
      sub(/^<<-?[ \t]*/, "", d); gsub(/[\\"'"'"']/, "", d)
      q[++n] = d; h = 1
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
')"
[ -n "$scan" ] || exit 0

# 單引號內容是字面資料，剝掉；雙引號**不可剝**（見檔頭）。
# 跨行字串用 SOH 哨符折成單行再剝，剝完把換行換成 `;`——語句分隔的語意與 `;` 相同，
# 後面的判定就只需要處理單行。
scan="$(printf '%s' "$scan" | tr '\n' '\001' | sed "s/'[^']*'//g" | tr '\001' ';')"

# 管線末段是純輸出工具，緊接著的**下一個**語句讀 $?。
# 兩段都用 [^;&|]* / [^;|]* 圈住，所以中間隔了別的語句時不會誤判——
# `cmd | tail -5; ls x; echo $?` 的 $? 是 ls 的，那是正確寫法，必須放行。
FILTERS='tail|head|cat|tee|less|more|nl|column|fmt|sort|uniq|rev|tac|xxd|hexdump'
hit="$(printf '%s' "$scan" | grep -oE "\|[[:space:]]*($FILTERS)([[:space:]][^;&|]*)?[[:space:]]*[;&]+[^;|]*\\\$\\?" | head -1)"
[ -n "$hit" ] || exit 0

# 取出命中的過濾器名字放進 deny 訊息：去掉開頭的 `|` 與空白，取第一個詞。
filter="${hit#|}"
filter="${filter#"${filter%%[![:space:]]*}"}"
filter="${filter%%[[:space:]]*}"
filter="${filter%%[;&]*}"
[ -n "$filter" ] || filter="該過濾器"

"$JQ" -cn --arg f "$filter" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "偵測到「管線吃掉離開碼」：指令以 | " + $f + " 結尾，下一句卻讀 $?。\n" +
      "$? 是管線【最後一個】指令的離開碼，也就是 " + $f + " 自己的——它只要讀得到 stdin\n" +
      "就回 0。所以不管前面那個指令成功還是失敗，你都會拿到 0。這個檢查對它宣稱要驗的\n" +
      "事情零鑑別力，而輸出看起來和真的通過一模一樣。\n" +
      "\n" +
      "改成下面任一種：\n" +
      "  1) 輸出導檔，離開碼直接取（最簡單，也最不會再錯）：\n" +
      "       cmd > out.txt 2>&1; rc=$?; tail -40 out.txt; echo \"EXIT=$rc\"\n" +
      "  2) 真的要邊跑邊看輸出 → 取管線第一段的狀態：\n" +
      "       cmd 2>&1 | tail -40; echo \"EXIT=${PIPESTATUS[0]}\"\n" +
      "  3) 讓整條管線的失敗能傳出來：\n" +
      "       set -o pipefail; cmd 2>&1 | tail -40; echo \"EXIT=$?\"\n" +
      "\n" +
      "確定就是要讀過濾器自己的離開碼 → 這次呼叫前面加 CLAUDE_ALLOW_PIPED_EXIT=1。"
    )
  }
}'
exit 0
