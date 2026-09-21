#!/usr/bin/env bash
# codex-decide.sh — 待決選項的跨家族第二意見(裁定,不是 review)
#
# 為什麼不塞進 codex-review.sh(2026-09-20 使用者裁定新寫一支):
#   那支的兩種模式問的都是「這份東西有沒有問題」——diff 模式問這段 code 對不對,
#   doc 模式問這份 spec 完不完整,prompt 全篇圍繞挑錯。這裡要問的是完全不同的一句話:
#   「這幾個選項,你選哪一個」。硬套 spec 模式會拿到一份針對需求完整性的回覆,對不上焦;
#   更關鍵的是【共識判定需要嚴格的契約行】,而 review 模式的自由格式輸出解析不了。
#
# 用在哪: 需要使用者裁決但使用者未回應時,先問 codex。
#   與呼叫端的傾向一致 → 共識,可逕行(exit 0)
#   不一致 / 沒問成 / codex 信心低 → 停下交使用者裁決(非 0)
#   安全鐵律與不可逆操作【不適用本流程】,那五類一律停下等使用者,呼叫端自己把關,
#   不要送進來——本腳本只驗證呼叫端有沒有聲明,無法代替判斷。
#
# 用法:
#   bash codex-decide.sh --question <path> --prefer <選項代號> [--severity <level>]
#
# 【離開碼是唯一可靠的判定管道】,呼叫端不得改用解析 stdout 字串來決定要不要逕行:
#   0 = 共識成立,可依共識進行
#   3 = 無共識(codex 選了別的,或信心不足) → 必須停下交使用者
#   4 = 沒問成(RATE_LIMITED) → 必須停下交使用者。【不得因為問不到就自己走】,
#       那會讓整條機制在額度用盡時靜默退化成「照自己的傾向做」——正是它要防的事。
#   1 = FAILED(諮詢根本沒發生)   2 = 呼叫端合約錯誤
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTION=""; PREFER=""; SEVERITY="required"; ALLOW_INFERENCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --question|--prefer|--severity)
      [ $# -ge 2 ] || { echo "[codex-decide] 錯誤: $1 需要值。" >&2; exit 2; }
      case "$1" in
        --question) QUESTION="$2" ;;
        --prefer)   PREFER="$2" ;;
        --severity) SEVERITY="$2" ;;
      esac; shift 2 ;;
    --allow-inference) ALLOW_INFERENCE=1; shift ;;
    -h|--help) echo "用法: bash codex-decide.sh --question <path> --prefer <代號> [--severity <level>] [--allow-inference]"; exit 0 ;;
    *) echo "[codex-decide] 未知參數: $1" >&2; exit 2 ;;
  esac
done
[ -n "$QUESTION" ] || { echo "[codex-decide] 錯誤: 需要 --question <path>。" >&2; exit 2; }
[ -f "$QUESTION" ] || { echo "[codex-decide] 錯誤: 找不到 '$QUESTION'。" >&2; exit 2; }
[ -n "$PREFER" ]   || { echo "[codex-decide] 錯誤: 需要 --prefer <代號>(你自己的傾向;沒有傾向就不該走這條流程,直接問使用者)。" >&2; exit 2; }

# 【呼叫端必須聲明這不是安全鐵律/不可逆類】。這裡只驗證聲明【在場】,不驗證它正確——
# 正確性無法用程式判定。缺聲明就擋下,是要逼呼叫端在送出前實際想過這一步,
# 而不是讓「忘了想」與「想過並排除」長得一模一樣(fail-closed)。
if ! grep -qE '^##[[:space:]]*安全與可逆性聲明' "$QUESTION" 2>/dev/null; then
  echo "[codex-decide] 錯誤: '$QUESTION' 缺少「## 安全與可逆性聲明」小節。" >&2
  echo "  這條流程不適用於安全鐵律五條與不可逆操作——那些一律停下等使用者。" >&2
  echo "  請在問題檔加一節寫明: 這個決定為什麼不屬於那幾類、以及做錯了怎麼還原。" >&2
  exit 2
fi

case "$(printf '%s' "$SEVERITY" | tr '[:upper:]' '[:lower:]')" in
  critical)         MODEL="gpt-6-astra";  EFFORT="low" ;;
  required)         MODEL="gpt-5.6-terra"; EFFORT="high" ;;
  optional|nit|fyi) MODEL="gpt-5.6-luna";  EFFORT="max" ;;
  *) echo "[codex-decide] 警告: 未知 severity '$SEVERITY',用 required 檔位。" >&2
     MODEL="gpt-5.6-terra"; EFFORT="high" ;;
esac

CODEX_BIN=""
for b in codex codex.cmd; do command -v "$b" >/dev/null 2>&1 && { CODEX_BIN="$b"; break; }; done
if [ -z "$CODEX_BIN" ]; then
  for p in "$HOME/.local/bin/codex" "$HOME/AppData/Local/Programs/OpenAI/Codex/bin/codex" \
           "$HOME/.codex/packages/standalone/current/bin/codex" "/usr/local/bin/codex"; do
    [ -x "$p" ] && { CODEX_BIN="$p"; break; }
  done
fi
# 【環境缺失也要停下】,不同於 codex-review.sh 的自我略過(那裡 review 只是加值,
# 這裡 codex 的意見是「可不可以逕行」的唯一依據,缺了就沒有共識可言)。
if [ -z "$CODEX_BIN" ]; then
  echo "[codex-decide] SKIP: 未偵測到 codex CLI —— 沒有第二意見就沒有共識,停下交使用者。" >&2
  exit 3
fi
if ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  echo "[codex-decide] SKIP: codex 未授權 —— 停下交使用者。" >&2
  exit 3
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SKIP_GIT=""; git rev-parse --is-inside-work-tree >/dev/null 2>&1 || SKIP_GIT="--skip-git-repo-check"

read -r -d '' PROMPT <<EOF
你要做的是【在幾個選項之間選一個】,不是審查文件、也不是挑錯。stdin 是待決問題的完整內容。

情境: 第一位決策者(Claude)在自動執行中遇到一個需要人類裁決的分歧,但使用者當下不在。
規則是: 你與它的判斷一致才可以逕行,不一致就停下等使用者。所以【你的不同意見很有價值】
——如果你認為它的傾向是錯的,直說,那會讓這件事正確地停下來等人,不會有人因此怪你。
反過來,為了讓流程順暢而附和一個你並不真的支持的選項,是這條機制最糟的失效方式。

你在唯讀沙箱內執行,工作根是:
  $REPO_ROOT
你的 shell 目前目錄【不是】上面那個工作根(Windows 上實測是 C:\\)。讀檔一律用絕對路徑
把工作根整串接在前面;存取被拒通常是路徑寫法問題,不代表你沒有讀取權,不得據此改用純推論作答。
需要看實際程式碼才能判斷就去讀,但【只讀與這個決定直接相關的】,不要遍歷探索。
你沒有網路。禁止修改任何檔案。

判斷時請特別注意三件事:
  1. 選項是否窮盡 —— 有沒有一個更好的第三條路兩邊都沒想到?有就講,並選「其他」。
  2. 傾向的理由是否成立 —— 它給的理由有沒有事實錯誤或站不住的假設?
  3. 不可逆性 —— 這個決定做錯了能不能還原?若你認為它其實屬於不可逆或安全相關,
     直接講出來並選「停下」,那比選任何一個選項都重要。

回覆最後必須以【五行】作結,每行獨立一行,格式完全照抄(冒號用半形),五行缺一不可
——【少任何一行都會被判定為無共識而停下】,寧可寫得保守也不要省略:
裁定:<選項代號,或 其他,或 停下>
信心:<高|中|低>
依據:<已讀|推論>
理由:<一句話,不超過 60 字>
異議:<無,或具體寫出你不同意第一位決策者哪一點>

其中【依據】的意思: 你實際讀過相關檔案或歷史來支撐這個裁定就寫「已讀」;完全只憑本訊息
提供的內容推得、沒有查證任何東西就寫「推論」。誠實標註——標錯比標保守糟得多。
EOF

OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR" 2>/dev/null || true' EXIT

printf '%s\n\n---\n\n%s\n' "$PROMPT" "$(cat "$QUESTION")" \
  | "$CODEX_BIN" exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
      --sandbox read-only $SKIP_GIT --cd "$REPO_ROOT" - >"$OUT" 2>"$ERR"
RC=$?

cat "$OUT"

RATE_PAT="you'?ve (hit|reached) your usage limit|you have (hit|reached) your usage limit|reached your workspace credit limit|out of credits|quota exceeded|rate limit reached"
if grep -qiE "$RATE_PAT" "$ERR" "$OUT" 2>/dev/null && ! grep -qE '^裁定[:：]' "$OUT" 2>/dev/null; then
  echo "[codex-decide] RATE_LIMITED: 諮詢沒有取得結果。沒有第二意見就沒有共識——停下交使用者。" >&2
  exit 4
fi
if [ "$RC" -ne 0 ] || [ ! -s "$OUT" ]; then
  echo "[codex-decide] FAILED: codex 非正常結束(exit=$RC)或零輸出,諮詢根本沒發生。" >&2
  tail -n 20 "$ERR" >&2
  exit 1
fi

field() { grep -m1 -E "^$1[:：]" "$OUT" | sed -E "s/^$1[:：][[:space:]]*//" | tr -d '\r' | xargs; }
VERDICT="$(field 裁定)"; CONF="$(field 信心)"; BASIS="$(field 依據)"
REASON="$(field 理由)"; DISSENT="$(field 異議)"

# 【五個欄位全部必填,且值域要驗】(2026-09-21 codex 複查抓到的 fail-open,實際存在):
# 原版只把「裁定」當必填,於是一份只有 `裁定:A` 的截斷回覆會讓 CONF 與 DISSENT 都是空字串
# ——空字串既不等於「低」也不是非空,兩個阻擋條件【同時失效】,直接 exit 0 放行。
# 缺欄位與值不合法一律視為無共識:這裡的預設必須是「不放行」,因為放行才是不可逆的那一邊。
MISSING=""
for f in 裁定:VERDICT 信心:CONF 依據:BASIS 理由:REASON 異議:DISSENT; do
  eval "v=\${${f#*:}}"
  [ -n "$v" ] || MISSING="$MISSING ${f%%:*}"
done
if [ -n "$MISSING" ]; then
  echo "[codex-decide] 無共識: 回覆缺少契約行:$MISSING。格式不完整無法判定,停下交使用者。" >&2
  exit 3
fi
case "$CONF" in 高|中|低) ;; *)
  echo "[codex-decide] 無共識: 信心值「$CONF」不在 高|中|低 之內,停下交使用者。" >&2; exit 3 ;;
esac
case "$BASIS" in 已讀|推論) ;; *)
  echo "[codex-decide] 無共識: 依據值「$BASIS」不在 已讀|推論 之內,停下交使用者。" >&2; exit 3 ;;
esac

if [ "$VERDICT" != "$PREFER" ]; then
  echo "[codex-decide] 無共識: codex 裁定「$VERDICT」,我方傾向「$PREFER」。停下交使用者。" >&2
  [ "$DISSENT" != "無" ] && echo "  codex 異議: $DISSENT" >&2
  exit 3
fi
# 選了同一個但信心低 = 兩邊都不確定,不該當成可以逕行的依據。
if [ "$CONF" = "低" ]; then
  echo "[codex-decide] 無共識: codex 同選「$VERDICT」但信心低——兩邊都不確定,停下交使用者。" >&2
  exit 3
fi
if [ "$DISSENT" != "無" ]; then
  echo "[codex-decide] 無共識: codex 雖同選「$VERDICT」但提出異議,停下交使用者。" >&2
  echo "  codex 異議: $DISSENT" >&2
  exit 3
fi
# 【純推論預設不構成共識】,對齊 decision-consensus.md 的 "unverified inference are not
# consensus"。但不無條件擋死: 有一類決定(先做哪張卡、優先序)本來就沒有原始碼可讀,
# 那時標「推論」是誠實的。所以放寬要由呼叫端【明確】聲明,而不是靜默容許——
# 預設 fail-closed,例外要具名,這是安全鐵律第 4 條的形狀。
if [ "$BASIS" = "推論" ] && [ "$ALLOW_INFERENCE" != "1" ]; then
  echo "[codex-decide] 無共識: codex 標【推論】(未查證任何檔案),依預設不構成共識。" >&2
  echo "  這個決定若本來就不需要讀程式碼(例如純優先序),呼叫端加 --allow-inference 重跑;" >&2
  echo "  若它其實需要查證,那就是該停下交使用者的情況。" >&2
  exit 3
fi

NOTE=""; [ "$BASIS" = "推論" ] && NOTE=" 【注意: 無查證共識,呼叫端已聲明本決定不需查證】"
echo "[codex-decide] 共識成立: 裁定=$VERDICT 信心=$CONF 依據=$BASIS (模型=$MODEL/$EFFORT)。可依共識進行。$NOTE" >&2
exit 0
