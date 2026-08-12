#!/usr/bin/env bash
# codex-review.sh — eng-flow 的 OpenAI Codex 跨家族交叉複查(無狀態,一次呼叫=一次諮詢)
#
# 兩種模式(互斥):
#   diff 模式(預設): code review 收尾的第二意見。第一輪(Claude / eng-flow 五軸)review
#        完成、該輪所有 required/critical 已修正後,對本分支相對 base 的「整體 diff」
#        跑一次非互動 codex review。純第二意見,不自動改 code。
#   doc 模式(--doc + --kind): 規劃設計階段的共議(co-design)。對 mao-brainstorm 的
#        design spec 或 mao-plan 的 implementation plan 跑一次共同設計諮詢;多輪收斂
#        狀態由呼叫端維護在文件尾端「## Cross-Check Log」小節,腳本本身無狀態。
#   兩者皆唯讀,腳本不改任何檔。
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
#   後續動作;下次需要諮詢時照常再呼叫本腳本。腳本無狀態,不會因為被擋過就永久跳過。
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
若文件尾端有「## Cross-Check Log」: 那是前幾輪共議的處置紀錄。已處置的議題,除非你有新論據,
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
若文件尾端有「## Cross-Check Log」: 已處置議題除非有新論據不要重提;對「不採納」項目可提出
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
  PAYLOAD="$(cat "$DOC")"
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
  DIFF="$(git diff "$MB")"
  if [ -z "$DIFF" ]; then
    echo "[codex-review] SKIP: $BASE 與工作區沒有差異,無需複查。"
    exit 0
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

# --- 送出前的輸入長度守門(2026-08-12 新增) ---
# 為什麼要在送出前擋: codex 對超長 payload 是在 turn/start 就拒絕,跑都沒跑。等它回錯誤才發現,
# 已經白等一輪(實測 admin 那份 136 萬字元的 diff 等了 9 分鐘才拿到錯誤),而且錯誤訊息容易被
# 誤讀成額度問題。先量再送:超標時直接印出實際大小、上限與可行的縮小做法,exit 1(＝複查沒有
# 發生,呼叫端不得放行),不浪費一次往返。
# 上限取 codex 回報的 max_chars(1048576);字元數以 wc -m 計(非位元組)——錯誤訊息講的是
# characters,中文註解在 UTF-8 下一字 3 bytes,用 wc -c 會高估到誤擋。
# 保留 2% 餘裕: PAYLOAD 之外 codex 還會附上 REVIEW_PROMPT 與自身的系統訊息。
CODEX_MAX_CHARS=1048576
PAYLOAD_CHARS="$(printf '%s' "$PAYLOAD" | wc -m | tr -d '[:space:]')"
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
  exit 1
fi

# --- 單次 codex 諮詢: 模型由來源嚴重度決定,唯讀,--ephemeral 不落地 session 檔 ---
echo "[codex-review] $SRC_INFO | 來源嚴重度=$SEV_SHOWN → $MODEL / $EFFORT | 輸入 ${PAYLOAD_CHARS} 字元" >&2
# 輸出邊串流給使用者、邊留存一份,供事後判斷是否被用量上限擋下。
# stderr 另存不與 review 內容混流,才能只對 stderr 套用較寬鬆的 429 判定。
OUT_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-out-$$.txt")"
ERR_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-err-$$.txt")"
RC_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/codex-rc-$$.txt")"

trap 'rm -f "$OUT_FILE" "$ERR_FILE" "$RC_FILE"' EXIT

# stderr 改為「即時可見 + 同時留存」: 舊版 2>"$ERR_FILE" 只在整段結束後才 cat,中途被
# Windows 背景 shell killer 砍掉就什麼都看不到(症狀: 印完 header 就沒了)。實測 codex
# 0.144.5 一開跑就往 stderr 寫 "Reading additional input from stdin...",所以只要即時
# 露出 stderr,就能分辨「還在跑」與「開頭就死了」——不需要另外做心跳。
#
# 下面的 fd 調度是標準做法: 內層 group 的 stderr 走 tee 到 ERR_FILE 並轉回終端,stdout
# 經 fd 3 走外層 tee 到 OUT_FILE。兩個 tee 都是同步 pipeline 成員,結束時兩個檔必定完整,
# 所以 rate limit 判定照舊能只對 stderr 套較寬鬆的 429 規則。
# codex 的結束碼經 RC_FILE 帶出(內層在 subshell 裡,變數傳不回來)。
# $SKIP_GIT_FLAG 刻意不加引號: 空值展開為零個參數,非空時為單一 flag
{ { printf '%s\n' "$PAYLOAD" | "$CODEX_BIN" exec --sandbox read-only --ephemeral $SKIP_GIT_FLAG \
      -c model="$MODEL" -c model_reasoning_effort="$EFFORT" "$REVIEW_PROMPT"
    echo "${PIPESTATUS[1]}" > "$RC_FILE"
  } 2>&1 1>&3 | tee "$ERR_FILE" >&2 ; } 3>&1 | tee "$OUT_FILE"
RC="$(cat "$RC_FILE" 2>/dev/null)"
case "$RC" in ''|*[!0-9]*) RC=1 ;; esac   # RC_FILE 沒寫成(內層整個被砍)一律當失敗

if is_rate_limited "$RC" "$ERR_FILE" "$OUT_FILE"; then
  echo "[codex-review] RATE_LIMITED: codex 回報用量/額度上限,本次諮詢沒有取得結果(codex exit=$RC)。" >&2
  echo "  處置: 不要重試、不要為本次補記 Cross-Check Log 的「### Round」(doc 模式),直接繼續後續動作。" >&2
  echo "  下次需要諮詢時照常再呼叫本腳本——不會因為這次被擋就永久跳過。" >&2
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

echo "[codex-review] 完成(嚴重度=$SEV_SHOWN, 模型=$MODEL/$EFFORT, codex exit=$RC)。唯讀諮詢,腳本未改任何檔。" >&2
exit 0
