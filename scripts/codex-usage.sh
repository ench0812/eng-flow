#!/usr/bin/env bash
# codex-usage.sh — codex-review 用量報表與 codex-decide 離開碼摘要(唯讀,只讀 $CODEX_REVIEW_LOG 與 $CODEX_DECIDE_LOG)
#
# 存在的理由: 在這份遙測之前,「codex 用量成長過快」只能靠感覺——腳本用 mktemp 暫存並在
# EXIT 全部刪除,本機一筆用量都沒有留下。要判斷「哪裡在燒」必須有數字。
#
# 用法: bash codex-usage.sh [--since YYYY-MM-DD] [--top N] [--log <path>] [--decide-log <path>]
#
# codex-decide 區塊(2026-11-28 起): codex-decide.sh 每次結束都追加一列(任何離開碼,含 FAILED／
# RATE_LIMITED／契約錯誤),這裡依 status、模型與 detail(離開原因的固定代號)計數。--help 的那列
# (detail=help)不計入。exit 3 的 detail: missing_fields:<欄名>(契約行缺漏,例如被加粗)、mismatch、
# dissent、low_confidence、launch_fail、inference_not_allowed、multi_verdict、bad_confidence／bad_basis、
# no_codex／no_auth。status=INTERRUPTED 是被訊號或 TaskStop 砍掉(rc 可能留空)。原始欄位見 codex-decide.sh 的 write_decide_log。
#
# 讀哪一欄:
#   cache hit rate = cached_input_tokens / input_tokens。這是「有多少 input 走 0.1x 費率」。
#   未快取 input   = input_tokens - cached_input_tokens。這才是實際被全額計費的量,
#                    比總 input 更能反映成本——看趨勢要看這一欄。
set -uo pipefail

LOG="${CODEX_REVIEW_LOG:-$HOME/.claude/cache/codex-review-usage.tsv}"
# ${HOME:+…}: 沒有 HOME 時不得在 set -u 下讓整支腳本死掉(呼叫端可能只靠 CODEX_REVIEW_LOG 與 --decide-log 指定路徑;上一行的 LOG 預設值仍會展開 $HOME,那是既有行為)
DECIDE_LOG="${CODEX_DECIDE_LOG:-${HOME:+$HOME/.claude/cache/codex-decide-usage.tsv}}"
REVIEW_RC=0
SINCE=""; TOP=10
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --since 需要值。" >&2; exit 2; }; SINCE="$2"; shift 2 ;;
    --top)   [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --top 需要值。" >&2; exit 2; };   TOP="$2";   shift 2 ;;
    --log)   [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --log 需要值。" >&2; exit 2; };   LOG="$2";   shift 2 ;;
    --decide-log) [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --decide-log 需要值。" >&2; exit 2; }; DECIDE_LOG="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash codex-usage.sh [--since YYYY-MM-DD] [--top N] [--log <path>] [--decide-log <path>]"
      exit 0 ;;
    *) echo "[codex-usage] 未知參數: $1" >&2; exit 2 ;;
  esac
done

# review log 不存在時不提早結束: codex-decide 的紀錄可能先有(兩份各自獨立)。
if [ ! -f "$LOG" ]; then
  echo "[codex-usage] 還沒有任何用量紀錄: $LOG" >&2
  echo "  跑過一次 codex-review.sh 之後就會有。" >&2
else
awk -F'\t' -v since="$SINCE" -v top="$TOP" -v logpath="$LOG" '
$1=="ts" { next }                               # 表頭(不綁 NR==1: log 可能被截斷過或串接,中段也會出現表頭)
NF < 17 { next }                                # 半列(寫入被截斷)不計。17 = 表頭欄位數
{
  day = substr($1,1,10)
  if (since != "" && day < since) next
  n++
  inp+=$9; cin+=$10; outp+=$11; rea+=$12; ch+=$8
  st[$16]++
  dn[day]++; di[day]+=$9; dc[day]+=$10
  mn[$3]++; mi[$3]+=$9; mc[$3]+=$10
  sn[$14]++; si[$14]+=$9; sc[$14]+=$10
  key = $3 ":" $4
  if ($15+0 > tr[key]) tr[key] = $15+0
  tc[key]++; ti[key]+=$9
  if (!(key in seenk)) { korder[++nk]=key; seenk[key]=1 }
  if (!(day in seend)) { dorder[++nd]=day; seend[day]=1 }
}
function pct(a,b) { return b>0 ? sprintf("%.1f%%", a*100/b) : "n/a" }
function k(v) { return v>=1000 ? sprintf("%.1fk", v/1000) : sprintf("%d", v) }
END{
  if (n==0) { print "(範圍內沒有紀錄)"; exit 0 }
  printf "來源: %s\n", logpath
  printf "呼叫 %d 次", n
  for (s in st) printf "  %s=%d", s, st[s]
  printf "\n\n"
  printf "input %s  cached %s  未快取 %s  output %s(其中 reasoning %s)\n",
         k(inp), k(cin), k(inp-cin), k(outp), k(rea)
  printf "cache hit rate %s   平均送出 %d 字元/次\n\n", pct(cin,inp), (n>0? ch/n : 0)

  print "── 依日 ──────────────────────────────────────────"
  printf "%-12s %5s %10s %10s %8s\n", "日期", "次數", "input", "未快取", "hit"
  for (i=1;i<=nd;i++){ d=dorder[i]
    printf "%-12s %5d %10s %10s %8s\n", d, dn[d], k(di[d]), k(di[d]-dc[d]), pct(dc[d],di[d]) }

  print "\n── 依模式 ────────────────────────────────────────"
  printf "%-8s %5s %10s %10s %8s\n", "mode", "次數", "input", "未快取", "hit"
  for (m in mn) printf "%-8s %5d %10s %10s %8s\n", m, mn[m], k(mi[m]), k(mi[m]-mc[m]), pct(mc[m],mi[m])

  print "\n── fresh vs resume(resume 的價值就看這裡)────────"
  printf "%-8s %5s %10s %10s %8s\n", "session", "次數", "input", "未快取", "hit"
  for (m in sn) printf "%-8s %5d %10s %10s %8s\n", m, sn[m], k(si[m]), k(si[m]-sc[m]), pct(sc[m],si[m])

  print "\n── 呼叫最多的複查線(輪數 = 同一條線被問了幾次)──"
  printf "%-5s %6s %10s  %s\n", "輪數", "次數", "input", "目標"
  for (i=1;i<=nk;i++){ ka=korder[i]; ord[i]=ka }
  for (i=1;i<=nk;i++) for (j=i+1;j<=nk;j++) if (tr[ord[j]] > tr[ord[i]]) { t=ord[i]; ord[i]=ord[j]; ord[j]=t }
  shown=0
  for (i=1;i<=nk && shown<top;i++){ ka=ord[i]; shown++
    printf "%-5d %6d %10s  %s\n", tr[ka], tc[ka], k(ti[ka]), ka }
  if (nk > shown) printf "(另有 %d 條複查線未列出;--top N 可調)\n", nk-shown
}
' "$LOG"
REVIEW_RC=$?
fi

# 離開碼: review 報表失敗優先(這是加入 decide 區塊之前的離開碼),否則取 decide 報表的。
if [ -z "$DECIDE_LOG" ] || [ ! -f "$DECIDE_LOG" ]; then
  echo "[codex-usage] 還沒有任何 codex-decide 紀錄: ${DECIDE_LOG:-(沒有 HOME,未指定 --decide-log)}" >&2
  exit "$REVIEW_RC"
fi
# 欄位(codex-decide.sh 的 write_decide_log): 1 ts 2 repo 3 question 4 severity 5 model 6 effort 7 used_legacy
# 8 agree 9 verdict_kind 10 confidence 11 basis 12 allow_inference 13-16 tokens 17 status 18 detail 19 rc
awk -F'\t' -v since="$SINCE" -v logpath="$DECIDE_LOG" '
$1=="ts" { next }                               # 表頭(理由同上)
NF != 19 { next }                               # 半列與拼接列都不計(多於 19 欄代表接在殘列後面)。19 = 表頭欄位數
$18=="help" { next }                            # --help 不是諮詢
{
  day = substr($1,1,10)
  if (since != "" && day < since) next
  n++; st[$17]++
  m = ($5 == "" ? "(未送出)" : $5 "/" $6)
  mn[m]++; ms[m, $17]++
  if (!(m in seenm)) { morder[++nm]=m; seenm[m]=1 }
  if ($19 == 3) { k = m SUBSEP $18; if (!(k in dt)) dorder[++ndk]=k; dt[k]++; nd++ }   # 依模型分列: 要看的是 gpt-6.2-sol 自己的 exit 3
  if ($7 == 1) legacy++
}
END{
  print "\n── codex-decide(離開碼)──────────────────────────"
  printf "來源: %s\n", logpath
  if (n==0) { print "(範圍內沒有紀錄)"; exit 0 }
  printf "呼叫 %d 次", n
  split("OK NO_CONSENSUS FAILED RATE_LIMITED STOP CONTRACT_ERROR INTERRUPTED OTHER", order, " ")
  for (i=1;i<=8;i++) if (order[i] in st) printf "  %s=%d", order[i], st[order[i]]
  printf "  已退回舊模型=%d\n", legacy+0
  print "依模型(model/effort;未送出 = 選定模型之前就離開,即參數錯誤或缺安全聲明;沒有 codex／未登入時已選定模型,記在該模型下):"
  for (i=1;i<=nm;i++){ m=morder[i]; printf "  %-24s %4d 次", m, mn[m]
    for (j=1;j<=8;j++) if ((m, order[j]) in ms) printf "  %s=%d", order[j], ms[m, order[j]]
    printf "\n" }
  if (nd > 0) {
    print "exit 3 的原因(依模型):"
    for (i=1;i<=nm;i++){ m=morder[i]; line=""
      for (j=1;j<=ndk;j++){ split(dorder[j], p, SUBSEP); if (p[1]==m) line = line sprintf("  %s=%d", p[2], dt[dorder[j]]) }
      if (line != "") printf "  %-24s%s\n", m, line }
  }
}
' "$DECIDE_LOG"
DECIDE_RC=$?
[ "$REVIEW_RC" -ne 0 ] && exit "$REVIEW_RC"
exit "$DECIDE_RC"
