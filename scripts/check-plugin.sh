#!/usr/bin/env bash
# check-plugin.sh — eng-flow plugin 的自我一致性檢查（唯讀，不改任何檔案；hermetic，
# 只讀 plugin 根目錄之下的檔案，不碰 ~/.claude 等外部設定）。
#
# 為什麼要有這支：這個 plugin 有幾組「同一件事寫在好幾個地方」的事實——tier 的
# model/effort 同時出現在 agent frontmatter、description、三份文件的表格與派工範例；
# hooks.json、hooks/*.sh、tests/ 三者要互相對得上；文件裡指向檔案的路徑會隨檔案搬動
# 而過時。這些在改的當下都看起來「只是改一個地方」，漏掉的那一處不會報錯，只會讓某天的
# 派工悄悄走錯檔位（Agent tool 沒有 effort 參數，寫錯的下場是繼承 session 的 high）。
# 一條什麼都沒比對到的檢查和「通過」外表一模一樣，所以每條檢查在 tests/check-plugin.test.sh
# 都有一個會讓它失敗的 fixture。
#
# 用法：
#   bash scripts/check-plugin.sh                 對工作樹跑檢查 1～4
#   bash scripts/check-plugin.sh --pre-push [<remote> [<url>]]
#                                                給 git pre-push hook（git 會把 remote 名稱與 url 放在 $1 $2，
#                                                githooks/pre-push 原樣轉交）。對每個被推送的 commit
#                                                （不是工作樹）跑檢查 1～4，再核對推往 refs/heads/main 的 ref
#                                                有沒有把版本嚴格調大。
#                                                stdin 為 <local ref> <local sha> <remote ref> <remote sha>
#   --root DIR                                   指定 plugin 根目錄（預設：本檔所在目錄的上一層）
#
# 離開碼：0 全過；1 發現問題（印 file:line 與規則）；2 環境不足或無法判斷
#   （缺 jq/awk/git、根目錄不對、pre-push 求不出比較基準）。一律 fail-closed，不會 SKIP 後回 0。
#
# 檢查項（括號內是輸出裡的規則 id）：
#   1. tier 一致性：唯一來源是 agents/tier-*.md frontmatter 的 model:／effort:。
#      (tier-frontmatter) frontmatter 缺 model 或 effort
#      (tier-desc)        同檔 description 括號裡的「（sonnet + effort xhigh）」與 frontmatter 不符
#      (tier-line)        skills/ references/ agents/ 裡，同一組寫法（以 + 或 , 相連的
#                         eng-flow:tier-X / model:V / effort:V，順序不限）的值與該 tier 不符
#      (tier-table)       表格列首格為 **B1**／**B2**／**C** 時，第 2、3 格要等於該 tier 的 model、effort
#      (tier-unknown)     引用了不存在的 eng-flow:tier-X
#   2. 派工寫法 lint（skills/ references/ agents/）：
#      (dispatch-model)   model 值為 sonnet／haiku 時，同一行必須有 eng-flow:tier-
#      (dispatch-prefix)  subagent_type／agentType 的值是 tier 名稱時必須帶 eng-flow: 前綴
#      文件刻意舉的反例，在同一行行尾加放行標記：<!-- check-plugin: allow dispatch -->
#   3. hooks：(hooks-json) (hooks-missing) (hooks-unregistered) (hooks-no-test)
#   4. 散文路徑：(prose-path) 反引號內以 scripts/ hooks/ references/ skills/ agents/ tests/
#      templates/ 開頭的相對路徑必須存在於根目錄之下；不含 fenced code block。
#      指的是使用者專案裡的路徑時，在同一行行尾加：<!-- check-plugin: allow path -->
#   5. --pre-push：(version-bump) 推往 refs/heads/main 的範圍內動到 plugin 內容，version 卻沒有嚴格變大
#      （不變或降版都拒絕）。
#      --pre-push 的檢查 1～4 對象是「被推送的 commit」：每個 sha 用 git archive 解到暫存目錄，再以本腳本
#      --root 檢查那棵樹，輸出以 <sha7>: 開頭。不看工作樹——工作樹與被推送的內容常常不同（git push
#      origin side:main、修正只留在工作樹、工作樹有未提交的半成品），看工作樹會在兩個方向都出錯。
#      推非 main 的 ref（分支、tag）也一樣檢查被推送的 commit；刪除 ref 沒有東西可檢查。
set -u
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
SELF="$SELF_DIR/${BASH_SOURCE[0]##*/}"     # 絕對路徑：--pre-push 會對解出來的樹再叫自己一次，而那時已 cd 走了
ROOT="$(cd "$SELF_DIR/.." && pwd)" || exit 2
JQ="${CHECK_PLUGIN_JQ:-jq}"        # 測試用：指向不存在的指令即可模擬「環境缺 jq」
GIT="${CHECK_PLUGIN_GIT:-git}"     # 測試用：指向會讓特定子指令失敗的包裝程式，驗證 fail-closed 分支
TAR="${CHECK_PLUGIN_TAR:-tar}"     # 同上（解開 git archive 的輸出）
MODE=check

# 不需要測試檔、也不需要註冊的 hooks 輔助檔（lib）。明文清單，不放寬規則。
HOOK_LIBS="iso-secret-lib.sh"

# 需要 bump version 的 plugin 內容（相對根目錄）。tests/、README.md、.gitattributes、
# githooks/、dist/ 不在其中：改那些不影響安裝 plugin 的人拿到的行為。
CONTENT_PATHS="skills hooks agents scripts references templates .claude-plugin"

MARK_DISPATCH='<!-- check-plugin: allow dispatch -->'
MARK_PATH='<!-- check-plugin: allow path -->'

FOUND=0
ENV_ERR=0

die_env() { echo "check-plugin: 環境不足：$*" >&2; exit 2; }
soft_env() { echo "check-plugin: 無法判斷（fail-closed）：$*" >&2; ENV_ERR=1; }
bad() { # bad <file> <line> <rule> <msg>
  printf '%s:%s: [%s] %s\n' "$1" "$2" "$3" "$4" >&2
  FOUND=$((FOUND + 1))
}
emit() { # emit <awk 輸出的多行 findings>（格式已是 file:line: [rule] msg）
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" >&2
  FOUND=$((FOUND + $(printf '%s\n' "$1" | grep -c '')))
}
usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//' >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pre-push) MODE=prepush ;;
    --root) shift; [ $# -gt 0 ] || die_env "--root 需要一個目錄"; ROOT="$(cd "$1" 2>/dev/null && pwd)" || die_env "--root 目錄不存在：$1" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-plugin: 不認得的參數：$1（用 --help 看用法）" >&2; exit 2 ;;
  esac
  shift
done

# ---------- 環境（fail-closed）----------
command -v "$JQ" >/dev/null 2>&1 || die_env "找不到 jq（$JQ）；hooks.json 與版本比對都靠它，沒有就不能宣稱通過"
"$JQ" -n '1' >/dev/null 2>&1 || die_env "jq 無法執行（$JQ）"
for t in awk grep sed find sort; do
  command -v "$t" >/dev/null 2>&1 || die_env "找不到 $t"
done
if [ "$MODE" = prepush ]; then
  command -v "$GIT" >/dev/null 2>&1 || die_env "找不到 git（$GIT）；--pre-push 需要它"
  command -v "$TAR" >/dev/null 2>&1 || die_env "找不到 tar（$TAR）；--pre-push 要把被推送的 commit 解開來檢查"
  command -v mktemp >/dev/null 2>&1 || die_env "找不到 mktemp"
fi
cd "$ROOT" || die_env "無法進入根目錄 $ROOT"

finish() { # 依 ENV_ERR／FOUND 收尾並離開
  if [ "$ENV_ERR" = 1 ]; then
    echo "check-plugin: 有無法判斷的項目（fail-closed，離開碼 2）" >&2
    exit 2
  fi
  if [ "$FOUND" -gt 0 ]; then
    echo "check-plugin: $FOUND 個問題" >&2
    exit 1
  fi
  if [ "$MODE" = prepush ]; then
    if [ "$PUSHED_CHECKED" -eq 0 ]; then
      echo "check-plugin: OK（沒有需要檢查的 commit：stdin 沒有 ref，或只有刪除）"
    else
      echo "check-plugin: OK（被推送的 commit 的 tier 一致性、派工寫法、hooks、散文路徑、版本核對）"
    fi
  else
    echo "check-plugin: OK（tier 一致性、派工寫法、hooks、散文路徑）"
  fi
  exit 0
}

# =====================================================================
# --pre-push：檢查「被推送的 commit」（規則 5 與規則 1～4 的 commit 版）
# =====================================================================
is_zero() { case "$1" in ''|*[!0]*) return 1 ;; *) return 0 ;; esac; }
is_sha()  { case "$1" in ''|*[!0-9a-f]*) return 1 ;; *) [ "${#1}" -ge 40 ] ;; esac; }
plugin_version() { # plugin_version <commit> → 印 version；讀不到就回非 0
  local j v
  # 兩段各自檢查離開碼（不接管線，理由同下方 git diff）。
  j="$("$GIT" show "$1:.claude-plugin/plugin.json" 2>/dev/null)" || return 1
  v="$("$JQ" -r '.version // empty' <<<"$j" 2>/dev/null)" || return 1
  v="${v%$'\r'}"                                          # 本機 jq 輸出 CRLF
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# ver_cmp <a> <b> → 設 VCMP 為 -1／0／1（a 小於／等於／大於 b）；格式不是純數字點分就回 1。
# 不用 sort -V（BSD sort 沒有，且對 1.0.2 與 1.0.10 以外的怪格式行為不一）；逐段當十進位整數比，缺的段當 0，
# 所以 1.0.2 與 1.0.2.0 相等。每段限 9 位數以內，避免 bash 算術溢位後比出錯誤的大小。
ver_cmp() {
  local a="$1" b="$2" i n x y
  local -a va vb
  [[ "$a" =~ ^[0-9]+([.][0-9]+)*$ ]] && [[ "$b" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  IFS=. read -r -a va <<<"$a"
  IFS=. read -r -a vb <<<"$b"
  n=${#va[@]}; [ "${#vb[@]}" -le "$n" ] || n=${#vb[@]}
  for ((i = 0; i < n; i++)); do
    x="${va[i]:-0}"; y="${vb[i]:-0}"
    if [ "${#x}" -gt 9 ] || [ "${#y}" -gt 9 ]; then return 1; fi
    x=$((10#$x)); y=$((10#$y))
    if [ "$x" -gt "$y" ]; then VCMP=1; return 0; fi
    if [ "$x" -lt "$y" ]; then VCMP=-1; return 0; fi
  done
  VCMP=0
}

PUSHED_CHECKED=0
CHECKED=" "
# 把 sha 的內容用 git archive 解到暫存目錄，再以本腳本 --root 檢查那棵樹（檢查 1～4）。
# 為什麼不直接檢查工作樹：被推送的內容常常不是工作樹——git push origin side:main、壞內容已 commit
# 而修正只留在工作樹、工作樹有未提交的半成品；看工作樹在兩個方向都會判錯。
# 不接管線：git archive 先寫成檔案再解開，兩段各自檢查離開碼，失敗一律 fail-closed。
check_pushed_tree() { # check_pushed_tree <sha>
  local sha="$1" s7="${1:0:7}" td out rc l n=0
  case "$CHECKED" in *" $sha "*) return 0 ;; esac        # 同一個 sha 推到多個 ref，只檢查一次
  CHECKED="$CHECKED$sha "
  PUSHED_CHECKED=$((PUSHED_CHECKED + 1))
  td="$(mktemp -d 2>/dev/null)" && [ -n "$td" ] && [ -d "$td" ] || { soft_env "mktemp -d 失敗，無法檢查 $s7 的內容"; return 0; }
  if ! "$GIT" archive --format=tar -o "$td/pushed.tar" "$sha" 2>/dev/null; then
    rm -rf "${td:?}"; soft_env "git archive $sha 失敗，無法檢查被推送的內容"; return 0
  fi
  if ! mkdir "$td/tree" || ! "$TAR" -x -C "$td/tree" <"$td/pushed.tar" 2>/dev/null; then
    rm -rf "${td:?}"; soft_env "解開 $s7 的內容失敗（$TAR）"; return 0
  fi
  out="$(bash "$SELF" --root "$td/tree" 2>&1 </dev/null)"; rc=$?
  rm -rf "${td:?}"
  case "$rc" in
    0) ;;
    1)
      while IFS= read -r l; do
        printf '%s:%s\n' "$s7" "$l" >&2
        case "$l" in check-plugin:*) ;; *) n=$((n + 1)) ;; esac
      done <<<"$out"
      [ "$n" -gt 0 ] || n=1
      FOUND=$((FOUND + n))
      ;;
    *)
      while IFS= read -r l; do printf '%s:%s\n' "$s7" "$l" >&2; done <<<"$out"
      soft_env "被推送的 $s7 無法判斷（對它跑檢查的離開碼是 $rc）"
      ;;
  esac
  return 0
}

pre_push() {
  local input line lref lsha rref rsha extra base changed bv lv shown
  input="$(cat)" || { soft_env "讀不到 pre-push 的 stdin"; return 0; }
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    extra=""
    read -r lref lsha rref rsha extra <<<"$line"
    if [ -z "$rsha" ] || [ -n "$extra" ]; then soft_env "pre-push stdin 的格式不是 4 欄：$line"; continue; fi
    if is_zero "$lsha"; then continue; fi                    # 刪除 ref：沒有被推送的內容
    if ! is_sha "$lsha"; then soft_env "local sha 不是合法的 sha：$lsha"; continue; fi
    if ! "$GIT" cat-file -e "${lsha}^{commit}" 2>/dev/null; then soft_env "local sha $lsha 不在本機物件庫"; continue; fi
    check_pushed_tree "$lsha"                                # 不論推到哪個 ref，檢查對象都是被推送的 commit
    [ "$rref" = "refs/heads/main" ] || continue              # 版本核對只管 main
    if is_zero "$rsha"; then
      # 新建遠端 main：以 refs/remotes/origin/main 求比較基準，求不出來就拒絕（不猜）
      if ! base="$("$GIT" merge-base "$lsha" refs/remotes/origin/main 2>/dev/null)" || [ -z "$base" ]; then
        soft_env "refs/heads/main 是新建的遠端 ref，但求不出 $lsha 對 refs/remotes/origin/main 的比較基準；先 git fetch origin 再推"
        continue
      fi
    else
      if ! is_sha "$rsha" || ! "$GIT" cat-file -e "${rsha}^{commit}" 2>/dev/null; then
        soft_env "remote sha $rsha 不在本機物件庫，無法比較版本；先 git fetch 再推"
        continue
      fi
      base="$rsha"
    fi
    # 不接管線：管線的離開碼是最後一段的，`git diff | tr` 會把 git 的失敗吞掉、changed 變空字串而被當成
    # 「沒動到 plugin 內容」放行（fail-open）。也不用 -z：bash 變數放不了 NUL，這裡只需要知道有沒有變動與列前幾個檔名。
    if ! changed="$("$GIT" diff --name-only --no-renames "$base" "$lsha" -- $CONTENT_PATHS 2>/dev/null)"; then
      soft_env "git diff $base $lsha 失敗"; continue
    fi
    [ -n "$changed" ] || continue                            # 只動 tests/、README.md、.gitattributes 等：不需要 bump
    if ! bv="$(plugin_version "$base")"; then soft_env "讀不到 $base 的 .claude-plugin/plugin.json version"; continue; fi
    if ! lv="$(plugin_version "$lsha")"; then soft_env "讀不到 $lsha 的 .claude-plugin/plugin.json version"; continue; fi
    # version 要「嚴格變大」：不變或降版都拒絕（降版會讓已安裝新版的人拿不到更新）
    shown="$(printf '%s\n' "$changed" | head -n 5 | tr '\n' ' ')"
    if [ "$bv" = "$lv" ]; then
      bad .claude-plugin/plugin.json 1 version-bump "推往 refs/heads/main 的 ${base:0:7}..${lsha:0:7} 動到 plugin 內容（$(printf '%s\n' "$changed" | grep -c '') 個檔：${shown% }），但 version 仍是 $lv，請先 bump"
    elif ! ver_cmp "$lv" "$bv"; then
      soft_env "version 從「$bv」變成「$lv」，格式不是純數字點分（如 1.2.3），無法判斷是不是變大；改成純數字點分，或先 bump 成可比較的版本"
    elif [ "$VCMP" -lt 0 ]; then
      bad .claude-plugin/plugin.json 1 version-bump "推往 refs/heads/main 的 ${base:0:7}..${lsha:0:7} 動到 plugin 內容（${shown% }），但 version 從 $bv 降到 $lv，必須嚴格變大"
    elif [ "$VCMP" -eq 0 ]; then
      bad .claude-plugin/plugin.json 1 version-bump "推往 refs/heads/main 的 ${base:0:7}..${lsha:0:7} 動到 plugin 內容（${shown% }），但 version 從 $bv 變成 $lv，數值相同，必須嚴格變大"
    fi
  done <<<"$input"
}

if [ "$MODE" = prepush ]; then
  pre_push
  finish
fi

# 待掃描的文件：skills/ references/ agents/ 下的 .md（規則 1、2、4）；規則 4 另加 README.md。
DOCS=()
for d in skills references agents; do
  [ -d "$d" ] || continue
  # find 的失敗不能被後面的 sort 吞掉（少掃檔案卻照樣通過是 fail-open），所以先收進變數檢查離開碼再排序
  fl="$(find "$d" -type f -name '*.md')" || die_env "find $d 失敗"
  [ -n "$fl" ] || continue
  while IFS= read -r f; do DOCS+=("$f"); done < <(sort <<<"$fl")
done
[ "${#DOCS[@]}" -gt 0 ] || die_env "在 $ROOT 底下找不到任何 skills/ references/ agents/ 的 .md（根目錄不對？）——掃描零個檔案不能算通過"
PROSE=("${DOCS[@]}")
[ -f README.md ] && PROSE+=(README.md)

# ---------- awk 程式（獨立成變數；用 quoted heredoc，反斜線與引號原樣保留）----------
# 解析 agent frontmatter：輸出 model|model行|effort|effort行|description行|desc裡的model|desc裡的effort
IFS= read -r -d '' AWK_FRONTMATTER <<'AWK' || true
{ sub(/\r$/, "") }
FNR == 1 { if ($0 != "---") exit; infm = 1; next }
infm && $0 == "---" { exit }
infm && /^model:/ && !ml { v = $0; sub(/^model:[ ]*/, "", v); gsub(/["' ]/, "", v); model = v; ml = FNR }
infm && /^effort:/ && !el { v = $0; sub(/^effort:[ ]*/, "", v); gsub(/["' ]/, "", v); effort = v; el = FNR }
infm && /^description:/ && !dl {
  dl = FNR
  # 括號可能是全形（　）或半形；用 alternation 而不是 bracket，byte 模式下才不會把三個 byte 當成三個字元
  if (match($0, /(（|[(])[a-z0-9.-]+ [+] effort [a-z]+(）|[)])/)) {
    s = substr($0, RSTART, RLENGTH)
    sub(/^(（|[(])/, "", s); sub(/(）|[)])$/, "", s)
    split(s, p, " [+] effort ")
    dmodel = p[1]; deffort = p[2]
  }
}
END { printf "%s|%d|%s|%d|%d|%s|%s\n", model, ml, effort, el, dl, dmodel, deffort }
AWK

# 規則 1（tier-line／tier-table／tier-unknown）與規則 2（dispatch-*）。
# 變數：TIERS="tier-b1:sonnet:xhigh;tier-b2:sonnet:medium;..."  MARK=放行標記
IFS= read -r -d '' AWK_DOCSCAN <<'AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function firstword(s) { if (match(s, /[a-z][a-z0-9]*/)) return substr(s, RSTART, RLENGTH); return "" }
function bad(rule, msg) { printf "%s:%d: [%s] %s\n", FILENAME, FNR, rule, msg }
function valof(t,   v) {
  v = t
  sub(/^[a-zA-Z_]+[ ]*[:=][ ]*["'`]?/, "", v)
  sub(/[._-]+$/, "", v)
  return v
}
# 把一行切成 token：T=eng-flow:tier-X（可帶 agentType:／subagent_type: 前綴）、M=model:V、E=effort:V
function tokenize(l,   rest, off, s, t, rs, rl, prev) {
  nt = 0; rest = l; off = 0
  while (match(rest, tokre)) {
    rs = RSTART; rl = RLENGTH
    t = substr(rest, rs, rl)
    s = off + rs
    prev = (s > 1) ? substr(l, s - 1, 1) : ""
    if (prev ~ /[A-Za-z0-9_-]/) { off += rs; rest = substr(rest, rs + 1); continue }   # 字的一部分（如 submodel:）
    nt++
    ts[nt] = s; te[nt] = s + rl - 1
    if (index(t, "eng-flow:tier-") > 0) { tt[nt] = "T"; tv[nt] = substr(t, index(t, "eng-flow:") + 9) }
    else if (t ~ /^model/)             { tt[nt] = "M"; tv[nt] = valof(t) }
    else                               { tt[nt] = "E"; tv[nt] = valof(t) }
    off += rs + rl - 1
    rest = substr(rest, rs + rl)
  }
}
BEGIN {
  n = split(TIERS, tl, ";")
  for (i = 1; i <= n; i++) {
    split(tl[i], f, ":")
    tmodel[f[1]] = f[2]; teffort[f[1]] = f[3]
    names = names (i > 1 ? "|" : "") f[1]
    bylabel[toupper(substr(f[1], 6))] = f[1]          # tier-b1 -> B1
  }
  keyt = "((agentType|subagent_type)[ ]*[:=][ ]*[\"'`]?)?"
  tokre = "(" keyt "eng-flow:tier-[a-z0-9]+|model[ ]*[:=][ ]*[\"'`]?[a-z0-9._-]+|effort[ ]*[:=][ ]*[\"'`]?[a-z0-9._-]+)"
  gapre = "^[ `'\"+,{}()]*$"                            # 同一組寫法的 token 之間只允許這些字元
  prefre = "(subagent_type|agentType)[ ]*[:=]?[ ]*[\"'`]?(" names ")([^a-z0-9-]|$)"
}
{
  line = $0
  sub(/\r$/, "", line)
  if (FNR == 1) infm = (line == "---" && index(FILENAME, "agents/") == 1) ? 1 : 0
  else if (infm && line == "---") infm = 0

  tokenize(line)

  for (i = 1; i <= nt; i++)
    if (tt[i] == "T" && !(tv[i] in tmodel))
      bad("tier-unknown", "引用了不存在的 tier agent「eng-flow:" tv[i] "」（agents/ 底下沒有對應檔）")

  # 規則 1：以 + 或 , 相連的 token 視為同一組寫法（run）；run 裡有 tier 時，model／effort 要與該 tier 一致。
  k = 1
  while (k <= nt) {
    j = k
    while (j < nt && substr(line, te[j] + 1, ts[j + 1] - te[j] - 1) ~ gapre) j++
    ntier = 0; tier1 = ""; nvals = 0
    for (m = k; m <= j; m++) {
      if (tt[m] == "T") { if (tier1 == "") { tier1 = tv[m]; ntier = 1 } else if (tv[m] != tier1) ntier++ }
      else nvals++
    }
    if (tier1 != "" && nvals > 0) {
      if (ntier > 1) bad("tier-line", "同一組寫法混了多個 tier，無法判斷 model／effort 屬於誰")
      else if (tier1 in tmodel) {
        for (m = k; m <= j; m++) {
          if (tt[m] == "M" && tv[m] != tmodel[tier1])
            bad("tier-line", tier1 " 的 model 寫成「" tv[m] "」，agents/" tier1 ".md frontmatter 是「" tmodel[tier1] "」")
          if (tt[m] == "E" && tv[m] != teffort[tier1])
            bad("tier-line", tier1 " 的 effort 寫成「" tv[m] "」，agents/" tier1 ".md frontmatter 是「" teffort[tier1] "」")
        }
      }
    }
    k = j + 1
  }

  # 規則 1：表格列首格為 **B1**／**B2**／**C** 時，第 2、3 格是 model、effort
  if (line ~ /^[ ]*[|]/) {
    nc = split(line, c, "|")
    lab = trim(c[2])
    if (lab ~ /^[*][*][A-Za-z0-9]+[*][*]$/) {
      L = toupper(substr(lab, 3, length(lab) - 4))
      if (L in bylabel) {
        tn = bylabel[L]
        if (firstword(c[3]) != tmodel[tn])
          bad("tier-table", "表格列 " lab " 的 model 欄是「" firstword(c[3]) "」，agents/" tn ".md frontmatter 是「" tmodel[tn] "」")
        if (firstword(c[4]) != teffort[tn])
          bad("tier-table", "表格列 " lab " 的 effort 欄是「" firstword(c[4]) "」，agents/" tn ".md frontmatter 是「" teffort[tn] "」")
      }
    }
  }

  # 規則 2：派工寫法 lint（agent frontmatter 自己的 model: 行是來源，不檢查）
  if (index(line, MARK) == 0) {
    if (!(infm && line ~ /^model:/)) {
      for (i = 1; i <= nt; i++) {
        if (tt[i] == "M" && (tv[i] == "sonnet" || tv[i] == "haiku") && index(line, "eng-flow:tier-") == 0) {
          bad("dispatch-model", "model 值為 " tv[i] " 的派工寫法同一行沒有 eng-flow:tier-*（Agent tool 不能帶 effort，會繼承 session 的檔位）；若是刻意舉的反例，行尾加 " MARK)
          break
        }
      }
    }
    if (match(line, prefre))
      bad("dispatch-prefix", "subagent_type／agentType 的值缺少 eng-flow: 前綴，會解析不到 plugin agent；應為 eng-flow:tier-*")
  }
}
AWK

# 規則 4：抽出反引號內以 plugin 目錄開頭的路徑候選，輸出 file<TAB>line<TAB>token，存在性交給 shell 判斷。
IFS= read -r -d '' AWK_PROSE <<'AWK' || true
FNR == 1 { fence = 0 }
{ line = $0; sub(/\r$/, "", line) }
line ~ /^[ ]*(```|~~~)/ { fence = !fence; next }
fence { next }
index(line, MARK) > 0 { next }
{
  rest = line
  while (match(rest, /`[^`]+`/)) {
    span = substr(rest, RSTART + 1, RLENGTH - 2)
    rest = substr(rest, RSTART + RLENGTH)
    n = split(span, w, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      tok = w[i]
      sub(/^[("']+/, "", tok)
      sub(/^[$][{]CLAUDE_PLUGIN_ROOT[}]"?\//, "", tok)
      sub(/[].,;:)"']+$/, "", tok)
      if (tok ~ /^(scripts|hooks|references|skills|agents|tests|templates)\//)
        printf "%s\t%d\t%s\n", FILENAME, FNR, tok
    }
  }
}
AWK

# =====================================================================
# 規則 1：tier 一致性
# =====================================================================
TIERS_SPEC=""
tier_files=()
for f in agents/tier-*.md; do [ -f "$f" ] && tier_files+=("$f"); done
if [ "${#tier_files[@]}" -eq 0 ]; then
  bad agents 1 tier-frontmatter "找不到任何 agents/tier-*.md（tier 一致性的唯一來源）"
fi
for f in ${tier_files[@]+"${tier_files[@]}"}; do
  name="${f##*/}"; name="${name%.md}"
  fm="$(awk "$AWK_FRONTMATTER" "$f")" || die_env "awk 解析 $f 失敗"
  IFS='|' read -r t_model t_ml t_effort t_el t_dl t_dm t_de <<<"${fm%$'\r'}"
  ok=1
  [ -n "$t_model" ]  || { bad "$f" 1 tier-frontmatter "frontmatter 缺少 model:"; ok=0; }
  [ -n "$t_effort" ] || { bad "$f" 1 tier-frontmatter "frontmatter 缺少 effort:"; ok=0; }
  [ "$ok" = 1 ] || continue
  TIERS_SPEC="${TIERS_SPEC:+$TIERS_SPEC;}$name:$t_model:$t_effort"
  if [ -z "$t_dm" ] || [ -z "$t_de" ]; then
    bad "$f" "${t_dl:-1}" tier-desc "description 缺少「（$t_model + effort $t_effort）」這樣的 model／effort 標示"
  else
    [ "$t_dm" = "$t_model" ]  || bad "$f" "$t_dl" tier-desc "description 括號寫 model「$t_dm」，frontmatter 是「$t_model」"
    [ "$t_de" = "$t_effort" ] || bad "$f" "$t_dl" tier-desc "description 括號寫 effort「$t_de」，frontmatter 是「$t_effort」"
  fi
done

# 規則 1 的文件掃描 + 規則 2
if [ -n "$TIERS_SPEC" ]; then
  out="$(awk -v "TIERS=$TIERS_SPEC" -v "MARK=$MARK_DISPATCH" "$AWK_DOCSCAN" "${DOCS[@]}")" || die_env "awk 掃描派工寫法失敗"
  emit "$out"
fi

# =====================================================================
# 規則 3：hooks.json
# =====================================================================
if [ ! -f hooks/hooks.json ]; then
  bad hooks/hooks.json 1 hooks-json "hooks/hooks.json 不存在"
else
  if ! cmds="$("$JQ" -r '.. | objects | select(has("command")) | .command' hooks/hooks.json 2>&1)"; then
    bad hooks/hooks.json 1 hooks-json "jq 無法解析：${cmds%%$'\n'*}"
    cmds=""
  fi
  # 迴圈內全用 bash 內建（不開子行程）：Windows 上每個 fork 約 30～100 ms，這段原本佔掉執行時間的一半
  HJ=()
  while IFS= read -r l || [ -n "$l" ]; do HJ+=("${l%$'\r'}"); done < hooks/hooks.json
  hj_line() { # hj_line <needle> → HJ_LN = hooks.json 中第一個含 needle 的行號（找不到 1）
    local i=0 l
    HJ_LN=1
    for l in ${HJ[@]+"${HJ[@]}"}; do
      i=$((i + 1))
      case "$l" in *"$1"*) HJ_LN=$i; return 0 ;; esac
    done
  }
  ref_re='CLAUDE_PLUGIN_ROOT[}]?"?/([A-Za-z0-9._/-]+)'
  REFS=()      # hooks.json 裡引用的 plugin 內相對路徑（去重）
  while IFS= read -r cmd; do
    cmd="${cmd%$'\r'}"                                  # 本機 jq 輸出 CRLF
    rest="$cmd"
    while [[ "$rest" =~ $ref_re ]]; do
      ref="${BASH_REMATCH[1]}"; whole="${BASH_REMATCH[0]}"
      rest="${rest#*"$whole"}"
      seen=0
      for r in ${REFS[@]+"${REFS[@]}"}; do [ "$r" = "$ref" ] && seen=1; done
      [ "$seen" = 1 ] || REFS+=("$ref")
    done
  done <<<"$cmds"

  REGISTERED=()   # 註冊的 hooks/<檔名>（檔名，不含目錄）
  for ref in ${REFS[@]+"${REFS[@]}"}; do
    if [ ! -e "$ref" ]; then
      hj_line "$ref"; bad hooks/hooks.json "$HJ_LN" hooks-missing "hooks.json 引用的 $ref 不存在"
      continue
    fi
    case "$ref" in hooks/*) REGISTERED+=("${ref#hooks/}") ;; esac
  done

  # 每支 hooks/*.sh 都要註冊，或列在 HOOK_LIBS
  for f in hooks/*.sh; do
    [ -f "$f" ] || continue
    b="${f##*/}"
    reg=0
    for r in ${REGISTERED[@]+"${REGISTERED[@]}"}; do [ "$r" = "$b" ] && reg=1; done
    for l in $HOOK_LIBS; do [ "$l" = "$b" ] && reg=1; done
    [ "$reg" = 1 ] || bad "$f" 1 hooks-unregistered "$b 沒有在 hooks/hooks.json 註冊，也不在 HOOK_LIBS 清單（$HOOK_LIBS）"
  done

  # 每支註冊的 hook 都要有測試檔。名稱對不上的例外用明文對照表，不放寬規則。
  hook_test_candidates() { # → CANDS（陣列）
    case "$1" in
      no-heredoc-backslashes) CANDS=("tests/test_heredoc_backslashes.py") ;;
      *) CANDS=("tests/$1.test.sh" "tests/test_${1//-/_}.py") ;;
    esac
  }
  for b in ${REGISTERED[@]+"${REGISTERED[@]}"}; do
    name="${b%.*}"
    hook_test_candidates "$name"
    found=0; cands=""
    for c in "${CANDS[@]}"; do
      cands="${cands:+$cands 或 }$c"
      [ -f "$c" ] && found=1
    done
    if [ "$found" != 1 ]; then
      hj_line "hooks/$b"
      bad hooks/hooks.json "$HJ_LN" hooks-no-test "已註冊的 hook「$name」沒有測試檔（期望 $cands）"
    fi
  done
fi

# =====================================================================
# 規則 4：散文路徑
# =====================================================================
out="$(awk -v "MARK=$MARK_PATH" "$AWK_PROSE" "${PROSE[@]}")" || die_env "awk 擷取散文路徑失敗"
while IFS=$'\t' read -r pfile pline ptok; do
  [ -n "$pfile" ] || continue
  p="${ptok%%#*}"                                            # 去掉 #錨點
  if [[ "$p" =~ ^(.*[^:]):[0-9]+(-[0-9]+)?$ ]]; then p="${BASH_REMATCH[1]}"; fi   # 去掉 :行號
  p="${p%/}"
  case "$p" in
    *'<'*|*'>'*|*'{'*|*'}'*|*'$'*|*'['*|*'...'*)             # 佔位符：只驗到佔位符之前的目錄
      stat="$(printf '%s' "$p" | sed -E 's/([<>{}$[]|[.][.][.]).*$//')"
      d="${stat%/*}"
      [ -d "$d" ] && continue
      ;;
    *'*'*|*'?'*)                                             # 萬用字元：至少要有一個符合
      compgen -G "$p" >/dev/null 2>&1 && continue
      ;;
    *)
      [ -e "$p" ] && continue
      ;;
  esac
  bad "$pfile" "$pline" prose-path "反引號內的路徑 $ptok 不存在於 plugin 根目錄；若指的是使用者專案或使用者設定 repo 的路徑，改寫成 ~/... 或在行尾加 $MARK_PATH"
done <<<"$out"

# ---------- 結果 ----------
finish
