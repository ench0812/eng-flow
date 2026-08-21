#!/usr/bin/env bash
# output-audit.sh — 離線分析 Claude Code transcript，量化「工具輸出吃掉多少 context」。
#
# 為什麼是離線分析而不是 hook：
#   transcript（~/.claude/projects/**/*.jsonl）已經完整記錄每個 tool_use 與
#   tool_result，包含模型實際看到的輸出內容。用 PostToolUse hook 再記一次是重複
#   蒐集，而且要付出每條指令的執行成本——實測那種 hook 在 86KB 輸出時要 570ms，
#   掛在每一條 Bash 上。離線分析同樣的資料是零執行期成本，而且拿得到 hook 拿不到
#   的東西：is_error、tool_use_id 串接、跨事件關聯。
#
#   另外，Claude Code 對過大的輸出**本來就會**落檔並只餵 preview
#   （~/.claude/projects/*/*/tool-results/*.txt），所以「大輸出落檔」這層不需要
#   自己再造一次；transcript 裡的長度已經是扣掉那層之後、模型真正收到的值。
#
# 誠實邊界：token 數是**估計值**，用固定 bytes/token 比換算並標明。真實比值隨內容
# 型別浮動，這裡不假裝精確。門檻模擬給的是「可少進多少 context」的上限，不是淨節省
# ——取回與重跑的成本不在其中。
#
# 安全：報表會顯示指令預覽以利判斷，但先做遮罩（Authorization / Bearer / token /
# api_key / password / secret，含引號包覆的形式）。完整指令不寫入任何檔案，只印到
# stdout。
#
# 用法: bash output-audit.sh [--days N] [--bytes-per-token R] [--top N]
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd -P)"
EXTRACT_JQ="$SCRIPTS/output-audit-extract.jq"
REPORT_JQ="$SCRIPTS/output-audit-report.jq"
PROJ_DIR="$HOME/.claude/projects"
DAYS=14
BPT=3.6
TOP=15

while [ $# -gt 0 ]; do
  case "$1" in
    --days)            [ $# -ge 2 ] || { echo "--days 需要值" >&2; exit 2; }; DAYS="$2"; shift 2 ;;
    --bytes-per-token) [ $# -ge 2 ] || { echo "--bytes-per-token 需要值" >&2; exit 2; }; BPT="$2"; shift 2 ;;
    --top)             [ $# -ge 2 ] || { echo "--top 需要值" >&2; exit 2; }; TOP="$2"; shift 2 ;;
    -h|--help) echo "用法: bash output-audit.sh [--days N] [--bytes-per-token R] [--top N]"; exit 0 ;;
    *) echo "未知參數: $1" >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "--days 必須是正整數" >&2; exit 2 ;; esac
case "$TOP"  in ''|*[!0-9]*) echo "--top 必須是正整數" >&2; exit 2 ;; esac
[ "$TOP" -gt 0 ] 2>/dev/null || { echo "--top 必須大於 0" >&2; exit 2; }
# BPT 是除數，0 或非數字會讓 token 換算爆掉或吐出未整理的 jq 錯誤。
case "$BPT" in
  ''|*[!0-9.]*|.|*.*.*) echo "--bytes-per-token 必須是正數" >&2; exit 2 ;;
esac
awk -v v="$BPT" 'BEGIN { exit !(v + 0 > 0) }' || { echo "--bytes-per-token 必須大於 0" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "需要 jq" >&2; exit 2; }
[ -f "$EXTRACT_JQ" ] || { echo "找不到 $EXTRACT_JQ" >&2; exit 2; }
[ -f "$REPORT_JQ" ]  || { echo "找不到 $REPORT_JQ" >&2; exit 2; }
[ -d "$PROJ_DIR" ] || { echo "找不到 $PROJ_DIR" >&2; exit 2; }

CUTOFF="$(date -u -d "-${DAYS} days" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"

EXTRACT="$(mktemp)"; trap 'rm -f "$EXTRACT"' EXIT

# 逐檔 streaming 抽取。分兩階段是刻意的：transcript 可能有數十 MB，逐檔串流的
# 記憶體用量遠低於一次 slurp 全部。
#
# 壞行處理：先用 `fromjson? // empty` 逐行容錯解析，再餵給抽取程式。
# 不能直接把整個檔案丟給 jq——jq 讀到無法解析的行會**中止該檔**，
# 於是壞行之後的合法事件會被靜默漏算（而不是只損失那一行）。
# 略過的行數要回報，不可靜默吞掉。
skipped=0
exterr=0
found=0
for f in "$PROJ_DIR"/*/*.jsonl; do
  [ -f "$f" ] || continue
  found=1
  srcsid="$(basename "$f" .jsonl)"
  total_lines="$(grep -c . "$f" 2>/dev/null || echo 0)"
  jq -c -R 'fromjson? // empty' "$f" 2>/dev/null > "$EXTRACT.parsed"
  parsed_lines="$(grep -c . "$EXTRACT.parsed" 2>/dev/null || echo 0)"
  skipped=$(( skipped + total_lines - parsed_lines ))
  # 抽取階段的結束碼要檢查，不能只丟掉 stderr：jq 遇到執行期錯誤
  # （例如欄位型別異常）會中止該檔，損失的是那一筆**之後的全部**事件。
  # 靜默漏算比報錯危險——會讓報表看起來完整、實際少了一段。
  if ! jq -c --arg cutoff "$CUTOFF" --arg srcsid "$srcsid" -f "$EXTRACT_JQ" "$EXTRACT.parsed" 2>/dev/null; then
    exterr=$(( exterr + 1 ))
  fi
done >> "$EXTRACT"
rm -f "$EXTRACT.parsed"

[ "$found" -eq 1 ] || { echo "$PROJ_DIR 下沒有 transcript。"; exit 0; }
[ -s "$EXTRACT" ] || { echo "近 $DAYS 天沒有資料（cutoff $CUTOFF）。"; exit 0; }

jq -sr \
  --argjson bpt "$BPT" \
  --argjson top "$TOP" \
  --argjson skipped "$skipped" \
  --argjson exterr "$exterr" \
  --arg days "$DAYS" \
  --arg cutoff "$CUTOFF" \
  -f "$REPORT_JQ" "$EXTRACT"
