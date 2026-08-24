#!/usr/bin/env bash
# codex-usage.sh — codex-review 用量報表(唯讀,只讀 $CODEX_REVIEW_LOG)
#
# 存在的理由: 在這份遙測之前,「codex 用量成長過快」只能靠感覺——腳本用 mktemp 暫存並在
# EXIT 全部刪除,本機一筆用量都沒有留下。要判斷「哪裡在燒」必須有數字。
#
# 用法: bash codex-usage.sh [--since YYYY-MM-DD] [--top N] [--log <path>]
#
# 讀哪一欄:
#   cache hit rate = cached_input_tokens / input_tokens。這是「有多少 input 走 0.1x 費率」。
#   未快取 input   = input_tokens - cached_input_tokens。這才是實際被全額計費的量,
#                    比總 input 更能反映成本——看趨勢要看這一欄。
set -uo pipefail

LOG="${CODEX_REVIEW_LOG:-$HOME/.claude/cache/codex-review-usage.tsv}"
SINCE=""; TOP=10
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --since 需要值。" >&2; exit 2; }; SINCE="$2"; shift 2 ;;
    --top)   [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --top 需要值。" >&2; exit 2; };   TOP="$2";   shift 2 ;;
    --log)   [ $# -ge 2 ] || { echo "[codex-usage] 錯誤: --log 需要值。" >&2; exit 2; };   LOG="$2";   shift 2 ;;
    -h|--help)
      echo "用法: bash codex-usage.sh [--since YYYY-MM-DD] [--top N] [--log <path>]"
      exit 0 ;;
    *) echo "[codex-usage] 未知參數: $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$LOG" ]; then
  echo "[codex-usage] 還沒有任何用量紀錄: $LOG" >&2
  echo "  跑過一次 codex-review.sh 之後就會有。" >&2
  exit 0
fi

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
