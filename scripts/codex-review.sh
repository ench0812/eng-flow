#!/usr/bin/env bash
# codex-review.sh — eng-flow 的 OpenAI Codex 跨家族交叉複查
#
# 兩種模式(互斥):
#   diff 模式(預設): code review 收尾的第二意見。第一輪(Claude / eng-flow 五軸)review
#        完成、該輪所有 required/critical 已修正後,對本分支相對 base 的「整體 diff」
#        跑一次非互動 codex review。純第二意見,不自動改 code。
#   doc 模式(--doc + --kind): 規劃設計階段的共議(co-design)。對 mao-brainstorm 的
#        design spec 或 mao-plan 的 implementation plan 跑一次共同設計諮詢;多輪收斂
#        狀態由呼叫端維護在文件尾端「## Cross-Check Log」小節。
#   兩者皆唯讀,腳本不改 repo 內任何檔(狀態與遙測只寫 $CODEX_REVIEW_STATE / $CODEX_REVIEW_LOG)。
#
# 收斂機制(2026-08-04 起取代舊版的諮詢次數上限,所有模式皆無次數上限):
#   每次諮詢的 prompt 都要求 codex 在回覆末尾附單獨一行「收斂問句:<最關鍵的一個未決問題>」
#   (已無足以改變產出的問題則「收斂問句:無」)。是否續輪由呼叫端(Claude)每輪判斷——
#   問句重複已處置議題、超出文件/變更範圍、或回答後不會改變產出,就收斂停止;續輪必須讓
#   未決集合變小。細則見 mao-brainstorm / mao-plan / mao-review / mao-execute skill。
#   doc 模式輪數 >= CONVERGE_WARN_ROUNDS 時本腳本印警示(不阻斷、照常諮詢),提醒強制收斂。
#
# Rate limit: 若 codex 回報用量/額度上限,印 RATE_LIMITED 並 exit 0。該次諮詢視為未發生
#   ——呼叫端不得重試、不為它補記 Cross-Check Log 的「### Round」(doc 模式),直接繼續
#   後續動作;下次需要諮詢時照常再呼叫本腳本。被擋的那次不推進輪數、不覆蓋 payload 快照。
#
# 依「來源嚴重度」選模型(嚴重度由呼叫端提供,腳本不自行分診):
#   複查深度應與風險相稱。嚴重度是【輸入】——
#     diff 模式: 第一輪五軸 review 對本次變更判定的最高原始嚴重度
#     doc  模式: Claude 對該設計/計畫的風險自評(規則見 mao-brainstorm / mao-plan skill)
#   映射(嚴重度用語同 mao-review taxonomy;2026-08-07 改版,理由:舊映射 token 消耗過大):
#     critical          -> gpt-5.6-sol   / medium(旗艦保留給阻斷級風險,但 effort 由 max 降到 medium)
#     required          -> gpt-5.6-terra / high  (中階模型 + 高 effort 補償)
#     optional/nit/fyi  -> gpt-5.6-luna  / max   (nano 級模型,單價低到直接給最高 effort 也划算)
#   --severity 未傳/未知 -> fallback gpt-5.6-luna / max(對齊最低一級:沒說嚴重度就不燒旗艦額度;
#                            腳本仍印警告要求呼叫端補傳,別靠 fallback 過日子)。
#   策略:模型階梯隨嚴重度下降(sol > terra > luna),effort 反向上升作為補償。舊版 sol/max
#   ＋ sol/high 兩級都吃旗艦模型的最貴檔位,是 token 消耗的主因。
#
# 成本治理(2026-08-24 新增,起因: 實測 5 天內被呼叫 129 次、diff 模式 107 次全無輪次計數):
#   1. 遙測 — 改用 `codex exec --json` 取 turn.completed 的 usage,每次呼叫(含 FAILED /
#      RATE_LIMITED)在 $CODEX_REVIEW_LOG 追加一列 TSV,含 cache hit rate。人類模式只印
#      `tokens used <總數>`,沒有 cached/input 拆分,所以無法用來量快取。報表: codex-usage.sh
#   2. payload 瘦身 — doc 模式只附最後一輪 Cross-Check Log(舊行為整份重送,實測讓 payload
#      在 12 輪內從 4,929 長到 26,758);diff 模式排除產生物/鎖檔並回報排除了什麼。
#   3. 輪次 ledger — 每條複查線(repo/模式/目標)記錄輪數,超過警示線印【非阻斷】提醒。
#      diff 模式警示線比 doc 嚴,因為它的協議是「一輪 review 一次」。
#   4. 去重 — 送出內容與上一輪完全相同就 SKIP,不送。
#   5. session resume — TTL 內續用同一 session 只送 delta,讓歷史變成 cached input
#      (實測未快取 input 4,929 → 863)。【預設關閉】: 快取窗口實測只有數十秒,真實 review
#      節奏落在窗口外時 resume 反而更貴。CODEX_REVIEW_RESUME=1 開啟。去重不受此開關影響。
#      ★ resume 只讓【歷史】變 cached,新訊息永遠全價 ⇒ resume 輪一定要送 delta,不能送全文。
#
# 用法: bash codex-review.sh --severity <critical|required|optional|nit|fyi> [--base <branch>]
#        bash codex-review.sh --severity <...> --doc <path> --kind <spec|plan>
#        --base 省略時自動偵測(origin/HEAD → main → master);--doc 與 --base 互斥。
#
# 前置: codex client >= 0.144.x 且帳號 plan(Plus 以上)已 rollout GPT-5.6 家族,
#        否則 gpt-5.6-* slug 會被 server 回 400 invalid_request。
#
# 結束碼: 環境缺失(codex 未裝/未授權、diff 模式不在 repo) → 印提示並 exit 0(不阻斷);
#          用量/額度上限 → 印 RATE_LIMITED 並 exit 0(不阻斷、不重試、不計 round);
#          諮詢失敗(codex 非正常結束,或跑了但零輸出) → 印 FAILED 並 exit 1;
#          呼叫端合約錯誤(--doc 檔不存在、參數矛盾) → exit 2(顯錯,不可靜默)。
#
# FAILED 與其他 exit 0 分支的差別(刻意): 前面幾種都是「已知且已判定的狀況」,呼叫端照著
#   訊息處置即可;FAILED 是「複查根本沒發生」。舊版無論 codex 回什麼都印「完成」,呼叫端
#   因此以為複查過了——假成功比直接報錯危險得多,所以這一種給非零結束碼。
#   實測(codex 0.144.5): 非信任目錄 → exit 1、stdout 0 bytes、stderr 只有
#   "Not inside a trusted directory and --skip-git-repo-check was not specified."
set -uo pipefail

# --- 嚴重度 → 模型/effort 映射(集中一處,要調策略只改這裡) ---
CRIT_MODEL="gpt-5.6-sol";      CRIT_EFFORT="medium"     # critical
REQ_MODEL="gpt-5.6-terra";     REQ_EFFORT="high"        # required
LOW_MODEL="gpt-5.6-luna";      LOW_EFFORT="max"         # optional / nit / fyi
FALLBACK_MODEL="gpt-5.6-luna"; FALLBACK_EFFORT="max"    # --severity 未傳/未知時的保底(對齊 optional)
CONVERGE_WARN_ROUNDS=6         # doc 模式共議輪數警示線:達此輪數仍未收斂即印提醒(不阻斷)。
                               # 無硬上限——收斂由呼叫端依每輪「收斂問句」判斷,見 header。
CONVERGE_WARN_ROUNDS_DIFF=3    # diff 模式警示線。比 doc 嚴,因為 diff 模式的協議是「一輪
                               # review 一次」(not per file or per fix);第 3 次就該被看見。

# --- 成本治理(2026-08-24 新增;全部可用環境變數覆寫,預設值即建議值) ---
# 背景(實測,非推測): 2026-08-20~24 五天內本腳本被真實執行 129 次,其中 diff 模式 107 次
# (83%),單一 session 最高 17 次、中位間隔 5.0 分鐘——即「每修一處就複查一次」,正是協議
# 禁止的用法;而 diff 模式當時完全沒有輪次計數,所以沒有任何一次被看見。
# 另一筆: 某份 plan 52 分鐘內 12 輪,payload 從 4,929 字元長到 26,758(每輪把新增的
# Cross-Check Log 連同全文再送一次),累計送出 181,335 字元 = 6.8x 冗餘。
CODEX_REVIEW_STATE="${CODEX_REVIEW_STATE:-$HOME/.claude/cache/codex-review}"   # ledger + payload 快照
CODEX_REVIEW_LOG="${CODEX_REVIEW_LOG:-$HOME/.claude/cache/codex-review-usage.tsv}"  # 用量遙測
# resume 預設【關閉】——理由是實測,不是保守。codex 的 session 歷史快取窗口遠短於文件講的
# 30 分鐘 exact TTL(那個數字描述 API 端的 prompt cache,不等於這裡觀察到的行為):
#     間隔  25s → cached 15,104/16,219 = 93.1%(命中歷史)
#     間隔 100s → cached  9,984/17,004 = 58.7%(只剩靜態 prefix,歷史沒命中)
#     fresh 基線                        = 64.7%
# 窗口之外 resume 會把歷史【連同上一輪的回覆】全額重送,實測比 fresh 貴約 30%。而真實的
# review 節奏(實測中位間隔 5 分鐘)幾乎永遠落在窗口外,預設開啟只會讓事情變差。
# CODEX_REVIEW_RESUME=1 可開啟,適用「連續兩輪相隔數十秒」——諷刺的是那正是本次要勸阻的
# per-fix 複查用法;開啟後仍有 per-line 的 TTL 自我校正兜底。
CODEX_REVIEW_RESUME="${CODEX_REVIEW_RESUME:-0}"
CODEX_REVIEW_FORCE="${CODEX_REVIEW_FORCE:-0}"   # 1=略過「與上一輪相同」的去重攔截,強制重問同一份內容
CODEX_RESUME_TTL="${CODEX_RESUME_TTL:-30}"        # 秒。上界由上面的實測夾出(25s 命中、100s 沒命中)
CODEX_WARN_CHARS="${CODEX_WARN_CHARS:-60000}"     # 軟性大小警示(硬守門是 1M,實務上等於沒有)
CODEX_ROUND_RESET="${CODEX_ROUND_RESET:-21600}"  # 秒。距上次諮詢超過這個間隔就視為新的一輪 review,輪數歸零(預設 6 小時)
CODEX_REVIEW_STATE_TTL_DAYS="${CODEX_REVIEW_STATE_TTL_DAYS:-7}"  # payload 快照保留天數,0=不清理

# diff 模式排除清單: 只排除【建置產物】—— 它們佔 diff 體積但幾乎不帶 review 價值。
# 測試檔【刻意不排除】(prompt 第一軸就含測試覆蓋)。
# lockfile 也【刻意不排除】(2026-08-24 codex 交叉複查指出): lockfile 才記錄實際解析到的
# 版本、transitive dependency 與 integrity hash,manifest 乾淨不代表 lockfile 沒被動過。
# 把它排掉等於在供應鏈這一軸開盲點,而「不知道有沒有被動」與「確認不需要審」是兩件事。
# 專案若真的受不了 lockfile 的 diff 體積,自行把它加進 CODEX_REVIEW_EXCLUDE。
# 【必須帶 ,glob】: 沒有 glob magic 時 git 的 `**/` 不匹配根層檔案——實測
# `:(exclude)**/package-lock.json` 排得掉 sub/package-lock.json 卻排不掉根目錄那份。
CODEX_REVIEW_EXCLUDE="${CODEX_REVIEW_EXCLUDE-:(exclude,glob)**/*.min.*
:(exclude,glob)**/dist/**
:(exclude,glob)**/build/**
:(exclude,glob)**/vendor/**
:(exclude,glob)**/node_modules/**
:(exclude,glob)**/__snapshots__/**}"

# 疑似機密的檔案【不送出,但要大聲講】。兩條規則同時成立:
#   (a) 不該把金鑰/憑證內容送給外部服務;
#   (b) 這種檔案出現在 diff 裡本身就是安全鐵律 #1(secrets 不進版控)的違反,必須被看見。
# 所以這一類是「排除 + 警示」,不是靜默略過。
CODEX_REVIEW_SECRET_EXCLUDE="${CODEX_REVIEW_SECRET_EXCLUDE-:(exclude,glob)**/.env
:(exclude,glob)**/.env.*
:(exclude,glob)**/*.pem
:(exclude,glob)**/*.key
:(exclude,glob)**/*.p12
:(exclude,glob)**/*.pfx
:(exclude,glob)**/id_rsa*
:(exclude,glob)**/id_ed25519*}"

# --- Rate limit 判定 ---
# pattern 取自 codex 0.144.x binary 內實際的使用者可見字串。刻意不涵蓋「接近但仍可用」
# 的字樣: "Approaching rate limits"、"Remaining usage on the ... usage limit"(額度查詢)、
# "Hide future rate limit reminders"(偏好設定)——那些不代表本次被擋。
# 429 / too many requests 只在 stderr 且 codex 非正常結束時採信: review 內容(stdout)
# 本來就可能提到這些字或剛好有行號 429,拿來當訊號會誤判。
# 成功短路(2026-08-04 兩次 dogfood 實測誤判後加入): codex exec 的 transcript 會回顯
# prompt+stdin 原文,當 diff/doc 內容本身含限制字樣(例如本腳本的 rate limit 測試
# fixture)時,成功的諮詢會被誤判成 RATE_LIMITED。rc=0 且 stdout 有實質內容(>=200 個
# 非空白字元)＝諮詢確實發生,不可能同時是被擋;唯一例外是「stdout 極短且全是限制訊息、
# exit 仍為 0」——那種真被擋的情況輸出遠小於門檻,仍會被 pattern 攔到。
RATE_PAT_STRICT="you'?ve (hit|reached) your usage limit|you have (hit|reached) your usage limit|reached your workspace credit limit|out of credits|quota exceeded|rate limit reached"
RATE_PAT_ERR_ONLY='too many requests|(^|[^0-9.])429([^0-9]|$)'
# 輸入過長判定(2026-08-12 實測誤判後新增): codex 對超過模型輸入上限的 payload 會在
# turn/start 就拒絕,錯誤形如
#   Error: turn/start failed: Input exceeds the maximum length of 1048576 characters.
#   (code -32602), data: {"input_error_code":"input_too_large","max_chars":...,"actual_chars":...}
# 這**不是**額度問題,是「這份 diff 永遠不會被複查,除非縮小範圍」——必須走 FAILED,
# 不可走 RATE_LIMITED(後者的處置是「直接繼續、下次再叫」,會讓呼叫端以為只是暫時被擋)。
TOO_LARGE_PAT='input_too_large|Input exceeds the maximum length'

is_rate_limited() {  # $1=codex exit code  $2=stderr 檔  $3=stdout 檔
  # 成功證據二選一(round 4 共議: 短版有效回覆「無重大遺漏+收斂問句:無」遠小於長度門檻,
  # 不能只看長度): (a) stdout 有行首收斂問句合約行——真回覆才會有,prompt 回顯裡它永遠
  # 在行中;(b) 實質輸出量(>=200 非空白字元)。兩者都再要求尾端 1000 bytes 無限制字樣
  # ——「回顯完 payload 之後才被擋、exit 仍 0」的情況,限制訊息必然落在尾端(round 3)。
  local out_sz
  out_sz="$(tr -d '[:space:]' < "$3" 2>/dev/null | wc -c)"
  if [ "$1" -eq 0 ]; then
    if grep -qE "^收斂問句[:：]" "$3" 2>/dev/null || [ "${out_sz:-0}" -ge 200 ]; then
      tail -c 1000 "$3" 2>/dev/null | grep -qiE "$RATE_PAT_STRICT" || return 1
    fi
  fi
  grep -qiE "$RATE_PAT_STRICT" "$2" "$3" 2>/dev/null && return 0
  [ "$1" -ne 0 ] || return 1
  # 輸入過長不是 rate limit(見 TOO_LARGE_PAT 說明),讓它落到 FAILED 分支。
  grep -qiE "$TOO_LARGE_PAT" "$2" 2>/dev/null && return 1
  # 寬鬆的 429 規則**先剔除看起來像 diff 的行**再比對,不對整份 stderr 套用。
  # 2026-08-12 實測誤判: codex 0.144.x 會把 transcript(含被回顯的整份 diff)寫到 stderr,
  # 於是 diff 裡任何一個 429 都會命中——實際觸發的是一行 hunk header
  # `@@ -303,18 +429,23 @@`（`+429,` 命中 `[^0-9.]429[^0-9]`)。原註解假設「stderr 不與
  # review 內容混流」,那個前提對這個 codex 版本不成立。
  # 刻意用「排除 diff 行」而非「要求 Error 前綴」: 後者會漏掉 codex 直接印
  # `HTTP 429 Too Many Requests` 這種沒有前綴的訊息(既有測試涵蓋),收窄不可改壞既有行為。
  grep -vE '^(@@|\+\+\+|---|diff --git|index [0-9a-f]+\.\.|[+-])' "$2" 2>/dev/null     | grep -qiE "$RATE_PAT_ERR_ONLY"
}

# --- 成本治理工具函式(離線可測,不碰 codex) ---
now_ts() {
  date +%s 2>/dev/null || echo 0
}

# ledger key: repo/模式/目標三者決定一條複查線。sha1sum 缺席時退 cksum(仍具決定性)。
# 非密碼學用途: 只是把三元組壓成穩定的檔名,不作完整性或認證憑據(安全鐵律 #3 不適用)。
state_key() {
  printf '%s|%s|%s' "$1" "$2" "$3" | { sha1sum 2>/dev/null || cksum; } | awk '{print $1}'
}

# 刻意用 grep 讀而不 source: state 檔是本機快取,但不該存在「被當成 shell 執行」的路徑。
state_get() {  # $1=state 檔 $2=欄位名
  [ -f "$1" ] || return 0
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# doc 模式: 全文,但 Cross-Check Log 只保留最後一輪。
# 為什麼: 每輪把新增的 log 連同全文再送一次,是實測到的 payload 膨脹主因(4,929→26,758)。
# 已處置議題的語意不靠重送舊 log 維持——prompt 已明說「已處置的仍視為已處置」。
trim_crosscheck_log() {  # $1=doc 路徑
  local doc="$1" ccl last total
  # 取【最後】一個匹配: 本 repo 的 skill 文件本身就會示範這個協議,取第一個會從正文中間裁掉。
  ccl="$(grep -n '^## Cross-Check Log' "$doc" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -z "$ccl" ]; then cat "$doc"; return 0; fi
  total="$(awk -v s="$ccl" 'NR>=s && /^### Round /{n++} END{print n+0}' "$doc")"
  if [ "${total:-0}" -le 1 ]; then cat "$doc"; return 0; fi
  last="$(awk -v s="$ccl" 'NR>=s && /^### Round /{l=NR} END{print l+0}' "$doc")"
  sed -n "1,${ccl}p" "$doc"
  printf '\n> (前 %s 輪的 Cross-Check Log 已省略以節省 token;只附最後一輪。已處置的議題仍視為已處置。)\n\n' "$((total-1))"
  sed -n "${last},\$p" "$doc"
}

# diff 模式 resume delta: 依 `diff --git` 切檔,只送內容有變的檔案區塊。
# 未變更的檔案不重送——它們的完整內容已在 resume 的對話歷史裡(這正是 resume 划算的前提)。
# 【必須同時回報「本輪已消失」的檔案】: 上一輪存在、本輪已還原的檔案不會出現在本輪 diff,
# 若不明講,codex 的歷史裡那份舊 diff 仍然成立,它會依過期資訊給意見。
diff_delta_per_file() {  # $1=上一輪 diff 快照 $2=本輪 diff
  awk -v snapf="$1" '
    /^diff --git /{
      key=$0
      if (FILENAME==snapf) { if (!(key in oseen)) { oorder[++no]=key; oseen[key]=1 } }
      else                 { if (!(key in seen))  { order[++nk]=key;  seen[key]=1 } }
    }
    key=="" { next }
    { if (FILENAME==snapf) old[key]=old[key] $0 "\n"; else cur[key]=cur[key] $0 "\n" }
    function name(k,  n) { n=k; sub(/^diff --git a\//,"",n); sub(/ b\/.*$/,"",n); return n }
    function join(arr, cnt,   i, s) {
      s=""
      for (i=1; i<=cnt && i<=40; i++) s = s (s?", ":"") arr[i]
      if (cnt>40) s = s sprintf(" ...(共 %d 檔)", cnt)
      return s
    }
    END{
      for (i=1;i<=nk;i++) {
        k=order[i]
        if (cur[k]!=old[k]) printf "%s", cur[k]
        else un[++nu]=name(k)
      }
      for (i=1;i<=no;i++) { k=oorder[i]; if (!(k in cur)) gone[++ng]=name(k) }
      if (ng>0) printf "\n(以下檔案的變更【已還原】,不再屬於本次變更,先前輪次對它們的意見已不適用: %s)\n", join(gone, ng)
      if (nu>0) printf "\n(以下檔案自上一輪起未變更,完整內容已在本對話先前輪次中,不再重送: %s)\n", join(un, nu)
    }' "$1" "$2"
}

# JSON 取數(只取第一個匹配;usage 物件是扁平的整數欄位,不需要 jq)
jnum() {
  printf '%s' "$1" | grep -o "\"$2\":[0-9]*" | head -1 | cut -d: -f2
}

# 用量遙測: 旁路寫檔,絕不影響任何判定路徑,寫不成也不能讓複查失敗。
# 為什麼連 FAILED / RATE_LIMITED 也要記: 沒發生的複查照樣可能已經燒掉 input token,
# 只記成功的會低估成本,而低估成本正是當初沒人發現用量失控的原因。
# 欄位轉義: 路徑含 tab/換行會把後續欄位整體位移,而 codex-usage.sh 全靠位置定址讀取。
tsv() { local v="$1"; v="${v//$'\t'/ }"; v="${v//$'\n'/ }"; printf '%s' "$v"; }
emit_telemetry() {  # $1=狀態(OK|FAILED|RATE_LIMITED)
  local usage in_t cin_t out_t rea_t hit
  usage="$(grep -o '"usage":{[^}]*}' "$JSON_FILE" 2>/dev/null | tail -1)"
  in_t="$(jnum "$usage" input_tokens)";  cin_t="$(jnum "$usage" cached_input_tokens)"
  out_t="$(jnum "$usage" output_tokens)"; rea_t="$(jnum "$usage" reasoning_output_tokens)"
  : "${in_t:=0}" "${cin_t:=0}" "${out_t:=0}" "${rea_t:=0}"
  hit="$(awk -v a="$cin_t" -v b="$in_t" 'BEGIN{ if (b>0) printf "%.1f", a*100/b; else printf "" }')"
  mkdir -p "$(dirname "$CODEX_REVIEW_LOG")" 2>/dev/null || true
  if [ ! -f "$CODEX_REVIEW_LOG" ]; then
    printf 'ts\trepo\tmode\ttarget\tseverity\tmodel\teffort\tsent_chars\tinput_tokens\tcached_input_tokens\toutput_tokens\treasoning_tokens\tcache_hit_pct\tsession_mode\tround\tstatus\trc\n' \
      >> "$CODEX_REVIEW_LOG" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$(tsv "$REPO_ROOT")" "$MODE_NAME" \
    "$(tsv "$LEDGER_TARGET")" "$SEV_SHOWN" "$MODEL" "$EFFORT" "${PAYLOAD_CHARS:-0}" \
    "$in_t" "$cin_t" "$out_t" "$rea_t" "$hit" "$SESSION_MODE" "$ROUND_NO" "$1" "${RC:-}" \
    >> "$CODEX_REVIEW_LOG" 2>/dev/null || true
}

# ledger 只在【複查確實發生】時更新。RATE_LIMITED 依協議「不計 round」,FAILED 是複查沒發生
# ——兩者都不得推進輪數,也不得覆蓋 payload 快照(否則下一輪會拿錯的基準算 delta)。
#
# payload 快照存的是完整 diff 或完整文件全文。它是本次改動唯一新增的長期明文副本
# (先前三個 mktemp 在 EXIT 全刪),所以: 目錄 0700、檔案 0600、並設保留期限自動清理。
# 寫入一律 tmp + mv(同目錄內 rename 是原子的): 兩個 Claude session 同時對同一條複查線
# 注意: chmod 在 Windows/MSYS 的 NTFS 上是 no-op(實測仍是 755/644),那裡靠的是使用者
#       profile 目錄本身的 ACL。這幾行是給 Linux/WSL/macOS 用的,不要當成跨平台保證。
# 呼叫時,不可能讀到「寫到一半」的 state 或快照,也不會出現 session 屬於 B、快照屬於 A
# 的交錯狀態。
persist_ledger() {
  local sid tmp
  mkdir -p "$CODEX_REVIEW_STATE" 2>/dev/null || true
  chmod 700 "$CODEX_REVIEW_STATE" 2>/dev/null || true

  # 保留期限清理: 過期的只清 payload(體積大且敏感),state 很小且是輪次判斷依據,留著。
  if [ "${CODEX_REVIEW_STATE_TTL_DAYS:-7}" -gt 0 ] 2>/dev/null; then
    find "$CODEX_REVIEW_STATE" -maxdepth 1 -name '*.payload' -type f \
         -mtime "+${CODEX_REVIEW_STATE_TTL_DAYS:-7}" -delete 2>/dev/null || true
  fi

  sid="$(grep -o '"thread_id":"[^"]*"' "$JSON_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)"
  [ -n "$sid" ] || sid="$(grep -oE '^session id: [0-9a-f-]{36}' "$ERR_FILE" 2>/dev/null | head -1 | awk '{print $3}')"
  [ -n "$sid" ] || sid="$RESUME_ID"   # 抓不到就沿用;仍抓不到則留空 → 下一輪自動 fresh

  # resume 是否真的吃到歷史快取: fresh 的基線約 65%(只有靜態 prefix),命中歷史會到 90%+,
  # 沒命中則掉回 40% 上下。0.8 這條線把兩種情況分得很開,不需要更精細的判準。
  local u ci ii hint
  hint="$(state_get "$STATE_FILE" resume_ttl_hint)"
  case "$hint" in ''|*[!0-9]*) hint="" ;; esac
  if [ "$SESSION_MODE" = "resume" ]; then
    u="$(grep -o '"usage":{[^}]*}' "$JSON_FILE" 2>/dev/null | tail -1)"
    ci="$(jnum "$u" cached_input_tokens)"; ii="$(jnum "$u" input_tokens)"
    : "${ci:=0}" "${ii:=0}"
    if [ "$ii" -gt 0 ] && [ "$(( ci * 100 / ii ))" -lt 80 ]; then
      hint=$(( RESUME_AGE / 2 )); [ "$hint" -lt 10 ] && hint=10
      echo "[codex-review] 注意: 本輪 resume 沒吃到歷史快取(cached ${ci}/${ii})。這條複查線的 resume 窗口收窄為 ${hint}s。" >&2
    else
      hint=""   # 命中 → 清掉修正值,回到全域 TTL
    fi
  fi

  tmp="$STATE_FILE.$$.tmp"
  if { echo "rounds=$ROUND_NO"
       echo "last_ts=$(now_ts)"
       echo "session_id=$sid"
       echo "model=$MODEL"
       echo "effort=$EFFORT"
       [ -n "$hint" ] && echo "resume_ttl_hint=$hint"
       true
     } > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi

  tmp="$SNAP_FILE.$$.tmp"
  if printf '%s\n' "$PAYLOAD" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SNAP_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

SEVERITY=""
BASE=""
DOC=""
KIND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --severity|--base|--doc|--kind)
      # 缺值時 shift 2 不會位移(bash shift n > $# 失敗但不動參數),會變無限迴圈 → 先驗
      [ $# -ge 2 ] || { echo "[codex-review] 錯誤: $1 需要值。" >&2; exit 2; }
      case "$1" in
        --severity) SEVERITY="$2" ;;
        --base)     BASE="$2" ;;
        --doc)      DOC="$2" ;;
        --kind)     KIND="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      echo "用法: bash codex-review.sh --severity <critical|required|optional|nit|fyi> [--base <branch>]"
      echo "      bash codex-review.sh --severity <...> --doc <path> --kind <spec|plan>"
      exit 0 ;;
    *) echo "[codex-review] 未知參數: $1" >&2; exit 2 ;;
  esac
done

# --- doc 模式呼叫端合約: 錯 = 呼叫端 bug → exit 2(刻意放在環境 gate 之前,可離線測試) ---
DOC_MODE=0
if [ -n "$DOC" ] || [ -n "$KIND" ]; then
  [ -n "$DOC" ]  || { echo "[codex-review] 錯誤: --kind 需搭配 --doc <path>。" >&2; exit 2; }
  [ -n "$KIND" ] || { echo "[codex-review] 錯誤: --doc 需搭配 --kind <spec|plan>。" >&2; exit 2; }
  [ -z "$BASE" ] || { echo "[codex-review] 錯誤: --doc 與 --base 互斥(doc 模式不看 diff)。" >&2; exit 2; }
  case "$KIND" in
    spec|plan) ;;
    *) echo "[codex-review] 錯誤: --kind 只接受 spec|plan,收到 '$KIND'。" >&2; exit 2 ;;
  esac
  [ -f "$DOC" ] || { echo "[codex-review] 錯誤: 找不到文件 '$DOC'(呼叫端應傳存在的檔案路徑)。" >&2; exit 2; }
  DOC_MODE=1
fi

# --- doc 模式共議輪數警示: 輪數異常偏高時提醒強制收斂(不阻斷,照常諮詢;離線可測) ---
# 無硬上限——收斂由呼叫端依每輪「收斂問句」判斷;這裡只是未收斂的 tripwire。
# 迴圈狀態本來就由呼叫端記在文件的「## Cross-Check Log」小節,腳本只讀不寫,仍屬無狀態。
if [ "$DOC_MODE" -eq 1 ]; then
  ROUNDS="$(awk '/^## Cross-Check Log/{f=1} f && /^### Round /{n++} END{print n+0}' "$DOC")"
  if [ "$ROUNDS" -ge "$CONVERGE_WARN_ROUNDS" ]; then
    echo "[codex-review] 警示: '$DOC' 的 Cross-Check Log 已累積 $ROUNDS 輪仍未收斂(警示線 $CONVERGE_WARN_ROUNDS)。檢查是否在追新戰線而非收斂舊問題——建議本輪後強制收斂:未決事項改記 user call 交使用者仲裁。" >&2
  fi
fi

# --- 依來源嚴重度決定模型/effort ---
case "$(printf '%s' "$SEVERITY" | tr '[:upper:]' '[:lower:]')" in
  critical)         MODEL="$CRIT_MODEL"; EFFORT="$CRIT_EFFORT"; SEV_SHOWN="critical" ;;
  required)         MODEL="$REQ_MODEL";  EFFORT="$REQ_EFFORT";  SEV_SHOWN="required" ;;
  optional|nit|fyi) MODEL="$LOW_MODEL";  EFFORT="$LOW_EFFORT";  SEV_SHOWN="$SEVERITY" ;;
  "")  MODEL="$FALLBACK_MODEL"; EFFORT="$FALLBACK_EFFORT"; SEV_SHOWN="(未指定)"
       echo "[codex-review] 警告: 未傳 --severity,fallback $FALLBACK_MODEL/$FALLBACK_EFFORT。呼叫端應依來源嚴重度指定(diff: 第一輪 review 最高判定;spec/plan: 設計風險自評)。" >&2 ;;
  *)   MODEL="$FALLBACK_MODEL"; EFFORT="$FALLBACK_EFFORT"; SEV_SHOWN="(未知:$SEVERITY)"
       echo "[codex-review] 警告: 未知 severity '$SEVERITY',fallback $FALLBACK_MODEL/$FALLBACK_EFFORT。有效值: critical|required|optional|nit|fyi。" >&2 ;;
esac

# --- Gate 1: 安裝偵測 ---
# 先查 PATH（Windows npm 版可能是 codex.cmd）；PATH 不全時（WSL/CI/git hook 等
# 非 login shell 不會把 ~/.local/bin 併進 PATH）再退查常見安裝路徑,避免明明裝了
# 卻因 command -v 找不到而誤 SKIP。
CODEX_BIN=""
for b in codex codex.cmd; do
  if command -v "$b" >/dev/null 2>&1; then CODEX_BIN="$b"; break; fi
done
if [ -z "$CODEX_BIN" ]; then
  for p in "$HOME/.local/bin/codex" \
           "$HOME/AppData/Local/Programs/OpenAI/Codex/bin/codex" \
           "$HOME/.codex/packages/standalone/current/bin/codex" \
           "/usr/local/bin/codex"; do
    if [ -x "$p" ]; then CODEX_BIN="$p"; break; fi
  done
fi
if [ -z "$CODEX_BIN" ]; then
  echo "[codex-review] SKIP: 未偵測到 codex CLI。"
  echo "  安裝: npm install -g @openai/codex   然後  codex login"
  exit 0
fi

# --- Gate 2: 授權偵測 ---
# 只信任 codex 指令回報,不看 ~/.codex/auth.json —— 該目錄可能被其他工具佔用,
# 檔案存在不代表 OpenAI Codex 已登入。保守策略: 狀態指令成功才算已授權。
if ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  echo "[codex-review] SKIP: codex 已安裝但未授權(codex login status 失敗)。"
  echo "  登入: codex login   (CI 環境: 設 OPENAI_API_KEY 後 codex login --with-api-key)"
  exit 0
fi

# --- git repo 檢查: diff 模式必須在 repo 內;doc 模式不在 repo 時加旗標續跑 ---
SKIP_GIT_FLAG=""
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$DOC_MODE" -eq 1 ]; then
    # codex exec 在非 git 目錄會報 "Not inside a trusted directory";sandbox 已是
    # read-only 續跑無風險,但 codex 無 repo 上下文可交叉比對(plan 模式讀不到 Spec: 上游檔)。
    SKIP_GIT_FLAG="--skip-git-repo-check"
    echo "[codex-review] 注意: 不在 git repo 內,doc 模式續跑(--skip-git-repo-check);codex 無 repo 上下文可讀。" >&2
  else
    echo "[codex-review] SKIP: 目前不在 git repo 內。" >&2
    exit 0
  fi
fi

if [ "$DOC_MODE" -eq 1 ]; then
  # ---------- doc 模式: spec/plan 共議(co-design)諮詢 ----------
  if [ "$KIND" = "spec" ]; then
    read -r -d '' PROMPT_BODY <<'EOF'
你是第二位共同設計者(co-designer)。第一位設計者(Claude)已完成需求釐清並寫出這份設計文件
(design spec)草稿,即 stdin 的完整內容;文件路徑在本訊息開頭。你有唯讀檔案權限,可自行讀取
repo 內程式碼與文件驗證假設,但禁止修改任何檔案。
你的任務不是挑錯,是把設計變得更好。請提出三類貢獻,每項都要給具體建議內容:
  a. 補充: 遺漏的需求、邊界情況、錯誤路徑、狀態轉換(附建議加入的條文)
  b. 替代: 更好的做法(附方案描述與取捨比較)
  c. 調整: 應改變的設計決策(附建議的修改文字與理由)
檢查面向:
  1. 需求完整性: 目標是否都有對應需求?有無漏掉的邊界條件與失敗路徑?
  2. 內部一致性: 章節之間有無矛盾(名詞、流程、數值、行為描述)?
  3. 模糊語義: 有無可兩種解讀的需求?指出兩種解讀各是什麼、建議採哪種寫法。
  4. 技術可行性: 方案在現有 codebase / 技術棧能否落地?必要時讀 repo 驗證。
  5. 安全與資料: 認證授權、敏感資料、資料遷移、不可逆操作是否被考慮?
  6. 可測試性: 成功準則能否客觀驗證?有無寫不出測試的需求?
  7. Out of Scope: 是否明確列出、且與正式需求互斥不重疊?
輸出格式: 逐項標明嚴重度,附「章節標題或引述原文片段 + 具體建議文字 + 理由」,順序由重到輕:
  Critical(不改會走錯方向) / Required(進 plan 前必改) / Optional(建議) / Nit(可忽略) / FYI
若文件尾端有「## Cross-Check Log」: 那是共議的處置紀錄(為節省 token 只附最後一輪;更早的輪次
同樣算已處置)。已處置的議題,除非你有新論據,
不要重提;對標記「不採納」的項目,你可提出一次異議(項目前加 [異議] 並給出新理由),之後尊重
第一位設計者的裁量。若無實質補充,直接回「無重大補充」(仍須附上收斂問句行)。
回覆最後必須以單獨一行作結:「收斂問句:<你認為最關鍵的一個未決問題>」——只能提一個,選對這份
設計影響最大者。若已無足以改變這份文件的問題,寫「收斂問句:無」;不要為了湊問題而發明新議題
或擴大範圍——這一行是收斂訊號,不是出題義務。你是唯讀的共同設計者,禁止修改任何檔案。
EOF
  else
    read -r -d '' PROMPT_BODY <<'EOF'
你是第二位共同設計者(co-designer)。第一位設計者(Claude)已依已核准的 spec 寫出這份實作計畫
(implementation plan)草稿,即 stdin 的完整內容;文件路徑在本訊息開頭。你有唯讀檔案權限,
禁止修改任何檔案。
第一步: 找到計畫開頭的「Spec:」行,讀取該 design doc 作為交叉比對基準;若沒有 Spec: 行或
檔案讀不到,明確註明這點,並僅就計畫本身共議。
你的任務不是挑錯,是讓這份計畫更能被零上下文的執行者一次做對。請提出三類貢獻,每項都要給
具體建議內容:
  a. 補充: 遺漏的 task、步驟、測試或驗證(附建議加入的內容)
  b. 替代: 更好的任務拆分或排序(附替代方案與理由)
  c. 調整: 應改變的實作決策(附建議的修改文字與理由)
檢查面向:
  1. Spec 覆蓋率: design doc 每條需求都有對應 task?Out of Scope 的項目不應出現 task。
  2. 依賴順序: task 順序符合依賴圖(先建後用)?可平行的有沒有被無謂串行?
  3. Placeholder: 有無 TBD / TODO /「適當處理」/「同 Task N」/ 只描述不給實碼的步驟?
  4. 型別與簽章一致: 同一函式/型別/檔案路徑在不同 task 間的定義與引用是否吻合?
  5. 驗證完整: 每個 task 都有具體可執行的驗證步驟(指令與預期輸出)?
  6. 規模合理: 有無單一 task 過大該拆(8+ 檔、驗收超過三點講不完、標題含「and」)?
輸出格式: 逐項標明嚴重度,附「Task 編號或章節 + 具體建議文字 + 理由」,順序由重到輕:
  Critical(照做會做壞) / Required(執行前必改) / Optional(建議) / Nit(可忽略) / FYI
若文件尾端有「## Cross-Check Log」(為節省 token 只附最後一輪;更早的輪次同樣算已處置):
已處置議題除非有新論據不要重提;對「不採納」項目可提出
一次異議(項目前加 [異議] 並給出新理由),之後尊重第一位設計者的裁量。
若無實質補充,直接回「無重大補充」(仍須附上收斂問句行)。
回覆最後必須以單獨一行作結:「收斂問句:<你認為最關鍵的一個未決問題>」——只能提一個,選對這份
計畫影響最大者。若已無足以改變這份計畫的問題,寫「收斂問句:無」;不要為了湊問題而發明新議題
或擴大範圍——這一行是收斂訊號,不是出題義務。你是唯讀的共同設計者,禁止修改任何檔案。
EOF
  fi
  # 文件路徑經變數插值放在引導行,不進 heredoc —— prompt 本體保持零展開
  REVIEW_PROMPT="待審文件路徑: ${DOC}(類型: ${KIND})。stdin 為其完整內容。
${PROMPT_BODY}"
  # 只附最後一輪 Cross-Check Log(見 trim_crosscheck_log 的說明):
  # 舊行為是整份重送,實測讓 payload 在 12 輪內從 4,929 長到 26,758 字元。
  PAYLOAD="$(trim_crosscheck_log "$DOC")"
  DOC_FULL_CHARS="$(wc -m < "$DOC" | tr -d '[:space:]')"
  DOC_SENT_CHARS="$(printf '%s' "$PAYLOAD" | wc -m | tr -d '[:space:]')"
  if [ "${DOC_SENT_CHARS:-0}" -lt "${DOC_FULL_CHARS:-0}" ]; then
    # 與 diff 模式的排除回報同一個原則: 裁掉什麼一定要講,靜默截斷會讓呼叫端以為全都審過了。
    echo "[codex-review] 已裁切較早的 Cross-Check Log $(( DOC_FULL_CHARS - DOC_SENT_CHARS )) 字元(只送最後一輪)。" >&2
  fi
  SRC_INFO="doc=$DOC kind=$KIND"
else
  # ---------- diff 模式(預設): 相對 base 的整體 diff 第二意見 ----------
  # --- 決定 base branch ---
  if [ -z "$BASE" ]; then
    DETECT="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    for c in "$DETECT" main master; do
      [ -n "$c" ] || continue
      if git rev-parse --verify -q "$c" >/dev/null 2>&1; then BASE="$c"; break; fi
    done
  fi
  if [ -z "$BASE" ] || ! git rev-parse --verify -q "$BASE" >/dev/null 2>&1; then
    echo "[codex-review] SKIP: 找不到可用的 base branch(試過 origin/HEAD、main、master)。" >&2
    echo "  用 --base <branch> 明確指定。" >&2
    exit 0
  fi

  # --- 產生整體 diff: merge-base 到工作區,涵蓋已 commit + 未 commit 的修正 ---
  MB="$(git merge-base "$BASE" HEAD 2>/dev/null)"
  [ -n "$MB" ] || MB="$BASE"
  DIFF_ALL="$(git diff "$MB")"
  if [ -z "$DIFF_ALL" ]; then
    echo "[codex-review] SKIP: $BASE 與工作區沒有差異,無需複查。"
    exit 0
  fi

  # --- 排除產生物/鎖檔(2026-08-24 新增) ---
  # set -f: 排除樣式含 * ,不關掉 glob 會在這裡被 pathname expansion 吃掉。
  EXCL=(); SECR=()
  set -f; OLDIFS="$IFS"; IFS='
'
  for sp in ${CODEX_REVIEW_EXCLUDE:-};        do [ -n "$sp" ] && EXCL+=("$sp"); done
  for sp in ${CODEX_REVIEW_SECRET_EXCLUDE:-}; do [ -n "$sp" ] && SECR+=("$sp"); done
  IFS="$OLDIFS"; set +f
  ALL_SPECS=(${EXCL[@]+"${EXCL[@]}"} ${SECR[@]+"${SECR[@]}"})

  EXCLUDED_FILES=""; ARTIFACT_FILES=""; SECRET_FILES=""
  # pathspec 用 ':/'(repo 根)而非 '.'(cwd 相對)——實測在子目錄下執行時,'.' 會把同 repo
  # 其他目錄的變更整批濾掉,而且還被標成「產生物」,等於靜默縮小複查範圍又給出錯誤理由。
  if [ "${#ALL_SPECS[@]}" -gt 0 ]; then
    if ! DIFF="$(git diff "$MB" -- ':/' "${ALL_SPECS[@]}" 2>&1)"; then
      # 不接 rc 的話,pathspec 壞掉會讓 DIFF 為空 → 落到「全部變更都落在排除清單內」+ exit 0,
      # 把 git 錯誤當成良性 SKIP。那是 fail-open: 呼叫端會以為不用複查。
      echo "[codex-review] FAILED: 排除 pathspec 無效,diff 產生失敗——複查沒有發生,呼叫端不得視為已複查。" >&2
      echo "  git 訊息: $(printf '%s' "$DIFF" | head -2)" >&2
      echo "  檢查 CODEX_REVIEW_EXCLUDE / CODEX_REVIEW_SECRET_EXCLUDE;或設 CODEX_REVIEW_EXCLUDE= 停用後重跑。" >&2
      exit 1
    fi
    NAMES_ALL="$(git diff --name-only "$MB" -- ':/' | sort)"
    NAMES_KEPT="$(git diff --name-only "$MB" -- ':/' "${ALL_SPECS[@]}" | sort)"
    if [ "${#SECR[@]}" -gt 0 ]; then
      NAMES_NOSECRET="$(git diff --name-only "$MB" -- ':/' ${EXCL[@]+"${EXCL[@]}"} | sort)"
    else
      NAMES_NOSECRET="$NAMES_KEPT"
    fi
    EXCLUDED_FILES="$(comm -23 <(printf '%s\n' "$NAMES_ALL") <(printf '%s\n' "$NAMES_KEPT") | tr '\n' ' ')"
    ARTIFACT_FILES="$(comm -23 <(printf '%s\n' "$NAMES_ALL") <(printf '%s\n' "$NAMES_NOSECRET") | tr '\n' ' ')"
    SECRET_FILES="$(comm -23 <(printf '%s\n' "$NAMES_NOSECRET") <(printf '%s\n' "$NAMES_KEPT") | tr '\n' ' ')"
  else
    DIFF="$DIFF_ALL"
  fi
  if [ -z "$DIFF" ]; then
    echo "[codex-review] SKIP: 全部變更都落在排除清單內($EXCLUDED_FILES),本次不送出。" >&2
    echo "  要連這些檔案一起複查: CODEX_REVIEW_EXCLUDE= CODEX_REVIEW_SECRET_EXCLUDE= bash codex-review.sh ..." >&2
    exit 0
  fi
  if [ -n "$EXCLUDED_FILES" ]; then
    ALL_CH="$(printf '%s' "$DIFF_ALL" | wc -m | tr -d '[:space:]')"
    KEPT_CH="$(printf '%s' "$DIFF" | wc -m | tr -d '[:space:]')"
    [ -n "$ARTIFACT_FILES" ] && echo "[codex-review] 已排除 $(( ALL_CH - KEPT_CH )) 字元未送出;其中建置產物: $ARTIFACT_FILES" >&2
  fi
  if [ -n "$SECRET_FILES" ]; then
    # 這一類是「排除 + 大聲講」,不是靜默略過: 不把金鑰內容送給外部服務,
    # 但它出現在 diff 裡本身就是安全鐵律 #1(secrets 不進版控)的違反,必須被看見。
    echo "[codex-review] 警示: 本次變更含疑似機密檔案,內容【未送出】也【未被複查】: $SECRET_FILES" >&2
    echo "  secrets 不得進版控。請自行確認這些檔案該不該在 repo 裡;若是誤加,改用 secrets manager 或 env 並輪替已外洩的憑證。" >&2
  fi

  # --- 第二意見 review prompt(人類可讀) ---
  read -r -d '' REVIEW_PROMPT <<'EOF'
你是獨立的第二位 code reviewer。第一輪五軸 review 已完成、所有 required/critical 已修正。
針對以下這次變更的 git diff,只回報「前一輪可能遺漏的問題」或「值得調整的建議」,不重述已明顯正確的部分。
逐項標明嚴重度並附「檔案:行 + 具體理由」,順序由重到輕:
  Critical(阻斷合併) / Required(合併前必修) / Optional(建議) / Nit(可忽略) / FYI
五個檢查軸: 正確性(邊界、錯誤路徑、測試覆蓋) / 可讀性與簡潔 / 架構(重複、邊界、循環相依) /
  安全(硬編 secrets、輸入驗證、輸出編碼、authz、加密演算法) / 效能(N+1、無界迴圈、同步阻塞)。
若無實質遺漏,直接回「無重大遺漏」(仍須附上收斂問句行)。
回覆最後必須以單獨一行作結:「收斂問句:<你認為最關鍵的一個未決問題>」——只能提一個,選對這次
變更風險最大者。若已無足以改變這次變更的問題,寫「收斂問句:無」;不要為了湊問題而發明新議題。
你是唯讀第二意見,禁止修改任何檔案。
EOF
  PAYLOAD="$DIFF"
  SRC_INFO="base=$BASE (merge-base=${MB:0:12})"
fi

# --- 輪次 ledger 與 resume 決策(2026-08-24 新增) ---
# 為什麼腳本不再完全無狀態: codex 的 prompt_cache_key = session_id,每次 `codex exec` 都開
# 新 session ⇒ payload 永遠拿不到快取折扣。唯一能把上一輪內容變成 cached input 的做法是
# `codex exec resume <id>`。本機實測(gpt-5.6-luna,同一份 payload):
#     fresh : input 14,913 / cached  9,984 → 未快取 4,929
#     resume: input 14,943 / cached 14,080 → 未快取   863   (未快取 input 降 82%)
# 狀態只放在 $CODEX_REVIEW_STATE,不碰 repo、不碰待審文件——文件裡的 Cross-Check Log 仍是
# 收斂協議的權威來源,ledger 只補上 diff 模式先前完全沒有的輪次概念。
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ "$DOC_MODE" -eq 1 ]; then
  MODE_NAME="doc"; LEDGER_TARGET="$DOC"; WARN_AT="$CONVERGE_WARN_ROUNDS"
else
  MODE_NAME="diff"; LEDGER_TARGET="$BASE@$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"; WARN_AT="$CONVERGE_WARN_ROUNDS_DIFF"
fi
SKEY="$(state_key "$REPO_ROOT" "$MODE_NAME" "$LEDGER_TARGET")"
STATE_FILE="$CODEX_REVIEW_STATE/$SKEY.state"
SNAP_FILE="$CODEX_REVIEW_STATE/$SKEY.payload"
PREV_ROUNDS="$(state_get "$STATE_FILE" rounds)"
case "$PREV_ROUNDS" in ''|*[!0-9]*) PREV_ROUNDS=0 ;; esac   # ledger 讀不到/損毀一律當 0,不阻斷
# 閒置重置: 輪次警示要抓的是「這一輪 review 裡問了幾次」,不是「這個 repo 歷史上問過幾次」。
# 沒有重置的話,一個 repo 用滿 3 次之後往後每一次 diff 複查都會警示,兩天內就退化成背景雜訊
# ——那等於沒解決原本的問題。一輪 review 的時間尺度是分鐘,隔了數小時的下一次就是新的一輪。
LEDGER_TS="$(state_get "$STATE_FILE" last_ts)"
case "$LEDGER_TS" in ''|*[!0-9]*) LEDGER_TS=0 ;; esac
if [ "$LEDGER_TS" -gt 0 ] && [ "$(( $(now_ts) - LEDGER_TS ))" -gt "$CODEX_ROUND_RESET" ]; then
  PREV_ROUNDS=0
fi
ROUND_NO=$((PREV_ROUNDS + 1))

if [ "$ROUND_NO" -ge "$WARN_AT" ]; then
  echo "[codex-review] 警示: 這條複查線($MODE_NAME:$LEDGER_TARGET)本次是第 $ROUND_NO 次諮詢(警示線 $WARN_AT)。" >&2
  if [ "$MODE_NAME" = "diff" ]; then
    echo "  diff 模式的協議是「一輪 review 一次」(not per file or per fix)。若這是「修一處就再叫一次」,請把該輪 required/critical 全部修完後一次送出。" >&2
  else
    echo "  檢查是否在追新戰線而非收斂舊問題——建議本輪後強制收斂:未決事項改記 user call 交使用者仲裁。" >&2
  fi
fi

# resume 只把【歷史】變成 cached(0.1x),新訊息永遠全價。所以 resume 輪一定要送 delta;
# 送全文 = 全價全文 + 額外的 cached 歷史,嚴格劣於 fresh。改這段前先讀懂這一句。
SESSION_MODE="fresh"; RESUME_ID=""; DELTA=""; RESUME_AGE=0
# 快照比對【與 resume 無關,永遠做】: 用途有兩個——去重(內容沒變就不送)與算 delta。
# 去重是獨立的成本攔截,不能因為 resume 預設關閉就跟著失效。
#
# 去重【必須直接比內容】,不可拿 delta 是否為空來判斷(2026-08-24 review 抓到的 Critical):
# per-file delta 只迭代【本輪】diff 裡出現的檔案,所以「上一輪有、本輪已還原」的檔案不會
# 產生任何區塊 → delta 為空 → 被誤判成「與上一輪完全相同」。實測: round1 改 a.txt 與
# b.txt;round2 還原 b.txt,實際仍有 a.txt 的變更,卻回報「完全相同」並 exit 0 ——
# 而那正是最需要複查的一輪(照 codex 建議還原後再問一次)。
if [ "$PREV_ROUNDS" -gt 0 ] && [ -s "$SNAP_FILE" ] \
   && [ "$(state_get "$STATE_FILE" model)" = "$MODEL" ] \
   && [ "$(state_get "$STATE_FILE" effort)" = "$EFFORT" ]; then
  PAY_TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-pay-$$.txt")"
  printf '%s\n' "$PAYLOAD" > "$PAY_TMP"

  if [ "$CODEX_REVIEW_FORCE" != "1" ] && cmp -s "$SNAP_FILE" "$PAY_TMP"; then
    rm -f "$PAY_TMP"
    echo "[codex-review] SKIP: 送出內容與上一輪(第 $PREV_ROUNDS 輪)完全相同,沒有新東西可複查。" >&2
    echo "  先套用修正再複查;若確定要重問同一份內容(上一輪回覆不完整、或想換角度再問),設 CODEX_REVIEW_FORCE=1 重跑。" >&2
    [ "$DOC_MODE" -eq 1 ] || echo "  註: git diff 看不到未追蹤的新檔,新增檔案請先 git add -N。" >&2
    emit_telemetry SKIP_DEDUP
    exit 0
  fi

  # delta 只有 resume 會用到,fresh 路徑(預設)不必算。
  if [ "$CODEX_REVIEW_RESUME" = "1" ]; then
    if [ "$DOC_MODE" -eq 1 ]; then
      DELTA="$(diff -u "$SNAP_FILE" "$PAY_TMP" 2>/dev/null | tail -n +3)"
    else
      DELTA="$(diff_delta_per_file "$SNAP_FILE" "$PAY_TMP" 2>/dev/null)"
      printf '%s' "$DELTA" | grep -q '^diff --git ' || DELTA=""   # 只有「未變更清單」不算 delta
    fi
    PREV_ID="$(state_get "$STATE_FILE" session_id)"
    PREV_TS="$(state_get "$STATE_FILE" last_ts)"
    case "$PREV_TS" in ''|*[!0-9]*) PREV_TS=0 ;; esac
    AGE=$(( $(now_ts) - PREV_TS ))
    # 每條複查線各自的 TTL 修正值: 上一次 resume 沒吃到歷史快取時,由 persist_ledger 寫入
    # 「當時的間隔 / 2」,下次就用更短的窗口再試。命中就清掉,回到全域 TTL。
    # 註: 下限鉗在 10s,所以只有在使用者調高 CODEX_RESUME_TTL 時這條校正才會改變行為。
    TTL_HINT="$(state_get "$STATE_FILE" resume_ttl_hint)"
    case "$TTL_HINT" in ''|*[!0-9]*) TTL_HINT="$CODEX_RESUME_TTL" ;; esac
    EFF_TTL="$CODEX_RESUME_TTL"
    [ "$TTL_HINT" -lt "$EFF_TTL" ] && EFF_TTL="$TTL_HINT"
    if [ -z "$DELTA" ]; then
      # 內容有變(否則上面已 SKIP),但算不出可送的 delta —— 例如變更只是「某檔案被還原」。
      # 送半份比送全文危險,退 fresh。
      echo "[codex-review] 注意: 算不出可送的增量(可能是變更為「還原某檔案」),本輪走 fresh 送全文。" >&2
    elif [ "$(printf '%s' "$DELTA" | wc -m | tr -d '[:space:]')" -ge "$(printf '%s' "$PAYLOAD" | wc -m | tr -d '[:space:]')" ]; then
      # delta 不比全文小就沒有 resume 的意義(小文件的 unified diff 常比原文還長),退 fresh。
      echo "[codex-review] 注意: 增量不比全文小,resume 沒有效益,本輪走 fresh 送全文。" >&2
    elif [ -n "$PREV_ID" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$EFF_TTL" ]; then
      SESSION_MODE="resume"; RESUME_ID="$PREV_ID"; RESUME_AGE="$AGE"
    elif [ -n "$PREV_ID" ]; then
      # 窗口之外 resume 反而更貴(歷史全額重送,還多帶上輪的回覆),直接退 fresh 送全文。
      echo "[codex-review] 注意: 距上一輪 ${AGE}s 已超出快取窗口(${EFF_TTL}s),本輪走 fresh 送全文。" >&2
    fi
  fi
  rm -f "$PAY_TMP"
fi

# resume 輪的指示: 歷史已在對話裡,這裡只描述「新增了什麼」與「要回報什麼」。
# 收斂問句合約行在這裡同樣必須要求——它是收斂協議唯一的機制載體(fresh 輪在 REVIEW_PROMPT)。
RESUME_PROMPT="這是同一份待審對象的下一輪諮詢(第 ${ROUND_NO} 輪)。先前輪次的完整內容已在本對話歷史中,不再重送;以下只給自上一輪以來的變更。
請沿用先前的檢查面向與輸出格式(嚴重度由重到輕),只回報兩類: (a) 這些變更帶來的新問題; (b) 先前指出但仍未解決的問題。已解決的不必重述。
若兩類都沒有,直接回「無重大遺漏」。
回覆最後必須以單獨一行作結:「收斂問句:<你認為最關鍵的一個未決問題>」——只能提一個;已無足以改變產出的問題就寫「收斂問句:無」,不要為了湊問題而擴大範圍。
你是唯讀第二意見,禁止修改任何檔案。"

# --- 送出前的輸入長度守門(2026-08-12 新增) ---
# 為什麼要在送出前擋: codex 對超長 payload 是在 turn/start 就拒絕,跑都沒跑。等它回錯誤才發現,
# 已經白等一輪(實測 admin 那份 136 萬字元的 diff 等了 9 分鐘才拿到錯誤),而且錯誤訊息容易被
# 誤讀成額度問題。先量再送:超標時直接印出實際大小、上限與可行的縮小做法,exit 1(＝複查沒有
# 發生,呼叫端不得放行),不浪費一次往返。
# 上限取 codex 回報的 max_chars(1048576);字元數以 wc -m 計(非位元組)——錯誤訊息講的是
# characters,中文註解在 UTF-8 下一字 3 bytes,用 wc -c 會高估到誤擋。
# 保留 2% 餘裕: PAYLOAD 之外 codex 還會附上 REVIEW_PROMPT 與自身的系統訊息。
CODEX_MAX_CHARS=1048576
# resume 輪送的是 delta,守門與遙測都要量【實際送出的東西】,不是完整 payload。
if [ "$SESSION_MODE" = "resume" ]; then SEND_PAYLOAD="$DELTA"; else SEND_PAYLOAD="$PAYLOAD"; fi
PAYLOAD_CHARS="$(printf '%s' "$SEND_PAYLOAD" | wc -m | tr -d '[:space:]')"
FULL_CHARS="$(printf '%s' "$PAYLOAD" | wc -m | tr -d '[:space:]')"
CODEX_SAFE_CHARS=$(( CODEX_MAX_CHARS * 98 / 100 ))
if [ "${PAYLOAD_CHARS:-0}" -gt "$CODEX_SAFE_CHARS" ]; then
  echo "[codex-review] FAILED: 輸入過長,未送出——複查沒有發生,呼叫端不得視為已複查。" >&2
  echo "  實際 ${PAYLOAD_CHARS} 字元 / 安全上限 ${CODEX_SAFE_CHARS}(codex 硬上限 ${CODEX_MAX_CHARS})。" >&2
  if [ -n "$DOC" ]; then
    echo "  縮小做法: 該文件已超過單次諮詢可容納的長度,請拆節後分次諮詢。" >&2
  else
    echo "  縮小做法(擇一):" >&2
    echo "    1. 縮小 --base 範圍(逐 commit 或逐主題複查,而非一次比整輪):" >&2
    echo "       bash codex-review.sh --severity <sev> --base <較近的 commit>" >&2
    echo "    2. 排除測試檔等佔比高但風險低的路徑後另行複查(測試檔往往佔 diff 大半)。" >&2
    echo "    3. 分批: 先複查高風險檔案,再單獨複查其餘。" >&2
  fi
  emit_telemetry TOO_LARGE
  exit 1
fi

# --- 軟性大小警示: 硬守門是 1M 字元,實務上等於沒有(實測最大一次只有 54,302) ---
if [ "${PAYLOAD_CHARS:-0}" -gt "$CODEX_WARN_CHARS" ]; then
  echo "[codex-review] 警示: 本次送出 ${PAYLOAD_CHARS} 字元(軟性警示線 ${CODEX_WARN_CHARS})。" >&2
  echo "  這個量級的 payload 每輪都會全額計費。考慮縮小 --base 範圍、或先分主題複查。" >&2
fi

# --- codex 諮詢: 模型由來源嚴重度決定,唯讀 ---
if [ "$SESSION_MODE" = "resume" ]; then
  SEND_INFO="round=$ROUND_NO resume(${RESUME_ID:0:8}) delta ${PAYLOAD_CHARS}/${FULL_CHARS} 字元"
else
  SEND_INFO="round=$ROUND_NO fresh 全文 ${PAYLOAD_CHARS} 字元"
fi
echo "[codex-review] $SRC_INFO | 來源嚴重度=$SEV_SHOWN → $MODEL / $EFFORT | $SEND_INFO" >&2
# 輸出邊串流給使用者、邊留存一份,供事後判斷是否被用量上限擋下。
# stderr 另存不與 review 內容混流,才能只對 stderr 套用較寬鬆的 429 判定。
ERR_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-err-$$.txt")"
RC_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-rc-$$.txt")"
JSON_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-json-$$.txt")"
LAST_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-last-$$.txt")"
: > "$LAST_FILE"

trap 'rm -f "$ERR_FILE" "$RC_FILE" "$JSON_FILE" "$LAST_FILE"' EXIT

# 為什麼改用 --json: 人類模式只印 `tokens used <總數>`,拿不到 cached/input 拆分,
# 沒有拆分就沒有 cache hit rate 可言。--json 的 turn.completed 事件帶
# {input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
#  reasoning_output_tokens},而 review 本體改由 -o 取得(乾淨的最後一則訊息)。
# 附帶好處: --json 不再回顯 prompt/payload,先前那一整類「transcript 回顯把限制字樣/
# hunk header 的 429 帶進判定」的誤判來源直接消失(判定邏輯仍保留,不靠這個假設)。
# stderr 仍即時透出(codex 一開跑就寫 "Reading additional input from stdin..."),
# 另用 awk 把事件名轉成進度行,取代舊版靠 transcript 串流看「還在跑」。
#
# resume 分支【必須】明確帶 -c sandbox_mode="read-only":
# `codex exec resume` 沒有 -s/--sandbox 旗標(實測 0.148.0),而使用者 config.toml 可能有
# [windows] sandbox = "elevated" 這種設定。不明確壓回唯讀就等於把沙箱交給環境決定——
# 認證/權限路徑上「還不知道」與「確認不需要」是兩件事,一律 fail-closed。
# 已實測: `exec resume <id> - -c sandbox_mode="read-only" --strict-config` rc=0 且
# header 顯示 `sandbox: read-only`。
# resume 關閉(預設)時 session 檔永遠不會被用到,沒有理由把整份 diff/文件連同回覆永久
# 寫進 ~/.codex 的 session store。只有開啟 resume 才需要落地。
EPHEMERAL_FLAG=""
[ "$CODEX_REVIEW_RESUME" = "1" ] || EPHEMERAL_FLAG="--ephemeral"

{ { if [ "$SESSION_MODE" = "resume" ]; then
      printf '%s\n\n%s\n' "$RESUME_PROMPT" "$DELTA" \
        | "$CODEX_BIN" exec resume "$RESUME_ID" - --json -o "$LAST_FILE" \
            -c sandbox_mode="read-only" $SKIP_GIT_FLAG \
            -c model="$MODEL" -c model_reasoning_effort="$EFFORT"
    else
      printf '%s\n' "$SEND_PAYLOAD" \
        | "$CODEX_BIN" exec --sandbox read-only --json -o "$LAST_FILE" $EPHEMERAL_FLAG $SKIP_GIT_FLAG \
            -c model="$MODEL" -c model_reasoning_effort="$EFFORT" "$REVIEW_PROMPT"
    fi
    echo "${PIPESTATUS[1]}" > "$RC_FILE"
  } 2>&1 1>&3 | tee "$ERR_FILE" >&2 ; } 3>&1 | tee "$JSON_FILE" \
  | awk 'match($0,/"type":"[a-z._]+"/){
           t=substr($0,RSTART+8,RLENGTH-9)
           if (t=="thread.started"||t=="turn.started"||t=="item.completed"||t=="turn.completed"||t=="error")
             printf "[codex-review] . %s\n", t > "/dev/stderr"
         }' 2>/dev/null

RC="$(cat "$RC_FILE" 2>/dev/null)"
case "$RC" in ''|*[!0-9]*) RC=1 ;; esac   # RC_FILE 沒寫成(內層整個被砍)一律當失敗

# review 本體來源: -o 檔(真實 codex)。stub 或 codex 沒寫成 -o 檔時退回 stdout 捕獲的內容
# ——後續所有判定(rate limit 短路、零輸出 FAILED、收斂問句在場)都沿用 OUT_FILE,不必分支。
# fallback 存在是為了讓測試用的 stub(印純文字、不寫 -o 檔)照舊可用。但它不能把
# 「真 codex 印了 JSONL、-o 卻落空」也一起吞掉——那會讓呼叫端拿到一坨 JSON 當第二意見,
# 外加一句「完成」,正是本腳本 header 說「假成功比直接報錯危險」要防的那一類。
if [ -s "$LAST_FILE" ]; then
  OUT_FILE="$LAST_FILE"
elif head -c 16 "$JSON_FILE" 2>/dev/null | grep -q '^{"type":'; then
  echo "[codex-review] FAILED: codex 有輸出但 -o 檔是空的,取不到 review 本體(exit=$RC)。" >&2
  echo "  這不是「無重大遺漏」,是複查沒有拿到結果——呼叫端不得視為已複查。" >&2
  echo "  codex stderr(末 20 行):" >&2
  tail -n 20 "$ERR_FILE" >&2
  emit_telemetry FAILED
  exit 1
else
  OUT_FILE="$JSON_FILE"
fi
cat "$OUT_FILE"
# -o 寫出的最後一則訊息沒有結尾換行,不補的話後續 stderr 狀態行會黏在 review 的最後一行上
# (症狀: `收斂問句:...[codex-review] 用量: ...`)。$( ) 會吃掉結尾換行,所以「非空」即代表缺換行。
[ -s "$OUT_FILE" ] && [ -n "$(tail -c1 "$OUT_FILE")" ] && echo

# --json 之後 codex 的錯誤(含額度被擋)可能只以 {"type":"error",...} 事件出現在 stdout,
# 而 rate-limit 判定看的是 stderr 與 review 本體 —— 不補這一步,額度被擋會被誤判成
# FAILED,而兩者處置方向相反(RATE_LIMITED 不重試直接繼續;FAILED 不得放行)。
# 只併入 error 事件行,不併整份 JSONL,避免把模型回覆內容帶進判定造成誤判。
grep -o '"type":"error"[^}]*}' "$JSON_FILE" 2>/dev/null >> "$ERR_FILE" || true

if is_rate_limited "$RC" "$ERR_FILE" "$OUT_FILE"; then
  echo "[codex-review] RATE_LIMITED: codex 回報用量/額度上限,本次諮詢沒有取得結果(codex exit=$RC)。" >&2
  echo "  處置: 不要重試、不要為本次補記 Cross-Check Log 的「### Round」(doc 模式),直接繼續後續動作。" >&2
  echo "  下次需要諮詢時照常再呼叫本腳本——不會因為這次被擋就永久跳過。" >&2
  emit_telemetry RATE_LIMITED
  exit 0
fi

# --- 諮詢是否真的取得結果(順序在 rate limit 之後: 被擋下也是零輸出,但那有專屬處置) ---
# codex 可能跑都沒跑就拒絕(實測: 非信任目錄),或非正常結束而輸出截斷。舊版兩種都印「完成」。
OUT_TRIMMED="$(tr -d '[:space:]' < "$OUT_FILE" 2>/dev/null)"
if [ -z "$OUT_TRIMMED" ] || [ "$RC" -ne 0 ]; then
  if [ -z "$OUT_TRIMMED" ]; then
    echo "[codex-review] FAILED: codex 沒有產出任何 review 內容(exit=$RC, stdout 零個非空白字元)。" >&2
    echo "  這不是「無重大遺漏」,是複查根本沒有發生——呼叫端不得視為已複查、不得據此放行。" >&2
  else
    echo "[codex-review] FAILED: codex 非正常結束(exit=$RC),已產出的 ${#OUT_TRIMMED} 個字元可能是截斷的半份 review。" >&2
    echo "  不可當成完整的第二意見;要嘛重跑,要嘛明講這一輪複查未完成。" >&2
  fi
  if grep -qiE "$TOO_LARGE_PAT" "$ERR_FILE" 2>/dev/null; then
    echo "  已知原因: 輸入超過 codex 的長度上限,codex 在 turn/start 就拒絕、跑都沒跑。" >&2
    echo "  這不是額度問題——縮小 --base 範圍或分批複查後重跑(見送出前守門的說明)。" >&2
  fi
  if grep -qi 'trusted directory' "$ERR_FILE" 2>/dev/null; then
    echo "  已知原因: codex 拒絕在非信任目錄執行。改在 git repo 內呼叫本腳本,或讓 codex 信任該目錄。" >&2
  fi
  echo "  codex stderr(末 20 行):" >&2
  tail -n 20 "$ERR_FILE" >&2
  emit_telemetry FAILED
  exit 1
fi

# --- 收斂問句在場檢查: 缺行不算失敗(review 內容仍是有效的第二意見),但要告知呼叫端 ---
# 依協議缺行視為「收斂問句:無」=保守收斂停止,不得據此續輪。不用 FAILED——那會連帶丟棄
# 已取得的有效 findings,懲罰過當。
# 行首錨定是關鍵: transcript 會回顯 prompt,而 prompt 裡「收斂問句」只出現在行中
# (「…作結:「收斂問句:…」)。codex 依指示輸出的是「單獨一行」=行首。不錨定會永遠命中。
if ! grep -qE "^收斂問句[:：][[:space:]]*[^[:space:]]" "$OUT_FILE" 2>/dev/null; then
  echo "[codex-review] 注意: 回覆未附行首「收斂問句:」行(協議要求)。視為「收斂問句:無」——依預設收斂停止,不得據此續輪。" >&2
fi

# 複查確實發生 → 推進 ledger、留 payload 快照給下一輪算 delta,並記一筆用量。
persist_ledger
emit_telemetry OK

USAGE_SHOWN="$(grep -o '"usage":{[^}]*}' "$JSON_FILE" 2>/dev/null | tail -1)"
if [ -n "$USAGE_SHOWN" ]; then
  _in="$(jnum "$USAGE_SHOWN" input_tokens)"; _cin="$(jnum "$USAGE_SHOWN" cached_input_tokens)"
  _out="$(jnum "$USAGE_SHOWN" output_tokens)"
  echo "[codex-review] 用量: input ${_in:-?}(cached ${_cin:-?}) / output ${_out:-?} | $(awk -v a="${_cin:-0}" -v b="${_in:-0}" 'BEGIN{ if (b>0) printf "cache hit %.1f%%", a*100/b; else printf "cache hit n/a" }') | 明細見 $CODEX_REVIEW_LOG" >&2
fi
echo "[codex-review] 完成(嚴重度=$SEV_SHOWN, 模型=$MODEL/$EFFORT, $SESSION_MODE round=$ROUND_NO, codex exit=$RC)。唯讀諮詢,腳本未改 repo 內任何檔。" >&2
exit 0
