#!/usr/bin/env bash
# codex-review.sh — eng-flow code review 收尾的 OpenAI Codex 第二意見複查
#
# 定位: 第一輪(Claude / eng-flow 五軸)review 完成、且該輪所有 required/critical
#        已修正之後,對本分支相對 base 的「整體 diff」跑一次非互動 codex review,
#        讓不同模型家族交叉檢查是否有遺漏或值得調整處。純第二意見,唯讀,不改任何檔。
#
# 依「來源嚴重度」選模型(嚴重度由呼叫端提供,腳本不自行分診):
#   複查深度應與這次變更的風險相稱。嚴重度是【輸入】—— 由 eng-flow 收尾情境(第一輪五軸
#   review 對本次變更判定的最高原始嚴重度)以 --severity 傳入,不用弱模型事後猜。
#   映射(嚴重度用語同 mao-review taxonomy):
#     critical          -> gpt-5.6-sol   / max   (旗艦最深,阻斷級風險值得最貴複查)
#     required          -> gpt-5.6-sol   / high
#     optional/nit/fyi  -> gpt-5.6-terra / medium(低風險用便宜模型快速掃)
#   --severity 未傳/未知 -> fallback gpt-5.6-sol / high(保守:不靜默降級、也不漏看)。
#
# 用法: bash codex-review.sh --severity <critical|required|optional|nit|fyi> [--base <branch>]
#        --base 省略時自動偵測(origin/HEAD → main → master)。
#
# 前置: codex client >= 0.144.x 且帳號 plan(Plus 以上)已 rollout GPT-5.6 家族,
#        否則 gpt-5.6-* slug 會被 server 回 400 invalid_request。
#
# Gate: codex 未安裝 或 未授權 → 印提示並 exit 0(安靜跳過,不阻斷 eng-flow 流程)。
set -uo pipefail

# --- 嚴重度 → 模型/effort 映射(集中一處,要調策略只改這裡) ---
CRIT_MODEL="gpt-5.6-sol";      CRIT_EFFORT="max"        # critical
REQ_MODEL="gpt-5.6-sol";       REQ_EFFORT="high"        # required
LOW_MODEL="gpt-5.6-terra";     LOW_EFFORT="medium"      # optional / nit / fyi
FALLBACK_MODEL="gpt-5.6-sol";  FALLBACK_EFFORT="high"   # --severity 未傳/未知時的保底

SEVERITY=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --severity) SEVERITY="${2:-}"; shift 2 ;;
    --base)     BASE="${2:-}"; shift 2 ;;
    -h|--help)  echo "用法: bash codex-review.sh --severity <critical|required|optional|nit|fyi> [--base <branch>]"; exit 0 ;;
    *) echo "[codex-review] 未知參數: $1" >&2; exit 2 ;;
  esac
done

# --- 依來源嚴重度決定模型/effort ---
case "$(printf '%s' "$SEVERITY" | tr '[:upper:]' '[:lower:]')" in
  critical)         MODEL="$CRIT_MODEL"; EFFORT="$CRIT_EFFORT"; SEV_SHOWN="critical" ;;
  required)         MODEL="$REQ_MODEL";  EFFORT="$REQ_EFFORT";  SEV_SHOWN="required" ;;
  optional|nit|fyi) MODEL="$LOW_MODEL";  EFFORT="$LOW_EFFORT";  SEV_SHOWN="$SEVERITY" ;;
  "")  MODEL="$FALLBACK_MODEL"; EFFORT="$FALLBACK_EFFORT"; SEV_SHOWN="(未指定)"
       echo "[codex-review] 警告: 未傳 --severity,fallback $FALLBACK_MODEL/$FALLBACK_EFFORT。呼叫端應依第一輪 review 最高嚴重度指定。" >&2 ;;
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

# --- 必須在 git repo 內 ---
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[codex-review] SKIP: 目前不在 git repo 內。" >&2
  exit 0
fi

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

# --- 單次 codex 複查:模型由來源嚴重度決定,唯讀,--ephemeral 不落地 session 檔 ---
echo "[codex-review] base=$BASE (merge-base=${MB:0:12}) | 來源嚴重度=$SEV_SHOWN → $MODEL / $EFFORT" >&2
printf '%s\n' "$DIFF" | "$CODEX_BIN" exec --sandbox read-only --ephemeral \
  -c model="$MODEL" -c model_reasoning_effort="$EFFORT" "$REVIEW_PROMPT"
RC=$?
echo "[codex-review] 完成(嚴重度=$SEV_SHOWN, 模型=$MODEL/$EFFORT, codex exit=$RC)。純第二意見,腳本未改任何檔。" >&2
exit 0
