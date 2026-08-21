#!/usr/bin/env bash
# scripts/memory.sh 的回歸測試。
#
# 全部在隔離 fixture 上跑，**一律傳 --home**，絕不讀使用者真實記憶庫。
# 斷言比對穩定 code（如 overdue / index_drift），不比對中文字樣——字樣會改，code 不會。
# 標 [regression] 的是實作時實測踩到過的缺陷，不可移除。
#
# Run: bash tests/memory.test.sh [--only parser|checks|cli|write]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MEM="$ROOT/scripts/memory.sh"
[ -f "$MEM" ] || { echo "找不到 $MEM" >&2; exit 2; }

ONLY="all"
[ "${1:-}" = "--only" ] && { ONLY="${2:-all}"; }

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "$2"; }
# 斷言「某個 code 不出現」，不管整體 exit code。
# 需要它是因為多數 fixture 沒有 MEMORY.md（那是另一項檢查的範圍），
# 用 exit 0 當條件會把不相關的 index_missing 也算進來，測不出真正要測的東西。
wantnot(){ # wantnot <desc> <forbidden-substr> <cmd...>
  local d="$1" sub="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in
    *"$sub"*) ng "$d" "不該出現「$sub」：$(printf '%s' "$out" | grep -F "$sub" | head -1)" ;;
    *) ok "$d" ;;
  esac
}
want(){ # want <desc> <expected-exit> <expected-substr|-> <cmd...>
  local d="$1" ec="$2" sub="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" != "$ec" ]; then ng "$d" "exit 期望 $ec 實得 $rc；輸出: $(printf '%s' "$out" | head -2)"; return; fi
  if [ "$sub" != "-" ]; then
    case "$out" in *"$sub"*) ;; *) ng "$d" "輸出缺少「$sub」：$(printf '%s' "$out" | head -2)"; return ;; esac
  fi
  ok "$d"
}

# mkmem <bank> <id> [extra metadata lines...] < body
mkmem(){
  local bank="$1" id="$2"; shift 2
  mkdir -p "$bank"
  { printf -- '---\nname: %s\ndescription: %s 的說明\nmetadata:\n' "$id" "$id"
    printf '  node_type: memory\n  type: project\n'
    for l in "$@"; do printf '  %s\n' "$l"; done
    printf -- '---\n'
    cat
  } > "$bank/$id.md"
}

# mkbig <bank> <id> <目標 bytes> <段落數>
# 門檻是「> SPLIT_BYTES 且 >= SPLIT_PARAS」，要驗邊界就得能**精準**做出剛好等於
# 門檻與剛好多一 byte 的檔案；靠「大概幾百 bytes 乘幾段」湊不出來，而且門檻一改動，
# 那種 fixture 會無聲地跑到門檻的另一邊（實測發生過）。
mkbig(){
  local bank="$1" id="$2" target="$3" paras="$4" f cur pad i
  mkdir -p "$bank"; f="$bank/$id.md"
  { printf -- '---\nname: %s\ndescription: 門檻邊界測試\nmetadata:\n  node_type: memory\n  type: project\n---\n' "$id"
    i=1; while [ "$i" -lt "$paras" ]; do printf 'x\n\n'; i=$((i+1)); done
    printf 'y\n'
  } > "$f"
  cur=$(wc -c < "$f"); pad=$((target - cur))
  if [ "$pad" -gt 0 ]; then
    # 補在**最後一段內部**：先去掉結尾換行、補字、再補回換行，段落數才不會多一
    head -c $((cur - 1)) "$f" > "$f.tmp"
    head -c "$pad" /dev/zero | tr '\0' 'z' >> "$f.tmp"
    printf '\n' >> "$f.tmp"
    mv "$f.tmp" "$f"
  fi
}

golden_index(){ # golden_index <topics> <pinned-blocks...>
  printf '# Memory Index\n\n<!-- PINNED:BEGIN -->\n'
  printf '%s' "$2"
  printf '<!-- PINNED:END -->\n\n<!-- TOPICS:BEGIN -->\n%s\n<!-- TOPICS:END -->\n\n' "$1"
  printf '搜尋：`~/.claude/scripts/memory search "<關鍵字>"`\n'
  printf '稽核：`~/.claude/scripts/memory audit`\n'
}

# ============================ parser / renderer ============================
if [ "$ONLY" = "all" ] || [ "$ONLY" = "parser" ]; then
echo "== frontmatter 契約 =="

H="$SANDBOX/h1"; B="$H/memory"
mkmem "$B" good <<< '正文。'
wantnot "合法記憶不報 malformed" "malformed_frontmatter" bash "$MEM" audit --home "$H" --today 2026-01-01

# [regression] 既有資料的 originSessionId 是 camelCase；鍵名 regex 若只允許小寫，
# 會把全部既有記憶誤判為 bad_indent（實作時 9/9 全中）。
H="$SANDBOX/h2"; B="$H/memory"
mkmem "$B" camel 'originSessionId: 3ebe0795-0c0c-47b5-b61f-fb976ab72adf' <<< '正文。'
wantnot "[regression] camelCase 既有欄位不得判 malformed" "malformed_frontmatter" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/h3"; B="$H/memory"
mkmem "$B" mismatch <<< '正文。'
sed -i 's/^name: mismatch$/name: something-else/' "$B/mismatch.md"
want "name ≠ filename stem → malformed" 1 "malformed_frontmatter" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/h4"; B="$H/memory"
mkmem "$B" baddate 'review_by: 2026-13-99' <<< '正文。'
want "review_by 非合法日期 → malformed" 1 "bad_review_by" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

# [regression] 只做「數字形狀」檢查會放行 2026-02-30 這種不存在的日期。
# 更隱蔽的是 fallback 的觸發條件：曾把「date 說這個日期非法」誤讀成
# 「date 工具不可用」而掉進寬鬆分支，於是 2 月 30 日被放行。
H="$SANDBOX/h4b"; B="$H/memory"
mkmem "$B" feb30 'review_by: 2026-02-30' <<< '正文。'
want "[regression] 2 月 30 日 → malformed" 1 "bad_review_by" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/h4c"; B="$H/memory"
mkmem "$B" nonleap 'review_by: 2026-02-29' <<< '正文。'
want "[regression] 非閏年 2/29 → malformed" 1 "bad_review_by" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/h4d"; B="$H/memory"
mkmem "$B" leap 'review_by: 2024-02-29' <<< '正文。'
wantnot "閏年 2/29 → 合法（不可過度嚴格）" "bad_review_by" \
     bash "$MEM" audit --home "$H" --today 2024-01-01

H="$SANDBOX/h5"; B="$H/memory"
mkmem "$B" quoted <<< '正文。'
sed -i 's/^description: .*$/description: "帶引號"/' "$B/quoted.md"
want "值帶引號 → malformed" 1 "malformed_frontmatter" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== 到期判定（--today 可注入，不依賴真實時鐘）=="
H="$SANDBOX/h6"; B="$H/memory"
mkmem "$B" due 'review_by: 2026-09-03' <<< '正文。'
wantnot "到期前一天不報" "overdue" bash "$MEM" audit --home "$H" --today 2026-09-02
wantnot "當天不報（< 才算過期）" "overdue" bash "$MEM" audit --home "$H" --today 2026-09-03
want "隔天報 overdue（含穩定 code）" 1 "overdue review_by=2026-09-03 today=2026-09-04" \
     bash "$MEM" audit --home "$H" --today 2026-09-04

echo "== canonical rendering =="
H="$SANDBOX/h7"; B="$H/memory"
mkmem "$B" zero <<< '不釘選。'
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
want "零 pin 的 golden 通過 --check" 0 - bash "$MEM" index --check --home "$H"

H="$SANDBOX/h8"; B="$H/memory"
mkmem "$B" p1 'pin: true' <<< '第一則釘選。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM p1 -->\n第一則釘選。\n')
" > "$B/MEMORY.md"
want "一個 pin 的 golden 通過 --check" 0 - bash "$MEM" index --check --home "$H"

H="$SANDBOX/h9"; B="$H/memory"
mkmem "$B" a1 'pin: true' <<< 'A 內容。'
mkmem "$B" b1 'pin: true' <<< 'B 內容。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM a1 -->\nA 內容。\n<!-- PINNED:ITEM b1 -->\nB 內容。\n')
" > "$B/MEMORY.md"
want "兩個 pin 依 ID 排序且不插空行" 0 - bash "$MEM" index --check --home "$H"

echo "== 索引狀態三分 =="
H="$SANDBOX/h10"; B="$H/memory"
mkmem "$B" x1 <<< '正文。'
want "無 MEMORY.md → index_missing" 1 "index_missing" bash "$MEM" index --check --home "$H"

H="$SANDBOX/h11"; B="$H/memory"
mkmem "$B" x2 <<< '正文。'
printf '# Memory Index\n\n沒有標記\n' > "$B/MEMORY.md"
want "標記缺失 → invalid_index_markers" 1 "invalid_index_markers" \
     bash "$MEM" index --check --home "$H"

H="$SANDBOX/h12"; B="$H/memory"
mkmem "$B" x3 'pin: true' <<< '原始內容。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM x3 -->\n原始內容。\n')
" > "$B/MEMORY.md"
want "索引與來源一致 → 通過" 0 - bash "$MEM" index --check --home "$H"
printf '被改動了。\n' >> "$B/x3.md"
want "[regression] 改動 pin 原檔 → index_drift" 1 "index_drift" \
     bash "$MEM" index --check --home "$H"

echo "== eligible set =="
H="$SANDBOX/h13"; B="$H/memory"
mkmem "$B" old1 'pin: true' 'superseded_by: new1' <<< '舊的。'
mkmem "$B" new1 'pin: true' 'supersedes: [old1]' <<< '新的。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM new1 -->\n新的。\n')
" > "$B/MEMORY.md"
want "已被取代者不進 pin block" 0 - bash "$MEM" index --check --home "$H"

echo "== 來源集合 =="
H="$SANDBOX/h14"; B="$H/memory"
mkmem "$B" only1 'pin: true' <<< '唯一內容。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM only1 -->\n唯一內容。\n')
" > "$B/MEMORY.md"
want "[regression] MEMORY.md 不得被當成來源記憶" 0 - bash "$MEM" index --check --home "$H"
out="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>&1)"
case "$out" in *"memories 1"*) ok "來源計數排除 MEMORY.md" ;; *) ng "來源計數排除 MEMORY.md" "$out" ;; esac

echo "== TOPICS 區塊由人工維護，renderer 原樣保留 =="
H="$SANDBOX/h15"; B="$H/memory"
mkmem "$B" t1 'pin: true' <<< '內容。'
golden_index "主題：部署與環境／制度與裁定" "$(printf '<!-- PINNED:ITEM t1 -->\n內容。\n')
" > "$B/MEMORY.md"
want "自訂 TOPICS 不被 renderer 覆寫" 0 - bash "$MEM" index --check --home "$H"

echo "== 多 bank =="
H="$SANDBOX/h16"
mkmem "$H/memory" g1 'pin: true' <<< '全域內容。'
mkmem "$H/projects/proj-a/memory" p1 <<< '專案 A。'
mkmem "$H/projects/proj-b/memory" p1 <<< '專案 B。'
out="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>&1)"
case "$out" in
  *"banks 3"*) ok "全域庫與專案庫都被掃到" ;;
  *) ng "全域庫與專案庫都被掃到" "$out" ;;
esac
case "$out" in
  *"memories 3"*) ok "[regression] 兩庫同名 p1 各自獨立，不互相吃掉" ;;
  *) ng "[regression] 兩庫同名 p1 各自獨立" "$out" ;;
esac

echo "== 2-gram 能力偵測 =="
out="$(bash "$MEM" audit --home "$SANDBOX/h1" --today 2026-01-01 2>&1)"
case "$out" in
  *"gram_mode char"*|*"gram_mode byte"*) ok "有回報 gram_mode（不默默降級）" ;;
  *) ng "有回報 gram_mode" "$out" ;;
esac
fi


# ================================ checks ================================
if [ "$ONLY" = "all" ] || [ "$ONLY" = "checks" ]; then
echo "== 連結與關係 =="

H="$SANDBOX/c1"; B="$H/memory"
mkmem "$B" src1 <<< '參考 [[nowhere]]。'
want "[[不存在]] → dangling_ref" 1 "dangling_ref" bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/c2"; B="$H/memory"
mkmem "$B" a2 <<< '參考 [[b2]]。'
mkmem "$B" b2 <<< '被參考。'
wantnot "[[存在]] → 不報 dangling_ref" "dangling_ref" bash "$MEM" audit --home "$H" --today 2026-01-01

# 跨專案庫引用禁止；解析到全域庫則合法
H="$SANDBOX/c3"
mkmem "$H/memory" gid <<< '全域記憶。'
mkmem "$H/projects/pa/memory" pa1 <<< '參考全域 [[gid]]。'
wantnot "專案庫可解析到全域庫" "dangling_ref" bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/c4"
mkmem "$H/projects/pa/memory" only-a <<< '內容。'
mkmem "$H/projects/pb/memory" pb1 <<< '想參考別的專案 [[only-a]]。'
want "[regression] 跨專案庫引用 → dangling_ref" 1 "dangling_ref" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== 取代關係雙向一致 =="
H="$SANDBOX/c5"; B="$H/memory"
mkmem "$B" oldx 'superseded_by: newx' <<< '舊。'
mkmem "$B" newx 'supersedes: [oldx]' <<< '新。'
wantnot "雙向一致 → 不報 relation_mismatch" "relation_mismatch" bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/c6"; B="$H/memory"
mkmem "$B" old2 'superseded_by: new2' <<< '舊。'
mkmem "$B" new2 <<< '新（忘了寫 supersedes）。'
want "[regression] 只寫單邊 → relation_mismatch" 1 "relation_mismatch" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/c7"; B="$H/memory"
mkmem "$B" selfsup 'superseded_by: selfsup' <<< '自我取代。'
want "自我取代 → relation_mismatch" 1 "relation_mismatch" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

H="$SANDBOX/c8"; B="$H/memory"
mkmem "$B" cyc1 'superseded_by: cyc2' 'supersedes: [cyc2]' <<< '環 1。'
mkmem "$B" cyc2 'superseded_by: cyc1' 'supersedes: [cyc1]' <<< '環 2。'
want "取代環路 → relation_mismatch" 1 "relation_mismatch" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== zombie =="
H="$SANDBOX/c9"; B="$H/memory"
mkmem "$B" zomb 'pin: true' 'superseded_by: alive' <<< '殭屍。'
mkmem "$B" alive 'supersedes: [zomb]' <<< '現行。'
golden_index "主題：（尚未分類）" "$(printf '<!-- PINNED:ITEM zomb -->\n殭屍。\n')
" > "$B/MEMORY.md"
want "已取代者仍在索引 → zombie" 1 "zombie" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== CLAUDE.md 跨庫引用 =="
H="$SANDBOX/c10"; mkdir -p "$H/memory"
mkmem "$H/memory" exists1 <<< '存在。'
printf '見 memory `exists1` 的說明。\n' > "$H/CLAUDE.md"
wantnot "引用存在的全域記憶 → 不報" "claude_md_dangling" bash "$MEM" audit --home "$H" --today 2026-01-01
printf '見 memory `gone1` 的說明。\n' >> "$H/CLAUDE.md"
want "[regression] 引用不存在 → claude_md_dangling" 1 "claude_md_dangling" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
printf '一般散文提到 memory 這個詞不該被解析。\n' > "$H/CLAUDE.md"
wantnot "散文中的 memory 不解析（不得誤報）" "claude_md_dangling" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== 候選型檢查不影響 exit code =="
H="$SANDBOX/c11"; B="$H/memory"
mkbig "$B" big 4096 6
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
want "[regression] 只有 SUGGEST 時 exit 仍為 0" 0 "split_candidate" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== split_candidate 的門檻邊界 =="
# 條件是「bytes > 3072 **且** paras >= 4」，四個邊界都要驗：
# 剛好等於（不報）、多一 byte（報）、段落剛好不足（不報）、段落剛好足夠（報）。
H="$SANDBOX/sb1"; B="$H/memory"; mkbig "$B" exact 3072 6
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
[ "$(wc -c < "$B/exact.md")" = 3072 ] && ok "fixture 精準命中 3072 bytes" || ng "fixture 大小" "$(wc -c < "$B/exact.md")"
want "剛好等於門檻時 audit 乾淨（不混入 index_missing）" 0 - \
     bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "[regression] 剛好等於門檻 → 不報（條件是 >，不是 >=）" "split_candidate" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
H="$SANDBOX/sb2"; B="$H/memory"; mkbig "$B" over 3073 6
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
want "[regression] 門檻 +1 byte → 報" 0 "split_candidate" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
H="$SANDBOX/sb3"; B="$H/memory"; mkbig "$B" fewpara 8000 3
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
want "段落不足時 audit 乾淨" 0 - bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "[regression] 夠大但只有 3 段 → 不報（需 >= 4 段）" "split_candidate" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
H="$SANDBOX/sb4"; B="$H/memory"; mkbig "$B" justpara 8000 4
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
want "[regression] 夠大且剛好 4 段 → 報" 0 "split_candidate" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== 空 bank 不報 index_missing =="
H="$SANDBOX/c12"; mkdir -p "$H/projects/empty/memory" "$H/memory"
mkmem "$H/memory" one1 <<< '內容。'
golden_index "主題：（尚未分類）" "" > "$H/memory/MEMORY.md"
want "[regression] 沒有記憶的 bank 不報 index_missing" 0 - \
     bash "$MEM" index --check --home "$H"
fi

# ================================== cli ==================================
if [ "$ONLY" = "all" ] || [ "$ONLY" = "cli" ]; then
echo "== 參數驗證 =="
want "未知子命令 → exit 2" 2 - bash "$MEM" bogus
want "未知參數 → exit 2" 2 - bash "$MEM" audit --bogus
want "--home 缺值 → exit 2" 2 - bash "$MEM" audit --home
want "--today 非日期 → exit 2" 2 - bash "$MEM" audit --today notadate
want "根目錄不存在 → exit 2" 2 - bash "$MEM" audit --home /no/such/root
want "空關鍵字 → exit 2" 2 - bash "$MEM" search "" --home "$SANDBOX"

echo "== search =="
H="$SANDBOX/s1"; B="$H/memory"
mkmem "$B" alpha <<< '內容提到 Docker 與部署。'
mkmem "$B" beta  <<< '完全無關的內容。'
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
out="$(bash "$MEM" search "Docker" --home "$H")"
case "$out" in
  *"alpha"*) ok "命中正文關鍵字" ;;
  *) ng "命中正文關鍵字" "$out" ;;
esac
case "$out" in
  *"beta"*) ng "不該命中無關記憶" "$out" ;;
  *) ok "不命中無關記憶" ;;
esac
case "$out" in
  *"$B/alpha.md"$'\t'"alpha"$'\t'*) ok "輸出格式為 path<TAB>id<TAB>description" ;;
  *) ng "輸出格式" "$out" ;;
esac
out="$(bash "$MEM" search "docker" --home "$H")"
case "$out" in *"alpha"*) ok "ASCII 大小寫不敏感" ;; *) ng "ASCII 大小寫不敏感" "$out" ;; esac
out="$(bash "$MEM" search "Doc.er" --home "$H")"
case "$out" in *"alpha"*) ng "關鍵字不得當正規式" "$out" ;; *) ok "[regression] 關鍵字當字面字串，不當正規式" ;; esac
out="$(bash "$MEM" search "zzz-none" --home "$H")"; rc=$?
if [ -z "$out" ] && [ "$rc" = 0 ]; then ok "零命中 → 空輸出 exit 0"; else ng "零命中" "out=[$out] rc=$rc"; fi

# [regression] 已被取代的記憶不得出現在搜尋結果——裸 grep 會撈回舊事實，
# 這正是 search 存在的理由。
H="$SANDBOX/s2"; B="$H/memory"
mkmem "$B" oldfact 'superseded_by: newfact' <<< '舊做法是用 compose 部署。'
mkmem "$B" newfact 'supersedes: [oldfact]' <<< '現行做法是 native 部署。'
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
out="$(bash "$MEM" search "部署" --home "$H")"
case "$out" in *"newfact"*) ok "現行記憶會出現" ;; *) ng "現行記憶會出現" "$out" ;; esac
case "$out" in *"oldfact"*) ng "[regression] 已取代者不得出現" "$out" ;; *) ok "[regression] 已取代者不出現在搜尋結果" ;; esac

# 關係不一致時寧可不給答案
H="$SANDBOX/s3"; B="$H/memory"
mkmem "$B" broken1 'superseded_by: broken2' <<< '內容 A。'
mkmem "$B" broken2 <<< '內容 B（缺反向欄）。'
want "[regression] 關係不一致 → 中止且不輸出結果" 1 "search_aborted" \
     bash "$MEM" search "內容" --home "$H"
out="$(bash "$MEM" search "內容" --home "$H" 2>/dev/null)"
[ -z "$out" ] && ok "中止時 stdout 為空" || ng "中止時 stdout 為空" "$out"

# keyword 以 -- 之後取得，不會被誤判為選項
H="$SANDBOX/s4"; B="$H/memory"
mkmem "$B" opt1 <<< '這裡提到 --home 這個字串。'
golden_index "主題：（尚未分類）" "" > "$B/MEMORY.md"
out="$(bash "$MEM" search --home "$H" -- --home)"
case "$out" in *"opt1"*) ok "[regression] -- 之後的 --home 當關鍵字而非選項" ;; *) ng "-- 之後當關鍵字" "$out" ;; esac
fi

# ================================= write =================================
if [ "$ONLY" = "all" ] || [ "$ONLY" = "write" ]; then
echo "== index --write =="
H="$SANDBOX/w1"; B="$H/memory"
mkmem "$B" wp1 'pin: true' <<< '釘選內容。'
want "無索引時建立" 0 - bash "$MEM" index --write --home "$H"
want "建立後 --check 通過" 0 - bash "$MEM" index --check --home "$H"
[ -z "$(ls -a "$B" | grep '^\.MEMORY')" ] && ok "成功後無暫存/備份殘留" || ng "成功後無殘留" "$(ls -a "$B")"

# 新增 pin 必然造成漂移，--write 必須能修復它
H="$SANDBOX/w2"; B="$H/memory"
mkmem "$B" wa 'pin: true' <<< 'A。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
mkmem "$B" wb 'pin: true' <<< 'B。'
want "新增 pin → 先偵測到 drift" 1 "index_drift" bash "$MEM" index --check --home "$H"
want "[regression] --write 必須能修復自己偵測到的 drift" 0 - bash "$MEM" index --write --home "$H"
want "修復後 --check 通過" 0 - bash "$MEM" index --check --home "$H"

echo "== preflight：來源資料錯誤時不得修改任何檔案 =="
H="$SANDBOX/w3"; B="$H/memory"
mkmem "$B" wok 'pin: true' <<< '正常。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
before="$(md5sum < "$B/MEMORY.md")"
mkmem "$B" wbad <<< '參考 [[nowhere]]。'
want "[regression] dangling_ref → write_aborted" 1 "write_aborted" \
     bash "$MEM" index --write --home "$H"
[ "$before" = "$(md5sum < "$B/MEMORY.md")" ] && ok "阻擋時索引完全未動" || ng "阻擋時索引未動" "已被修改"

H="$SANDBOX/w4"; B="$H/memory"
mkmem "$B" wm1 <<< '正文含 <!-- PINNED:BEGIN --> 保留標記。'
want "正文含保留標記 → 阻擋" 1 "reserved_marker" bash "$MEM" index --write --home "$H"

H="$SANDBOX/w5"; B="$H/memory"
mkmem "$B" wz <<< '正常。'
printf '# Memory Index\n\n沒有標記\n' > "$B/MEMORY.md"
want "標記毀損 → 阻擋（不猜測範圍）" 1 "invalid_index_markers" \
     bash "$MEM" index --write --home "$H"

echo "== 交易性：任一 bank 失敗要全部回復 =="
H="$SANDBOX/w6"
mkmem "$H/memory" tg 'pin: true' <<< '全域。'
mkmem "$H/projects/pa/memory" tp 'pin: true' <<< '專案。'
printf '# Memory Index\n\n<!-- PINNED:BEGIN -->\n<!-- PINNED:END -->\n\n<!-- TOPICS:BEGIN -->\n主題：舊\n<!-- TOPICS:END -->\n\n舊尾巴\n' > "$H/memory/MEMORY.md"
b1before="$(md5sum < "$H/memory/MEMORY.md")"
want "注入第 2 個 bank 失敗 → 回復" 1 "write_rolled_back" \
     env MEMORY_FORCE_FAIL_BANK=2 bash "$MEM" index --write --home "$H"
[ "$b1before" = "$(md5sum < "$H/memory/MEMORY.md")" ] && ok "[regression] 已取代的 bank1 還原成原內容" \
  || ng "bank1 還原" "內容不同"
[ ! -f "$H/projects/pa/memory/MEMORY.md" ] && ok "[regression] 原本不存在的索引回復後仍不存在（不留空索引）" \
  || ng "原本不存在的索引" "留下了檔案"
[ -z "$(ls -a "$H/memory" "$H/projects/pa/memory" 2>/dev/null | grep '^\.MEMORY')" ] \
  && ok "回復後無暫存/備份殘留" || ng "回復後無殘留" "有殘留"

echo "== 交易性：備份失敗必須中止（T8a codex Required） =="
# 備份失敗若放行，existed 會停在 0，而索引已被覆寫；之後任一 bank 失敗時
# rollback 會把「原本就存在的索引」當成本次新建的直接刪掉——交易保證就地失效。
H="$SANDBOX/w7"
mkmem "$H/memory" bg 'pin: true' <<< '全域。'
mkmem "$H/projects/pa/memory" bp 'pin: true' <<< '專案。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
g_before="$(md5sum < "$H/memory/MEMORY.md")"
p_before="$(md5sum < "$H/projects/pa/memory/MEMORY.md")"
# 兩邊都改動 pin 內容，讓 --write 確實會重寫兩個 bank
mkmem "$H/memory" bg 'pin: true' <<< '全域改過了。'
mkmem "$H/projects/pa/memory" bp 'pin: true' <<< '專案改過了。'
want "[regression] 第 2 個 bank 備份失敗 → backup_failed" 1 "backup_failed"      env MEMORY_FORCE_FAIL_BACKUP=2 bash "$MEM" index --write --home "$H"
[ "$g_before" = "$(md5sum < "$H/memory/MEMORY.md")" ]   && ok "[regression] 備份失敗時已取代的 bank1 有被還原" || ng "bank1 還原" "內容不同"
[ "$p_before" = "$(md5sum < "$H/projects/pa/memory/MEMORY.md")" ]   && ok "備份失敗的 bank2 未被修改" || ng "bank2 未動" "內容不同"
[ -z "$(ls -a "$H/memory" "$H/projects/pa/memory" 2>/dev/null | grep '^\.MEMORY')" ]   && ok "備份失敗後無暫存/備份殘留" || ng "無殘留" "有殘留"

echo "== 保留標記涵蓋 TOPICS（T8a codex Required） =="
# extract_topics 取的是第一組 TOPICS 標記。釘選記憶的正文若含 TOPICS:BEGIN，
# 人工維護的主題區塊會被記憶正文蓋掉，且 --check 之後永遠對不起來。
H="$SANDBOX/w8"; B="$H/memory"
mkmem "$B" wt <<< '正文含 <!-- TOPICS:BEGIN --> 標記。'
want "[regression] 正文含 TOPICS 標記 → reserved_marker" 1 "reserved_marker"      bash "$MEM" index --write --home "$H"
fi


if [ "$ONLY" = "all" ] || [ "$ONLY" = "checks" ]; then
echo "== T8a codex 第二輪：來源讀取與交易安全 =="
# 1) model 建置失敗必須讓所有子命令中止。一份不完整的 model 在下游看起來
#    就是「記憶比較少」，renderer 會照著它把讀不到的釘選內容直接刪掉。
H="$SANDBOX/r1"; B="$H/memory"
mkmem "$B" r1a 'pin: true' <<< '重要的釘選內容。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
r1before="$(md5sum < "$B/MEMORY.md")"
want "[regression] model 建置失敗 → audit 中止" 1 "model_build_failed" \
     env MEMORY_FORCE_FAIL_BUILD=1 bash "$MEM" audit --home "$H"
want "[regression] model 建置失敗 → --write 中止" 1 "model_build_failed" \
     env MEMORY_FORCE_FAIL_BUILD=1 bash "$MEM" index --write --home "$H"
[ "$r1before" = "$(md5sum < "$B/MEMORY.md")" ] \
  && ok "[regression] 建置失敗時索引完全未動" || ng "索引未動" "已被修改"
want "[regression] model 建置失敗 → search 中止" 1 "model_build_failed" \
     env MEMORY_FORCE_FAIL_BUILD=1 bash "$MEM" search 釘選 --home "$H"

# 2) 零位元組 .md 完全不會觸發 awk 的 FNR==1，不特別處理的話它在 model 裡
#    根本不存在——而「不存在」在下游等於「沒有問題」。
H="$SANDBOX/r2"; B="$H/memory"
mkmem "$B" r2a <<< '正常。'
: > "$B/r2empty.md"
want "[regression] 零位元組記憶 → empty_file" 1 "empty_file" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

# 3) frontmatter 解析失敗可能把 superseded_by 整個吃掉，於是一則**已被取代**的
#    記憶看起來完全正常，照樣出現在搜尋結果裡，而且沒有 relation_mismatch 可偵測。
H="$SANDBOX/r3"; B="$H/memory"
mkmem "$B" r3old <<< '舊的部署做法 dockerdeploy。'
printf -- '---\nname: r3old\ndescription: 舊的部署做法\nmetadata:\n  node_type: memory\n  type: project\n  superseded_by: "r3new"\n---\n舊的部署做法 dockerdeploy。\n' > "$B/r3old.md"
mkmem "$B" r3new <<< '新的部署做法。'
want "[regression] 取代欄位解析失敗 → search 中止不給答案" 1 "search_aborted" \
     bash "$MEM" search dockerdeploy --home "$H"
# 反面：與取代關係無關的解析錯誤不該讓搜尋整個停擺
H="$SANDBOX/r3b"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: notmystem\ndescription: 名稱與檔名不符\nmetadata:\n  node_type: memory\n  type: project\n---\n關鍵字 zzfindme。\n' > "$B/r3ok.md"
want "[regression] 與取代無關的解析錯誤不阻斷搜尋" 0 "r3ok" \
     bash "$MEM" search zzfindme --home "$H"

# 4) 還原失敗時必須保留備份。備份是原始索引僅存的一份，連同人工維護的 TOPICS；
#    還原沒成功卻順手刪掉它，等於用一次失敗換掉使用者的資料。
H="$SANDBOX/r4"
mkmem "$H/memory" r4g 'pin: true' <<< '全域。'
mkmem "$H/projects/pa/memory" r4p 'pin: true' <<< '專案。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
mkmem "$H/memory" r4g 'pin: true' <<< '全域改過了。'
mkmem "$H/projects/pa/memory" r4p 'pin: true' <<< '專案改過了。'
want "[regression] 還原失敗 → rollback_failed" 1 "rollback_failed" \
     env MEMORY_FORCE_FAIL_BANK=2 MEMORY_FORCE_FAIL_RESTORE=1 \
     bash "$MEM" index --write --home "$H"
[ -n "$(ls -a "$H/memory" | grep '^\.MEMORY\.md\.bak\.')" ] \
  && ok "[regression] 還原失敗時備份被保留（不刪掉唯一一份原檔）" \
  || ng "備份保留" "備份被刪掉了"

# 5) bytes 必須等於 wc -c，包含沒有結尾換行的檔案
H="$SANDBOX/r5"; B="$H/memory"; mkdir -p "$B"
{ printf -- '---\nname: nonl\ndescription: 無結尾換行\nmetadata:\n  node_type: memory\n  type: project\n---\n'
  for i in 1 2 3 4 5; do
    for j in 1 2 3 4 5 6 7 8 9 10; do printf '這是一段中文正文用來測試位元組計數是否正確無誤。\n'; done
    printf '\n'
  done
  printf '最後一行沒有結尾換行'
} > "$B/nonl.md"
nb="$(wc -c < "$B/nonl.md")"
out="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep split_candidate)"
case "$out" in
  *"bytes=$nb"*) ok "[regression] 無結尾換行的檔案 bytes 仍等於 wc -c（$nb）" ;;
  *) ng "無結尾換行 bytes" "期望 bytes=$nb，實得: ${out:-（無 split_candidate）}" ;;
esac

# 6) dup 候選對不得因 awk 陣列迭代順序而重複輸出
H="$SANDBOX/r6"; B="$H/memory"; mkdir -p "$B"
for n in d1 d2 d3; do
  printf -- '---\nname: %s\ndescription: 部署與環境的設定與注意事項說明\nmetadata:\n  node_type: memory\n  type: project\n---\n正文 %s。\n' "$n" "$n" > "$B/$n.md"
done
dupout="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep -c dup_candidate)"
[ "$dupout" = 3 ] && ok "[regression] 三則互似 → 恰 3 對，無重複輸出" \
  || ng "dup 對數" "期望 3 實得 $dupout"

echo "== T8a codex 第三輪：標記範圍、fail-closed、重複 key =="
# 1) TOPICS 標記範圍未定義時不得寫入。缺 END 時 extract_topics 會一路抓到檔尾，
#    把搜尋／稽核兩行也吞進 TOPICS 區塊，人工維護的主題分類就被 --write 蓋掉。
for shape in missing_end double_begin wrong_order; do
  H="$SANDBOX/m-$shape"; B="$H/memory"
  mkmem "$B" ma 'pin: true' <<< '正文。'
  case "$shape" in
    missing_end)
      printf '# Memory Index\n\n<!-- PINNED:BEGIN -->\n<!-- PINNED:END -->\n\n<!-- TOPICS:BEGIN -->\n主題：手寫的分類\n\n搜尋：x\n' > "$B/MEMORY.md" ;;
    double_begin)
      printf '# Memory Index\n\n<!-- PINNED:BEGIN -->\n<!-- PINNED:END -->\n\n<!-- TOPICS:BEGIN -->\n主題：一\n<!-- TOPICS:BEGIN -->\n主題：二\n<!-- TOPICS:END -->\n' > "$B/MEMORY.md" ;;
    wrong_order)
      printf '# Memory Index\n\n<!-- TOPICS:BEGIN -->\n主題：手寫\n<!-- TOPICS:END -->\n\n<!-- PINNED:BEGIN -->\n<!-- PINNED:END -->\n' > "$B/MEMORY.md" ;;
  esac
  mbefore="$(md5sum < "$B/MEMORY.md")"
  want "[regression] TOPICS 標記 $shape → --check 報 invalid_index_markers" 1 "invalid_index_markers" \
       bash "$MEM" index --check --home "$H"
  want "[regression] TOPICS 標記 $shape → --write 阻擋" 1 "invalid_index_markers" \
       bash "$MEM" index --write --home "$H"
  [ "$mbefore" = "$(md5sum < "$B/MEMORY.md")" ] \
    && ok "TOPICS 標記 $shape：索引未被覆寫" || ng "索引未被覆寫" "$shape 被改了"
done

# 2) 檢查程式失敗必須 fail closed——它的沉默被 --write 與 search 當成「沒問題」
H="$SANDBOX/fc"; B="$H/memory"
mkmem "$B" fca 'pin: true' <<< '正文。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
fcbefore="$(md5sum < "$B/MEMORY.md")"
want "[regression] checks 失敗 → --write 中止" 1 "checks_failed" \
     env MEMORY_FORCE_FAIL_CHECKS=1 bash "$MEM" index --write --home "$H"
[ "$fcbefore" = "$(md5sum < "$B/MEMORY.md")" ] && ok "checks 失敗時索引未動" || ng "索引未動" "被改了"
want "[regression] checks 失敗 → search 不給答案" 1 "checks_failed" \
     env MEMORY_FORCE_FAIL_CHECKS=1 bash "$MEM" search 正文 --home "$H"
want "[regression] checks 失敗 → audit 中止" 1 "checks_failed" \
     env MEMORY_FORCE_FAIL_CHECKS=1 bash "$MEM" audit --home "$H" --today 2026-01-01

# 3) 重複 key 不得靜默取最後一個。先 superseded_by: new 再一個空的，
#    會讓已被取代的記憶變回「現行」，而兩邊都不會有 relation_mismatch。
H="$SANDBOX/dk"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: dkold\ndescription: 舊做法\nmetadata:\n  node_type: memory\n  type: project\n  superseded_by: dknew\n  superseded_by:\n---\n舊做法 dkkeyword。\n' > "$B/dkold.md"
mkmem "$B" dknew 'supersedes: [dkold]' <<< '新做法。'
want "[regression] 重複 key → duplicate_key" 1 "duplicate_key:superseded_by" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] 重複的取代欄位 → search 中止而非回舊事實" 1 "search_aborted" \
     bash "$MEM" search dkkeyword --home "$H"

# 4) 專案記憶指向全域記憶時，inbound 要記在**全域那則**身上，
#    記在來源 bank 的話那則全域記憶明明被引用著卻會被報成 orphan
H="$SANDBOX/xb"
mkmem "$H/memory" xbglobal <<< '全域事實。'
mkmem "$H/projects/pz/memory" xbproj <<< '參考 [[xbglobal]]。'
wantnot "[regression] 被專案引用的全域記憶不算 orphan" "xbglobal.md: orphan" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第四輪：search 失敗語意、控制字元 =="
# 1) `awk | sort` 之後直接 exit 0 會把 awk 的失敗蓋掉——掃描失敗與「真的沒命中」
#    在畫面上一模一樣，而使用者會把「查不到」讀成「不存在」。
#    用一份壞掉的 memory-search.awk 製造真實失敗，不靠注入旗標。
H="$SANDBOX/sf"; B="$H/memory"
mkmem "$B" sfa <<< '關鍵字 sfkeyword。'
BROKEN="$SANDBOX/broken-scripts"; mkdir -p "$BROKEN"
cp "$ROOT/scripts/memory.sh" "$ROOT/scripts/memory-model.awk" "$ROOT/scripts/memory-checks.awk" "$BROKEN/"
printf 'BEGIN { this is not valid awk ((( }\n' > "$BROKEN/memory-search.awk"
want "[regression] search 掃描失敗 → 非 0 且不輸出結果" 1 "search_failed" \
     bash "$BROKEN/memory.sh" search sfkeyword --home "$H"
sfout="$(bash "$BROKEN/memory.sh" search sfkeyword --home "$H" 2>/dev/null)"
[ -z "$sfout" ] && ok "search 失敗時 stdout 為空" || ng "stdout 應為空" "$sfout"
# 反面：正常的腳本仍要找得到
want "同一份 fixture 用正常腳本找得到" 0 "sfa" bash "$MEM" search sfkeyword --home "$H"
# 缺少 awk 檔 → 用法錯誤（exit 2），不是靜默零結果
rm -f "$BROKEN/memory-search.awk"
want "[regression] 缺少 memory-search.awk → exit 2" 2 "memory-search.awk" \
     bash "$BROKEN/memory.sh" search sfkeyword --home "$H"

# 2) 值裡的控制字元會讓 model 的 US 分欄整排左移，pin／superseded_by 被讀成別的東西
H="$SANDBOX/cc"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: ccx\ndescription: 前段\037後段\nmetadata:\n  node_type: memory\n  type: project\n---\n正文。\n' > "$B/ccx.md"
want "[regression] 值含 US 控制字元 → control_char" 1 "control_char:description" \
     bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第五輪：CRLF、--today 曆法、pin 布林 =="
# 1) CRLF：Windows 編輯器存過一次就會讓第一行變成 `---\r`。少了正規化，
#    整份記憶被判 missing_frontmatter，而那是會讓 --write 與 search 中止的
#    來源錯誤——「用記事本開過」等於讓整個記憶庫停擺。
H="$SANDBOX/crlf"; B="$H/memory"; mkdir -p "$B"
printf -- '---\r\nname: crlfa\r\ndescription: CRLF 記憶\r\nmetadata:\r\n  node_type: memory\r\n  type: project\r\n  pin: true\r\n---\r\nCRLF 正文 crlfkey。\r\n' > "$B/crlfa.md"
wantnot "[regression] CRLF 記憶不得被判 missing_frontmatter" "missing_frontmatter" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "[regression] CRLF 記憶不得被判 name_stem_mismatch" "name_stem_mismatch" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] CRLF 記憶搜尋得到" 0 "crlfa" bash "$MEM" search crlfkey --home "$H"
want "[regression] CRLF 記憶可寫索引" 0 - bash "$MEM" index --write --home "$H"
want "CRLF 記憶寫完後 --check 通過" 0 - bash "$MEM" index --check --home "$H"
grep -q '<!-- PINNED:ITEM crlfa -->' "$B/MEMORY.md" \
  && ok "CRLF 的 pin: true 有進索引" || ng "pin 進索引" "沒進去"

# 2) --today 形狀對不代表日期存在。字串比較會照單全收 2026-02-30，
#    於是 overdue 判定整批偏掉且毫無警告——稽核工具自己算錯比不算更糟。
want "[regression] --today 2026-02-30 → exit 2" 2 "不是存在的日期" \
     bash "$MEM" audit --home "$H" --today 2026-02-30
want "--today 2026-02-28 → 接受" 0 - bash "$MEM" audit --home "$H" --today 2026-02-28
want "--today 2024-02-29（閏年）→ 接受" 0 - bash "$MEM" audit --home "$H" --today 2024-02-29
want "[regression] --today 2026-02-29（非閏年）→ exit 2" 2 "不是存在的日期" \
     bash "$MEM" audit --home "$H" --today 2026-02-29

# 3) pin 只認 true／false。`pin: TRUE` 被當成沒釘選的話，那則記憶會從常駐
#    索引裡靜靜消失，而使用者以為它還在。
H="$SANDBOX/pb"; B="$H/memory"
mkmem "$B" pba 'pin: TRUE' <<< '正文。'
want "[regression] pin: TRUE → bad_pin 而非靜默當成未釘選" 1 "bad_pin:TRUE" \
     bash "$MEM" audit --home "$H" --today 2026-01-01
H="$SANDBOX/pb2"; B="$H/memory"
mkmem "$B" pbb 'pin: false' <<< '正文。'
wantnot "pin: false 仍是合法值" "bad_pin" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第六輪：取代 dangling、symlink bank、關鍵字跳脫 =="
# 1) superseded_by 指向不存在的記憶時，那則記憶會被當成已取代而排除——
#    一個**仍然有效**的事實從結果裡消失，而 exit code 是 0。
H="$SANDBOX/sd"; B="$H/memory"
mkmem "$B" sda 'superseded_by: nosuchmemory' <<< '仍然有效的事實 sdkeyword。'
want "[regression] superseded_by 指向不存在 → search 中止" 1 "search_aborted"      bash "$MEM" search sdkeyword --home "$H"
sdout="$(bash "$MEM" search sdkeyword --home "$H" 2>/dev/null)"
[ -z "$sdout" ] && ok "中止時不輸出殘缺清單" || ng "應無輸出" "$sdout"
# 反面：正文的 [[x]] 壞掉不影響「誰該被排除」，搜尋照常
H="$SANDBOX/sd2"; B="$H/memory"
mkmem "$B" sdb <<< '參考 [[nowhere]] 的事實 sdkeyword2。'
want "正文 [[x]] 壞掉不阻斷搜尋" 0 "sdb" bash "$MEM" search sdkeyword2 --home "$H"

# 2) 整個 bank 是 symlink 時，逐檔的 [ -L ] 完全擋不住——底下每個檔案看起來
#    都是普通檔，而 index --write 會把 MEMORY.md 寫到 --home 範圍外。
H="$SANDBOX/sl"; mkdir -p "$H"
OUTSIDE="$SANDBOX/outside-store"; mkdir -p "$OUTSIDE"
mkmem "$OUTSIDE" slx <<< '範圍外的記憶 slkeyword。'
if MSYS=winsymlinks:nativestrict ln -s "$OUTSIDE" "$H/memory" 2>/dev/null && [ -L "$H/memory" ]; then
  want "[regression] symlink bank → 拒收並回報" 1 "symlinked_bank"        bash "$MEM" audit --home "$H" --today 2026-01-01
  want "[regression] symlink bank → --write 阻擋" 1 "symlinked_bank"        bash "$MEM" index --write --home "$H"
  [ ! -f "$OUTSIDE/MEMORY.md" ] && ok "[regression] 沒有在 --home 範圍外寫出索引"     || ng "範圍外寫入" "$OUTSIDE/MEMORY.md 被建立了"
  want "[regression] symlink bank → search 中止（看不到的記憶不等於不存在）" 1 "search_aborted"        bash "$MEM" search slkeyword --home "$H"
else
  ok "（此環境不支援 symlink，跳過 symlink bank 檢查）"
fi

# 3) awk -v 會解譯反斜線跳脫，`search '	'` 會變成搜尋一個 TAB，
#    與 README 宣告的「字面子字串」不符。
H="$SANDBOX/kw"; B="$H/memory"; mkdir -p "$B"
printf -- '---
name: kwa
description: 跳脫測試
metadata:
  node_type: memory
  type: project
---
路徑寫成 C:\\temp 這種樣子。
' > "$B/kwa.md"
printf -- '---
name: kwb
description: 內含真 TAB
metadata:
  node_type: memory
  type: project
---
欄一	欄二。
' > "$B/kwb.md"
want "[regression] 關鍵字當字面字元，反斜線不被 awk 解譯" 0 "kwa"      bash "$MEM" search --home "$H" -- '\t'
kwout="$(bash "$MEM" search --home "$H" -- '\t' 2>/dev/null)"
case "$kwout" in *kwb*) ng "反斜線跳脫" "\\t' 不該命中含真 TAB 的 kwb" ;;
  *) ok "\\t' 不會誤命中含真 TAB 的記憶" ;; esac

echo "== T8a codex 第七輪：路徑控制字元 =="
# 檔名裡的控制字元會讓 model 的 US 分欄整排位移，後面每個治理欄位都被讀成
# 別的東西。POSIX 檔名允許這些字元；Windows 檔案系統不允許，所以此環境會跳過。
H="$SANDBOX/cp"; B="$H/memory"
mkmem "$B" cpok <<< '正常。'
# Windows 會默默把控制字元從檔名剝掉，於是 [ -f ] 成立但名字裡沒有控制字元，
# 測到的就不是要測的東西。剝掉的話 badname.md 會存在，用它判斷即可，
# 不必把控制字元再塞進 grep 一次。
CTRLNAME="$(printf 'bad\001name')"
if : > "$B/$CTRLNAME.md" 2>/dev/null && [ -f "$B/$CTRLNAME.md" ] && [ ! -f "$B/badname.md" ]; then
  cp "$B/cpok.md" "$B/$CTRLNAME.md"
  want "[regression] 檔名含控制字元 → 拒收並回報" 1 "control_char_in_path" \
       bash "$MEM" audit --home "$H" --today 2026-01-01
  want "[regression] 檔名含控制字元 → search 中止" 1 "search_aborted" \
       bash "$MEM" search 正常 --home "$H"
else
  ok "（此檔案系統不接受控制字元檔名，跳過）"
fi

echo "== T8a codex 第八輪：換行路徑、TAB、per-bank POST_CAP =="
# 1) bank 路徑先經換行分隔的管線再檢查的話，目錄名裡的換行會把一個 bank
#    拆成兩個看起來很正常的路徑，原 bank 被靜默略過、連拒收都不會記錄。
H="$SANDBOX/nl"; mkdir -p "$H"
NLDIR="$(printf 'proj\na')"
if mkdir -p "$H/projects/$NLDIR/memory" 2>/dev/null && [ -d "$H/projects/$NLDIR/memory" ]; then
  mkmem "$H/projects/$NLDIR/memory" nla <<< '換行目錄裡的記憶 nlkey。'
  mkmem "$H/memory" nlg <<< '全域。'
  want "[regression] 路徑含換行 → 明確拒收" 1 "control_char_in_path"        bash "$MEM" audit --home "$H" --today 2026-01-01
  want "[regression] 路徑含換行 → search 中止而非回報零結果" 1 "search_aborted"        bash "$MEM" search nlkey --home "$H"
else
  ok "（此檔案系統不接受換行目錄名，跳過）"
fi

# 2) search 的輸出契約是 path<TAB>id<TAB>description 三欄；
#    description 裡一個 TAB 就會多長出一欄，下游 TSV 解析全部錯位。
H="$SANDBOX/tb"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: tba\ndescription: 前段\t後段\nmetadata:\n  node_type: memory\n  type: project\n---\n正文 tbkey。\n' > "$B/tba.md"
want "[regression] description 含 TAB → control_char" 1 "control_char:description"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] description 含 TAB → search 不輸出破格的行" 1 "search_aborted"      bash "$MEM" search tbkey --home "$H"

# 3) POST_CAP 若以 gram 全域彙總，多個專案各自有相似描述時，跨 bank 的總數
#    會先撞到上限，於是同一個 bank 內本來抓得到的重複候選被整組跳過。
#    dup 只比同庫，跨庫數量本來就不該影響它。
H="$SANDBOX/cap"
for i in $(seq 1 4); do
  BK="$H/projects/p$i/memory"; mkdir -p "$BK"
  for j in $(seq 1 20); do
    printf -- '---\nname: c%s%s\ndescription: 部署與環境的設定與注意事項說明\nmetadata:\n  node_type: memory\n  type: project\n---\n正文 %s %s。\n'       "$i" "$j" "$i" "$j" > "$BK/c$i$j.md"
  done
done
capout="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep -c dup_candidate)"
[ "$capout" -gt 0 ] && ok "[regression] 跨 bank 的貼文數不會蓋掉同 bank 的 dup 偵測（$capout 對）"   || ng "per-bank POST_CAP" "同 bank 的 dup 被跨庫數量蓋掉了"

echo "== T8a codex 第九輪：層級錯置的治理欄位、--home 正規化 =="
# 1) 治理欄位寫在根層是「寫錯層級」，不是未知欄位。未知欄位原樣接受是為了
#    讓既有資料能遷移；但 superseded_by 放根層被靜默忽略，那則**已被取代**的
#    記憶會看起來仍然現行，照樣進搜尋結果與釘選索引。
H="$SANDBOX/mp"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: mpold\ndescription: 舊做法\nsuperseded_by: mpnew\nmetadata:\n  node_type: memory\n  type: project\n---\n舊做法 mpkey。\n' > "$B/mpold.md"
want "[regression] 根層 superseded_by → misplaced_key" 1 "misplaced_key:superseded_by"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] 根層 superseded_by → search 中止而非回舊事實" 1 "search_aborted"      bash "$MEM" search mpkey --home "$H"
# 反面：真正未知的既有欄位仍要原樣接受，否則遷移會把既有記憶全打成錯誤
H="$SANDBOX/mp2"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: mpok\ndescription: 有未知欄位\noriginSessionId: abc-123\nmetadata:\n  node_type: memory\n  type: project\n  modified: 2026-08-21T00:00:00Z\n---\n正文。\n' > "$B/mpok.md"
wantnot "未知的既有根層欄位不判 malformed" "malformed_frontmatter"      bash "$MEM" audit --home "$H" --today 2026-01-01

# 2) search 的輸出契約是絕對路徑。`--home ./fixture` 若不正規化，
#    每一行都會變成相對路徑，貼到別的地方就打不開。
H="$SANDBOX/ab"; B="$H/memory"
mkmem "$B" aba <<< '關鍵字 abkey。'
about="$(cd "$SANDBOX" && bash "$MEM" search abkey --home ./ab 2>/dev/null)"
case "$about" in
  /*) ok "[regression] 相對 --home 仍輸出絕對路徑" ;;
  *)  ng "絕對路徑輸出" "實得: $about" ;;
esac

echo "== T8a codex 第十輪：看不見的來源、排序失敗 =="
# 1) 不跟隨 symlink 是對的，但**靜默**跳過不是：跳掉的那則在下游等於不存在，
#    而 index --write 會照著少了東西的 model 重寫索引，把它的釘選內容刪掉。
H="$SANDBOX/sm"; B="$H/memory"
mkmem "$B" smreal <<< '正常。'
if MSYS=winsymlinks:nativestrict ln -s "$B/smreal.md" "$B/smlink.md" 2>/dev/null && [ -L "$B/smlink.md" ]; then
  want "[regression] symlink 記憶 → 明確回報並 fail closed" 1 "symlinked_memory"        bash "$MEM" audit --home "$H" --today 2026-01-01
  want "[regression] symlink 記憶 → search 中止" 1 "search_aborted"        bash "$MEM" search 正常 --home "$H"
else
  ok "（此環境不支援 symlink，跳過 symlink 記憶檢查）"
fi

# 2) 不可讀的目錄會讓 glob 原樣留著、一則都掃不到，看起來就像「這個 bank 是空的」。
H="$SANDBOX/ur"; B="$H/projects/pu/memory"
mkmem "$B" ura <<< '正常。'
mkmem "$H/memory" urg <<< '全域。'
if chmod 000 "$B" 2>/dev/null && [ ! -r "$B" ]; then
  want "[regression] 不可讀的 bank → unreadable_bank" 1 "unreadable_bank"        bash "$MEM" audit --home "$H" --today 2026-01-01
  chmod 755 "$B" 2>/dev/null
else
  chmod 755 "$B" 2>/dev/null
  ok "（此檔案系統不支援移除讀取權限，跳過 unreadable_bank 檢查）"
fi
wantnot "可讀的 bank 不得誤報 unreadable_bank" "unreadable_bank"      bash "$MEM" audit --home "$H" --today 2026-01-01

# 3) sort 也要確認成功再輸出。空間不足時它會吐出半截結果，
#    而 search 的契約是「失敗不可以長得像查無」。
H="$SANDBOX/so"; B="$H/memory"
mkmem "$B" soa <<< '關鍵字 sokey。'
want "[regression] 排序失敗 → 非 0 且不輸出" 1 "search_failed"      env MEMORY_FORCE_FAIL_SORT=1 bash "$MEM" search sokey --home "$H"
soout="$(env MEMORY_FORCE_FAIL_SORT=1 bash "$MEM" search sokey --home "$H" 2>/dev/null)"
[ -z "$soout" ] && ok "排序失敗時 stdout 為空" || ng "應無輸出" "$soout"

echo "== T8a codex 第十二輪：render 失敗傳遞、mktemp 暫存 =="
# 取正文的 awk 跑在 while 子 shell 裡，退出碼傳不回來。而「某則 pinned 的正文
# 讀不到」正是最不能靜默的失敗：索引會少掉那一段卻以成功狀態提交，
# 等於工具自己把使用者的常駐記憶刪了一塊。
H="$SANDBOX/rf"; B="$H/memory"
mkmem "$B" rfa 'pin: true' <<< '重要的釘選內容。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
rfbefore="$(md5sum < "$B/MEMORY.md")"
want "[regression] pinned 正文讀取失敗 → render_failed" 1 "render_failed"      env MEMORY_FORCE_FAIL_RENDER=1 bash "$MEM" index --write --home "$H"
[ "$rfbefore" = "$(md5sum < "$B/MEMORY.md")" ]   && ok "[regression] render 失敗時索引完全未動" || ng "索引未動" "被改了"
[ -z "$(ls -a "$B" | grep '^\.MEMORY')" ] && ok "render 失敗後無暫存殘留" || ng "無殘留" "有殘留"
# 反面：正常情況仍寫得出來
want "正常 render 仍可寫入" 0 - bash "$MEM" index --write --home "$H"
want "寫入後 --check 通過" 0 - bash "$MEM" index --check --home "$H"

# 暫存檔名改由 mktemp 產生（固定 $$ 名稱的「先檢查再開檔」是 TOCTOU）。
# 名稱仍以 . 開頭，不得被當成記憶來源。
H="$SANDBOX/mt"; B="$H/memory"
mkmem "$B" mta 'pin: true' <<< '內容。'
touch "$B/.MEMORY.md.new.ABC123" "$B/.MEMORY.md.bak.ABC123"
before_n="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep '^INFO -: memories' | awk '{print $4}')"
[ "$before_n" = 1 ] && ok "[regression] mktemp 風格的殘留檔不被當成記憶"   || ng "殘留檔被當成記憶" "memories=$before_n"

echo "== T8a codex 第十四輪：索引檔名的大小寫變體 =="
# 大小寫不敏感的檔案系統（Windows、預設的 macOS）上 memory.md 與 MEMORY.md
# 是同一個檔；只比對精確大小寫的話，索引自己會被當成來源記憶納進來。
H="$SANDBOX/ci"; B="$H/memory"
mkmem "$B" cia 'pin: true' <<< '內容。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
cp "$B/cia.md" "$B/memory.md" 2>/dev/null
if [ -f "$B/memory.md" ] && [ "$(wc -c < "$B/memory.md")" != "$(wc -c < "$B/MEMORY.md")" ]; then
  want "[regression] memory.md（大小寫變體）→ reserved_filename" 1 "reserved_filename"        bash "$MEM" audit --home "$H" --today 2026-01-01
  want "[regression] memory.md → search 中止而非污染結果" 1 "search_aborted"        bash "$MEM" search 內容 --home "$H"
else
  # 大小寫不敏感：cp 其實覆蓋掉了 MEMORY.md，這正是要防的情形本身
  ok "（此檔案系統大小寫不敏感，memory.md 即 MEMORY.md）"
fi

echo "== T8a codex 第十五輪：ID 字元集 =="
# ID 就是檔名 stem，而它會原樣寫進 <!-- PINNED:ITEM %s -->。檔名裡放得下
# 空白與角括號，那足以從記憶正文**外面**破壞索引的標記結構；而 CLAUDE.md 的
# `memory `id`` 與 [[id]] 兩個 parser 本來也只認 [A-Za-z0-9._-]。
H="$SANDBOX/bi"; B="$H/memory"; mkdir -p "$B"
printf -- '---
name: bad id
description: 檔名含空白
metadata:
  node_type: memory
  type: project
---
正文。
' > "$B/bad id.md"
want "[regression] 檔名不符 ID 字元集 → bad_id" 1 "bad_id"      bash "$MEM" audit --home "$H" --today 2026-01-01
# 反面：正常的 kebab-case 不得誤判
H="$SANDBOX/bi2"; B="$H/memory"
mkmem "$B" ok-id_1.2 <<< '正文。'
wantnot "合法 ID 不得誤判 bad_id" "bad_id" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第十六輪：dot-prefixed 檔案、search locale =="
# 以點開頭的 .md 被靜默略過的話，那則記憶在 audit/search/index 三處都不存在，
# 而使用者完全不會知道。交易暫存（.MEMORY.md.*）是本工具自己的檔，才可以安靜跳過。
H="$SANDBOX/hf"; B="$H/memory"
mkmem "$B" hfa <<< '正常。'
cp "$B/hfa.md" "$B/.hidden.md"
want "[regression] .hidden.md → hidden_file 並 fail closed" 1 "hidden_file"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] 有隱藏檔時 search 中止" 1 "search_aborted"      bash "$MEM" search 正常 --home "$H"
rm -f "$B/.hidden.md"
touch "$B/.MEMORY.md.new.ZZZ" "$B/.MEMORY.md.bak.ZZZ"
wantnot "[regression] 交易暫存檔不觸發 hidden_file" "hidden_file"      bash "$MEM" audit --home "$H" --today 2026-01-01

# search 的契約是「ASCII 大小寫不敏感」。ambient locale 的 tolower 不是——
# 土耳其語 locale 下 I 不會對到 ASCII 的 i，命中會靜默消失。
H="$SANDBOX/lc"; B="$H/memory"
mkmem "$B" lca <<< '關鍵字 INDEX 在正文裡。'
if locale -a 2>/dev/null | grep -qi '^tr_TR'; then
  want "[regression] 土耳其語 locale 下仍找得到 index/INDEX" 0 "lca"        env LC_ALL=tr_TR.UTF-8 bash "$MEM" search index --home "$H"
else
  want "（無 tr_TR locale）至少驗 ASCII 大小寫不敏感" 0 "lca"        bash "$MEM" search index --home "$H"
fi

echo "== T8a codex 第十七輪：索引 symlink、壞掉的 symlink、Jaccard 對稱性 =="
# 1) 索引檔本身是 symlink 的話，mv 會把暫存檔搬到它指向的地方（可能在 --home 之外），
#    而 [ -f ] 對「指向目錄的 symlink」是 false，連備份都不會做。
H="$SANDBOX/si"; B="$H/memory"
mkmem "$B" sia 'pin: true' <<< '內容。'
OUT2="$SANDBOX/outside2"; mkdir -p "$OUT2"
if MSYS=winsymlinks:nativestrict ln -s "$OUT2" "$B/MEMORY.md" 2>/dev/null && [ -L "$B/MEMORY.md" ]; then
  want "[regression] 索引是 symlink → --write 阻擋" 1 "symlinked_index"        bash "$MEM" index --write --home "$H"
  [ -z "$(ls -A "$OUT2")" ] && ok "[regression] 沒有寫到 symlink 指向的目錄" || ng "寫出邊界" "有檔案"
  rm -f "$B/MEMORY.md"
else
  ok "（此環境不支援 symlink，跳過索引 symlink 檢查）"
fi

# 2) 壞掉的 symlink（指向已刪除的檔）既不是 -f 也不是 -e，先問 -f 就會讓它
#    從縫裡掉出去、連拒收都不記。
H="$SANDBOX/bs"; B="$H/memory"
mkmem "$B" bsa <<< '正常。'
if MSYS=winsymlinks:nativestrict ln -s "$B/gone.md" "$B/broken.md" 2>/dev/null && [ -L "$B/broken.md" ]; then
  want "[regression] 壞掉的 symlink → symlinked_memory" 1 "symlinked_memory"        bash "$MEM" audit --home "$H" --today 2026-01-01
else
  ok "（此環境不支援 symlink，跳過壞 symlink 檢查）"
fi

# 3) build_grams 截到 DESC_CAP，jaccard 若掃完整字串，同一對記憶用 (a,b) 與 (b,a)
#    會算出兩個值——相似度變成看候選順序而定。
H="$SANDBOX/js"; B="$H/memory"; mkdir -p "$B"
HEAD="$(printf '部署與環境的設定與注意事項說明以及各種細節的補充%.0s' 1 2 3 4 5 6 7 8)"
printf -- '---
name: jsa
description: %s尾巴甲甲甲甲甲甲甲甲甲甲
metadata:
  node_type: memory
  type: project
---
正文甲。
' "$HEAD" > "$B/jsa.md"
printf -- '---
name: jsb
description: %s尾巴乙乙乙乙乙乙乙乙乙乙
metadata:
  node_type: memory
  type: project
---
正文乙。
' "$HEAD" > "$B/jsb.md"
jsn="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep -c dup_candidate)"
[ "$jsn" = 1 ] && ok "[regression] 超長 description 的重複候選恰報一次"   || ng "Jaccard 對稱性" "期望 1 對，實得 $jsn"

echo "== T8a codex 第十八輪：重複的 metadata 區塊 =="
# 兩個 metadata: 區塊會被合併解讀，後面那組把前面那組的 superseded_by 覆寫掉
# ——已取代的記憶就這樣復活，而且兩邊都不會有 relation_mismatch。
H="$SANDBOX/dm"; B="$H/memory"; mkdir -p "$B"
printf -- '---
name: dma
description: 舊做法
metadata:
  node_type: memory
  superseded_by: dmb
metadata:
  type: project
---
舊做法 dmkey。
' > "$B/dma.md"
mkmem "$B" dmb 'supersedes: [dma]' <<< '新做法。'
want "[regression] 重複的 metadata 區塊 → duplicate_key" 1 "duplicate_key:metadata"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] 重複的 metadata 區塊 → search 中止" 1 "search_aborted"      bash "$MEM" search dmkey --home "$H"

echo "== T8a codex 第十九輪：非普通檔、無法列舉的 projects =="
# 名字像記憶、卻不是普通檔（目錄、FIFO）。靜默跳過的話，一個叫 foo.md 的目錄
# 就能讓原本的 foo 記憶從 model 裡消失，而 --write 會照著把它從索引裡刪掉。
H="$SANDBOX/nr"; B="$H/memory"
mkmem "$B" nra <<< '正常。'
mkdir -p "$B/fake.md"
want "[regression] 名為 *.md 的目錄 → not_regular_file" 1 "not_regular_file"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "[regression] 有非普通檔時 search 中止" 1 "search_aborted"      bash "$MEM" search 正常 --home "$H"
want "[regression] 有非普通檔時 --write 阻擋" 1 "write_aborted"      bash "$MEM" index --write --home "$H"
rmdir "$B/fake.md"
wantnot "移除後不再回報" "not_regular_file" bash "$MEM" audit --home "$H" --today 2026-01-01

# projects/ 讀不到時 glob 不展開，一個專案庫都掃不到，而輸出看起來就是
# 「只有全域庫」——少掉的記憶在 search 是「查無」，在 --write 是「不用更新」。
H="$SANDBOX/up"
mkmem "$H/memory" upg <<< '全域。'
mkmem "$H/projects/pp/memory" upp <<< '專案。'
if chmod 000 "$H/projects" 2>/dev/null && [ ! -r "$H/projects" ]; then
  want "[regression] projects 無法列舉 → unreadable_bank" 1 "unreadable_bank"        bash "$MEM" audit --home "$H" --today 2026-01-01
  chmod 755 "$H/projects" 2>/dev/null
else
  chmod 755 "$H/projects" 2>/dev/null
  ok "（此檔案系統不支援移除讀取權限，跳過 projects 列舉檢查）"
fi
wantnot "可讀時不得誤報" "unreadable_bank" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第二十輪：索引不是普通檔 =="
# 寫入目標必須是「不存在」或「普通檔」，沒有第三種。目錄會讓 mv 把暫存檔
# **搬進去**、一切回報成功，而索引根本沒生成。
H="$SANDBOX/ir"; B="$H/memory"
mkmem "$B" ira 'pin: true' <<< '內容。'
mkdir -p "$B/MEMORY.md"
want "[regression] 索引是目錄 → --check 阻擋" 1 "index_not_regular_file"      bash "$MEM" index --check --home "$H"
want "[regression] 索引是目錄 → --write 阻擋" 1 "index_not_regular_file"      bash "$MEM" index --write --home "$H"
[ -z "$(ls -A "$B/MEMORY.md")" ] && ok "[regression] 沒有把暫存索引搬進那個目錄"   || ng "搬進目錄了" "$(ls -A "$B/MEMORY.md")"
rmdir "$B/MEMORY.md"
want "移除後 --write 恢復正常" 0 - bash "$MEM" index --write --home "$H"
want "移除後 --check 通過" 0 - bash "$MEM" index --check --home "$H"

echo "== T8a codex 第二十一輪：清空的 bank 仍留著舊索引 =="
# 刪掉最後一則記憶後，舊 MEMORY.md 會帶著它的釘選正文永遠留著，
# 每個 session 照樣讀進去——而那正是這支工具存在的理由。
H="$SANDBOX/eb"; B="$H/memory"
mkmem "$B" eba 'pin: true' <<< '這段內容應該要消失。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
grep -q '這段內容應該要消失' "$B/MEMORY.md" && ok "前置：釘選內容確實在索引裡" || ng "前置" "不在"
rm -f "$B/eba.md"
want "[regression] 清空 bank 後 --check 報 drift" 1 "index_drift"      bash "$MEM" index --check --home "$H"
want "[regression] 清空 bank 後 --write 可修復" 0 - bash "$MEM" index --write --home "$H"
grep -q '這段內容應該要消失' "$B/MEMORY.md" && ng "舊釘選內容" "還留在索引裡"   || ok "[regression] 已刪除記憶的釘選內容不再留在索引"
want "修復後 --check 通過" 0 - bash "$MEM" index --check --home "$H"
# 反面：空 bank 且本來就沒有索引 → 不該報任何東西
H="$SANDBOX/eb2"; mkdir -p "$H/memory" "$H/projects/pe/memory"
mkmem "$H/memory" ebg <<< '全域。'
# 只有**空的**那個 bank 不該被報；有記憶卻缺索引的全域庫報 index_missing 是對的
wantnot "空 bank 且無索引 → 不報 index_missing" "pe/memory/MEMORY.md: index_missing"      bash "$MEM" audit --home "$H" --today 2026-01-01
want "有記憶卻缺索引的 bank 仍要報" 1 "memory/MEMORY.md: index_missing"      bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第二十三輪：checks 判定看欄位、專案目錄不可讀 =="
# 裸 grep 掃整行的話，路徑或 detail 裡出現 code 字樣就會誤中止。
H="$SANDBOX/dangling_ref"; B="$H/memory"
mkmem "$B" gfa <<< '關鍵字 gfkey。'
want "[regression] 路徑含 code 字樣不得誤中止 search" 0 "gfa"      bash "$MEM" search gfkey --home "$H"
want "[regression] 路徑含 code 字樣不得誤擋 --write" 0 - bash "$MEM" index --write --home "$H"
# description 含 code 字樣同樣不得誤判
H="$SANDBOX/gf2"; B="$H/memory"; mkdir -p "$B"
printf -- '---\nname: gfb\ndescription: 這則說明裡就寫著 relation_mismatch 三個字\nmetadata:\n  node_type: memory\n  type: project\n---\n正文 gfkey2。\n' > "$B/gfb.md"
want "[regression] description 含 code 字樣不得誤中止 search" 0 "gfb"      bash "$MEM" search gfkey2 --home "$H"
# 反面：真的有 relation_mismatch 時仍要中止
H="$SANDBOX/gf3"; B="$H/memory"
mkmem "$B" gfc 'superseded_by: gfd' <<< '舊 gfkey3。'
mkmem "$B" gfd <<< '新。'
want "真的不一致時仍要中止" 1 "search_aborted" bash "$MEM" search gfkey3 --home "$H"

# 單一專案目錄不能 traverse 時，projects/*/memory 對它就是不匹配——沒有錯誤、
# 沒有訊息，那個 bank 就這樣從清單裡消失。
H="$SANDBOX/pu2"
mkmem "$H/memory" pug <<< '全域。'
mkmem "$H/projects/px/memory" pux <<< '專案。'
if chmod 000 "$H/projects/px" 2>/dev/null && [ ! -x "$H/projects/px" ]; then
  want "[regression] 單一專案目錄不可進入 → unreadable_bank" 1 "unreadable_bank"        bash "$MEM" audit --home "$H" --today 2026-01-01
  chmod 755 "$H/projects/px" 2>/dev/null
else
  chmod 755 "$H/projects/px" 2>/dev/null
  ok "（此檔案系統不支援移除目錄權限，跳過單一專案檢查）"
fi
wantnot "可進入時不得誤報" "unreadable_bank" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第二十四輪：supersedes 必須是陣列 =="
# `supersedes: old-id` 與 `supersedes: a,b` 都會被 split_array 當成合法輸入解析掉
# ——寫錯格式卻靜默接受，之後所有取代關係的判定都建立在猜出來的語意上。
H="$SANDBOX/sa"; B="$H/memory"
mkmem "$B" saa 'supersedes: sab' <<< '新做法。'
mkmem "$B" sab 'superseded_by: saa' <<< '舊做法。'
want "[regression] supersedes 未加中括號 → array_expected" 1 "array_expected:supersedes"      bash "$MEM" audit --home "$H" --today 2026-01-01
# 反面：正確的陣列形式（含空陣列）不得誤判
H="$SANDBOX/sa2"; B="$H/memory"
mkmem "$B" sac 'supersedes: [sad]' <<< '新做法。'
mkmem "$B" sad 'superseded_by: sac' <<< '舊做法。'
wantnot "[a] 形式不得誤判" "array_expected" bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "[a] 形式不得有 relation_mismatch" "relation_mismatch"      bash "$MEM" audit --home "$H" --today 2026-01-01
H="$SANDBOX/sa3"; B="$H/memory"
mkmem "$B" sae 'supersedes: []' <<< '正文。'
wantnot "空陣列 [] 不得誤判" "array_expected" bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第二十五輪：CLAUDE.md 讀不到 =="
# 讀不到與「沒有引用」在輸出上一模一樣，而 grep 的 exit 1（無匹配）與
# exit 2（讀取錯誤）也被 2>/dev/null 一起吞掉。
H="$SANDBOX/cm"; B="$H/memory"
mkmem "$B" cma <<< '正文。'
mkdir -p "$H/CLAUDE.md"          # 存在但不是普通檔 → 讀不到
want "[regression] CLAUDE.md 不是普通檔 → claude_md_unreadable" 1 "claude_md_unreadable"      bash "$MEM" audit --home "$H" --today 2026-01-01
rmdir "$H/CLAUDE.md"
# 反面：正常的 CLAUDE.md（沒有 memory 引用）不得誤報
printf '# 一般設定檔，沒有記憶引用。
' > "$H/CLAUDE.md"
wantnot "正常 CLAUDE.md 不得誤報" "claude_md_unreadable"      bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "沒有引用時不得報 dangling" "claude_md_dangling"      bash "$MEM" audit --home "$H" --today 2026-01-01
# 真的有壞引用時仍要報
printf '見 memory `nosuchid` 的說明。
' >> "$H/CLAUDE.md"
want "壞引用仍要報" 1 "claude_md_dangling nosuchid"      bash "$MEM" audit --home "$H" --today 2026-01-01

echo "== T8a codex 第二十六輪：標記必須獨佔整行 =="
# `<!-- TOPICS:BEGIN --> 手寫的東西` 若算合法標記，extract_topics 取區塊時
# 會把同一行的手寫內容一起丟掉——而這正是「標記範圍不明時不猜測」要防的事。
for shape in topics_inline pinned_inline; do
  H="$SANDBOX/ml-$shape"; B="$H/memory"
  mkmem "$B" mla 'pin: true' <<< '正文。'
  case "$shape" in
    topics_inline)
      printf '# Memory Index

<!-- PINNED:BEGIN -->
<!-- PINNED:END -->

<!-- TOPICS:BEGIN --> 手寫的分類不能被吃掉
<!-- TOPICS:END -->
' > "$B/MEMORY.md" ;;
    pinned_inline)
      printf '# Memory Index

<!-- PINNED:BEGIN --> 尾巴
<!-- PINNED:END -->

<!-- TOPICS:BEGIN -->
主題：手寫
<!-- TOPICS:END -->
' > "$B/MEMORY.md" ;;
  esac
  mlbefore="$(md5sum < "$B/MEMORY.md")"
  want "[regression] $shape → invalid_index_markers" 1 "invalid_index_markers"        bash "$MEM" index --check --home "$H"
  want "[regression] $shape → --write 阻擋" 1 "invalid_index_markers"        bash "$MEM" index --write --home "$H"
  [ "$mlbefore" = "$(md5sum < "$B/MEMORY.md")" ]     && ok "$shape：手寫內容未被覆寫" || ng "手寫內容" "$shape 被改了"
done

echo "== T8a codex 第二十八輪：陣列內空白、索引 CRLF =="
# `[foo bar]` 被靜默正規化成 `foobar` 的話，一個根本沒寫對的取代關係會通過檢查
# ——若 foobar 剛好存在、雙向關係也對得起來，某則記憶就被錯誤地排除掉。
H="$SANDBOX/sw"; B="$H/memory"
mkmem "$B" foobar 'superseded_by: swnew' <<< '會被錯誤排除的記憶 swkey。'
mkmem "$B" swnew 'supersedes: [foo bar]' <<< '新做法。'
want "[regression] 陣列元素內的空白不得被吃掉" 1 "dangling_ref"      bash "$MEM" audit --home "$H" --today 2026-01-01
# 反面：分隔符周圍的空白要照常容忍
H="$SANDBOX/sw2"; B="$H/memory"
mkmem "$B" swa 'superseded_by: swb' <<< '舊。'
mkmem "$B" swb 'supersedes: [ swa ]' <<< '新。'
wantnot "[a, b] 的分隔符空白仍可接受" "dangling_ref"      bash "$MEM" audit --home "$H" --today 2026-01-01
wantnot "分隔符空白不得誤判關係" "relation_mismatch"      bash "$MEM" audit --home "$H" --today 2026-01-01

# 索引也要接受 CRLF：來源記憶已經接受了，索引卻不接受的話，
# 用 Windows 編輯器改過一次 TOPICS，四個 marker 全部對不上，--write 也修不好。
H="$SANDBOX/ic"; B="$H/memory"
mkmem "$B" ica 'pin: true' <<< '內容。'
bash "$MEM" index --write --home "$H" >/dev/null 2>&1
CR="$(printf '\015')"
awk -v cr="$CR" '{ sub(/\r$/, ""); printf "%s%s\n", $0, cr }' "$B/MEMORY.md" > "$B/MEMORY.md.crlf" && mv "$B/MEMORY.md.crlf" "$B/MEMORY.md"
wantnot "[regression] CRLF 索引不得被判 invalid_index_markers" "invalid_index_markers"      bash "$MEM" index --check --home "$H"
want "[regression] CRLF 索引 → 報 drift（可修）" 1 "index_drift"      bash "$MEM" index --check --home "$H"
want "[regression] CRLF 索引 → --write 修得好" 0 - bash "$MEM" index --write --home "$H"
want "修好後 --check 通過" 0 - bash "$MEM" index --check --home "$H"

echo "== T8a codex 第二十九輪：隱藏檔的各種型態 =="
# `.foo.md` 是 symlink／壞 symlink／目錄時，只認 [ -f ] 會靜默略過，
# 下游看到的是「少了一則」——正是 fail-closed 要防的。
H="$SANDBOX/hd"; B="$H/memory"
mkmem "$B" hda <<< '正常。'
mkdir -p "$B/.dirlike.md"
want "[regression] 隱藏的目錄型 .md → hidden_file" 1 "hidden_file"      bash "$MEM" audit --home "$H" --today 2026-01-01
rmdir "$B/.dirlike.md"
wantnot "移除後不再回報" "hidden_file" bash "$MEM" audit --home "$H" --today 2026-01-01
if MSYS=winsymlinks:nativestrict ln -s "$B/gone.md" "$B/.brokenlink.md" 2>/dev/null && [ -L "$B/.brokenlink.md" ]; then
  want "[regression] 隱藏的壞 symlink → hidden_file" 1 "hidden_file"        bash "$MEM" audit --home "$H" --today 2026-01-01
  rm -f "$B/.brokenlink.md"
else
  ok "（此環境不支援 symlink，跳過隱藏 symlink 檢查）"
fi

echo "== T8a codex 第三十輪：--check/--write 互斥、陣列空元素 =="
# 靜默取最後一個的話，`index --check --write` 會實際寫入——本來是唯讀意圖的
# 指令變成改檔，不能靠使用者自己注意順序。
H="$SANDBOX/mx"; B="$H/memory"
mkmem "$B" mxa 'pin: true' <<< '內容。'
want "[regression] --check --write → usage error" 2 "互斥"      bash "$MEM" index --check --write --home "$H"
want "[regression] --write --check → usage error" 2 "互斥"      bash "$MEM" index --write --check --home "$H"
[ ! -f "$B/MEMORY.md" ] && ok "[regression] 互斥時完全沒有寫入" || ng "互斥時未寫入" "索引被建立了"
want "單獨 --write 仍正常" 0 - bash "$MEM" index --write --home "$H"
want "重複的 --write 不算互斥" 0 - bash "$MEM" index --write --write --home "$H"

# `[old,]`、`[a,,b]`、`[,]` 的空元素會被 split_array 靜默跳過，
# 三種不同寫法被正規化成同一個關係——治理資料的語意用猜的。
for arr in '[mxb,]' '[mxb,,mxc]' '[,]'; do
  H="$SANDBOX/ae-$(printf '%s' "$arr" | tr -cd 'a-z')$RANDOM"; B="$H/memory"
  mkmem "$B" mxd "supersedes: $arr" <<< '新做法。'
  want "[regression] supersedes $arr → empty_array_element" 1 "empty_array_element:supersedes"        bash "$MEM" audit --home "$H" --today 2026-01-01
done

echo "== bytes 必須是 byte 而非字元（T8a codex Optional） =="
# gawk 在 multibyte locale 下 length() 回的是字元數；中文記憶會被低估成約三分之一，
# 於是超過門檻的長記憶不會被建議拆分——稽核在中文環境靜默失效。
H="$SANDBOX/c9"; B="$H/memory"; mkdir -p "$B"
{ printf -- '---\n'
  printf 'name: cjkbig\ndescription: 中文長記憶\nmetadata:\n  node_type: memory\n  type: project\n'
  printf -- '---\n'
  for i in 1 2 3 4 5; do
    for j in 1 2 3 4 5 6 7 8 9 10; do
      printf '這是一段中文正文用來測試位元組計數是否正確無誤。\n'
    done
    printf '\n'
  done
} > "$B/cjkbig.md"
real_bytes="$(wc -c < "$B/cjkbig.md")"
out="$(bash "$MEM" audit --home "$H" --today 2026-01-01 2>/dev/null | grep split_candidate)"
case "$out" in
  *"bytes=$real_bytes"*) ok "[regression] CJK 記憶的 bytes 與 wc -c 一致（$real_bytes）" ;;
  *) ng "CJK bytes 計數" "期望 bytes=$real_bytes，實得: ${out:-（沒有 split_candidate）}" ;;
esac
fi

# ============================ 可攜性（awk 方言） ============================
if [ "$ONLY" = "all" ] || [ "$ONLY" = "portability" ]; then
echo "== shell 腳本不得有引號外的字面 \\n =="
# `cmd || \\n    next` 這種被工具鏈吃掉一個字元的續行，bash -n 完全看不出來
# ——它會被讀成「執行一個叫 n 的命令」，語法完全合法。實測後果是 search 的
# 排序守衛整段變成死碼，而測試照樣全綠（注入旗標那條路徑仍會走到）。
lint="$(awk -f "$ROOT/scripts/shell-lint.awk" "$ROOT/scripts/memory.sh" "$ROOT/tests/memory.test.sh" "$ROOT/tests/gen-bench-fixture.sh" 2>/dev/null)"
[ -z "$lint" ] && ok "[regression] 無引號外的字面 \\n" || ng "續行被吃掉" "$lint"

echo "== awk 腳本不得使用 gawk 專屬構造 =="
# README 宣告 mawk 環境會降級成 byte 模式而非失效。ENDFILE 只有 gawk 會執行，
# mawk 靜默跳過——search 會變成「無論命中與否都沒有輸出」的全失效。
# 註解裡提到名稱是可以的（正是在說明為什麼不用），所以先去掉註解再掃。
# `delete <整個 array>` 也在內：舊版 mawk 直接 parse fail，而 README 宣告
# mawk 只是降級成 byte 模式、不是跑不起來。清空 array 要用 split("", a)。
bad=""
for a in "$ROOT"/scripts/memory-*.awk; do
  hits="$(sed 's/#.*$//' "$a" | grep -nE '(ENDFILE|BEGINFILE|gensub|asort|asorti|PROCINFO|IGNORECASE|systime|strftime|mktime)|delete[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(;|$)' || true)"
  [ -n "$hits" ] && bad="$bad$(basename "$a"): $hits"$'
'
done
[ -z "$bad" ] && ok "[regression] 無 gawk 專屬構造" || ng "gawk 專屬構造" "$bad"
fi

# ================================= scale =================================
# 500 則規模。這組守住整個設計的核心主張——**常駐成本與記憶總數無關**。
# 沒有這組，日後任何一次「順手」把 N 相關的東西寫回索引都不會被發現。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "scale" ]; then
echo "== 500 則規模 =="
GEN="$ROOT/tests/gen-bench-fixture.sh"
if [ ! -f "$GEN" ]; then
  ng "找得到 benchmark generator" "缺少 $GEN"
else
  BIG="$SANDBOX/bench"; mkdir -p "$BIG"
  bash "$GEN" "$BIG" >/dev/null 2>&1
  n_files="$(find "$BIG/memory" -name '*.md' | grep -c .)"
  [ "$n_files" = 500 ] && ok "產生 500 則" || ng "產生 500 則" "實得 $n_files"

  # 可重現：同一支 generator 跑兩次要產生一樣的 manifest
  BIG2="$SANDBOX/bench2"; mkdir -p "$BIG2"
  bash "$GEN" "$BIG2" >/dev/null 2>&1
  if diff -q "$BIG/manifest.txt" "$BIG2/manifest.txt" >/dev/null 2>&1; then
    ok "generator 可重現（manifest 一致）"
  else
    ng "generator 可重現" "manifest 不同"
  fi

  bash "$MEM" index --write --home "$BIG" >/dev/null 2>&1
  out="$(bash "$MEM" audit --home "$BIG" --today 2026-01-01 2>"$SANDBOX/scale.err")"
  [ "$(grep -c . "$SANDBOX/scale.err")" = 0 ] && ok "500 則下無 WARN" || ng "500 則下無 WARN" "$(cat "$SANDBOX/scale.err")"
  case "$out" in *"dup_pairs 0"*) ok "benchmark 描述不觸發 dup_candidate" ;;
    *) ng "dup_pairs 應為 0" "$(printf '%s' "$out" | grep dup_pairs)" ;; esac
  [ "$(printf '%s' "$out" | grep -c split_candidate)" = 0 ] \
    && ok "benchmark 正文不觸發 split_candidate" || ng "split 應為 0" "有 split"

  # 核心主張：只留 9 則與留 500 則，索引 byte 數必須完全相同
  SMALL="$SANDBOX/bench-small"; mkdir -p "$SMALL/memory"
  for f in alpha bravo charlie delta echo foxtrot golf hotel india; do
    cp "$BIG/memory/$f.md" "$SMALL/memory/" 2>/dev/null
  done
  bash "$MEM" index --write --home "$SMALL" >/dev/null 2>&1
  b9="$(wc -c < "$SMALL/memory/MEMORY.md")"; b500="$(wc -c < "$BIG/memory/MEMORY.md")"
  [ "$b9" = "$b500" ] && ok "[regression] 9 則與 500 則的索引 byte 數相同（成本與 N 無關）" \
    || ng "常駐成本與 N 無關" "9 則=$b9 / 500 則=$b500"

  # 增量必須恰等於「marker + 去 frontmatter 正文」，不多不少
  before="$b500"
  sed -i 's/^  type: project$/  type: project\n  pin: true/' "$BIG/memory/bench-0001.md"
  bash "$MEM" index --write --home "$BIG" >/dev/null 2>&1
  after="$(wc -c < "$BIG/memory/MEMORY.md")"
  bs="$(awk '/^---$/{n++; if(n==2){print NR+1; exit}}' "$BIG/memory/bench-0001.md")"
  expect=$(( $(printf '<!-- PINNED:ITEM bench-0001 -->\n' | wc -c) + $(awk -v s="$bs" 'NR>=s' "$BIG/memory/bench-0001.md" | wc -c) ))
  [ $((after - before)) -eq "$expect" ] && ok "新增一則 pin 的增量恰等於 marker + 正文" \
    || ng "pin 增量" "實得 $((after-before)) 期望 $expect"
fi
fi

echo
echo "結果: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
