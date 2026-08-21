# output-audit 第二階段：彙總中間格式並輸出報表。
# 由 output-audit.sh 以 `jq -sr -f` 執行；輸入為 extract 階段的 JSONL。

def pct(a; b): if b == 0 then 0 else (a * 1000 / b | round / 10) end;
def quant(s; q): if (s | length) == 0 then 0 else s[ (((s | length) - 1) * q) | floor ] end;
def human:
  if . >= 1048576 then ((. * 10 / 1048576 | round / 10 | tostring) + " MB")
  elif . >= 1024 then ((. * 10 / 1024 | round / 10 | tostring) + " KB")
  else ((. | tostring) + " B") end;
def pad(n): (tostring) as $s | $s + (" " * (if n > ($s | length) then n - ($s | length) else 0 end));
def lpad(n): (tostring) as $s | (" " * (if n > ($s | length) then n - ($s | length) else 0 end)) + $s;

# 預覽遮罩。順序是關鍵，兩個實測缺陷逼出來的：
#   1. 舊版先匹配 `authorization[=:\s]+\S+`，對 `Authorization: Bearer sk-xxx`
#      只吃掉 "Bearer"，真正的憑證留在後面；而後續的 bearer 規則此時已無
#      "Bearer" 可匹配 → 外洩。所以 header 形式要先吃到引號為止。
#   2. 舊版字元類只以空白與雙引號為界，`API_KEY="sk-xxx"` 只替換掉 `API_KEY=`，
#      `"sk-xxx"` 原樣留下 → 外洩。所以雙引號／單引號包覆的形式要各自先處理，
#      未加引號的形式最後才收尾。
def redact:
  gsub("(?i)(?<k>authorization)\\s*:\\s*[^\"']*"; "\(.k): <redacted>")
  | gsub("(?i)bearer\\s+[^\\s\"']+"; "Bearer <redacted>")
  | gsub("(?i)(?<k>token|api[_-]?key|apikey|password|passwd|secret)\\s*[=:]\\s*\"[^\"]*\""; "\(.k)=<redacted>")
  | gsub("(?i)(?<k>token|api[_-]?key|apikey|password|passwd|secret)\\s*[=:]\\s*'[^']*'"; "\(.k)=<redacted>")
  | gsub("(?i)(?<k>token|api[_-]?key|apikey|password|passwd|secret)\\s*[=:]\\s*[^\\s\"']*"; "\(.k)=<redacted>");

# jq 的 "" | split("\n") 回傳 []（不是 [""]），取 [0] 得 null，
# 後續 gsub/test 對 null 會整份中止。空指令字串是真實輸入，必須保底。
def firstline: (split("\n")[0] // "");

# 取「真正做事」的程式名。三層過濾都是實測資料逼出來的：
#   1. 跳過變數賦值（`FOO=1 npm ...` 的 prog 是 npm）
#   2. 依 && || ; 切段——`cd X && npm test` 的成本要算在 npm 頭上；
#      不切的話 cd 會吃掉 28% 的統計，整張表變成無法行動的雜訊
#   3. 跳過純前綴指令（cd/sudo/time/exec/env/command），它們不是成本來源
def prog:
  firstline
  | [splits("&&|\\|\\||;")]
  | map(sub("^\\s+"; "") | sub("\\s+$"; ""))
  | map(split(" ") | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=") | not)) | (.[0] // ""))
  | map(select(. != ""))
  | (map(select(test("^(cd|sudo|time|exec|env|command)$") | not)) | .[0]) // (.[0] // "env");

# json 判定只看第一個非空行，且開括號後必須接合法的 JSON 值起始字元。
# 舊版對多行內容用 ^ 錨點，於是任何一行以 [ 開頭就命中——3000 行的
# `[INFO] building module N` 因此被歸成 json，污染了整份分類資料。
def klass($h):
  if   ($h | test("^\\s*[\\[{]\\s*([\"\\[{\\]}0-9-]|$)")) then "json"
  elif ($h | test("^diff --git|^commit [0-9a-f]{4}|\\n@@ ")) then "git"
  elif ($h | test("Traceback \\(most recent|Exception in thread|panic: |Fatal error:")) then "trace"
  elif ($h | test("(^|\\s)(PASS|FAIL)(\\s|$)|[0-9]+ (passing|failing)|Tests:\\s")) then "test"
  elif ($h | test("error TS[0-9]|error\\[|error:|warning:|^Compiling |webpack")) then "build"
  elif ($h | test("^\\[(INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\\]")) then "log"
  else "other" end;

# 配對鍵含 sid：tool_use id 只保證在單一 session 內唯一，跨 transcript
# 重複使用同一個 id 會把結果錯配到別的指令上。NUL 當分隔字元，
# 避免字串串接產生的邊界碰撞。
def pairkey: (.sid // "?") + "|#|" + (.id // "");

(map(select(.k == "u")) | INDEX(pairkey)) as $uses
| [ .[]
    | select(.k == "r")
    | . as $r
    | ($uses[$r | pairkey] // null) as $u
    | select($u != null)
    # 每個字串欄位都要保底：transcript 是跨版本累積的資料，欄位缺漏一定會
    # 發生，而 test()/gsub() 對 null 會整份中止而不是略過該筆。
    | ($u.cmd // "") as $c
    | ($r.head // "") as $h
    | { day: (($r.ts // "")[0:10]),
        sid: ($r.sid // "?"),
        tool: ($u.tool // "?"),
        prog: (if ($u.tool // "") == "Bash" then ($c | prog) else ($u.tool // "?") end),
        preview: ($c | firstline | redact | .[0:56]),
        cmdkey: ($c | .[0:400]),
        len: ($r.len // 0),
        nontext: ($r.nontext // 0),
        persisted: ($r.persisted // false),
        class: klass($h) } ] as $all
| ($all | length) as $n
| if $n == 0 then "近 \($days) 天沒有可配對的 tool_use/tool_result。" else

($all | map(.len) | add // 0) as $tot
| ($all | map(.len) | sort) as $sorted
| ($all | map(.nontext) | add // 0) as $nontext_blocks

| "工具輸出稽核   近 \($days) 天（cutoff \($cutoff)）   token 估算比 \($bpt) bytes/token",
  "",
  "== 總覽 ==",
  "  tool_result 筆數   \($n)" +
    (if $skipped > 0 then "   [transcript 有 \($skipped) 行無法解析，已略過]" else "" end),
  (if $exterr > 0 then
     "  ⚠ 有 \($exterr) 個 transcript 在抽取階段出錯——該檔自出錯處起的事件未計入，"
     + "本報表為**低估值**。"
   else empty end),
  "  進入 context 總量  \($tot | human)   (est. \(($tot / $bpt) | round) tokens)",
  "  中位數 / p90 / max \(quant($sorted;0.5)|human) / \(quant($sorted;0.9)|human) / \(($sorted|last)|human)",
  "  Claude Code 原生落檔觸發  \([$all[]|select(.persisted)]|length) 次" +
    "（超大輸出會自動存成檔案、只餵 preview——這層本來就存在）",
  (if $nontext_blocks > 0 then
     "  非文字 block  \($nontext_blocks) 個（圖片等，無 text 可計 bytes，未計入總量）"
   else empty end),
  "",
  "== 依工具 ==",
  "  工具            筆數    總量     佔比   中位數",
  ( $all | group_by(.tool) | sort_by(-(map(.len)|add)) | .[]
    | "  \(.[0].tool|pad(14)) \(length|lpad(5))  \((map(.len)|add)|human|lpad(9)) \(pct(map(.len)|add; $tot)|lpad(5))%  \((map(.len)|sort|quant(.;0.5))|human|lpad(8))" ),
  "",
  "== Bash：最耗 context 的指令（top \($top)）==",
  "  這是可行動的部分：同樣的資訊常常有更省的取法（--oneline / --stat / head）。",
  "  程式        次數    總量    佔比  指令預覽",
  ( [$all[] | select(.tool == "Bash")] | group_by(.prog) | sort_by(-(map(.len)|add)) | .[0:$top] | .[]
    | "  \(.[0].prog|pad(11)) \(length|lpad(4))  \((map(.len)|add)|human|lpad(8)) \(pct(map(.len)|add; $tot)|lpad(5))%  \(.[0].preview)" ),
  "",
  "== 內容型別 ==",
  "  型別     筆數   總量      佔比   中位數     p90",
  ( $all | group_by(.class) | sort_by(-(map(.len)|add)) | .[]
    | (map(.len)|sort) as $s
    | "  \(.[0].class|pad(8)) \(length|lpad(4))  \((map(.len)|add)|human|lpad(9)) \(pct(map(.len)|add; $tot)|lpad(5))%  \(quant($s;0.5)|human|lpad(8)) \(quant($s;0.9)|human|lpad(8))" ),
  "",
  "== 門檻模擬：若在 T 之上只保留 T，可少進多少 context ==",
  "  上限值，非淨節省——取回與重跑的成本不在其中。",
  "  門檻     受影響   佔筆數   可省      佔總量  est. tokens",
  ( [4096, 8192, 16384, 32768, 65536] | .[] | . as $t
    | ($all | map(select(.len > $t))) as $hit
    | ($hit | map(.len - $t) | add // 0) as $save
    | "  \((($t/1024)|tostring) + " KB"|pad(8)) \($hit|length|lpad(5))   \(pct($hit|length;$n)|lpad(5))%  \($save|human|lpad(9)) \(pct($save;$tot)|lpad(5))%  \(($save/$bpt|round)|lpad(9))" ),
  "",
  "== 重跑（同 session 內重複的指令）==",
  "  沒有任何截斷機制時的自然重跑率。日後若加上有損縮減，要看的是相對這條線升高多少。",
  ( [$all[] | select(.tool == "Bash")] as $b
    | ($b | group_by([.sid, .cmdkey]) | map(select(length > 1)) | map(length - 1) | add // 0) as $dup
    | "  重複次數 \($dup) / Bash 呼叫 \($b|length)   → \(pct($dup; ($b|length)))%" ),
  "",
  "== 判讀 ==",
  ( ($all | map(select(.len > 16384)) | length) as $big
    | ($all | map(select(.len > 16384)) | map(.len) | add // 0) as $bigb
    | if $big == 0 then
        "  近 \($days) 天沒有任何 tool_result 超過 16 KB——不需要額外的輸出縮減層。"
      else
        "  \($big) 筆（\(pct($big;$n))%）超過 16 KB，佔總量 \(pct($bigb;$tot))%。"
        + "先看上面「最耗 context 的指令」——改指令本身是無損的，優於任何事後壓縮。"
      end ),
  "  提醒：單日資料會抖。要據此改動工作流，先確認同方向的結論連續出現 3 天以上。"
end
