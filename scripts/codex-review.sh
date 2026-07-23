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
# 依「來源嚴重度」選模型(嚴重度由呼叫端提供,腳本不自行分診):
#   複查深度應與風險相稱。嚴重度是【輸入】——
#     diff 模式: 第一輪五軸 review 對本次變更判定的最高原始嚴重度
#     doc  模式: Claude 對該設計/計畫的風險自評(規則見 mao-brainstorm / mao-plan skill)
#   映射(嚴重度用語同 mao-review taxonomy):
#     critical          -> gpt-5.6-sol   / max   (旗艦最深,阻斷級風險值得最貴複查)
#     required          -> gpt-5.6-sol   / high
#     optional/nit/fyi  -> gpt-5.6-terra / medium(低風險用便宜模型快速掃)
#   --severity 未傳/未知 -> fallback gpt-5.6-sol / high(保守:不靜默降級、也不漏看)。
#
# 用法: bash codex-review.sh --severity <critical|required|optional|nit|fyi> [--base <branch>]
#        bash codex-review.sh --severity <...> --doc <path> --kind <spec|plan>
#        --base 省略時自動偵測(origin/HEAD → main → master);--doc 與 --base 互斥。
#
# 前置: codex client >= 0.144.x 且帳號 plan(Plus 以上)已 rollout GPT-5.6 家族,
#        否則 gpt-5.6-* slug 會被 server 回 400 invalid_request。
#
# 結束碼: 環境缺失(codex 未裝/未授權、diff 模式不在 repo) → 印提示並 exit 0(不阻斷);
#          呼叫端合約錯誤(--doc 檔不存在、參數矛盾) → exit 2(顯錯,不可靜默)。
set -uo pipefail

# --- 嚴重度 → 模型/effort 映射(集中一處,要調策略只改這裡) ---
CRIT_MODEL="gpt-5.6-sol";      CRIT_EFFORT="max"        # critical
REQ_MODEL="gpt-5.6-sol";       REQ_EFFORT="high"        # required
LOW_MODEL="gpt-5.6-terra";     LOW_EFFORT="medium"      # optional / nit / fyi
FALLBACK_MODEL="gpt-5.6-sol";  FALLBACK_EFFORT="high"   # --severity 未傳/未知時的保底

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
第一位設計者的裁量。若無實質補充,直接回「無重大補充」。你是唯讀的共同設計者,禁止修改任何檔案。
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
若無實質補充,直接回「無重大補充」。你是唯讀的共同設計者,禁止修改任何檔案。
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
若無實質遺漏,直接回「無重大遺漏」。你是唯讀第二意見,禁止修改任何檔案。
EOF
  PAYLOAD="$DIFF"
  SRC_INFO="base=$BASE (merge-base=${MB:0:12})"
fi

# --- 單次 codex 諮詢: 模型由來源嚴重度決定,唯讀,--ephemeral 不落地 session 檔 ---
echo "[codex-review] $SRC_INFO | 來源嚴重度=$SEV_SHOWN → $MODEL / $EFFORT" >&2
# $SKIP_GIT_FLAG 刻意不加引號: 空值展開為零個參數,非空時為單一 flag
printf '%s\n' "$PAYLOAD" | "$CODEX_BIN" exec --sandbox read-only --ephemeral $SKIP_GIT_FLAG \
  -c model="$MODEL" -c model_reasoning_effort="$EFFORT" "$REVIEW_PROMPT"
RC=$?
echo "[codex-review] 完成(嚴重度=$SEV_SHOWN, 模型=$MODEL/$EFFORT, codex exit=$RC)。唯讀諮詢,腳本未改任何檔。" >&2
exit 0
