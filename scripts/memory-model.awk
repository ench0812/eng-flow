# memory-model.awk — 一次掃描所有記憶檔，產出 model 與 links。
#
# 用法: awk -v US=$'\x1f' -f memory-model.awk <bank>/*.md ...
#
# 為什麼是「一次處理全部檔案」而不是「每檔一次」：
#   在 Windows/Git Bash 上每開一個子行程約 30ms。舊版每個檔案要開 5 個
#   （frontmatter 解析、wc、段落數、保留標記、連結抽取），500 則就是 2500 個
#   子行程 ≈ 75 秒——遠超效能門檻。awk 本來就能一次吃多個檔案，用 FILENAME
#   區分即可，總共只開一個行程。
#
# 輸出兩種行（呼叫端依第一欄分流）：
#   M<US>bank<US>id<US>path<US>name<US>desc<US>type<US>pin<US>review<US>
#     supersedes<US>superseded_by<US>bytes<US>paras<US>body<US>errs
#   L<US>bank<US>src<US>dst
#
# frontmatter 只接受宣告的行導向子集；不符宣告形狀一律記 errs，絕不猜測。
# 未列出的既有欄位（node_type / originSessionId / modified 等）原樣接受，
# 否則遷移會把既有記憶全部打成錯誤。

# sizefile 是 `wc -c` 對同一批檔案的輸出。需要它的理由有兩個，
# 兩個都是「靠 awk 逐行累加」做不到的：
#   (1) 逐行 length($0)+1 假設每行都有結尾換行；沒有 final newline 的檔案會多算
#       1 byte，與 wc -c 及 README 的宣告不符，而 2048 門檻附近就會誤判
#   (2) **零位元組的檔案完全不會觸發 FNR==1**，於是那種檔在 model 裡整個消失，
#       audit 會對一個非法來源回報乾淨。sizefile 讓 END 補得出這些檔
BEGIN {
    if (sizefile != "") {
        nsz = 0
        while ((getline line < sizefile) > 0) {
            sub(/^[ \t]+/, "", line)
            if (line !~ /^[0-9]+[ \t]/) continue
            n = line; sub(/[ \t].*$/, "", n)
            f = line; sub(/^[0-9]+[ \t]+/, "", f)
            nsz++
            SZ_PATH[nsz] = f; SZ_N[nsz] = n + 0
        }
        close(sizefile)
        # 多檔時 wc 會多印一行 total；它不是檔案，丟掉
        if (nsz > 1 && SZ_PATH[nsz] == "total") nsz--
        for (i = 1; i <= nsz; i++) SZ[SZ_PATH[i]] = SZ_N[i]
    }
}

# 清空整個 array 用 `split("", a)` 而不是 `delete a`：後者是較新的擴充，
# 舊版 mawk 直接 parse fail——而 README 宣告 mawk 環境只是降級成 byte 模式，
# 不是完全跑不起來。
function reset() {
    state = "pre"; in_meta = 0
    name = ""; desc = ""; type = ""; pin = "false"
    review = ""; sup = ""; supby = ""
    body = 0; errs = ""; nbytes = 0; paras = 1; blank = 0
    split("", seenkey)
    split("", links); nlinks = 0
    has_reserved = 0
}

function adderr(r) { errs = errs (errs ? "," : "") r }

# 重複的 key 一律判 malformed，不取最後一個。靜默覆寫在治理欄位上是會出人命的：
# 先寫 `superseded_by: new` 再寫一個空的 `superseded_by:`，那則**已被取代**的記憶
# 會變回「現行」，重新進搜尋結果與釘選索引，而且兩邊都沒有 relation_mismatch。
function dupkey(k) {
    if (k in seenkey) { adderr("duplicate_key:" substr(k, 3)); return 1 }
    seenkey[k] = 1
    return 0
}

function check_value(v, k) {
    # 控制字元一律拒收。model 以 US（\x1f）分欄，值裡若混進一個 US，
    # 後面所有欄位就整排左移——pin、superseded_by 這些治理欄位會被讀成
    # 別的東西，而且看起來完全正常。這是可以被刻意構造的，所以擋在源頭。
    # TAB 也在內：search 的輸出契約是 path<TAB>id<TAB>description 三欄，
    # description 裡的一個 TAB 就會多長出一欄，下游 TSV 解析全部錯位。
    if (v ~ /[\001-\037]/) { adderr("control_char:" k); return 0 }
    if (v ~ /^["']/)            { adderr("quoted_value:" k); return 0 }
    if (v == "|" || v == ">")   { adderr("multiline_value:" k); return 0 }
    if (v ~ /^\[/ && v !~ /\]$/) { adderr("unterminated_array:" k); return 0 }
    return 1
}

function date_ok(d,    m, dd) {
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return 0
    m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
    if (m < 1 || m > 12 || dd < 1 || dd > 31) return 0
    # 月長度與閏年：awk 內判完，避免每則記憶再開一個 date 子行程
    if (m == 2) {
        y = substr(d, 1, 4) + 0
        leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
        if (dd > (leap ? 29 : 28)) return 0
    } else if (m == 4 || m == 6 || m == 9 || m == 11) {
        if (dd > 30) return 0
    }
    return 1
}

function flush(    i) {
    if (curfile == "") return
    if (state == "pre") adderr("empty_file")
    else if (state == "fm") adderr("unterminated_frontmatter")
    if (name == "") adderr("missing_name")
    if (desc == "") adderr("missing_description")
    # ID 就是檔名 stem，而它會原樣寫進 `<!-- PINNED:ITEM %s -->`。
    # 檔名裡放得下 `-->`、`<`、`>`，那足以從記憶正文外面破壞索引的標記結構；
    # 同時 CLAUDE.md 的 `memory `id`` 與 `[[id]]` 兩個 parser 都只認這個字元集，
    # 超出範圍的 ID 本來就引用不到。所以在來源就限制，不在輸出端補救。
    if (curstem !~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/) adderr("bad_id")
    if (name != "" && name != curstem) adderr("name_stem_mismatch")
    if (review != "" && !date_ok(review)) adderr("bad_review_by")
    if (has_reserved) adderr("reserved_marker")
    if (body == 0) body = 1
    if (curfile in SZ) nbytes = SZ[curfile]

    print curbank US curstem US curfile US name US desc US type US pin \
          US review US sup US supby US nbytes US paras US body US errs
    for (i = 1; i <= nlinks; i++)
        print curbank US curstem US links[i] > linksfile
}

FNR == 1 {
    flush()
    reset()
    curfile = FILENAME
    curbank = FILENAME; sub(/\/[^\/]*$/, "", curbank)
    curstem = FILENAME; sub(/^.*\//, "", curstem); sub(/\.md$/, "", curstem)
    SEEN[FILENAME] = 1
}

# CRLF 正規化必須排在所有內容規則**之前**。少了它，Windows 編輯器存過的記憶
# 第一行是 `---\r`，不等於 `---`，整個檔被判 missing_frontmatter；
# 而 missing_frontmatter 屬於會讓 `--write` 與 `search` 中止的來源錯誤，
# 於是「用記事本開過一次」就足以讓整個記憶庫停擺。
# 這不是猜測——CRLF 是有明確定義的行尾慣例，不是格式不明。
# bytes 由 wc 供給，仍會把 \r 算進去，與 wc -c 的宣告一致。
{ sub(/\r$/, "") }

{
    nbytes += length($0) + 1        # +1 為換行；與 wc -c 對齊
}

FNR == 1 && $0 ~ /^\xef\xbb\xbf/ { adderr("bom_not_allowed"); state = "skip"; next }
FNR == 1 && $0 != "---"           { adderr("missing_frontmatter"); state = "skip"; next }
FNR == 1                          { state = "fm"; next }

state == "fm" && $0 == "---" { state = "body"; body = FNR + 1; next }

state == "fm" {
    if ($0 ~ /^[[:space:]]*$/) { adderr("blank_line_in_frontmatter"); next }
    if ($0 ~ /^  [A-Za-z_][A-Za-z0-9_]*:/) {
        if (!in_meta) { adderr("indented_key_outside_metadata"); next }
        k = $0; sub(/^  /, "", k); sub(/:.*$/, "", k)
        v = $0; sub(/^  [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*/, "", v)
        if (!check_value(v, k)) next
        if (dupkey("m:" k)) next
        # supersedes 的資料模型是陣列。`supersedes: old-id` 與 `supersedes: a,b`
        # 目前都會被 split_array 當成合法輸入解析掉——寫錯格式卻靜默接受，
        # 之後所有取代關係的判定都建立在猜出來的語意上。
        if (k == "supersedes" && v !~ /^\[.*\]$/) { adderr("array_expected:supersedes"); next }
        # `[old,]`、`[a,,b]`、`[,]` 這種空元素會被 split_array 靜默跳過，
        # 於是三種不同的寫法被正規化成同一個關係——治理資料的語意用猜的。
        if (k == "supersedes" &&
            (v ~ /,[[:space:]]*,/ || v ~ /\[[[:space:]]*,/ || v ~ /,[[:space:]]*\]/)) {
            adderr("empty_array_element:supersedes"); next
        }
        if (k == "type") type = v
        else if (k == "pin") {
            # 只認 true／false。`pin: TRUE` 或拼錯會被當成「沒釘選」，
            # 那則記憶就這樣從常駐索引裡消失，而且沒有任何訊息。
            if (v != "true" && v != "false") { adderr("bad_pin:" v); next }
            pin = v
        }
        else if (k == "review_by") review = v
        else if (k == "supersedes") sup = v
        else if (k == "superseded_by") supby = v
        next
    }
    if ($0 ~ /^[[:space:]]+/) { adderr("bad_indent"); next }
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
        k = $0; sub(/:.*$/, "", k)
        v = $0; sub(/^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*/, "", v)
        in_meta = (k == "metadata")
        # 重複的 metadata: 區塊同樣是重複 key。不擋的話兩個區塊會被合併解讀，
        # 後面那組把前面那組的 superseded_by 覆寫掉——已取代的記憶就這樣復活。
        if (in_meta) {
            if (dupkey("r:metadata")) next
            if (v != "") adderr("metadata_must_be_mapping")
            next
        }
        if (!check_value(v, k)) next
        if (dupkey("r:" k)) next
        # 治理欄位放在根層是**寫錯層級**，不是未知欄位。未知欄位原樣接受是為了
        # 讓既有資料能遷移；但把 superseded_by 寫在根層而被靜默忽略，會讓一則
        # 已被取代的記憶看起來仍然現行，照樣進搜尋結果與釘選索引。
        if (k == "pin" || k == "supersedes" || k == "superseded_by" ||
            k == "review_by" || k == "type") {
            adderr("misplaced_key:" k); next
        }
        if (k == "name") name = v
        else if (k == "description") desc = v
        next
    }
    adderr("unparsable_line")
    next
}

state == "body" {
    if ($0 ~ /^[[:space:]]*$/) { blank = 1 }
    else if (blank) { paras++; blank = 0 }
    # TOPICS 標記也要列為保留：extract_topics 取的是第一組標記，
    # 釘選記憶的正文若含 TOPICS:BEGIN，人工維護的主題區塊會被它蓋掉。
    if ($0 ~ /<!-- (PINNED:(BEGIN|END|ITEM )|TOPICS:(BEGIN|END))/) has_reserved = 1
    line = $0
    while (match(line, /\[\[[^]]+\]\]/)) {
        lid = substr(line, RSTART + 2, RLENGTH - 4)
        # links 檔同樣以 US 分欄，id 裡的控制字元會讓下游讀錯目標
        if (lid ~ /[\001-\010\013-\037]/) adderr("control_char:link")
        else links[++nlinks] = lid
        line = substr(line, RSTART + RLENGTH)
    }
}

END {
    flush()
    # 零位元組檔一行都沒有，上面的規則全部沒跑過。不補的話它在 model 裡不存在，
    # 而「不存在」在下游等同「沒有問題」——一個空的 .md 會被當成乾淨。
    for (i = 1; i <= nsz; i++) {
        f = SZ_PATH[i]
        if (f in SEEN) continue
        eb = f; sub(/\/[^\/]*$/, "", eb)
        es = f; sub(/^.*\//, "", es); sub(/\.md$/, "", es)
        print eb US es US f US "" US "" US "" US "false" US "" US "" US "" \
              US SZ[f] US 1 US 1 US "empty_file,missing_name,missing_description"
    }
}
