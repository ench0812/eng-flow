#!/usr/bin/env bash
# memory.sh — 記憶庫治理工具（稽核、索引、搜尋）。
#
# 解決的問題：記憶累積後會退化——索引一行指向含十個事實的檔案、時效寫在散文裡
# 查不到、跨庫壞引用、以及「存檔前先檢查重複」這種只能靠自覺的治理。本工具把
# 這些變成可機械檢查的東西。
#
# 設計要點：
#   - 常駐成本由 pin 數決定，不隨記憶總數 N 成長（索引模板不含任何隨 N 變動的內容）
#   - 釘選區是**產生物**，來源是記憶檔本身；兩邊各自可改就一定會漂移
#   - 已被取代的記憶不進索引、也不進搜尋結果——結構性防誤導，不靠讀者判斷日期
#   - 唯讀為主；只有 `index --write` 會改檔，且是交易式的
#
# 用法:
#   memory.sh audit  [--home PATH] [--today YYYY-MM-DD]
#   memory.sh index  [--check|--write] [--home PATH]
#   memory.sh search <keyword> [--home PATH]
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
MODEL_AWK="$SELF_DIR/memory-model.awk"

HOME_DIR=""
TODAY=""
MODE=""
KEYWORD=""
INDEX_ACTION="check"
INDEX_SET=""

# 測試用的失敗注入旗標（正式使用不設）。交易保證只有靠注入真實失敗才驗得出來，
# 而 Windows 上沒有可靠的方式讓 cp／mv 自然失敗（chmod 對讀取權限無效）：
#   MEMORY_FORCE_FAIL_BUILD=1     model 建置失敗
#   MEMORY_FORCE_FAIL_BANK=<n>    第 n 個 bank 的取代步驟失敗
#   MEMORY_FORCE_FAIL_BACKUP=<n>  第 n 個 bank 的備份步驟失敗
#   MEMORY_FORCE_FAIL_CHECKS=1    檢查程式（memory-checks.awk）失敗
#   MEMORY_FORCE_FAIL_RENDER=1    取 pinned 正文時讀檔失敗
#   MEMORY_FORCE_FAIL_SORT=1      search 結果排序失敗
#   MEMORY_FORCE_FAIL_RESTORE=1   回復時的還原步驟失敗
die_usage() { printf '%s\n' "$1" >&2; exit 2; }

usage() {
  cat <<'USAGE'
用法:
  memory.sh audit  [--home PATH] [--today YYYY-MM-DD]
  memory.sh index  [--check|--write] [--home PATH]
  memory.sh search <keyword> [--home PATH]

  --home    記憶庫根目錄，預設 $HOME/.claude
            掃描 <home>/memory/、<home>/memory-machine/、<home>/memory-work/
            與 <home>/projects/*/memory/
  --today   到期判定的基準日（UTC），預設今天。讓測試不依賴真實時鐘。

結束碼: 0 無問題 / 1 發現治理問題 / 2 用法或根目錄錯誤
USAGE
}

# ---------- 參數 ----------
[ $# -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  audit|index|search) MODE="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) die_usage "未知子命令: $1" ;;
esac

# 選項可出現在**任何位置**，不是只能在關鍵字之前。
# [regression] 舊版遇到第一個非選項就 break，於是
# `search <keyword> --home <path>` 的 --home 完全沒被解析，HOME_DIR 落回
# 預設值 $HOME/.claude——測試以為在讀 fixture，實際讀的是使用者真實記憶庫。
# `--` 之後的一切一律視為位置參數，讓關鍵字可以長得像選項。
POSITIONAL=""
END_OF_OPTS=0
while [ $# -gt 0 ]; do
  if [ "$END_OF_OPTS" = 1 ]; then
    [ -n "$POSITIONAL" ] || POSITIONAL="$1"; shift; continue
  fi
  case "$1" in
    --home)  [ $# -ge 2 ] || die_usage "--home 需要值";  HOME_DIR="$2"; shift 2 ;;
    --today) [ $# -ge 2 ] || die_usage "--today 需要值"; TODAY="$2";    shift 2 ;;
    # 互斥。靜默取最後一個的話，`index --check --write` 會實際寫入——
    # 一個本來是唯讀意圖的指令變成改檔，這種事不能靠使用者自己注意順序。
    --check) [ "$INDEX_SET" = write ] && die_usage "--check 與 --write 互斥"
             INDEX_ACTION="check"; INDEX_SET="check"; shift ;;
    --write) [ "$INDEX_SET" = check ] && die_usage "--check 與 --write 互斥"
             INDEX_ACTION="write"; INDEX_SET="write"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) END_OF_OPTS=1; shift ;;
    -*) die_usage "未知參數: $1" ;;
    *)  [ -n "$POSITIONAL" ] || POSITIONAL="$1"; shift ;;
  esac
done

if [ "$MODE" = "search" ]; then
  KEYWORD="$POSITIONAL"
  [ -n "$KEYWORD" ] || die_usage "search 需要關鍵字"
fi

HOME_DIR="${HOME_DIR:-$HOME/.claude}"
[ -d "$HOME_DIR" ] || die_usage "找不到根目錄: $HOME_DIR"
# 正規化成絕對路徑。search 的輸出契約是絕對路徑，而 `--home ./fixture` 會讓
# 每一行都變成相對路徑——貼進別的地方就打不開。用 `pwd` 而非 `pwd -P`：
# 只補上絕對前綴，不解析 symlink，因為 `--home` 是使用者宣告的根（見下方
# bank_is_safe 的說明），把它換成 realpath 等於擅自改掉那個宣告。
HOME_DIR="$(cd "$HOME_DIR" && pwd)" || die_usage "無法解析根目錄: $HOME_DIR"
[ -f "$MODEL_AWK" ] || die_usage "找不到 $MODEL_AWK"
[ -f "$SELF_DIR/memory-checks.awk" ] || die_usage "找不到 $SELF_DIR/memory-checks.awk"
[ -f "$SELF_DIR/memory-search.awk" ] || die_usage "找不到 $SELF_DIR/memory-search.awk"

if [ -n "$TODAY" ]; then
  # 形狀對不代表日期存在。`--today 2026-02-30` 會被字串比較照單全收，
  # 於是 overdue 的判定整批偏掉，而且不會有任何警告——稽核工具自己算錯
  # 比不算更糟。這裡的曆法驗證與 review_by 用的是同一套規則。
  case "$TODAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die_usage "--today 需為 YYYY-MM-DD" ;;
  esac
  awk -v d="$TODAY" 'BEGIN{
      m = substr(d,6,2) + 0; dd = substr(d,9,2) + 0; y = substr(d,1,4) + 0
      if (m < 1 || m > 12 || dd < 1 || dd > 31) exit 1
      if (m == 2) {
          leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
          if (dd > (leap ? 29 : 28)) exit 1
      } else if (m == 4 || m == 6 || m == 9 || m == 11) {
          if (dd > 30) exit 1
      }
      exit 0
  }' || die_usage "--today 不是存在的日期: $TODAY"
else
  TODAY="$(date -u +%Y-%m-%d)"
fi

# ---------- 2-gram 能力偵測 ----------
# gawk 的 length/substr 以字元計，mawk 以 byte 計（實測：mawk 對 5 個 CJK 字元
# 回 length=15、substr 切出半個字）。切在 byte 邊界會讓中文相似度失真，
# 所以先偵測，不能默默降級成看似同義的結果。
GRAM_MODE="char"
if [ "$(printf '部署與環境' | awk '{print length($0)}' 2>/dev/null)" != "5" ]; then
  GRAM_MODE="byte"
fi

# MEMORY_SH_CAPABILITY: banks=global,machine,work,project
#   ^ 這一行是【契約】：~/.claude/scripts/memory 的 wrapper 用它判斷 md fallback 有沒有
#     涵蓋四個 bank。涵蓋範圍變了就要同步改這行，否則 wrapper 會做出錯誤的退回決定。
# ---------- bank 掃描 ----------
# bank 依絕對路徑 byte-order 排序，讓多 bank 寫入的順序可重現。
#
# **路徑上任何一段是 symlink 就整個 bank 不收**。逐檔的 `[ -L ]` 擋不住這件事：
# 被 symlink 的是**目錄**時，底下每個檔案看起來都是普通檔，而 `index --write`
# 會照著寫 `MEMORY.md`——寫到 `--home` 範圍外去。工具唯一會改檔的地方就是索引，
# 它的寫入邊界必須一眼看得出來，所以這裡選擇拒收而非解析後放行。
# 用 `[ -L ]` 逐段檢查而不是 realpath：後者每個 bank 一個子行程，
# 而這支腳本的效能預算正是被子行程吃掉的。
bank_is_safe() {
  local d="$1" p
  [ -L "$d" ] && return 1
  p="${d%/memory}"
  while [ -n "$p" ] && [ "$p" != "$HOME_DIR" ] && [ "$p" != "/" ]; do
    [ -L "$p" ] && return 1
    p="${p%/*}"
  done
  return 0
}

BANKS="$(mktemp)"
# 拒收旗標與 CLAUDE.md 旗標各自 mktemp，不用 `$BANKS.rej` 這種可推導的名字：
# 可推導的名字在共用暫存目錄裡可以被同 UID 的程序先擺成 symlink，`>>` 就寫到
# 別的地方去了；而且 README 說的是「暫存檔一律走 mktemp」。
BANKS_REJ="$(mktemp)"
LINKS_FLAG="$(mktemp)"
rm -f "$LINKS_FLAG"   # 存在與否就是旗標本身，先清成「未設定」
build_banks() {
  local d list=() n=0
  # 四個固定 bank。**少收 machine/work 的後果不是「查不到」而是「查無」**——PG 停機時
  # 這條 fallback 是唯一的檢索路徑，回傳不完整的結果會讓那兩類記憶消失得像不存在，
  # 直接違反「失敗不可以長得像查無」。wrapper 會用下方的 capability 標記偵測版本。
  for d in "$HOME_DIR/memory" "$HOME_DIR/memory-machine" "$HOME_DIR/memory-work"; do
    [ -d "$d" ] && { list+=("$d"); n=$((n+1)); }
  done
  # projects/ 讀不到或不能 traverse 時，下面的 glob 直接不展開——一個專案庫都
  # 掃不到，而輸出看起來就是「只有全域庫」。少掉的記憶在 search 是「查無」、
  # 在 --write 是「這些 bank 不用更新」，兩種都會被當成正常結果。
  if [ -e "$HOME_DIR/projects" ] &&
     { [ ! -d "$HOME_DIR/projects" ] || [ ! -r "$HOME_DIR/projects" ] ||
       [ ! -x "$HOME_DIR/projects" ]; }; then
    printf 'WARN %s: unreadable_bank 無法列舉專案目錄\n' "$HOME_DIR/projects" >&2
    printf 'x' >> "$BANKS_REJ"
  fi
  # 單一專案目錄不能 traverse 時，`projects/*/memory` 這一段 glob 對它就是不匹配
  # ——沒有錯誤、沒有訊息，那個 bank 就這樣從清單裡消失。上面那圈只看得到
  # projects/ 本身，看不到底下某一個。
  for d in "$HOME_DIR"/projects/*/; do
    [ -d "$d" ] || continue
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
      printf 'WARN %s: unreadable_bank 無法進入專案目錄\n' "${d%/}" >&2
      printf 'x' >> "$BANKS_REJ"
    fi
  done 2>/dev/null
  for d in "$HOME_DIR"/projects/*/memory; do
    [ -d "$d" ] && { list+=("$d"); n=$((n+1)); }
  done 2>/dev/null
  [ "$n" -gt 0 ] || return 0
  # **不可先經 `printf | while read` 再檢查**：那是以換行分隔的傳遞，
  # 目錄名裡的換行會先把一個 bank 拆成兩個看起來很正常的路徑，
  # 原本那個 bank 就這樣被靜默略過，連拒收都不會被記錄下來。
  # 所以控制字元的檢查必須發生在字串還完整的時候。
  for d in "${list[@]}"; do
    case "$d" in
      *[[:cntrl:]]*)
        printf 'WARN %s: control_char_in_path\n' "$d" >&2
        printf 'x' >> "$BANKS_REJ"
        continue ;;
    esac
    if bank_is_safe "$d"; then
      printf '%s\n' "$d"
    else
      printf 'WARN %s: symlinked_bank 路徑含 symlink，不納入掃描或寫入\n' "$d" >&2
      printf 'x' >> "$BANKS_REJ"
    fi
  done | LC_ALL=C sort -u
}

list_banks() { cat "$BANKS"; }

# ---------- 建 model ----------
# 每則記憶一行，欄位以 US（\x1f）分隔：
#   bank id path name description type pin review_by supersedes superseded_by
#   bytes paras body_start parse_errors
#
# **不可用 TAB 當分隔符**：TAB 屬於 IFS whitespace，`IFS=$'\t' read` 會把
# **連續的 TAB 摺疊成一個分隔符**，於是中間連續的空欄位（例如同時沒有
# review_by／supersedes／superseded_by）會讓後面所有欄位左移。實測症狀是
# review_by 讀到了檔案 byte 數。US 是非 whitespace，不會被摺疊。
FS_US=$'\x1f'
# 一次把所有記憶檔餵給同一個 awk，避免逐檔開子行程。
# 逐檔會在 Windows/Git Bash 上以每檔 5 個子行程 × 30ms 的速度累積成分鐘級的耗時。
build_model() {
  local bank f base files=()
  while IFS= read -r bank; do
    [ -n "$bank" ] || continue
    # 不可讀的目錄會讓 glob 原樣留著、一則都掃不到，看起來就像「這個 bank 是空的」。
    # 空與讀不到是兩件事，後者必須講出來。
    if [ ! -r "$bank" ] || [ ! -x "$bank" ]; then
      printf 'WARN %s: unreadable_bank\n' "$bank" >&2
      printf 'x' >> "$BANKS_REJ"
      continue
    fi
    for f in "$bank"/*.md; do
      [ -e "$f" ] || [ -L "$f" ] || continue     # glob 沒展開時的字面樣式
      # symlink 要**排在 `[ -f ]` 之前**判。壞掉的 symlink（指向已刪除的檔）
      # 既不是 -f 也不是 -e，先問 -f 就會讓它從縫裡掉出去、連拒收都不記。
      # 不跟隨 symlink——但**不能靜默跳過**。跳掉的那則記憶在下游等於不存在，
      # 而 `index --write` 會照著這份少了東西的 model 重寫索引，把它原本的
      # 釘選內容一併刪掉。看不見的來源一律記成拒收，讓整批操作 fail closed。
      if [ -L "$f" ]; then
        printf 'WARN %s: symlinked_memory 不跟隨 symlink，該則未納入\n' "$f" >&2
        printf 'x' >> "$BANKS_REJ"
        continue
      fi
      # 名字像記憶、卻不是普通檔（目錄、FIFO、device）。靜默跳過的話，
      # 一個叫 `foo.md` 的目錄就能讓原本的 `foo` 記憶從 model 裡消失，
      # 而 --write 會照著把它的釘選內容從索引裡刪掉。
      if [ ! -f "$f" ]; then
        printf 'WARN %s: not_regular_file 不是普通檔，未納入\n' "$f" >&2
        printf 'x' >> "$BANKS_REJ"
        continue
      fi
      # 用參數展開取檔名，**不呼叫 basename**：那是每個檔案一個子行程，
      # 500 則就是 500 個 × 約 14ms ≈ 7 秒——實測時這一行就佔掉全部耗時的一半以上。
      base="${f##*/}"
      # 大小寫不敏感的檔案系統（Windows、預設的 macOS）上 `memory.md` 與
      # `MEMORY.md` 是同一個檔；只比對精確大小寫的話，索引自己會被當成
      # 來源記憶納進來。大小寫敏感的系統上它是另一個合法檔案，所以
      # **不能靜默略過**——講出來並讓整批 fail closed。
      # 用大小寫樣式而不是 `${base,,}`：後者要 bash 4+，macOS 內建的是 3.2，
      # 在那裡會直接 bad substitution，讓整支工具無法執行。
      case "$base" in
        MEMORY.md) continue ;;                         # 索引不是來源，否則會納入自身而永遠漂移
        [Mm][Ee][Mm][Oo][Rr][Yy].[Mm][Dd])
          printf 'WARN %s: reserved_filename 與索引檔同名（大小寫變體）\n' "$f" >&2
          printf 'x' >> "$BANKS_REJ"
          continue ;;
        .MEMORY.md.*) continue ;;                      # 本工具的交易暫存/備份，不是記憶
        # 其餘 dot-prefixed 一律不當來源，但**不靜默**：ID 字元集不允許開頭的點，
        # 所以這種檔在這裡被略過之後，別處也不會有人發現它應該存在。
        .*)
          printf 'WARN %s: hidden_file 檔名以點開頭，不視為記憶來源\n' "$f" >&2
          printf 'x' >> "$BANKS_REJ"
          continue ;;
        # 檔名裡的控制字元會讓 model 的 US 分欄整排位移，後面每個治理欄位
        # 都會被讀成別的東西。POSIX 檔名允許這些字元，所以擋在掃描這一層。
        *[[:cntrl:]]*)
          printf 'WARN %s: control_char_in_path\n' "$f" >&2
          printf 'x' >> "$BANKS_REJ"
          continue ;;
      esac
      files+=("$f")
    done
    # bash 的 glob **不會**展開以點開頭的檔名，所以上面那圈永遠看不到 `.foo.md`。
    # 不另外掃一次的話，那種檔在 audit／search／index 三處同時不存在，
    # 而使用者不會收到任何訊息。ID 字元集不允許開頭的點，所以它不可能是
    # 合法記憶——但「不可能是記憶」要講出來，不是默默當作沒有。
    # `.MEMORY.md.new.XXXXXX` 這類交易暫存不符合 `.*.md`，不會落進來。
    for f in "$bank"/.*.md; do
      # 與一般 *.md 掃描同一條規則：symlink、壞掉的 symlink、目錄、FIFO 都算
      # 「看不見的來源」。只認 `[ -f ]` 的話，`.foo.md` 是 symlink 就會靜默略過，
      # 而下游看到的是「少了一則」——那正是 fail-closed 要防的。
      [ -e "$f" ] || [ -L "$f" ] || continue
      printf 'WARN %s: hidden_file 檔名以點開頭，不視為記憶來源\n' "$f" >&2
      printf 'x' >> "$BANKS_REJ"
    done
  done < <(list_banks)

  [ ${#files[@]} -gt 0 ] || return 0

  # 一次 wc 取得所有檔案的精確 byte 數（**單一子行程**，不是每檔一個）。
  # awk 端逐行累加做不到兩件事：沒有 final newline 的檔案會多算 1 byte；
  # 零位元組的檔案連 FNR==1 都不會觸發，於是在 model 裡整個消失。
  # 不加 `--`：BSD 的 wc（macOS 內建）不接受它，整個 model 建置會失敗，
  # 三個子命令一起變成 model_build_failed。這裡的路徑全是絕對路徑，
  # 不會以 `-` 開頭，所以本來就不需要選項終止符。
  if ! wc -c "${files[@]}" > "$SIZES" 2>>"$BUILD_ERR"; then
    printf 'wc 失敗\n' >> "$BUILD_ERR"; return 1
  fi
  # 在 C locale 執行：gawk 在 multibyte locale 下 length() 回的是**字元數**，
  # 於是 substr／length 相關計算對中文會失真。大小改由 wc 供給，這裡仍固定
  # C locale 以免其他長度運算隨環境漂移。
  LC_ALL=C awk -v US="$FS_US" -v linksfile="$LINKS" -v sizefile="$SIZES"       -f "$MODEL_AWK" "${files[@]}" 2>>"$BUILD_ERR" || return 1
}


# ---------- canonical renderer ----------
# 索引整份不得含隨 N 變動的內容；TOPICS 區塊由人工維護、renderer 原樣保留。
render_index() {
  local bank="$1" model="$2" existing="$3"
  local topics flag pipe_rc=0 wr_rc=0
  topics="$(extract_topics "$existing")"
  # 取正文的 awk 跑在 `while` 子 shell 裡，退出碼傳不回來——而「某則 pinned
  # 的正文讀不到」正是最不能靜默的一種失敗：索引會少掉那一段、卻以成功狀態
  # 提交，等於工具自己把使用者的常駐記憶刪了一塊。用檔案把失敗帶回來。
  flag="$(mktemp)"

  printf '# Memory Index\n\n<!-- PINNED:BEGIN -->\n' || wr_rc=1
  awk -F"$FS_US" -v b="$bank" -v u="$FS_US" \
      '$1==b && $7=="true" && $10=="" && $14=="" {print $2 u $3 u $13}' "$model" \
    | LC_ALL=C sort | while IFS="$FS_US" read -r id path body; do
        printf '<!-- PINNED:ITEM %s -->\n' "$id"
        rp="$path"
        [ "${MEMORY_FORCE_FAIL_RENDER:-}" = 1 ] && rp="$path/nonexistent"
        awk -v s="$body" 'NR>=s' "$rp" || printf 'x' >> "$flag"
      done || pipe_rc=1
  printf '<!-- PINNED:END -->\n\n<!-- TOPICS:BEGIN -->\n%s\n<!-- TOPICS:END -->\n\n' "$topics" || wr_rc=1
  printf '搜尋：`~/.claude/scripts/memory search "<關鍵字>"`\n' || wr_rc=1
  printf '稽核：`~/.claude/scripts/memory audit`\n' || wr_rc=1

  # flag 抓的是「某一則正文讀不到」，pipe_rc 抓的是整條管線本身失敗
  # （例如 sort 因暫存空間不足中途死掉），wr_rc 抓的是**輸出本身**失敗
  # （ENOSPC、I/O error）。三者都會讓索引少掉內容，而 pipefail 只是讓管線
  # 回非 0，不會自動中止函式；printf 的失敗更是連回傳值都沒人看。
  if [ -s "$flag" ] || [ "$pipe_rc" != 0 ] || [ "$wr_rc" != 0 ]; then
    rm -f "$flag"; return 1
  fi
  rm -f "$flag"
  return 0
}

# 索引狀態判定。audit 與 index --check 共用同一套，避免兩處各自解讀而漂移。
# 回傳 0 代表無問題；有問題時把 WARN 印到 stderr 並回傳 1。
# 空 bank 不需要索引。Claude Code 會替每個開過的專案建 memory 目錄，
# 多數是空的；對它們報 index_missing 只是噪音，而噪音會讓人忽略真正的警告。
# 每次呼叫都開一個 awk 全掃 $MODEL 的話，成本是 O(bank 數 × 記憶數) 再乘上
# 子行程開銷——而 audit／--check／--write 每個 bank 都會問好幾次。
# 建完 model 就把「有記憶的 bank」算成一個集合，之後純字串比對，零子行程。
# bank 路徑不可能含 US（含控制字元的路徑在掃描時就被拒收了），拿它當分隔安全。
BANKS_NONEMPTY=""
bank_has_memory() {
  case "$FS_US$BANKS_NONEMPTY" in
    *"$FS_US$1$FS_US"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 交易回復：把已取代的 bank 還原。
# existed=0 代表該 bank 原本**沒有**索引，回復要**刪掉**本次建立的檔案，
# 不能留一個空索引——留下來的話交易失敗還順手製造了新的治理問題。
# 還原失敗時**必須保留備份**。備份是原始索引僅存的一份，連同人工維護的
# TOPICS 區塊；還原沒成功卻順手把它刪掉，等於用一次失敗換掉使用者的資料。
#
# 記錄格式（US 分欄）：APPLIED 為 bank/existed/備份檔；STAGED 為 bank/暫存檔。
# 暫存檔名由 mktemp 產生而非 `$$`，所以必須逐筆記下來——猜不回去。
rollback() {
  local applied="$1" bank existed bak failed=0
  while IFS="$FS_US" read -r bank existed bak; do
    [ -n "$bank" ] || continue
    if [ "$existed" = 1 ]; then
      if [ "${MEMORY_FORCE_FAIL_RESTORE:-}" != 1 ] &&
         mv -f "$bak" "$bank/MEMORY.md" 2>/dev/null; then
        rm -f "$bak"
      else
        printf 'WARN %s: rollback_failed 備份保留於 %s\n' "$bank/MEMORY.md" "$bak" >&2
        failed=1
      fi
    else
      if rm -f "$bank/MEMORY.md" 2>/dev/null && [ ! -f "$bank/MEMORY.md" ]; then
        :
      else
        printf 'WARN %s: rollback_failed 無法刪除本次建立的索引\n' "$bank/MEMORY.md" >&2
        failed=1
      fi
      [ -n "$bak" ] && rm -f "$bak"
    fi
  done <<EOF
$(printf '%s' "$applied")
EOF
  [ "$failed" = 0 ] || printf 'WARN -: rollback_incomplete 索引未完全回復，請依上列備份手動還原\n' >&2
  return 0
}
cleanup_staged() {
  local staged="$1" bank tmp
  while IFS="$FS_US" read -r bank tmp; do
    [ -n "$tmp" ] || continue
    rm -f "$tmp"
  done <<EOF
$(printf '%s' "$staged")
EOF
}

check_index() {
  local bank="$1" idx="$bank/MEMORY.md" expected
  # 空 bank 沒有索引才是正常。**空 bank 卻還有索引不是**——刪掉最後一則記憶後，
  # 舊 MEMORY.md 會帶著它的釘選正文永遠留著，每個 session 照樣讀進去，
  # 而那正是這支工具存在的理由（索引是產生物，不是被維護的第二份真相）。
  if ! bank_has_memory "$bank"; then
    [ -e "$idx" ] || [ -L "$idx" ] || return 0
  fi
  if [ -L "$idx" ]; then
    printf 'WARN %s: symlinked_index 索引檔是 symlink\n' "$idx" >&2; return 1
  fi
  if [ -e "$idx" ] && [ ! -f "$idx" ]; then
    printf 'WARN %s: index_not_regular_file 索引檔不是普通檔\n' "$idx" >&2; return 1
  fi
  if [ ! -f "$idx" ]; then
    printf 'WARN %s: index_missing\n' "$idx" >&2; return 1
  fi
  if ! index_markers_ok "$idx"; then
    printf 'WARN %s: invalid_index_markers\n' "$idx" >&2; return 1
  fi
  expected="$(render_index "$bank" "$MODEL" "$idx")"
  if ! printf '%s\n' "$expected" | diff -q - "$idx" >/dev/null 2>&1; then
    printf 'WARN %s: index_drift\n' "$idx" >&2; return 1
  fi
  return 0
}

# 索引標記的完整性。C4 規定 TOPICS 區塊由人工維護、renderer 原樣保留，
# 那就得先能**確定它的範圍**。標記缺一個、多一組或前後顛倒時範圍是未定義的，
# 而 render 會照著錯的範圍抓一段文字塞回去——實測 TOPICS:END 不見時
# extract_topics 一路抓到檔尾，把搜尋／稽核兩行也吞進 TOPICS 區塊，
# 使用者手寫的主題分類就這樣被 --write 覆寫掉。範圍不明時一律不猜。
index_markers_ok() {
  # 比對**整行**，不是子字串。`<!-- TOPICS:BEGIN --> 手寫的東西` 若算合法標記，
  # extract_topics 取區塊時會把同一行的手寫內容一起丟掉——而這正是
  # 「標記範圍不明時不猜測、不覆寫」要防的事。
  # 索引也要正規化 CRLF。來源記憶已經接受 CRLF，索引卻不接受的話，
  # 使用者用 Windows 編輯器改過一次 TOPICS，四個 marker 全部對不上，
  # `--write` 會以 invalid_index_markers 擋住——變成工具自己修不好自己。
  awk '
    { sub(/\r$/, "") }
    $0 == "<!-- PINNED:BEGIN -->" { pb++; a = NR }
    $0 == "<!-- PINNED:END -->"   { pe++; b = NR }
    $0 == "<!-- TOPICS:BEGIN -->" { tb++; c = NR }
    $0 == "<!-- TOPICS:END -->"   { te++; d = NR }
    END { exit (pb == 1 && pe == 1 && tb == 1 && te == 1 &&
                a < b && b < c && c < d) ? 0 : 1 }' "$1"
}

extract_topics() {
  local f="$1"
  # 同樣比對整行——與 index_markers_ok 用同一個判準，兩處不一致就會出現
  # 「檢查說標記合法、取內容卻取到別的範圍」。
  if [ -f "$f" ] && awk '{sub(/\r$/, "")} $0 == "<!-- TOPICS:BEGIN -->" {found=1} END{exit found?0:1}' "$f" 2>/dev/null; then
    awk '{sub(/\r$/, "")} $0 == "<!-- TOPICS:BEGIN -->" {f=1;next} $0 == "<!-- TOPICS:END -->" {f=0} f' "$f"
  else
    printf '主題：（尚未分類）'
  fi
}

# ---------- 子命令 ----------
# 全部走 mktemp。這裡曾有一個 MEMORY_DEBUG_MODEL 讓開發期間留下 model 檔，
# 但那等於「一個環境變數就能把寫入導到任意可寫路徑」，與整支腳本
# 「只寫 --home 底下的索引」的邊界相牴觸。要看 model 就改用管線，不留後門。
MODEL="$(mktemp)"
LINKS="$(mktemp)"
SIZES="$(mktemp)"
BUILD_ERR="$(mktemp)"
CHECKS_ERR="$(mktemp)"
trap 'rm -f "$MODEL" "$LINKS" "$SIZES" "$BUILD_ERR" "$CHECKS_ERR" "$BANKS" "$BANKS_REJ" "$LINKS_FLAG"' EXIT

# 檢查程式失敗必須 fail closed。它算的是 dangling／relation／dup，
# 而 `--write` 與 `search` 都拿它的**沉默**當「沒問題」——awk 一旦沒跑成，
# 沉默就變成「沒檢查」，`--write` 會略過驗證直接寫，`search` 會把
# 已取代的舊事實當成現行答案送出去。
# 列 bank 失敗就不能繼續。清單少了一個 bank，`index --write` 會安靜地只更新
# 一部分索引然後回報成功——多 bank 的交易性就是在這裡破掉的。
if ! build_banks > "$BANKS"; then
  printf 'WARN -: bank_scan_failed 無法列出記憶庫，未執行任何動作\n' >&2
  exit 1
fi
run_checks() { # run_checks <outfile>；失敗回傳 1
  if [ "${MEMORY_FORCE_FAIL_CHECKS:-}" = 1 ]; then
    printf 'injected checks failure\n' > "$CHECKS_ERR"; : > "$1"; return 1
  fi
  awk -v US="$FS_US" -v today="$TODAY" -v gram="$GRAM_MODE" \
      -v globalbank="$HOME_DIR/memory" \
      -f "$SELF_DIR/memory-checks.awk" "$MODEL" "$LINKS" > "$1" 2>"$CHECKS_ERR"
}
# checks 的輸出是 `LEVEL<TAB>path<TAB>code<TAB>detail`。判定必須看**欄位**，
# 不能拿裸 grep 掃整行：`--home` 路徑或候選 detail 裡只要出現 code 的字樣
# （例如某個專案的目錄就叫 dangling_ref），write 與 search 就會無故中止。
#
# 兩種阻擋條件不同：write 擋的是來源關係類錯誤；search 擋的是「無法判定誰
# 已被取代」，所以只認取代欄位上的 dangling_ref，正文 `[[x]]` 壞掉不算。
# 條件寫在 awk 裡而不是用變數傳程式碼進來——傳程式碼就得再過一層 shell 引號，
# 而那正是這條 finding 的來源。
checks_scan() { # checks_scan <file> <write|search> <test|emit>；有命中回 0
  awk -F"\t" -v mode="$2" -v action="$3" '
    $1 != "WARN" { next }
    {
      hit = 0
      if (mode == "write") {
        if ($3 == "dangling_ref" || $3 == "relation_mismatch" || $3 == "ambiguous_id") hit = 1
      } else if (mode == "search") {
        if ($3 == "relation_mismatch") hit = 1
        else if ($3 == "dangling_ref" && ($4 ~ /^superseded_by=/ || $4 ~ /^supersedes=/)) hit = 1
      }
      if (!hit) next
      found = 1
      if (action == "emit") printf "WARN %s: %s %s\n", $2, $3, $4
    }
    END { exit found ? 0 : 1 }' "$1"
}
checks_failed() { # checks_failed <what>
  sed 's/^/  /' "$CHECKS_ERR" >&2
  printf 'WARN -: checks_failed 檢查程式未能完成，%s\n' "$1" >&2
}

# model 建置失敗必須讓**所有**子命令中止，`--write` 尤其如此。
# 一份不完整的 model 在下游看起來就是「記憶比較少」——renderer 會照著它
# 重寫索引，把讀不到的那幾則釘選內容直接刪掉，而交易保證只涵蓋
# 「已知的來源資料錯誤」，管不到「來源根本沒讀進來」。
if [ "${MEMORY_FORCE_FAIL_BUILD:-}" = 1 ]; then
  printf 'WARN -: model_build_failed 無法完整讀取記憶來源，未執行任何動作\n' >&2
  exit 1
fi
if ! build_model > "$MODEL"; then
  sed 's/^/  /' "$BUILD_ERR" >&2
  printf 'WARN -: model_build_failed 無法完整讀取記憶來源，未執行任何動作\n' >&2
  exit 1
fi

# 被拒收的 bank 或檔案等於「這批記憶完全看不到」。那是 WARN 等級的狀態，
# 不能只印一行就當沒事——尤其 search，看不到的記憶與「沒有這回事」
# 在輸出上長得一樣。**必須算在 build_model 之後**：檔案層級的拒收
# 發生在掃描記憶檔的時候，早於它就永遠讀到 0。
BANKS_NONEMPTY="$(awk -F"$FS_US" '{print $1}' "$MODEL" | LC_ALL=C sort -u | tr '\n' "$FS_US")"

BANKS_REJECTED=0
if [ -s "$BANKS_REJ" ]; then BANKS_REJECTED=1; fi
rm -f "$BANKS_REJ"

case "$MODE" in
  index)
    if [ "$INDEX_ACTION" = check ]; then
      rc=0
      while IFS= read -r bank; do
        [ -n "$bank" ] || continue
        check_index "$bank" || rc=1
      done < <(list_banks)
      [ "$BANKS_REJECTED" = 1 ] && rc=1
      exit $rc
    fi

    # ---------- index --write：交易式 ----------
    # Preflight 只擋**來源資料錯誤**。index_drift／index_missing／zombie 不擋——
    # 它們正是 renderer 要修的狀態，一起擋的話 `--write` 會被自己偵測到的漂移
    # 永久卡死（新增一則 pin 必然產生漂移）。
    blocked=0
    [ "$BANKS_REJECTED" = 1 ] && blocked=1
    while IFS="$FS_US" read -r bank id path name desc type pin review sup supby bytes paras body errs; do
      if [ -n "$errs" ]; then
        printf 'WARN %s: malformed_frontmatter %s\n' "$path" "$errs" >&2; blocked=1
      fi
    done < "$MODEL"

    CHECKS_OUT="$(mktemp)"
    if ! run_checks "$CHECKS_OUT"; then
      rm -f "$CHECKS_OUT"
      checks_failed "未修改任何索引"
      exit 1
    fi
    if checks_scan "$CHECKS_OUT" write test; then
      checks_scan "$CHECKS_OUT" write emit >&2
      blocked=1
    fi
    rm -f "$CHECKS_OUT"

    # 標記毀損的索引不可猜測範圍，一律阻擋，交由人工 bootstrap
    while IFS= read -r bank; do
      [ -n "$bank" ] || continue
      idx="$bank/MEMORY.md"
      bank_has_memory "$bank" || [ -e "$idx" ] || [ -L "$idx" ] || continue
      # 索引檔本身是 symlink 的話，`mv` 會把暫存檔搬到它指向的地方——
      # 那可能在 `--home` 之外，而且 `[ -f ]` 對「指向目錄的 symlink」是 false，
      # 所以連備份都不會做。寫入目標必須是普通檔，沒有例外。
      # 寫入目標必須是「不存在」或「普通檔」，沒有第三種。
      # symlink 會讓 `mv` 寫穿到它指向的地方；目錄會讓 `mv` 把暫存檔**搬進去**，
      # 然後一切回報成功，而索引根本沒生成；FIFO 之類則會在沒有備份的情況下被蓋掉。
      if [ -L "$idx" ]; then
        printf 'WARN %s: symlinked_index 索引檔是 symlink，不寫入\n' "$idx" >&2
        blocked=1
      elif [ -e "$idx" ] && [ ! -f "$idx" ]; then
        printf 'WARN %s: index_not_regular_file 索引檔不是普通檔，不寫入\n' "$idx" >&2
        blocked=1
      fi
      if [ -f "$idx" ] && ! index_markers_ok "$idx"; then
        printf 'WARN %s: invalid_index_markers\n' "$idx" >&2; blocked=1
      fi
    done < <(list_banks)

    if [ "$blocked" = 1 ]; then
      printf 'WARN -: write_aborted 來源資料有誤，未修改任何索引\n' >&2
      exit 1
    fi

    # 階段一：全部 bank 先產生暫存檔並驗證，任何一個失敗就整批不動
    #
    # 暫存與備份檔名由 mktemp 在**同一個目錄**產生，不用 `$$`。
    # 固定名稱要先 `[ -e ]` 再 `>`，那中間就是一段 TOCTOU：同帳號的另一個
    # 程序可以在這兩步之間把該路徑換成 symlink，讓內容寫到 `--home` 之外。
    # mktemp 以 O_EXCL 原子建立、名稱不可預測，直接讓那個競態不存在。
    # 名稱以 `.` 開頭，仍不符合 `*.md` 來源條件，不會被當成記憶。
    STAGED=""
    # staging 期間就要有 trap。暫存檔裡是完整的 pinned 正文，中斷若落在
    # 所有 bank staging 完成之前，EXIT trap 只清那幾個 mktemp 開的檔案、
    # 不會碰 bank 裡的 .MEMORY.md.new.*，那些內容就留在記憶庫目錄裡。
    trap 'cleanup_staged "$STAGED"; exit 130' INT TERM HUP
    while IFS= read -r bank; do
      [ -n "$bank" ] || continue
      # 空 bank 但仍有索引 → 也要重寫，把過期的釘選內容清成零 pin 的樣板
      bank_has_memory "$bank" || [ -f "$bank/MEMORY.md" ] || continue
      if ! tmp="$(mktemp "$bank/.MEMORY.md.new.XXXXXX" 2>/dev/null)"; then
        printf 'WARN %s: temp_create_failed\n' "$bank/MEMORY.md" >&2
        cleanup_staged "$STAGED"; exit 1
      fi
      # **建立後立刻登錄**。訊號若落在 mktemp 成功與登錄之間，trap 看不到這個
      # 暫存檔，而它裡面是完整的 pinned 正文——會被留在記憶庫目錄裡。
      STAGED="$STAGED$bank$FS_US$tmp"$'\n'
      if ! render_index "$bank" "$MODEL" "$bank/MEMORY.md" > "$tmp" 2>/dev/null; then
        printf 'WARN %s: render_failed\n' "$bank/MEMORY.md" >&2
        cleanup_staged "$STAGED"; exit 1
      fi
      # 再驗一次**成品**：四個標記齊全且順序正確，代表它沒有被截斷在中途。
      # 這比逐個 printf 檢查更難繞過——不管哪一段寫壞，缺標記就過不了。
      if ! index_markers_ok "$tmp"; then
        printf 'WARN %s: staged_index_invalid 產生的索引不完整\n' "$bank/MEMORY.md" >&2
        cleanup_staged "$STAGED"; exit 1
      fi
    done < <(list_banks)

    # 階段二：逐檔原子取代，每次取代前留備份。
    # 只做逐檔 rename 不等於交易——第二個 bank 失敗時第一個已經被改掉了，
    # 所以要記住已取代的清單，失敗時全部回復。
    APPLIED=""
    n=0
    # 中斷也要回復。少了這個，Ctrl-C 打在兩個 bank 之間就會留下
    # 「第一個已換、第二個沒換」的半提交狀態，而 EXIT trap 只清暫存檔、
    # 不會把索引還原回去。
    trap 'rollback "$APPLIED"; cleanup_staged "$STAGED"; exit 130' INT TERM HUP
    while IFS="$FS_US" read -r bank tmp; do
      [ -n "$bank" ] || continue
      n=$((n+1))
      idx="$bank/MEMORY.md"
      # 備份失敗必須立刻中止整個交易。若放行，existed 會停在 0，而索引已被
      # 覆寫——之後任一 bank 失敗時，rollback 會把「原本存在的索引」當成
      # 「本次新建的」直接刪掉，交易保證就地失效。
      existed=0; bak=""
      if [ -f "$idx" ]; then
        if [ "${MEMORY_FORCE_FAIL_BACKUP:-}" != "$n" ] &&
           bak="$(mktemp "$bank/.MEMORY.md.bak.XXXXXX" 2>/dev/null)" &&
           cp -p "$idx" "$bak" 2>/dev/null; then
          existed=1
        else
          printf 'WARN %s: backup_failed bank=%s\n' "$idx" "$n" >&2
          [ -n "$bak" ] && rm -f "$bak"
          rollback "$APPLIED"
          cleanup_staged "$STAGED"
          printf 'WARN -: write_aborted 無法建立備份，未修改本檔\n' >&2
          exit 1
        fi
      fi
      # **先記錄再取代**。反過來的話，訊號正好落在「mv 已成功、APPLIED 還沒更新」
      # 這一格，trap 的 rollback 就不知道這個 bank 已經被換掉，留下半提交狀態。
      # 先記錄是安全的：mv 若失敗，rollback 對這筆做的事（從備份還原，或刪掉
      # 本來就不存在的索引）結果與「沒動過」相同。
      APPLIED="$APPLIED$bank$FS_US$existed$FS_US$bak"$'\n'
      if [ "${MEMORY_FORCE_FAIL_BANK:-}" = "$n" ] || ! mv -f "$tmp" "$idx" 2>/dev/null; then
        printf 'WARN %s: write_failed bank=%s\n' "$idx" "$n" >&2
        rollback "$APPLIED"
        rm -f "$tmp"
        [ -n "$bak" ] && rm -f "$bak"
        cleanup_staged "$STAGED"
        printf 'WARN -: write_rolled_back 已回復所有索引\n' >&2
        exit 1
      fi
    done <<EOF
$(printf '%s' "$STAGED")
EOF
    trap - INT TERM HUP

    # 成功：清掉備份與殘留暫存
    cleanup_staged "$STAGED"
    while IFS="$FS_US" read -r bank existed bak; do
      [ -n "$bak" ] || continue
      rm -f "$bak"
    done <<EOF
$(printf '%s' "$APPLIED")
EOF
    exit 0
    ;;
  audit)
    rc=0
    # 輸出分流固定：INFO/SUGGEST → stdout，WARN → stderr。
    # 呼叫端才能用「stderr 是否有內容」快速判斷有無治理問題。
    emit() { # emit <LEVEL> <path> <code> <details>
      case "$1" in
        WARN) printf 'WARN %s: %s %s\n' "$2" "$3" "$4" >&2; rc=1 ;;
        *)    printf '%s %s: %s %s\n' "$1" "$2" "$3" "$4" ;;
      esac
    }

    [ "$BANKS_REJECTED" = 1 ] && rc=1
    emit INFO - banks "$(list_banks | grep -c .)"
    emit INFO - memories "$(grep -c . "$MODEL")"

    # shell 端負責的檢查：frontmatter 解析結果與到期
    while IFS="$FS_US" read -r bank id path name desc type pin review sup supby bytes paras body errs; do
      [ -n "$errs" ] && emit WARN "$path" malformed_frontmatter "$errs"
      if [ -n "$review" ] && [ "$review" \< "$TODAY" ]; then
        emit WARN "$path" overdue "review_by=$review today=$TODAY"
      fi
      # zombie：已被取代卻仍出現在索引的釘選區
      if [ -n "$supby" ] && [ -f "$bank/MEMORY.md" ] &&
         grep -qF "<!-- PINNED:ITEM $id -->" "$bank/MEMORY.md" 2>/dev/null; then
        emit WARN "$bank/MEMORY.md" zombie "id=$id superseded_by=$supby"
      fi
    done < "$MODEL"

    # 索引狀態（與 index --check 同一套判定，避免兩處各自解讀）
    while IFS= read -r bank; do
      [ -n "$bank" ] || continue
      check_index "$bank" || rc=1     # 不可吞掉：吞了就會 WARN 滿天飛卻 exit 0
    done < <(list_banks)

    # CLAUDE.md 的跨庫引用：只掃 <home>/CLAUDE.md，且只認「memory 後面接一個
    # 反引號包住的 id」——散文裡的 memory 不解析，否則會誤報一片。
    # 兩種寫法都要接受（實測既有寫法是後者）：
    #   `memory foo`   → 整段包在反引號內
    #   memory `foo`   → 只有 id 包在反引號內
    # 讀不到與「沒有引用」在輸出上一模一樣，而 grep 的 exit 1（無匹配）與
    # exit 2（讀取錯誤）也被 `2>/dev/null` 一起吞掉。分開處理：只有真正確認
    # 「檔案在、讀得完、沒有壞引用」才算這一項乾淨。
    CM="$HOME_DIR/CLAUDE.md"
    if [ -e "$CM" ] && { [ ! -f "$CM" ] || [ ! -r "$CM" ]; }; then
      emit WARN "$CM" claude_md_unreadable ""
    elif [ -f "$CM" ]; then
      CM1="$(mktemp)"; CM2="$(mktemp)"
      grep -o '`memory [A-Za-z0-9._-]\+`' "$CM" > "$CM1" 2>/dev/null; g1=$?
      grep -o 'memory `[A-Za-z0-9._-]\+`' "$CM" > "$CM2" 2>/dev/null; g2=$?
      if [ "$g1" -ge 2 ] || [ "$g2" -ge 2 ]; then
        emit WARN "$CM" claude_md_unreadable "grep_status=$g1/$g2"
      fi
      { sed 's/^`memory //; s/`$//' "$CM1"
        sed 's/^memory `//; s/`$//' "$CM2"
      } | LC_ALL=C sort -u | while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            if ! awk -F"$FS_US" -v g="$HOME_DIR/memory" -v r="$ref" \
                   'BEGIN{f=1} $1==g && $2==r {f=0} END{exit f}' "$MODEL"; then
              printf 'WARN %s: claude_md_dangling %s\n' "$HOME_DIR/CLAUDE.md" "$ref" >&2
              printf 'CLAUDE_MD_DANGLING\n' >> "$LINKS_FLAG"
            fi
          done
      rm -f "$CM1" "$CM2"
      [ -f "$LINKS_FLAG" ] && rc=1
      rm -f "$LINKS_FLAG"
    fi

    # 圖與相似度檢查交給 awk（單次掃描，避免逐則開子行程）。
    # 結果先落暫存檔再讀：用管線接 while 會讓迴圈跑在子 shell，rc 傳不回來，
    # 而為了取 rc 再跑一次 awk 等於把 Jaccard 算兩遍。
    CHECKS_OUT="$(mktemp)"
    if ! run_checks "$CHECKS_OUT"; then
      rm -f "$CHECKS_OUT"
      checks_failed "稽核結果不完整"
      exit 1
    fi
    while IFS=$'\t' read -r lvl path code det; do
      [ -n "$lvl" ] || continue
      emit "$lvl" "$path" "$code" "$det"
    done < "$CHECKS_OUT"
    rm -f "$CHECKS_OUT"

    exit $rc
    ;;
  search)
    if [ "$BANKS_REJECTED" = 1 ]; then
      printf 'WARN -: search_aborted 有記憶庫未納入掃描，結果會少掉看不到的那些\n' >&2
      exit 1
    fi
    # 取代關係若不一致，「該排除誰」就無法判定。此時**寧可不給答案**——
    # 給一份可能混入已取代事實的清單，比沒有清單危險：使用者會照著它做決定。
    #
    # 同一個理由涵蓋「frontmatter 解析錯誤」，而這比關係不一致更隱蔽：
    # `superseded_by: "new"` 帶引號會被 parser 拒收，於是該欄留空——
    # 一則**已經被取代**的記憶看起來完全正常，照樣出現在搜尋結果裡，
    # 而且沒有任何 relation_mismatch 可供偵測（兩邊都不知道彼此存在）。
    # 只有「證明得了與取代關係無關」的錯誤才放行；結構性錯誤一律中止，
    # 因為結構壞掉時整段 metadata 都可能沒被讀到。
    PARSE_OUT="$(mktemp)"
    awk -v US="$FS_US" 'BEGIN{FS=US}
      $14 != "" {
        n = split($14, E, ",")
        for (k = 1; k <= n; k++) {
          e = E[k]
          if (e == "missing_name" || e == "missing_description" ||
              e == "name_stem_mismatch" || e == "bad_review_by" ||
              e == "reserved_marker") continue
          if (e ~ /^(quoted_value|multiline_value|unterminated_array):/) {
            key = e; sub(/^[^:]*:/, "", key)
            if (key != "supersedes" && key != "superseded_by") continue
          }
          print $3 "\t" e
        }
      }' "$MODEL" > "$PARSE_OUT"
    if [ -s "$PARSE_OUT" ]; then
      while IFS=$'\t' read -r ppath pcode; do
        [ -n "$ppath" ] || continue
        printf 'WARN %s: malformed_frontmatter %s\n' "$ppath" "$pcode" >&2
      done < "$PARSE_OUT"
      rm -f "$PARSE_OUT"
      printf 'WARN -: search_aborted frontmatter 解析失敗，無法判定哪些記憶已被取代\n' >&2
      exit 1
    fi
    rm -f "$PARSE_OUT"

    CHECKS_OUT="$(mktemp)"
    if ! run_checks "$CHECKS_OUT"; then
      rm -f "$CHECKS_OUT"
      checks_failed "未輸出任何搜尋結果"
      exit 1
    fi
    # dangling_ref 也要擋，但只擋**取代關係**上的那種：`superseded_by` 指向
    # 一則不存在的記憶時，那則記憶會被當成已取代而排除，於是一個**仍然有效**
    # 的事實從結果裡消失，而 exit code 是 0——使用者讀到的是「沒有這回事」。
    # 正文的 `[[x]]` 壞掉不影響「誰該被排除」，不在此列。
    if checks_scan "$CHECKS_OUT" search test; then
      checks_scan "$CHECKS_OUT" search emit >&2
      printf 'WARN -: search_aborted 取代關係無法判定，不輸出可能已遺漏事實的清單\n' >&2
      rm -f "$CHECKS_OUT"; exit 1
    fi
    rm -f "$CHECKS_OUT"

    # 單次 awk 掃完所有檔案。舊版在 bash 迴圈裡逐則開兩個子行程
    # （描述一次 grep、正文一次 awk|grep），500 則實測 14.3 秒——
    # 搜尋是日常操作，慢成那樣等於沒人會用。
    search_files=()
    while IFS= read -r sbank; do
      [ -n "$sbank" ] || continue
      for sf in "$sbank"/*.md; do
        [ -f "$sf" ] || continue
        [ -L "$sf" ] && continue   # 已由 build_model 記成拒收，此處不重複回報
        sbase="${sf##*/}"
        # 與 build_model 同一條規則，兩邊看到的檔案集必須一致
        case "$sbase" in
          [Mm][Ee][Mm][Oo][Rr][Yy].[Mm][Dd]) continue ;;
          .*) continue ;;
          *[[:cntrl:]]*) continue ;;
        esac
        search_files+=("$sf")
      done
    done < <(list_banks)
    [ ${#search_files[@]} -gt 0 ] || exit 0
    # 不可寫成 `awk ... | sort` 後直接 exit 0——那會把 awk 的失敗蓋掉，
    # 掃描失敗與「真的沒有命中」在畫面上長得一模一樣，而使用者會把
    # 「查不到」當成「不存在」。先落暫存檔、確認成功，再輸出。
    SEARCH_OUT="$(mktemp)"
    # 關鍵字走環境變數而非 `-v`：awk 的 `-v` 會解譯反斜線跳脫，
    # `search '\t'` 會變成搜尋一個 TAB，與 README 宣告的「字面子字串」不符。
    # ENVIRON 是 POSIX awk 的一部分，gawk 與 mawk 都有。
    # 固定 LC_ALL=C：契約寫的是「ASCII 大小寫不敏感」，而 ambient locale 的
    # tolower 不是。土耳其語 locale 下 `I` 不會對到 ASCII 的 `i`，
    # 於是搜尋靜默地漏掉命中。UTF-8 的子字串比對在 byte 層仍然正確。
    if ! MEMORY_KW="$KEYWORD" LC_ALL=C awk -v US="$FS_US" -f "$SELF_DIR/memory-search.awk" \
             "$MODEL" "${search_files[@]}" > "$SEARCH_OUT" 2>"$CHECKS_ERR"; then
      rm -f "$SEARCH_OUT"
      sed 's/^/  /' "$CHECKS_ERR" >&2
      printf 'WARN -: search_failed 掃描記憶正文失敗，未輸出任何結果\n' >&2
      exit 1
    fi
    # sort 也要確認成功再輸出。磁碟或暫存空間不足時它會吐出半截結果，
    # 而 search 的契約是「失敗不可以長得像查無」。
    if [ "${MEMORY_FORCE_FAIL_SORT:-}" = 1 ]; then
      sort_ok=1
    elif LC_ALL=C sort -o "$SEARCH_OUT" "$SEARCH_OUT" 2>"$CHECKS_ERR"; then
      sort_ok=0
    else
      sort_ok=1
    fi
    if [ "$sort_ok" = 1 ]; then
      rm -f "$SEARCH_OUT"
      sed 's/^/  /' "$CHECKS_ERR" >&2
      printf 'WARN -: search_failed 結果排序失敗，未輸出任何結果\n' >&2
      exit 1
    fi
    cat "$SEARCH_OUT"
    rm -f "$SEARCH_OUT"
    exit 0
    ;;
esac
