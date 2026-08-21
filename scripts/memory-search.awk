# memory-search.awk — 單次掃描完成搜尋。
#
# 用法:
#   awk -v US=$'\x1f' -v kw="<keyword>" -f memory-search.awk model.tsv <files...>
#
# 為什麼要單次掃描：舊版在 bash 迴圈裡對每則記憶開兩個子行程
# （描述一次 grep、正文一次 awk|grep），500 則就是 1000 個子行程，
# 實測 14.3 秒。搜尋是日常操作，慢到這種程度等於沒人會用。
#
# 比對語意（與 README 的宣告一致，不可默默放寬）：
#   - 字面子字串，**不當正規式**（用 index() 而非 match()）
#   - 大小寫不敏感僅涵蓋 ASCII（tolower 的能力邊界）；CJK 無大小寫故不受影響
#   - 比對範圍為 description 與正文
#   - superseded_by 非空者一律排除——搜尋結果混入已被取代的事實，
#     比沒有搜尋更危險，因為使用者會照著它做決定
#
# 輸出: <絕對路徑>\t<id>\t<description>，由呼叫端排序。

# 關鍵字從 ENVIRON 取，不從 -v：`-v` 會解譯反斜線跳脫，
# 於是 `search '\t'` 變成搜尋一個 TAB 而非兩個字面字元。
BEGIN { FS = US; lkw = tolower(ENVIRON["MEMORY_KW"]) }

FNR == NR {                                   # 第一個檔：model
    path = $3
    P_id[path]   = $2
    P_desc[path] = $5
    P_supby[path]= $10
    P_body[path] = $13
    next
}

# 不可用 ENDFILE：那是 gawk 專屬的，mawk 不會執行該區塊——搜尋會變成
# 「無論命中與否都沒有輸出」的靜默全失效。改成在「換到下一個檔案」與 END
# 兩處收尾，語意相同且可攜。
function emit_cur() {
    if (cur != "" && !skip && hit) print cur "\t" P_id[cur] "\t" P_desc[cur]
}

FNR == 1 {                                    # 換到下一個記憶檔
    emit_cur()
    cur = FILENAME
    skip = (cur in P_id) ? (P_supby[cur] != "") : 1
    hit = 0
    if (!skip && index(tolower(P_desc[cur]), lkw) > 0) hit = 1
}

!skip && !hit && FNR >= P_body[cur] {
    if (index(tolower($0), lkw) > 0) hit = 1
}

END { emit_cur() }
