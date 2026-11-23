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
# 檢查範圍＝**本 session 實際碰過的 repo**，不是「cwd」也不是「全機器」。
#   只看 cwd：session 中途 cd 到別處工作、或 cwd 根本不是 repo 時會漏掉。
#   掃全機器：會報出跟這次工作無關的專案。範圍不對的警告會被忽略，
#            而被忽略的警告等於沒有警告。
# 折衷做法是從 transcript 取出本 session 出現過的所有 cwd，以及 Write/Edit
# 動過的檔案所在目錄，解析成 repo（最內層的那一個：外層 repo 底下的巢狀 repo、linked worktree
# 各自算）後只檢查那些。這正好是「這次工作可能造成遺失」的集合。成本是兩個 grep 先篩、一次 jq 反跳脫（167MB 實測約 1.4 秒，見下方掃描段）。
#
# ~/.claude/git-guard-roots 仍然支援，但定位改為「不論這次有沒有碰、都要盯著的
# 根目錄」的明確加選，不是預設。多數情況不需要它——session 範圍已經涵蓋。
set -uo pipefail

ROOTS_FILE="$HOME/.claude/git-guard-roots"
SCAN_MAXDEPTH=3

JQ="$(command -v jq || true)"
[ -z "$JQ" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# TMPDIR 轉成與 git 頂層相同的寫法（小寫、正斜線、x:/ 磁碟形式），整支只算一次。
# Git Bash 的 TMPDIR 可能是磁碟寫法（/d/Temp）或掛載寫法（/tmp，實際掛在 D:/Temp），
# git rev-parse 卻回 D:/Temp/...，不先轉換前綴永遠對不上（2026-10-18：mktemp 的 fixture
# 全被誤報）。cygpath 一次轉 TMPDIR 與 HOME 兩個值，每次 hook 一個子行程、不是每個路徑
# 一個，不違反下面的效能守則。
# 【轉得越準，TMPDIR 吞掉的範圍就越真】：寫法對上之後，TMPDIR 若指向 repo 的上層，底下
# 所有 repo 都會靜默——這是本 hook 唯一不能出現的方向（fail-open）。所以以下幾種整條不用：
# 空字串與根目錄（""/* 匹配所有絕對路徑）、磁碟根（d:）、UNC 的 server 或 share 根、
# 以及涵蓋 $HOME 的值（~/.claude 的三個 repo 都在那底下）。列舉擋不完所有上層目錄，
# 擋的是真的會被設成 TMPDIR 的那幾種；D:/Projects 這種值仍會吞掉其下的 repo。
# 【反斜線只在 Windows 是分隔符】(codex 複查 Required ×4): Linux 上 `\` 是合法的檔名字元，
# `a\b` 與 `a/b` 是不同目錄。TMPDIR／HOME、輸入路徑、git 回傳的頂層、寫入證據的比對、取父目錄，
# 全部用同一套規則；只換其中一處，同一個鍵就會對著兩個不同目錄（例如 cwd `/w/a\b` 與寫入的
# `/w/a/b` 共用 `/w/a/b`，寫入證據被歸到只有 cwd 的 repo；TMPDIR `/w/cache\run` 被轉成
# `/w/cache/run`，真正在它底下的 repo 反而被列入）。
WINPATH=0
case "${OSTYPE:-}" in msys*|cygwin*) WINPATH=1 ;; esac

TMP_NORM=""; tmp_path=""
if [ -n "${TMPDIR:-}" ]; then
  home_norm=""
  if command -v cygpath >/dev/null 2>&1; then
    { IFS= read -r tmp_path; IFS= read -r home_norm; } < <(cygpath -m "$TMPDIR" "$HOME" 2>/dev/null)
  fi
  if [ -z "$tmp_path" ]; then
    tmp_path="$TMPDIR"; home_norm="$HOME"
    [ "$WINPATH" = 1 ] && { tmp_path="${TMPDIR//\\//}"; home_norm="${HOME//\\//}"; }
    # /d/... 只在 Windows 上是磁碟寫法；Linux 的 /d/temp 是一般目錄，不能轉。
    case "${OSTYPE:-}" in msys*|cygwin*)
      case "$tmp_path" in /[a-zA-Z]/*) tmp_path="${tmp_path:1:1}:${tmp_path:2}" ;; esac
      case "$home_norm" in /[a-zA-Z]/*) home_norm="${home_norm:1:1}:${home_norm:2}" ;; esac ;;
    esac
  fi
  tmp_path="${tmp_path%/}"; TMP_NORM="${tmp_path,,}"
  home_norm="${home_norm,,}"; home_norm="${home_norm%/}"
  case "$TMP_NORM" in
    ""|/|[a-z]:) TMP_NORM="" ;;
    //*) case "$TMP_NORM" in //*/*/*) ;; *) TMP_NORM="" ;; esac ;;
  esac
  if [ -n "$TMP_NORM" ] && [ -n "$home_norm" ]; then
    case "$home_norm/" in "$TMP_NORM"/*) TMP_NORM="" ;; esac
  fi
  [ -n "$TMP_NORM" ] || tmp_path=""
fi
# 標記檔只寫進驗證過的 TMPDIR：原始值若是 //server/share，每次寫入都要等網路逾時
# （實測 53 秒，超過 15 秒 timeout，hook 被取消就等於靜默）。GIT_GUARD_STAMP_DIR 只給測試用。
STAMP_DIR="${GIT_GUARD_STAMP_DIR:-${tmp_path:-/tmp}/claude-git-guard}"

# 一次 jq 取出三個欄位（舊版三次 jq＋tr＋cut），一行一欄讀回，所以值裡不能留換行：
# - sid：換行直接去掉（舊版 tr 本來就只留安全字元）。
# - cwd／transcript_path：與舊版 `$(jq -r …)` 相同，只去掉尾端的 \n（不含 \r）；仍含 \r 或 \n 的值【不可】
#   把換行刪掉——那會把 /a\n-b 改寫成另一個可能真的存在的 /a-b（codex 第三輪）。舊版拿到的是
#   含換行、不存在的路徑；這裡改輸出 0x1f 當「無效」記號：cwd 無效就不檢查（也不退回 $PWD），
#   transcript 無效就當成沒有 transcript，結果與舊版相同。
# 輸入不是 JSON 物件時 jq 沒有輸出，三個欄位維持預設值。【不看 jq 的離開碼】（最終版複查 O1）：
# 「合法物件後面接垃圾」時 jq 先印完第一個物件的三行才以 exit 5 結束，舊版逐欄的 `|| true` 會
# 保住那些值；看離開碼就會丟掉 transcript、少檢查。陣列在 .[] 之前已完整建好，不會只印一半。
sid=nosession; cwd=""; transcript=""; BAD=$'\x1f'
meta="$(printf '%s' "$input" | "$JQ" -r '
            def path_field: tostring | sub("\n+$"; "") | if test("[\r\n]") then "\u001f" else . end;
            [(.session_id // "nosession" | tostring | gsub("[\r\n]"; "")),
             (.cwd // "" | path_field), (.transcript_path // "" | path_field)] | .[]' 2>/dev/null)"
if [ -n "$meta" ]; then
  { IFS= read -r sid; IFS= read -r cwd; IFS= read -r transcript; } <<<"$meta"
  sid="${sid%$'\r'}"; cwd="${cwd%$'\r'}"; transcript="${transcript%$'\r'}"   # Windows 的 jq 輸出 CRLF
fi
sid="${sid//[!A-Za-z0-9._-]/}"; sid="${sid:0:40}"
[ "$transcript" = "$BAD" ] && transcript=""
[ -n "$cwd" ] || cwd="$PWD"

# --- 收集要檢查的 repo ---
repos=""
repo_list=()    # 同一批 repo 的陣列形式，逐 repo 迴圈直接用，不必再開 tr／grep 拆字串
writable=""     # 其中「本 session 有寫入證據」的 repo（正規化頂層），只有這些能進 auto 桶
tops_norm=()    # 已解析出的 repo 頂層（正斜線形式），用於前綴短路
not_repo=""     # 問過 git、結論是「不列入」的路徑（不是 repo，或頂層在臨時目錄），同一路徑不再問

# 效能守則（實測逼出來的，改動前請先量）：本函式對 transcript 取出的每個路徑
# 都會跑一次，而一個 session 可以有 20+ 個相異路徑。在 Windows/Git Bash 上，
# **每開一個子行程約 30ms**，所以這裡一律用 bash 內建運算，不用 printf|sed|tr。
#   實測 23 個路徑：printf|sed 取目錄共 740ms、git rev-parse 共 493ms。
#   前者用參數展開可降到接近 0，後者靠「已知 repo 底下不再問」收斂。
# 臨時目錄底下的 repo 一律不報（2026-09-08）：session scratchpad、mktemp -d 出來的
# fixture、測試用的暫存 repo——它們**本來就不該有遠端**，報了只是雜訊，而被忽略的
# 警告等於沒有警告（同本檔開頭「範圍不對的警告會被忽略」那條理由）。
# 實測動機：一個 session 裡同一個 fixture repo 報了三次。
# 比對用小寫化的正斜線路徑，Windows 路徑大小寫不敏感。刻意**不**用寬鬆的 `*/temp/*`
# ——那會誤殺 D:/Projects/temp-tool 這類正常 repo；只認真正的臨時根。
is_temp_path() {
  # 測試專用的繞道：測試 fixture 本身就是 mktemp -d 出來的，落在同一批臨時根底下，
  # 不給開關的話整份測試會全部被這條規則擋掉（實測 15 條紅）。
  # 只有測試會設它；生產路徑不設，維持排除行為。「temp 排除有沒有生效」另有專門的
  # 案例在不設此變數的情況下驗——否則這個開關會把它要保護的行為一起關掉。
  [ "${GIT_GUARD_ALLOW_TEMP:-0}" = "1" ] && return 1
  local lp="${1,,}"
  case "$lp" in
    */appdata/local/temp/*|/tmp/*|*/scratchpad/*|*/.cache/*) return 0 ;;
  esac
  if [ -n "$TMP_NORM" ]; then
    case "$lp" in "$TMP_NORM"/*) return 0 ;; esac
  fi
  return 1
}

# 【巢狀 repo】(2026-11-23 擁有者裁定修，項目 27): 前綴短路只能在「已知頂層與這個目錄之間
# 沒有別的 .git」時成立。舊版只看前綴：cwd 是外層 repo（D:/Projects/IntelliPark 本身就是 repo）
# 時它第一個進 tops_norm，底下 pgs-* 的每個路徑都被歸給外層、從不問 git，內層 repo 有未推送
# commit 也永遠不提醒——fail-open。這裡從目錄往上逐層看 .git 是否存在（檔案或目錄都算：
# linked worktree 與 submodule 的 .git 是檔案），到已知頂層為止；有就不短路、交給 git 判定
# 最內層的 repo。只用 [ -e ]／[ -L ]（stat，不開子行程），而且只走 transcript 實際出現的路徑，
# 不掃描子目錄——cwd 底下沒被碰過的巢狀 repo 不會因此被列入。
# 【字串前綴不等於實際位置】(五軸審查 O1): `<top>/../elsewhere`、或經過符號連結／junction 的
# 路徑，字串上在 top 底下、實際上不在。短路會把那筆寫入算成 top 的寫入證據（實測重現：外層
# 因此進 auto 桶），而真正被寫的 repo 反而不在範圍內。所以路徑含 `.`／`..` 片段、或中間有任何
# 一層是符號連結時，同樣不短路，交給 git 依實際路徑解析。1.51.2 的前綴短路就有這個缺口。
nested_git_below() {  # nested_git_below <top> <dir>：<dir> 在 <top> 底下；兩者之間（不含 top）有 .git、符號連結或 ./.. 片段就回 0
  local t="$1" d="$2"
  case "$d/" in */./*|*/../*) return 0 ;; esac
  while [ "${#d}" -gt "${#t}" ]; do
    [ -e "$d/.git" ] && return 0
    [ -L "$d" ] && return 0
    d="${d%/*}"
  done
  return 1
}
declare -A known_dir=()   # git 解析回【已知 repo】的目錄 → 該 repo（正規化頂層）；同一目錄不再問 git（審查 O2）

# $2="w" 表示這個路徑帶有【本 session 的寫入證據】（Write/Edit 類工具動過的檔；cwd 不算，見下方）。
# 為什麼要分：auto 桶會讓模型【不問就推】，而 push 是這條路徑上唯一不可逆的動作。
# 只有「讀過一個檔」就授權推送，會把使用者自己留在那個 repo 的 WIP commit 推出去——
# 那筆 commit 根本不是這次工作產生的。範圍收集維持寬鬆（多報方向安全），
# 收緊的只是【授權】：沒有寫入證據的 repo 一律留在 ask 桶。
add_repo() {
  local p="${1:-}" mode="${2:-}" top np ntop t
  [ -n "$p" ] || return 0
  # 反斜線換正斜線（內建，不開子行程）只在 Windows 做（WINPATH，見其定義處）。
  np="$p"; [ "$WINPATH" = 1 ] && np="${p//\\//}"
  for t in ${tops_norm+"${tops_norm[@]}"}; do
    case "$np/" in
      "$t/"*)
        # 中間有別的 .git＝可能是巢狀 repo，不歸給這個頂層（見上方 nested_git_below）。
        # 換下一個已知頂層：內層 repo 若已解析過，會在它那一輪短路。
        nested_git_below "$t" "$np" && continue
        # 已知 repo 底下就不再問 git，但【寫入證據仍要補記】——否則先 Read 後 Write
        # 同一個 repo 時，寫入證據會被前綴短路吃掉，該 repo 就永遠進不了 auto 桶。
        [ "$mode" = w ] && case "$writable" in *"|$t|"*) ;; *) writable="$writable|$t|" ;; esac
        return 0 ;;
    esac
  done
  # 【負向結果也要記】(2026-10-05 週回顧): 前綴短路只涵蓋「已確認是 repo」的路徑；
  # 不是 repo 的目錄（session scratchpad 最典型）與頂層落在臨時目錄的 repo 不會進
  # tops_norm，於是同一個目錄底下每個檔案都重問一次 git。實測一份 110MB transcript：
  # 1,065 次 rev-parse、相異路徑只有 32 個，整支跑 30.6 秒，超過 hooks.json 的 15 秒
  # timeout 被取消——該週 632 次 Stop 有 180 次如此，git-guard 在那些回合靜默沒跑。
  # 只記「不列入」的結論：是 repo 的那一支已在 tops_norm，且寫入證據的補記必須
  # 繼續走上面的前綴迴圈，不能被這裡短路掉。
  case "$not_repo" in *"|$np|"*) return 0 ;; esac
  # 鍵加前綴 k：路徑可以是任意字串（例如 @），不讓它碰到陣列下標的特殊寫法。
  t="${known_dir["k$np"]-}"
  if [ -n "$t" ]; then
    [ "$mode" = w ] && case "$writable" in *"|$t|"*) ;; *) writable="$writable|$t|" ;; esac
    return 0
  fi
  top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || { not_repo="$not_repo|$np|"; return 0; }
  [ -n "$top" ] || { not_repo="$not_repo|$np|"; return 0; }
  ntop="$top"; [ "$WINPATH" = 1 ] && ntop="${top//\\//}"
  # 【臨時目錄要對 repo 頂層判定，不是對被存取的路徑】(複查抓到): 對入參判定的話，
  # D:/Projects/myapp/.cache/vite 這種子路徑會讓【整個 myapp】被丟掉——而漏掉的正是
  # 本 hook 唯一要防的東西。放在 rev-parse 之後、用 $ntop 判定；fixture 那種
  # /tmp/tmp.XXX/work 的 toplevel 本身就在臨時根底下，排除行為不變。
  is_temp_path "$ntop" && { not_repo="$not_repo|$np|"; return 0; }
  # git 回到已知的 repo（路徑裡有 `.`、寫法不同、經過指回同一 repo 的符號連結，或中間是空的
  # .git 目錄而 git 退回外層）：寫入證據照樣補記，否則這種路徑的 Write 會讓 repo 從 auto 掉到 ask
  # （1.51.2 前綴短路時會記），並記進 known_dir。中間的 .git 是失效的 gitdir 檔或內容無效時，
  # git 直接失敗（rc=128），那個目錄進上面的 not_repo、不給外層寫入證據——方向安全（外層落 ask）。
  case "$repos" in
    *"|$top|"*)
      known_dir["k$np"]="$ntop"
      [ "$mode" = w ] && case "$writable" in *"|$ntop|"*) ;; *) writable="$writable|$ntop|" ;; esac
      return 0 ;;
  esac
  repos="$repos|$top|"
  repo_list+=("$top")
  [ "$mode" = w ] && writable="$writable|$ntop|"
  tops_norm+=("$ntop")
}
[ "$cwd" = "$BAD" ] || add_repo "$cwd"   # 只進範圍，不算寫入證據（理由見下方掃描段的註解）

# 本 session 碰過的目錄：transcript 每筆記錄都帶 cwd，Write/Edit 則帶 file_path
# （檔案可能不在 cwd 底下，所以要另外取其所在目錄）。一次 jq 取完兩者。
# 用 jq 而不是 grep：路徑是 JSON 字串，Windows 的反斜線是跳脫過的，
# 自己反跳脫容易寫錯——正確性優先於省下的那幾十毫秒。
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # jq 只負責「把路徑原封取出」，取目錄的動作放到 shell 端。
  # 別在 jq 的正規式裡處理 Windows 反斜線：字元類 [^/\\] 要穿過
  # shell 引號、jq 字串、Oniguruma 三層跳脫，少一層就變成未閉合的
  # [/\]（實測 jq 報 premature end of char-class），而 jq 一出錯就會
  # 中止該檔剩下的記錄——變成靜默漏檢。
  # 分工：grep 做大量掃描（只認欄位名，不解析 JSON 結構），jq 只負責把去重後的
  # 少數字串做 JSON 反跳脫。純 jq 走完整份 transcript 要迭代每筆的 message.content
  # 陣列——實測 4.7MB 要 1889ms，比這個混合寫法慢 19 倍，而這段掛在每個回合結束。
  # 反跳脫交給 jq 而不是自己 sed：Windows 路徑的反斜線是跳脫過的，手寫容易錯。
  # 個別壞行以 try 略過，不中止整串。
  #
  # 路徑分兩類，以行首標記區分：
  # 1<TAB>路徑 ＝寫入證據：【只有】寫入類工具實際動過的檔。
  #   【cwd 不算證據】(codex 複查抓到): cwd 只表示「session 從那裡啟動」，不表示有寫入。
  #   在一個有既存 WIP commit 的 repo 裡開 session 做純唯讀 review，cwd 就指向它——
  #   若算證據，那些不屬於本次工作的 commit 會被自動推出去。
  #   代價：純 git 操作（merge / cherry-pick，沒有 Write/Edit）產生的 commit 會落到 ask 桶，
  #   每次多問一句。這個方向是對的——那種 commit 本來就該讓使用者確認。
  #   【必須以工具物件為單位抽路徑】(codex 複查抓到): 先 grep 含 Write/Edit 的整行、再抽該行
  #   所有 file_path 是錯的——同一筆 message.content 可以同時裝著 Write(A) 與 Read(B)，
  #   B 會跟著被授權。所以 grep 只用來把候選行縮到極少數，真正的抽取交給 jq 逐物件做。
  # 2<TAB>路徑 ＝其餘路徑（cwd、Read 過的檔，以及寫入行裡出現的所有路徑）：只納入檢查範圍，
  #   不授權自動推送。
  #
  # 【兩條管線，處理順序不影響結果】(2026-11-23 量測、codex 第三、四輪；巢狀修正後改寫):
  #   1.51.2 以前 add_repo 的前綴快取讓順序有意義（父 repo 的路徑先到，巢狀 repo 就被吃掉），
  #   所以當時刻意維持舊版的 locale 排序。現在前綴短路先確認中間沒有別的 .git
  #   （nested_git_below），歸屬與寫入證據都不再依賴順序，locale 排序已拿掉；最後逐 repo
  #   迴圈另外排序，輸出順序不變。先寫入、後唯讀的順序維持，但只是習慣，不是正確性條件。
  #   - LC_ALL=C 用在 grep 與去重：逐位元組比對，token 那支在 en_US.UTF-8 下 938ms、C 下
  #     432ms；UTF-8 locale 遇到無效位元組還會把整個檔當二進位、只印 "Binary file matches"
  #     （-a 再保險一次）。
  #   - 兩批都用 LC_ALL=C sort -u（位元組精確去重；一份 transcript 有上萬個重複 token、寫入行
  #     也常是同一個檔寫好幾次）。不用 locale 的 sort -u：UTF-8 collation 會把排序上相等的
  #     不同路徑併成一筆而少檢查一個 repo。
  #   - 【不要合成一個 grep】：試過以 `^.*"name":"Write".*$|<token>` 一次取整行與 token，
  #     grep 失去快速搜尋路徑，C locale 下單是 grep 就 4.1 秒，UTF-8 locale 下跑了數分鐘。
  #     多讀一次檔的成本在 page cache 裡很小，兩個簡單的 grep 比一個複雜的快。
  # jq -R 逐行 fromjson：舊版第一批的 jq 直接解析 JSON 串流，遇到一行壞 JSON 就中止，之後的
  # 寫入證據全部漏掉；-R 之下一行出錯只影響那一行（實測：拿掉 try 結果不變，try 只是不留 stderr）。
  # 寫入行裡的路徑 token 由第二個 grep 照樣取到（它掃全部的行）。
  # 成本：純 jq 走完整份 transcript 實測 4.7MB / 1889ms，比 grep 先篩慢 19 倍，故不那樣做。
  #
  # jq 程式放在 heredoc 外的單引號變數：裡面有 \" 與 \t，不要讓它們經過 heredoc 的反斜線處理。
  # 【含換行的路徑一律丟掉】(五軸審查 C1): 寫入與唯讀的區分放在輸出文字的行首（1／2），
  # 而 fromjson 會把路徑裡的 \n 還原成真的換行。一筆 Read 的 file_path 若是
  # "x\n1\t<repo>/f"，就會多出一行偽造的寫入證據，讓只讀過的 repo 進 auto 桶（實測重現）。
  # 路徑可由模型產生（prompt injection、失敗的工具呼叫也會留在 transcript），所以要擋在
  # 標記之前。代價：含換行的路徑整個退出檢查範圍（Linux 上檔名可以含換行；位在那種 repo 裡的
  # cwd 同樣含換行而被判無效，只剩 ROOTS_FILE 掃描找得到它）——為了擋偽造寫入證據而接受的取捨。
  # 舊版寫入批帶換行時也有同樣的偽造缺口，一併堵住。
  CLEAN_JQ='def clean: select(type == "string" and (test("[\r\n]") | not));'
  WRITE_JQ="$CLEAN_JQ"'
    try ([fromjson | .. | objects
          | select((.name? // "") | test("^(Write|Edit|MultiEdit|NotebookEdit)$"))
          | (.input.file_path? // .input.notebook_path?)
          | select(. != null)] | .[] | tostring | clean | "1\t" + .) catch empty'
  READ_JQ="$CLEAN_JQ"'
    try (fromjson | clean | "2\t" + .) catch empty'
  # 【必須用 heredoc 餵，不可用 `... | while`】：管線會讓迴圈跑在子行程裡，
  # $writable 與 tops_norm 的累積出不來，最後 auto 桶永遠是空的——靜默失效。
  # 本檔下方的逐 repo 迴圈已經為同一個理由寫過一次註解，這裡是第二個現場。
  while IFS= read -r d; do
    # 【先去掉行尾 \r】(2026-10-05 週回顧): Windows 上的 jq（實測 1.8.2）輸出 CRLF，
    # 多行清單除了最後一行都帶 \r。目錄字串帶 \r 時下面的 [ -d ] 判為否、被剝掉一層，
    # transcript 裡的 cwd 就被解析成父目錄，那個 repo 整個漏檢（檔案路徑剝最後一段時
    # 剛好連 \r 一起剝掉，所以只有 cwd 會中）。
    d="${d%$'\r'}"
    case "$d" in
      1$'\t'*) mode=w ;;
      2$'\t'*) mode="" ;;
      *) continue ;;
    esac
    d="${d#?$'\t'}"
    [ -n "$d" ] || continue
    # cwd 本來就是目錄；file_path 是檔案，取其所在目錄。
    # 用參數展開而非 printf|sed：後者每個路徑要開一個子行程，實測 23 個
    # 路徑共 740ms——本 hook 最大的單項成本，而它掛在每個回合結束。
    # 取父目錄的分隔符同樣只在 Windows 含反斜線（WINPATH）：Linux 上 outer/a\b.txt 的父目錄是
    # outer，不是 outer/a（a 若是巢狀 repo，寫入證據會被錯歸給它）。
    if [ ! -d "$d" ]; then
      if [ "$WINPATH" = 1 ]; then d="${d%[/\\]*}"; else d="${d%/*}"; fi
    fi
    add_repo "$d" "$mode"
  done <<EOF
$({ LC_ALL=C grep -ahE '"name":"(Write|Edit|MultiEdit|NotebookEdit)"' "$transcript" \
      | "$JQ" -rR "$WRITE_JQ" | LC_ALL=C sort -u
    LC_ALL=C grep -aohE '"(cwd|file_path|notebook_path)":"[^"]*"' "$transcript" \
      | sed 's/^"[a-z_]*"://' | LC_ALL=C sort -u | "$JQ" -rR "$READ_JQ"
  } 2>/dev/null)
EOF
fi

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

# 共用分支（2026-10-07）：推送目標若是這些分支，維持原本最嚴的授權條件（本 session 寫入
# 證據＋最多 3 筆）；其餘視為 feature 分支，目的地明確就照推，不再停下來問。
# 判定只看名稱與遠端預設分支，不打 API——同本檔「不連線」的成本前提。
# 遠端預設分支多問一次 git，但只在已確定要示警的 repo 上跑，乾淨路徑不受影響。
is_shared_branch() {  # is_shared_branch <top> <remote> <branch>
  case "$3" in
    main|master|develop|development|dev|trunk|staging|production|prod|gh-pages|release|release/*|release-*) return 0 ;;
  esac
  # 讀完整 symbolic ref、去掉完整的 refs/remotes/<remote>/ 前綴（codex 第三輪 Required）：
  # 短名稱用 ${d#*/} 只去掉第一段，遠端名稱含 `/` 時會截錯，共用的預設分支就被當成 feature。
  local d
  d="$(git -C "$1" symbolic-ref -q "refs/remotes/$2/HEAD" 2>/dev/null)"
  case "$d" in "refs/remotes/$2/"*) [ "${d#"refs/remotes/$2/"}" = "$3" ] && return 0 ;; esac
  return 1
}
# 推送指令一律固定遠端＋完整目的 refspec（codex 2026-10-07 Required）：裸 `git push` 的目的地
# 會被 remote.<r>.push、branch.<b>.pushRemote、push.default 改掉——例如 remote.origin.push=
# HEAD:refs/heads/main 會讓追蹤 feature 上游的分支直接推進 main，繞過共用分支的授權條件。
# 參數用 printf %q 跳脫：分支名稱可以合法地含 `;` 等字元（git check-ref-format 接受 feat/x;echo），
# 執行者照字面貼上就會多跑一個指令。另外 safe_ref 先把這類名稱擋在 auto 桶外。
mk_push_cmd() {  # mk_push_cmd <top> <remote> <branch> [u]
  # --no-follow-tags：push.followTags=true 的 repo 會順帶發布 HEAD 可達的 annotated tag，
  # 那不在「推這個分支」的授權範圍內（codex 第四輪 Optional）。
  printf 'git -C %q push --no-follow-tags%s %q %q' "$1" "${4:+ -u}" "$2" "HEAD:refs/heads/$3"
}
safe_ref() {  # safe_ref <name>...：全部只含保守字元集才回 0
  local n
  for n in "$@"; do
    case "$n" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  done
  return 0
}
NOTE_UNSAFE="（分支或遠端名稱含特殊字元，不提供自動推送指令）"
# feature 分支沒有寫入證據時附的說明（不再因此轉 ask，見上方 is_shared_branch）。
NOTE_NO_WRITE="（本 session 沒有寫入證據；推送目標是 feature 分支，依 2026-10-07 使用者裁定不必確認 commit 歸屬）"

# 每個 repo 一次 for-each-ref 就拿齊判定所需的狀態（2026-11-23 量測）：只列指向 HEAD 的分支
# （通常一兩條，ahead/behind 只對這幾條算），目前分支以 %(HEAD)=* 標示。欄位以 0x1f 分隔：
# tab 是 IFS 空白字元，連續兩個 tab 會被 read 合併，空欄位（沒有上游）就會讓後面的欄位錯位。
# %(upstream:remotename) 讀的就是 branch.<b>.remote 設定（與舊版 config --get 相同）；merge 設定
# 不從這裡取（多值時取法不同，待示警時另行 config --get，見迴圈內 R1）。%(upstream:track) 是
# plumbing 輸出、不翻譯，形式只有 ""／gone／ahead N／behind N／ahead N, behind N 幾種。
# 【輸出格式要先驗】(最終版複查 R-A): branch.<b>.merge 與 fetch refspec 的值可以含換行，
# %(upstream)／upstream:short 會把它原樣輸出，一列被拆成兩列——目前分支那一列被截短（上游變成
# 不存在的名字、track 變空＝誤判乾淨），或另一條分支的設定接出一列偽造的「* 列」。所以每一列
# 都必須以 "*<US>" 或 " <US>" 開頭、* 列剛好一列、且那一列剛好 7 個欄位；任何一點不符就整筆
# 轉 ask（state=unknown）。三項檢查對正常輸入互為備援，負控組刻意一次全拿掉（M20）。
# 刻意不防：值裡同時塞 0x1f 與換行、精心湊出格式的設定——能改 .git/config 的人本來就能設
# core.hooksPath 之類，這裡防的是「設定不正常」，不是「設定被惡意改寫」。
US=$'\x1f'
CUR_MARK="*$US"   # 目前分支那一列的開頭（%(HEAD) 輸出 *，其餘列是空白）
REF_FMT='%(HEAD)%1f%(objectname)%1f%(refname)%1f%(upstream)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)'
REF_SEPS="$US$US$US$US$US$US"   # 7 個欄位＝6 個分隔符

# 標記檔名＝HEAD sha＋repo 路徑的雜湊，全用 bash 內建運算算出。舊版每個待示警的 repo 要開
# sha256sum／tr／cut 四個子行程。兩個 31 位元的多項式雜湊合成 64 位元：只有「同一 session、
# 同一個 HEAD sha、不同路徑」（同一 repo 的多個 worktree）才需要靠它區分，碰撞機率可忽略。
# 換鍵的代價：升級當下的 session 對已提醒過的 repo 會再提醒一次。
path_hash() {  # path_hash <s>：結果放在 REPLY（16 個十六進位字元）
  local s="$1" i c h1=5381 h2=52711
  for ((i = 0; i < ${#s}; i++)); do
    printf -v c '%d' "'${s:i:1}"
    h1=$(( (h1 * 33 + c) & 0x7fffffff ))
    h2=$(( (h2 * 131 + c) & 0x7fffffff ))
  done
  printf -v REPLY '%08x%08x' "$h1" "$h2"
}
# 【一取得 HEAD 就先查標記】(2026-11-23 量測)：舊版把標記檢查排在每個 repo 的 rev-list、
# rev-parse @{u}、branch、兩次 config 之後，同一 session 第二次 Stop 仍要跑 104 個 git。
# 提前查不會改變結果：標記存在時，舊版不是在中途 continue、就是在標記檢查 continue，
# 兩者都不輸出；標記仍然只在確定要示警的位置寫入（見迴圈尾端）。
stamp_seen() {  # 依 $top 與 $head_sha 設定 $stamp；已存在回 0
  path_hash "$top"
  stamp="$STAMP_DIR/$sid/$head_sha.$REPLY"
  [ -f "$stamp" ]
}

# --- 逐 repo 判定 ---
findings=""
auto_findings=""   # fast-forward 且目的地明確：照列出的推送指令推，不需要逐一問人
ask_findings=""    # 目的地不明確、落後遠端、或推共用分支但授權條件不足：要人決定
# 必須用 while read 逐行讀，不能用 `for x in $(...)`：後者會依空白斷詞，
# 路徑含空格的 repo（Windows 上很常見，例如 D:/My Projects/foo）會被切成碎片，
# 於是該 repo 永遠檢查不到——正是本 hook 要防的那種靜默漏檢。
while IFS= read -r top; do
  [ -n "$top" ] || continue
  [ -d "$top" ] || continue
  push_cmd=""; pr_remote=""; pr_branch=""; pr_u=""; cmp_ref=""; head_sha=""; branch=""
  # 先跑唯一具決定性的那一次 git 呼叫（REF_FMT 見上方）。絕大多數情況是「乾淨」，這條路徑
  # 要最短：本 hook 掛在 Stop 上、每個回合結束都會跑，每多一次 git 子行程在 Windows/Git Bash
  # 上就是 20～180ms。細節（主旨、未提交數）只在確定要示警時才去取。
  # 需要 behind 是因為 2026-09-08 起有上游的 repo 會被歸類成「可直接推」，而那個結論
  # 只在 fast-forward 時成立——落後遠端時 push 會被拒（或需要 rebase/merge），
  # 那是要人決定的事，不能自動做。
  # 「有上游」的判準與舊版的 `rev-list @{u}...HEAD` 成功相同：設定了上游（%(upstream) 非空），
  # 而且它的 remote-tracking ref 存在（track 不是 gone）。
  state=unknown
  if refs="$(git -C "$top" for-each-ref --points-at HEAD --format="$REF_FMT" refs/heads/ 2>/dev/null)"; then
    # 只採 %(HEAD) 為 * 的那一列（目前分支）。CUR_MARK 在引號內，* 是字面字元不是萬用字元；
    # 其他指向同一個 HEAD 的分支列以空白開頭，不會被採用。沒有 * 列就是 detached（見下）。
    cur=""; nstar=0; fmt_ok=1
    if [ -n "$refs" ]; then
      while IFS= read -r line; do
        case "$line" in
          "$CUR_MARK"*) cur="$line"; nstar=$((nstar + 1)) ;;
          " $US"*) ;;
          *) fmt_ok=0 ;;   # 設定值裡的換行接出來的續行（R-A）
        esac
      done <<<"$refs"
    fi
    if [ "$nstar" -gt 1 ]; then fmt_ok=0; fi
    if [ "$nstar" = 1 ] && [ "${cur//[!$US]/}" != "$REF_SEPS" ]; then fmt_ok=0; fi
    if [ "$fmt_ok" = 0 ]; then
      head_sha="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" || continue
      state=unknown
    elif [ -n "$cur" ]; then
      IFS="$US" read -r _hmark head_sha ref up ups urem track <<<"$cur"
      branch="${ref#refs/heads/}"
      ahead=0; behind=0; track_ok=1
      case "$track" in
        '') ;;
        gone) up="" ;;
        'ahead '*', behind '*) ahead="${track#ahead }"; ahead="${ahead%%,*}"; behind="${track##*behind }" ;;
        'ahead '*) ahead="${track#ahead }" ;;
        'behind '*) behind="${track#behind }" ;;
        *) track_ok=0 ;;
      esac
      case "$ahead"  in ''|*[!0-9]*) track_ok=0 ;; esac
      case "$behind" in ''|*[!0-9]*) track_ok=0 ;; esac
      if [ "$track_ok" = 0 ]; then state=unknown
      elif [ -n "$up" ]; then state=up
      else state=noup; fi
    else
      # 沒有 * 列＝detached HEAD（目前分支一定指向 HEAD，一定會被列出）。
      head_sha="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" || continue
      branch="<detached>"; state=noup
    fi
  else
    # for-each-ref 失敗。HEAD 解析不了（空 repo、orphan 分支）時 --points-at HEAD 必然失敗，
    # 那沒有東西會遺失——與舊版 rev-list、rev-parse HEAD 都失敗而 continue 相同。
    # HEAD 解析得了卻失敗（例如 git 太舊、不認得欄位）就不可靜默：state=unknown 轉 ask。
    head_sha="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" || continue
  fi
  [ -n "$head_sha" ] || continue
  if [ "$state" = up ]; then
    [ "$ahead" -gt 0 ] || continue
    stamp_seen && continue
    cmp_ref='@{u}'   # 列 commit 用的比較基準；用 ref 本身，不用顯示用的短名稱
    upstream="${ups:-<upstream>}"
    # 遠端與上游分支要從分支設定讀，不可從 "origin/main" 這個字串用第一個 `/` 拆（codex 第二輪
    # Required）：遠端名稱本身可以含 `/`，`team/origin` 與 `team` 可以同時存在，拆錯就會推到
    # 另一個 repository。讀不到、或上游是本地分支（remote 為 "."），一律當成不明確。
    # urem 由上面的 for-each-ref 一併取得（＝branch.<b>.remote 設定）；umerge 在下面另讀。
    # 【merge 改用 config --get 重讀】(五軸審查 R1、codex 第一輪 Required): %(upstream:remoteref)
    # 取多值的第一個，舊版的 `git config --get` 取最後一個（含空值）；不同值會讓原本 ask 的分支
    # （上游名稱不同＋共用分支名稱、或 merge 為空）變成 auto。不可用 --get-all 自己取末行：
    # 命令替換會把尾端的空值連同換行一起吃掉。只在已確定要示警的 repo 上多問這一次。
    # 不另外剝 \r（codex 第五輪）：舊版就是原樣的命令替換結果；多剝一個 \r 會讓結尾帶 CR 的
    # merge 值變成與分支同名，把原本要問的共用分支推送放進 auto 桶。
    umerge="$(git -C "$top" config --get "branch.$branch.merge" 2>/dev/null)"
    ubranch="${umerge#refs/heads/}"
    if [ -z "$branch" ] || [ -z "$urem" ] || [ "$urem" = . ] || [ -z "$umerge" ] || [ "$ubranch" = "$umerge" ]; then
      urem='<upstream>'; ubranch='<upstream>'; upstream='<upstream>'
    fi
    ntop_chk="$top"; [ "$WINPATH" = 1 ] && ntop_chk="${top//\\//}"
    has_write=0; case "$writable" in *"|$ntop_chk|"*) has_write=1 ;; esac
    if [ -n "$branch" ] && [ "$upstream" != '<upstream>' ] && [ "$branch" != "$ubranch" ]; then
      # 【上游名稱與本地分支不同】(2026-10-07): `git worktree add -b feat/x origin/main` 或
      # `git checkout -b feat/x origin/main` 會自動把起點設成上游，於是 feat/x 的上游是
      # origin/main。這不代表要推到 main——目的地是遠端同名的 feat/x。舊版把它當成一般的
      # 「領先上游」並指示「推上去」：裸打 `git push` 在 push.default=simple 下會被 git 拒絕，
      # 但 push.default=upstream 的 repo 會直接推進 main。所以這裡一律給出明確的推送指令。
      if is_shared_branch "$top" "$urem" "$branch"; then
        bucket=ask
        reason="分支 $branch 的上游是 $upstream（名稱不同），而 $branch 本身是共用分支名稱——推去哪要使用者決定"
      elif git -C "$top" rev-parse -q --verify "refs/remotes/$urem/$branch" >/dev/null 2>&1; then
        # 遠端已有同名分支：快轉與否要對它判斷，不是對起點分支。用完整 ref——短名稱
        # "origin/feat/x" 在本地另有同名分支時會解析到本地分支（codex 第三輪 Optional）。
        cmp_ref="refs/remotes/$urem/$branch"
        lr2="$(git -C "$top" rev-list --left-right --count "$cmp_ref...HEAD" 2>/dev/null)"
        behind="${lr2%%[	 ]*}"; ahead="${lr2##*[	 ]}"
        case "$ahead"  in ''|*[!0-9]*) ahead=0 ;; esac
        case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
        [ "$ahead" -gt 0 ] || continue   # 遠端同名分支已涵蓋 HEAD，沒有東西會遺失
        upstream="$urem/$branch"
        if [ "$behind" -gt 0 ]; then
          bucket=ask
          reason="領先 $upstream $ahead 筆未推送，但也落後 $behind 筆（非 fast-forward，要先整合）"
        else
          bucket=auto
          reason="feature 分支 $branch 領先遠端同名分支 $upstream $ahead 筆未推送"
          pr_remote="$urem"; pr_branch="$branch"; pr_u=u
        fi
      else
        bucket=auto
        reason="feature 分支 $branch 從 $upstream 切出、遠端還沒有同名分支，領先 $ahead 筆未推送"
        pr_remote="$urem"; pr_branch="$branch"; pr_u=u
      fi
      [ "$bucket" = auto ] && [ "$has_write" = 0 ] && reason="$reason$NOTE_NO_WRITE"
    elif [ "$behind" -gt 0 ]; then
      reason="領先 $upstream $ahead 筆未推送，但也落後 $behind 筆（非 fast-forward，要先整合）"
      bucket=ask
    elif [ "$upstream" != '<upstream>' ] && ! is_shared_branch "$top" "$urem" "$ubranch"; then
      # 已用 -u 推過的 feature 分支：目的地就是它的上游，快轉，照推。
      bucket=auto
      reason="feature 分支 $ubranch 領先 $upstream $ahead 筆未推送"
      pr_remote="$urem"; pr_branch="$ubranch"; pr_u=""
      [ "$has_write" = 0 ] && reason="$reason$NOTE_NO_WRITE"
    else
      pr_remote="$urem"; pr_branch="$ubranch"; pr_u=""
      reason="領先 $upstream $ahead 筆未推送"
      # 【auto 桶要求本 session 有寫入證據】(複查抓到): 範圍收集刻意寬鬆（連 Read 過的
      # repo 都納入，多報方向安全），但【授權】不能跟著寬鬆——push 是這條路徑上唯一
      # 不可逆的動作。只讀過就自動推，等於把使用者自己留在那個 repo 的 WIP commit
      # 推出去，而那筆 commit 根本不是這次工作產生的。
      case "$writable" in
        *"|$ntop_chk|"*)
          # 【清單截斷就不能授權】(codex 第三輪抓到): 下面只列最近 3 筆，而指示要執行者
          # 「依列出的 commit 確認是本次工作」。若總數超過 3，更早的（可能是使用者自己的
          # WIP）會被截掉而看不見，push 卻是整批一起推——指示要求確認的東西，資料沒給全。
          # 與其把清單無上限印出來（一次 50 筆沒人會逐筆看），不如轉 ask：
          # 一輪工作累積超過 3 筆未推 commit，本來就值得人看一眼。
          if [ "$ahead" -gt 3 ]; then
            bucket=ask
            reason="$reason（超過 3 筆，下方只列得出最近 3 筆——無法逐筆確認是否都屬於本次工作）"
          else
            bucket=auto
          fi ;;
        *) bucket=ask
           reason="$reason（本 session 只讀取過這個 repo，沒有寫入證據——這些 commit 可能不是這次工作產生的）" ;;
      esac
    fi
  elif [ "$state" = noup ]; then
    # 沒有上游追蹤。空 repo（尚無 commit）在上面已經 continue，那沒有東西會遺失。
    stamp_seen && continue
    bucket=ask
    upstream=""
    # 「沒有上游」不等於「沒有遠端備份」：從 origin/main 切出、尚未新增 commit
    # 的本地分支，所有 commit 都已在遠端。所以再問一次「HEAD 是否被任何
    # remote-tracking ref 涵蓋」，據此分成兩種嚴重度不同的說法，不要一律當成
    # 最壞情況——狼來了的警告會被忽略，那等於沒有警告。
    # for-each-ref --count=1 等同舊版的 `branch -r --contains HEAD | head -1`，少一個 head 子行程。
    if [ -n "$(git -C "$top" for-each-ref --count=1 --contains HEAD --format=x refs/remotes/ 2>/dev/null)" ]; then
      reason="分支 $branch 沒有上游追蹤（HEAD 已被某個 remote-tracking ref 涵蓋，尚可確認有備份）"
    else
      reason="分支 $branch 沒有上游追蹤，且 HEAD 不在任何 remote-tracking ref 內（無遠端備份）"
      # 【目的地其實明確的情況】(2026-10-07): 只有一個遠端、在具名的 feature 分支上、遠端還沒有
      # 同名分支——推去哪只有一種合理答案，就是 `push -u <唯一遠端> <分支>`。沒有遠端、多個遠端、
      # detached HEAD、共用分支名稱，或遠端已有同名分支（要先判斷快轉）都維持 ask。
      remotes="$(git -C "$top" remote 2>/dev/null)"; remotes="${remotes//$'\r'/}"
      case "$remotes" in
        ''|*$'\n'*) ;;   # 零個或多個遠端
        *)
          if [ "$branch" != "<detached>" ] && ! is_shared_branch "$top" "$remotes" "$branch" \
             && ! git -C "$top" rev-parse -q --verify "refs/remotes/$remotes/$branch" >/dev/null 2>&1; then
            bucket=auto
            reason="feature 分支 $branch 沒有上游追蹤、尚無遠端備份，唯一的遠端是 $remotes"
            pr_remote="$remotes"; pr_branch="$branch"; pr_u=u
            ntop_chk="$top"; [ "$WINPATH" = 1 ] && ntop_chk="${top//\\//}"
            case "$writable" in *"|$ntop_chk|"*) ;; *) reason="$reason$NOTE_NO_WRITE" ;; esac
          fi ;;
      esac
    fi
  else
    # 讀不到分支狀態，但 HEAD 存在（有東西可能遺失）：不可當成「乾淨」靜默放過（fail-closed）。
    stamp_seen && continue
    bucket=ask; upstream=""
    reason="無法判定分支與上游狀態（git for-each-ref 失敗或輸出無法辨識），請手動確認是否已推送"
  fi
  # 推送指令在這裡統一組出：固定遠端＋完整 refspec，參數跳脫；名稱不安全就不給指令、轉 ask。
  if [ "$bucket" = auto ]; then
    if [ "$pr_remote" = '<upstream>' ]; then
      bucket=ask; reason="$reason（無法從分支設定確認遠端與上游分支，不提供自動推送指令）"
    elif safe_ref "$pr_remote" "$pr_branch"; then
      push_cmd="$(mk_push_cmd "$top" "$pr_remote" "$pr_branch" "$pr_u")"
    else
      bucket=ask; reason="$reason$NOTE_UNSAFE"
    fi
  fi
  # 同一 (session, repo, HEAD) 只提醒一次，避免 Stop 迴圈。標記有沒有存在，上面各分支一取得
  # HEAD 就先查過（stamp_seen 同時算好 $stamp）；這裡只在確定要示警時寫入，位置與舊版相同。
  # mkdir 失敗就不寫（同舊版）；寫檔包在 { } 裡，重導向失敗的訊息才會被 2>/dev/null 收掉——
  # Codex 轉接層看到 stderr 非空就丟掉整份發現（最終版複查 O-1）。
  { [ -d "${stamp%/*}" ] || mkdir -p "${stamp%/*}"; } 2>/dev/null && { : > "$stamp"; } 2>/dev/null

  # 帶上相對時間: 判斷「這些 commit 是不是本次工作做的」最直接的線索就是它有多舊。
  # hook 自己不做這個判斷——它沒有「本次工作是什麼」的上下文，而讀到這段訊息的一方有。
  # 分層是刻意的: hook 做機械過濾（有無上游 / 是否 fast-forward / 本 session 有無寫入），
  # commit 歸屬這種語意判斷留給執行者。往 hook 裡再堆推斷（比對 session 起始時間、
  # 配對 tool_result 確認寫入成功）只會擴大誤判面，而誤判的代價是不可逆的對外推送。
  # -n 3 而不是 `| head -3`：沒有上游時範圍是整條歷史，舊版要等 git log 印完（或被 SIGPIPE）
  # 才結束，實測最長 601ms；輸出與取前三行相同。
  subjects="$(git -C "$top" log -n 3 --format='      %h %ad %s' --date=relative \
                ${cmp_ref:+"$cmp_ref"..}HEAD 2>/dev/null)"
  # 未提交數只是給讀者的參考，不影響分桶。不掃未追蹤檔（2026-11-23 量測）：worktree 上
  # `git status --porcelain` 單次 0.45～2.15 秒，是逐 repo 迴圈裡最大的尖峰；訊息裡註明口徑。
  # 計數用 mapfile（內建）而不是 wc -l：省子行程，且狀態讀不到時維持 0。
  dirty=0
  if st="$(git -C "$top" status --porcelain --untracked-files=no 2>/dev/null)" && [ -n "$st" ]; then
    mapfile -t st_lines <<<"$st"; dirty=${#st_lines[@]}
  fi
  entry="
  - $top
      $reason；未提交變更 $dirty 筆（不含未追蹤檔）
$subjects"
  # auto 桶附上確切的推送指令：上游名稱可能與分支不同（見上方），讓執行者自己組指令就有推錯目標的機會。
  [ "$bucket" = auto ] && [ -n "$push_cmd" ] && entry="$entry
      推送指令：$push_cmd"
  # 分兩桶輸出。理由是「該不該停下來問人」在這兩類之間差很多，混在一起講會讓
  # 真正需要決定的那幾筆被例行項目淹沒——同樣是「範圍不對的警告會被忽略」那條。
  if [ "$bucket" = auto ]; then auto_findings="$auto_findings$entry"
  else ask_findings="$ask_findings$entry"; fi
  findings="$findings$entry"
# 用 heredoc 餵入而不是 `... | while`：管線會讓迴圈跑在子行程裡，
# $findings 累積的結果出不來，最後永遠是空的（＝靜默漏報）。
# sort 不加 -u：add_repo 已逐字去重；UTF-8 locale 的 sort -u 會把排序上相等的不同路徑
# 併成一筆而少檢查一個 repo（最終版複查 O-2）。不加 LC_ALL=C 是為了維持舊版的輸出順序。
done <<EOF
$(printf '%s\n' ${repo_list+"${repo_list[@]}"} | sort)
EOF

[ -n "$findings" ] || exit 0

# 指示分兩段（2026-09-08 使用者裁定）：舊版一律要求「不要自行 push、交由使用者決定」，
# 於是每次收工都變成一輪來回確認，而其中絕大多數是例行的推送。現在依「有沒有上游、
# 是不是 fast-forward」分流——那是 hook 在不連線的前提下唯一能可靠判定的東西。
# 刻意**不**去分辨遠端是 public 還是 private：那需要打 GitHub API，會帶來網路往返、
# 憑證提示與 rate limit，違反本 hook「不做 fetch」的成本前提（使用者已知並接受
# 公開 repo 也會落在自動那一類）。
"$JQ" -cn --arg auto "$auto_findings" --arg ask "$ask_findings" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: (
      "[git-guard] 偵測到已 commit 但尚未推送到遠端的工作。\n\n" +
      (if ($auto | length) > 0 then
        "【可自行處理，不需要開一輪確認】fast-forward、目的地明確：" + $auto + "\n\n" +
        "  一律照每筆列出的「推送指令」推，不要改打裸的 `git push`——上游名稱可能與分支不同\n" +
        "  （feature 分支的上游常是 origin/main），裸指令有推進錯誤分支的機會。\n" +
        "  推送目標是 feature 分支 → 直接推（2026-10-07 使用者裁定，不必確認 commit 歸屬），\n" +
        "  用一兩句回報推了什麼；需要的話接著開 PR。\n" +
        "  推送目標是共用分支（main 等）→ 先看一眼上面列出的 commit 主旨與時間，確認是\n" +
        "  【本 session 做的】再推：hook 只能證明「這個 repo 被本 session 寫過」，證明不了\n" +
        "  「這些 commit 是本次工作產生的」。認不出來、或混著更早的 commit → 別推，列給使用者。\n" +
        "  push 被拒或出現非預期輸出 → 停下來照實回報，不要重試或改用 force。\n\n"
       else "" end) +
      (if ($ask | length) > 0 then
        "【要你先問使用者】目的地不明確、落後遠端（非 fast-forward），或推共用分支但授權條件不足：" + $ask + "\n\n" +
        "  這幾筆不要自行推送。目的地不明確（沒有遠端、多個遠端、detached HEAD、共用分支名稱）\n" +
        "  代表推去哪要人決定；落後遠端代表要先整合，而整合方式（rebase／merge）是使用者的決定；\n" +
        "  推共用分支但本 session 沒寫入過或超過 3 筆，代表無法確認那些 commit 屬於本次工作。\n" +
        "  列出來並提議處置。\n\n"
       else "" end) +
      "判定只比對本機的 remote-tracking ref、不做 fetch：一般過期只會多報；\n" +
      "但遠端若被 force-push 或刪除，本檢查會漏報（已知盲點，非全稱保證）。\n" +
      "臨時目錄（scratchpad／TMPDIR／AppData\\Local\\Temp）底下的 repo 一律不列入。\n" +
      "同一個 commit 狀態在本 session 只提醒一次；有新 commit 才會再提醒。"
    )
  }
}'
exit 0
