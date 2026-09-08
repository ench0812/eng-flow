#!/usr/bin/env bash
# PreToolUse(Bash|PowerShell) — 擋下「固定長度的盲目等待」。
#
# 要解決的問題：模型想等一個沒有完成通知的東西（別的 session 起的程序、外部 CI、
# 還在寫的 log），就退化成 `sleep 500; tail -3 out.txt` 這種寫法。它有三個病：
#   1. 工作提早做完也照睡滿——等待時間與完成狀態完全解耦。
#   2. 時間到但工作沒完成時，tail 會印出半截內容而指令正常結束，看起來像「跑完了但
#      沒產出」。基於這份殘缺輸出繼續推論，比直接失敗更糟。
#   3. 使用者在這段時間內是被阻塞的，而且一輪一輪重複發生。
#
# 為什麼用 hook 而不是寫進 CLAUDE.md：規則靠自覺，而靠自覺的檢查等同沒有檢查
# （同 git-unpushed-check.sh 開頭那條理由）。這件事已經反覆發生，需要機制。
#
# 判定範圍刻意窄：只擋「單次睡眠 >= 門檻」。短的 sleep（等埠開、等檔案落地）照放，
# 迴圈裡的短 sleep 也照放——那正是我們要引導模型改成的寫法。
#
# 繞道：真的需要長睡時設 CLAUDE_ALLOW_LONG_SLEEP=1。刻意用環境變數而不是自然語言
# 白名單，因為它必須是「明確、當下、單次」的決定，不能靠模型自己說服自己。
#
# 【已知誤殺，刻意接受】(codex 第四輪指出，實測會 deny 但兩者都不會真的等待)：
#     git commit -m "document \"; sleep 300\" example"    ← 跳脫引號，剝除邏輯認不出
#     echo ok # old workaround; sleep 300                 ← 註解裡的分號
# 要正確處理需要一個能追蹤跳脫、引號狀態與註解的小型 shell 詞法分析器。那個複雜度
# （以及它自己會有的 bug）超過它擋掉的東西——這兩種寫法罕見，而繞道
# CLAUDE_ALLOW_LONG_SLEEP=1 一行就能過。刻意停在這裡，不做半套的引號解析。
#
# 【已知漏報，刻意接受】前綴集合只認 行首/;/&/|/空白，所以下列寫法溜得過去：
#     bash -c "sleep 500"     sh -c 'sleep 500'     (sleep 500)
# 把引號與括號加進前綴就能擋，代價是 `grep 'sleep 500' file` 這種【正常指令】會被誤殺
# ——而誤殺製造的摩擦會讓人乾脆關掉整個 hook，那比漏幾個邊緣寫法糟得多。
# 主要形態（`sleep 500; tail ...`）已經擋住，漏報方向也安全，所以停在這裡。
# 同 git-guard 的取捨：範圍不對的警告會被忽略，而被忽略的警告等於沒有警告。
set -uo pipefail

MAX="${CLAUDE_MAX_SLEEP_SECONDS:-60}"
case "$MAX" in ''|*[!0-9]*) MAX=60 ;; esac

# 【stdin 必須先讀完再做任何早退】(複查抓到): 在 cat 之前 exit 會讓上游寫入端拿到 EPIPE,
# Windows 上表現成 `jq: error: writing output failed: Invalid argument` 的常駐噪音。
# 目前無害,但這種噪音正是日後掩蓋真錯誤的東西。
input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# 早退(複查建議): 絕大多數指令根本沒有 sleep,不值得為它們付 jq + 兩次 grep 的成本。
# 實測 266ms/call → 82ms。字串比對在 bash 內建,不開子行程。
# 【大小寫要與後面的 grep -i 一致】(codex 第三輪抓到): 原本寫 *[sS]leep*，只容忍首字母
# 大小寫，於是 `START-SLEEP -SECONDS 300` 在這裡就被放行，後面的 grep -i 根本沒機會跑。
# 早退是效能優化，不該順手改變判定結果。
case "${input,,}" in *sleep*) ;; *) exit 0 ;; esac

[ "${CLAUDE_ALLOW_LONG_SLEEP:-0}" = "1" ] && exit 0

JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0

cmd="$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // ""' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# 【inline 前綴也要認】(複查抓到,實測): deny 訊息教模型「這次呼叫前面加
# CLAUDE_ALLOW_LONG_SLEEP=1」,但 hook 讀的是【自己 process 的環境變數】,而 inline 前綴
# 只存在於「將要被執行的那個 bash」裡——hook 在它執行【之前】就跑完了。
# 於是照訊息做會再次被擋,而且指令字串裡多了一個 sleep,必定再命中 → 迴圈。
# 唯一的逃生口不能是「照做也沒用」的,所以在這裡認它。
case "$cmd" in
  CLAUDE_ALLOW_LONG_SLEEP=1[[:space:]]*) exit 0 ;;
esac

# 取出所有睡眠秒數（含單位換算），回報最大的那一個。
# bash:       sleep 500 / sleep 10m / sleep 1h / sleep 0.5
# PowerShell: Start-Sleep 500 / Start-Sleep -Seconds 500 / Start-Sleep -s 500
#             （-Milliseconds 一律不管，它的量級不會構成問題）
# 【heredoc 內容是資料，不是要執行的指令】(複查抓到的誤殺): 用 heredoc 寫一支等待腳本時
#   cat > wait.sh <<EOF
#   sleep 300
#   EOF
# 那個 sleep 是給【別的程序】用的，不阻塞當前 session，可是它的行首和真指令長得一模一樣
# （`^` 是逐行錨點），於是被擋。只掃第一個 `<<` 之前的部分就避開了。
# 代價是一個漏報：`cat <<EOF ... EOF; sleep 500` 的 sleep 在 heredoc 之後，掃不到。
# 罕見，且方向安全（漏報不誤殺）——同本檔前面那條取捨的理由。
scan="${cmd%%<<*}"
[ -n "$scan" ] || scan="$cmd"
# 【引號內的內容也是資料】(codex 複查抓到): 前綴收緊到「指令位置」之後仍有漏網——
# 引號【裡面】的括號與分號一樣長得像指令分隔符。實測誤殺:
#   git commit -m "fix: remove (sleep 300)"    ← `(` 在引號內
#   echo "done; sleep 300"                     ← `;` 在引號內
# 兩者都沒有真的等待。把成對引號的內容剝掉再掃即可。
# 這也順帶讓 `bash -c "sleep 500"` 這個已知漏報更明確：引號內容一律當資料，
# 不再是「剛好沒匹配到」而是「刻意不看」——語意一致，行為不變。
# 【跨行字串也要剝】(codex 第二輪抓到): sed 逐行處理，跨行的引號字串剝不掉——
# 實測 `echo 'hello<換行>sleep 300<換行>world'` 這種純輸出被判 deny。
# 用 tr 把換行換成一個不會出現在指令裡的哨符，剝完再換回來，就變成單行處理。
# 選 \001（SOH）當哨符：控制字元不會出現在正常指令字串裡。
scan="$(printf '%s' "$scan" | tr '\n' '\001' | sed "s/'[^']*'//g; s/\"[^\"]*\"//g" | tr '\001' '\n')"

worst=0; worst_txt=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  # 取最後一段數字（前面可能有 -Seconds 之類的參數名）
  num="$(printf '%s' "$m" | grep -oE '[0-9]+(\.[0-9]+)?[smhdSMHD]?$')"
  [ -n "$num" ] || continue
  # 【換算要在取整【之前】】(codex 複查抓到): 原本先砍小數再乘倍率，於是 `sleep 0.5h`
  # 變成 0×3600 = 0 秒而放行——1800 秒的等待完全溜過去，`sleep 1.5m`（90s）同理。
  # bash 沒有浮點，所以用「毫為單位」的整數運算：把數值放大 1000 倍算完再除回來。
  int="${num%%.*}"; int="${int//[!0-9]/}"; [ -n "$int" ] || int=0
  case "$num" in
    *.*) frac="${num#*.}"; frac="${frac//[!0-9]/}" ;;
    *)   frac="" ;;
  esac
  frac="${frac}000"; frac="${frac:0:3}"          # 補/截到三位小數
  # 【超大數字要截斷】(複查抓到): 20 位數會讓 [ ] 報 "integer expected" 到 stderr、
  # worst 停在 0 → fail-open 放行。截到 9 位仍遠大於任何合理睡眠。
  int="${int:0:9}"
  # 【必須強制十進位】(複查抓到): 前導零會讓 $(( )) 走八進位——實測 `sleep 08m` 報
  # "value too great for base" 而整條被放行，`sleep 010m` 則算成 480 秒（真值 600）。
  milli=$(( 10#$int * 1000 + 10#$frac ))
  # 【大小寫要先統一】(codex 第二輪抓到): 擷取用的是 grep -i，單位判斷卻只列了部分大小寫，
  # 於是 `Start-Sleep -MILLISECONDS 500` 沒命中毫秒分支，被當成 500 秒而 deny。
  lm="${m,,}"
  case "$lm" in
    *milli*|*-ms*) mult=1; milli=$(( milli / 1000 )) ;;  # PowerShell -Milliseconds
    *m) mult=60 ;;
    *h) mult=3600 ;;
    *d) mult=86400 ;;
    *)  mult=1 ;;
  esac
  secs=$(( milli * mult / 1000 ))
  if [ "$secs" -gt "$worst" ]; then worst="$secs"; worst_txt="$m（約 ${secs}s）"; fi
done <<EOF
$(printf '%s' "$scan" | grep -oiE '(^|[;&|(\`]|[[:space:]](do|then|else)[[:space:]])[[:space:]]*(sleep|start-sleep)([[:space:]]+-[a-z]+)?[[:space:]:]+[0-9]+(\.[0-9]+)?[smhd]?')
EOF

[ "$worst" -le "$MAX" ] && exit 0

"$JQ" -cn --arg s "$worst" --arg t "$worst_txt" --arg max "$MAX" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "偵測到固定長度的盲等：sleep " + $t + "（約 " + $s + " 秒，門檻 " + $max + " 秒）。\n" +
      "固定 sleep 的問題是等待與完成狀態脫鉤：工作提早做完也照睡滿，時間到卻沒完成時\n" +
      "又會拿到半截輸出而指令仍正常結束——那份殘缺結果看起來像「跑完了但沒產出」。\n" +
      "\n" +
      "改用「有上限、會提早返回、逾時要能分辨」的寫法：\n" +
      "  1) 這是你用 run_in_background 起的工作 → 什麼都不要做，完成時會通知你。\n" +
      "  2) 等產出出現（逾時回非零，才分得出「完成」和「等到放棄」）：\n" +
      "       for i in $(seq 1 60); do grep -q DONE \"$out\" && break; sleep 5; done\n" +
      "       grep -q DONE \"$out\" || { echo TIMEOUT >&2; exit 1; }\n" +
      "     只寫 for 迴圈是不夠的——重試耗盡後最後一次 sleep 仍會讓迴圈正常結束，\n" +
      "     結果和「等到了」完全一樣，而那正是盲等最危險的地方。\n" +
      "  3) 等某個程序結束（同樣要有上限）：\n" +
      "       for i in $(seq 1 60); do kill -0 <pid> 2>/dev/null || break; sleep 5; done\n" +
      "  4) 等檔案不再變動 → 比對 mtime，連續 N 次沒變才視為結束。\n" +
      "共通點：每輪只睡幾秒、條件成立就跳出、迴圈之後【再判一次】並在逾時回非零。\n" +
      "\n" +
      "確定非長睡不可（例如外部服務有固定冷卻期）→ 這次呼叫前面加 CLAUDE_ALLOW_LONG_SLEEP=1，\n" +
      "或調高 CLAUDE_MAX_SLEEP_SECONDS。"
    )
  }
}'
exit 0
