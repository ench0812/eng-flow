# output-audit 第一階段：把 transcript 記錄抽成扁平的中間格式。
# 由 output-audit.sh 以 `jq -c -f` 逐檔 streaming 執行。
#
# 抽成獨立 .jq 檔的理由：這段程式需要用到撇號（正規式的字元類邊界），
# 而內嵌在 shell 單引號字串裡時，任何字面撇號都會就地截斷該字串。

# 型別防護：transcript 是跨版本累積的資料，「合法 JSON 但欄位型別不對」
# 一定會出現（例如 timestamp 是數字）。對非字串做 [0:10] 會讓 jq 執行期錯誤，
# 而 jq 一旦出錯就會中止該檔——損失的不只是那一筆，是那一筆之後的全部。
# 所以先過濾型別，不合的直接略過，不讓它有機會炸掉整個檔案。
def s: if type == "string" then . else "" end;

select((.timestamp | type) == "string")
| select(.timestamp[0:10] >= $cutoff)
| .timestamp as $ts
# 缺 sessionId 時以來源檔名（session id）補上，而不是全部塞 "?"。
# 全塞 "?" 會讓跨 transcript 的相同 tool id 又混在同一個命名空間裡，
# 正好抵銷「配對鍵含 session」的用意。
| ((.sessionId | s) | if . == "" then $srcsid else . end) as $sid

# `// []` 必須套在被迭代的值上，不能只用在 select 的判斷式裡：
# .message.content 在部分記錄是 null，只判斷不替換會在迭代時中止
# （Cannot iterate over null）。
| ((.message.content? // []) | if type == "array" then . else [] end)[]

| if .type == "tool_use" then
    { k: "u", ts: $ts, sid: $sid,
      id: (.id | s),
      tool: ((.name | s) | if . == "" then "?" else . end),
      cmd: ( [ (.input.command? | s), (.input.file_path? | s), (.input.pattern? | s) ]
             | map(select(. != "")) | (.[0] // "") ) }

  elif .type == "tool_result" then
    # content 可能是字串，也可能是 content-block 陣列（MCP／多模態工具）。
    # 只認字串會把陣列型結果記成 0 B，直接違反「模型實際收到多少 bytes」的定義。
    # 陣列時取各 block 的 text 串接；非文字 block（圖片等）沒有 text，
    # 以 blocks 計數另行揭露，不假裝它們是 0。
    ( .content ) as $c
    # 串接前先濾掉沒有 text 的 block（圖片等），否則每個非文字 block 都會
    # 因 join 多貢獻一個換行，讓 bytes 比模型實際收到的多。
    | ( if   ($c | type) == "string" then $c
        elif ($c | type) == "array"
        then ($c | map(.text? // "") | map(select(. != "")) | join("\n"))
        else "" end ) as $text
    | ( if ($c | type) == "array"
        then ($c | map(select((.text? // "") == "")) | length)
        else 0 end ) as $nontext
    | { k: "r", ts: $ts, sid: $sid, id: (.tool_use_id | s),
        len: ($text | utf8bytelength),
        nontext: $nontext,
        err: (.is_error // false),
        persisted: ($text | test("Output too large \\(")),
        head: ($text[0:400]) }

  else empty end
