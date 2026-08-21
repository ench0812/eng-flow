#!/usr/bin/env bash
# Stop — 收工前偵測「已 commit 但沒推上遠端」的工作。
#
# 要解決的問題：本機有 commit、遠端沒有，session 結束就被遺忘，機器一出事就是
# 真的遺失。這件事不能靠模型每次記得檢查——那是靠自覺；靠自覺的檢查等同沒有檢查。
#
# 為什麼掛 Stop：收工的那一刻正是風險成真的時點。Stop 的 additionalContext 是
# 「給模型的回饋，對話會繼續讓模型據以行動」，所以模型會把結果轉述給使用者並
# 提議處置，而不是靜靜結束。
#
# 不做 git fetch（刻意，但有已知盲點）：
#   只比對本機的 remote-tracking ref，所以不會網路往返、不會卡憑證提示。
#
#   常見的過期情形（別人推了新東西、本機沒 fetch）只會讓我們「多報」——
#   報了其實已經被涵蓋的 commit，方向安全。
#
#   **但這不是全稱保證**：若遠端分支被 force-push 覆蓋或整個刪除，本機的
#   tracking ref 仍指向含 HEAD 的舊提交，`@{u}..HEAD` 算出 0，本 hook 會靜默，
#   而遠端其實已不再保存那些 commit——正是本 hook 要防的遺失情境。
#   要涵蓋這種情況必須 fetch，那會帶來網路往返與憑證提示，成本不對稱，
#   因此**刻意接受這個盲點**並在此明示，而不是假裝沒有。
#
# 只警告一次：Stop 的 additionalContext 會讓對話繼續，若條件持續存在就會每次
# Stop 都再觸發，形成迴圈。因此以 (session, repo, HEAD) 為鍵留下標記，同一狀態
# 只提醒一次；有新 commit（HEAD 變了）才會再提醒。
#
# 檢查範圍：預設只看 cwd 所在的 repo（零成本）。要納入更多，在
# ~/.claude/git-guard-roots 每行寫一個根目錄，會以 maxdepth 3 掃描其下的 repo。
set -uo pipefail

STAMP_DIR="${TMPDIR:-/tmp}/claude-git-guard"
ROOTS_FILE="$HOME/.claude/git-guard-roots"
SCAN_MAXDEPTH=3

JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

sid="$(printf '%s' "$input" | "$JQ" -r '.session_id // "nosession"' 2>/dev/null || echo nosession)"
sid="$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)"
cwd="$(printf '%s' "$input" | "$JQ" -r '.cwd // ""' 2>/dev/null || true)"
[ -n "$cwd" ] || cwd="$PWD"

# --- 收集要檢查的 repo ---
repos=""
add_repo() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  case "$repos" in *"|$top|"*) return 0 ;; esac
  repos="$repos|$top|"
}
add_repo "$cwd"

if [ -f "$ROOTS_FILE" ]; then
  while IFS= read -r root; do
    case "$root" in ''|\#*) continue ;; esac
    [ -d "$root" ] || continue
    while IFS= read -r g; do
      add_repo "$(dirname "$g")"
    done <<EOF
$(find "$root" -maxdepth "$SCAN_MAXDEPTH" -type d -name .git -not -path "*/node_modules/*" 2>/dev/null)
EOF
  done < "$ROOTS_FILE"
fi

# --- 逐 repo 判定 ---
findings=""
# 必須用 while read 逐行讀，不能用 `for x in $(...)`：後者會依空白斷詞，
# 路徑含空格的 repo（Windows 上很常見，例如 D:/My Projects/foo）會被切成碎片，
# 於是該 repo 永遠檢查不到——正是本 hook 要防的那種靜默漏檢。
while IFS= read -r top; do
  [ -n "$top" ] || continue
  [ -d "$top" ] || continue
  # 先跑唯一具決定性的那一次 git 呼叫。絕大多數情況是「乾淨」，這條路徑要最短：
  # 本 hook 掛在 Stop 上、每個回合結束都會跑，每多一次 git 子行程在
  # Windows/Git Bash 上就是 50-80ms。細節（分支名、主旨、未提交數）只在
  # 確定要示警時才去取。
  #
  # rev-list 在沒有上游時會失敗，正好用它的失敗當「無上游」的訊號，
  # 省掉一次額外的 rev-parse。
  if ahead="$(git -C "$top" rev-list --count '@{u}'..HEAD 2>/dev/null)"; then
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    [ "$ahead" -gt 0 ] || continue
    upstream="$(git -C "$top" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo '<upstream>')"
    reason="領先 $upstream $ahead 筆未推送"
  else
    # 沒有上游追蹤。空 repo（尚無 commit）不算，那沒有東西會遺失。
    git -C "$top" rev-parse HEAD >/dev/null 2>&1 || continue
    upstream=""
    branch="$(git -C "$top" branch --show-current 2>/dev/null)"
    [ -n "$branch" ] || branch="<detached>"
    # 「沒有上游」不等於「沒有遠端備份」：從 origin/main 切出、尚未新增 commit
    # 的本地分支，所有 commit 都已在遠端。所以再問一次「HEAD 是否被任何
    # remote-tracking ref 涵蓋」，據此分成兩種嚴重度不同的說法，不要一律當成
    # 最壞情況——狼來了的警告會被忽略，那等於沒有警告。
    if [ -n "$(git -C "$top" branch -r --contains HEAD 2>/dev/null | head -1)" ]; then
      reason="分支 $branch 沒有上游追蹤（HEAD 已被某個 remote-tracking ref 涵蓋，尚可確認有備份）"
    else
      reason="分支 $branch 沒有上游追蹤，且 HEAD 不在任何 remote-tracking ref 內（無遠端備份）"
    fi
  fi
  head_sha="$(git -C "$top" rev-parse HEAD 2>/dev/null)" || continue
  [ -n "$head_sha" ] || continue

  # 同一 (session, repo, HEAD) 只提醒一次，避免 Stop 迴圈。
  key="$(printf '%s|%s' "$top" "$head_sha" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || cksum; } | tr -cd '0-9a-f' | cut -c1-32)"
  stamp="$STAMP_DIR/$sid/$key"
  [ -f "$stamp" ] && continue
  mkdir -p "$(dirname "$stamp")" 2>/dev/null && : > "$stamp" 2>/dev/null

  subjects="$(git -C "$top" log --oneline -3 ${upstream:+"$upstream"..}HEAD 2>/dev/null | sed 's/^/      /')"
  # 用 wc -l 不用 grep -c：工作目錄乾淨時 grep 會印 0 但以 status 1 結束，
  # 後面的 `|| echo 0` 於是再補一個 0，dirty 變成兩行的 "0\n0"，警告裡就會
  # 出現異常的數字。wc 永遠 exit 0。
  dirty="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -cd '0-9')"
  [ -n "$dirty" ] || dirty=0
  findings="$findings
  - $top
      $reason；未提交變更 $dirty 筆
$subjects"
# 用 heredoc 餵入而不是 `... | while`：管線會讓迴圈跑在子行程裡，
# $findings 累積的結果出不來，最後永遠是空的（＝靜默漏報）。
done <<EOF
$(printf '%s' "$repos" | tr '|' '\n' | grep -v '^$' | sort -u)
EOF

[ -n "$findings" ] || exit 0

"$JQ" -cn --arg f "$findings" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: (
      "[git-guard] 偵測到已 commit 但尚未推送到遠端的工作：\n" + $f + "\n\n" +
      "請把這件事告訴使用者並提議處置，不要自行 push——推送是對外動作，要由使用者決定。\n" +
      "判定只比對本機的 remote-tracking ref、不做 fetch：一般過期只會多報；\n" +
      "但遠端若被 force-push 或刪除，本檢查會漏報（已知盲點，非全稱保證）。\n" +
      "同一個 commit 狀態在本 session 只提醒一次；有新 commit 才會再提醒。"
    )
  }
}'
exit 0
