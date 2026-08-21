# memory-checks.awk — 對 model 與 links 執行治理檢查。
#
# 用法:
#   awk -v US=$'\x1f' -v today=YYYY-MM-DD -v gram=char|byte -v globalbank=<path> \
#       -f memory-checks.awk model.tsv links.tsv
#
# 輸出（channel 由呼叫端分流；本檔只負責決定級別）：
#   WARN    <path>: <code> <details>     治理問題，呼叫端據此 exit 1
#   SUGGEST <path>: <code> <details>     候選，不影響 exit code
#   INFO    -: <code> <details>          狀態資訊
#
# 分級原則：候選型 heuristic 一律 SUGGEST。若讓候選也 exit 1，
# 「正常存在的候選」會讓稽核永久失敗，成功標準就不穩定。

BEGIN {
    FS = US
    nm = 0; nl = 0
    SPLIT_BYTES = 2048      # 拆分候選門檻
    SPLIT_PARAS = 4
    DUP_JACCARD = 0.35      # 重複候選門檻
}

FNR == NR {                                  # 第一個檔：model
    nm++
    m_bank[nm] = $1; m_id[nm] = $2;  m_path[nm] = $3
    m_name[nm] = $4; m_desc[nm] = $5; m_type[nm] = $6
    m_pin[nm]  = $7; m_rev[nm]  = $8; m_sup[nm]  = $9
    m_supby[nm]= $10; m_bytes[nm]= $11; m_paras[nm]= $12
    m_body[nm] = $13; m_errs[nm] = $14
    key = $1 SUBSEP $2
    idx[key] = nm
    next
}
{                                            # 第二個檔：links
    nl++
    l_bank[nl] = $1; l_src[nl] = $2; l_dst[nl] = $3
}

# 解析順序：同庫 → 全域庫。全域庫只解析全域 ID；禁止跨專案庫引用。
function resolve(bank, id,    k) {
    k = bank SUBSEP id
    if (k in idx) return idx[k]
    if (bank != globalbank) {
        k = globalbank SUBSEP id
        if (k in idx) return idx[k]
    }
    return 0
}

# 單行陣列 [a, b] → 逐項；空或 [] 回 0 項
#
# **只去掉分隔符周圍的空白**，元素內部的空白原樣留著。舊版 `gsub(/[[:space:]]/,"")`
# 會把不合法的 `[foo bar]` 靜默正規化成 `foobar`——若 `foobar` 剛好存在、
# 雙向關係也對得起來，一個根本沒寫對的取代關係就這樣通過檢查，
# 然後把某則記憶從搜尋與索引裡排除掉。留著空白，resolve() 找不到，
# 它會走 dangling_ref，那才是實話。
function split_array(s, out,    n, i, t, e) {
    split("", out)
    gsub(/^\[|\]$/, "", s)
    if (s ~ /^[[:space:]]*$/) return 0
    n = split(s, t, ",")
    for (i = 1; i <= n; i++) {
        e = t[i]
        sub(/^[[:space:]]+/, "", e)
        sub(/[[:space:]]+$/, "", e)
        if (e != "") out[++cnt_tmp] = e
    }
    return cnt_tmp
}

function warn(path, code, det) { print "WARN\t" path "\t" code "\t" det }
function sugg(path, code, det) { print "SUGGEST\t" path "\t" code "\t" det }
function info(code, det)       { print "INFO\t-\t" code "\t" det }

END {
    # ---------- 已在 shell 端處理過的 malformed 不重複報 ----------

    # ---------- dangling_ref：正文 [[id]] ----------
    for (i = 1; i <= nl; i++) {
        tgt = resolve(l_bank[i], l_dst[i])
        if (tgt == 0) {
            src = idx[l_bank[i] SUBSEP l_src[i]]
            warn(m_path[src], "dangling_ref", "[[" l_dst[i] "]]")
        } else {
            # 必須記在**解析到的目標**身上，不是連結來源的 bank。
            # 專案記憶寫 [[某則全域記憶]] 時，resolve 會落到全域庫，
            # 記在來源 bank 的話那則全域記憶的 inbound 永遠是 0——
            # 明明被引用著，卻被報成 orphan。
            inbound[m_bank[tgt] SUBSEP m_id[tgt]]++
        }
    }

    # ---------- 取代關係 ----------
    for (i = 1; i <= nm; i++) {
        # superseded_by：單一值
        if (m_supby[i] != "") {
            t = resolve(m_bank[i], m_supby[i])
            if (t == 0) { warn(m_path[i], "dangling_ref", "superseded_by=" m_supby[i]); continue }
            if (m_bank[t] != m_bank[i]) { warn(m_path[i], "relation_mismatch", "cross_bank superseded_by=" m_supby[i]); continue }
            if (m_id[t] == m_id[i])     { warn(m_path[i], "relation_mismatch", "self_supersede"); continue }
            # 反向必須存在
            cnt_tmp = 0; n = split_array(m_sup[t], arr)
            found = 0
            for (j = 1; j <= n; j++) if (arr[j] == m_id[i]) found = 1
            if (!found) warn(m_path[i], "relation_mismatch", "missing_reverse supersedes on " m_id[t])
        }
        # supersedes：陣列
        cnt_tmp = 0; n = split_array(m_sup[i], arr)
        for (j = 1; j <= n; j++) {
            t = resolve(m_bank[i], arr[j])
            if (t == 0) { warn(m_path[i], "dangling_ref", "supersedes=" arr[j]); continue }
            if (m_bank[t] != m_bank[i]) { warn(m_path[i], "relation_mismatch", "cross_bank supersedes=" arr[j]); continue }
            if (m_id[t] == m_id[i])     { warn(m_path[i], "relation_mismatch", "self_supersede"); continue }
            if (m_supby[t] != m_id[i])  warn(m_path[i], "relation_mismatch", "missing_reverse superseded_by on " m_id[t])
        }
    }

    # ---------- 環路：沿 superseded_by 走，超過 nm 步即為環 ----------
    # 走過且確認無環的節點記下來。少了它，每一則都要從自己走到鏈尾，
    # 長鏈就是 O(N²)——治理工具沒有資料量上限，不能只靠「現在才 500 則」。
    for (i = 1; i <= nm; i++) {
        if (m_supby[i] == "" || (i in ACYCLIC)) continue
        steps = 0; cur = i; np = 0
        split("", PATH)
        while (cur != 0 && m_supby[cur] != "" && steps <= nm) {
            if (cur in ACYCLIC) break
            PATH[++np] = cur
            cur = resolve(m_bank[cur], m_supby[cur]); steps++
        }
        if (steps > nm) warn(m_path[i], "relation_mismatch", "supersede_cycle")
        else for (k = 1; k <= np; k++) ACYCLIC[PATH[k]] = 1
    }

    # ---------- split / orphan ----------
    n_orphan = 0
    for (i = 1; i <= nm; i++) {
        if (m_bytes[i] + 0 > SPLIT_BYTES && m_paras[i] + 0 >= SPLIT_PARAS)
            sugg(m_path[i], "split_candidate", "bytes=" m_bytes[i] " paras=" m_paras[i])
        k = m_bank[i] SUBSEP m_id[i]
        if (!(k in inbound) && m_pin[i] != "true") {
            n_orphan++
            sugg(m_path[i], "orphan", "no_inbound_link_and_not_pinned")
        }
    }
    info("orphan_total", n_orphan)

    # ---------- dup_candidate ----------
    # 只比同庫：跨庫「全域與專案各記一次」是預期的，報出來只是雜訊。
    #
    # 用倒排索引而非兩兩比對。N=500 時 two-pass 是 124,750 對，實測十幾秒——
    # 而這段掛在 audit 上、要在 10 秒門檻內完成。Jaccard ≥ 門檻的前提是
    # 至少共享一個 gram，所以只需要走訪「同一個 gram 的貼文清單」產生候選對。
    # 極常見的 gram（出現在超過 POST_CAP 則）跳過不建候選——它沒有鑑別度，
    # 卻會製造 O(postings²) 的爆炸。
    POST_CAP = 60
    DESC_CAP = 300
    for (i = 1; i <= nm; i++) build_grams(i)

    # 建 gram → 貼文清單
    # 貼文清單以 (bank, gram) 為鍵，不是只用 gram。只用 gram 的話，
    # 多個專案各自有相似描述時，跨 bank 的總數會先撞到 POST_CAP，
    # 於是**同一個 bank 內**本來抓得到的重複候選被整組跳過——
    # 而 dup 本來就只比同庫，跨庫的數量根本不該影響它。
    for (key in G) {
        split(key, kk, SUBSEP)
        gi = kk[1] + 0; gg = kk[2]
        bg = m_bank[gi] SUBSEP gg
        # 超過 cap 之後只計數、不再串接。字串每加一次就整份複製一遍，
        # 高頻 gram 會在「反正等下要跳過」的清單上付掉 O(N²) 的拼接成本。
        if (PN[bg] < POST_CAP) POST[bg] = (bg in POST) ? POST[bg] " " gi : gi
        PN[bg]++
    }
    ndup = 0
    for (bg in POST) {
        if (PN[bg] > POST_CAP) continue
        n = split(POST[bg], plist, " ")
        for (a = 1; a <= n; a++)
            for (b = a + 1; b <= n; b++) {
                i = plist[a] + 0; j = plist[b] + 0
                # 先正規化順序再查表。POST 的內容來自 `for (key in G)`，
                # 而 awk 的陣列迭代順序不保證——同一對記憶可能先以 (a,b)
                # 進 PAIRSEEN、之後又以 (b,a) 重算一次，於是 dup_candidate
                # 重複輸出、dup_pairs 灌水。
                if (i > j) { tmp = i; i = j; j = tmp }
                if (m_bank[i] != m_bank[j]) continue
                if ((i, j) in PAIRSEEN) continue
                PAIRSEEN[i, j] = 1
                s = jaccard(i, j)
                if (s >= DUP_JACCARD) {
                    sugg(m_path[i], "dup_candidate", "with=" m_id[j] " jaccard=" sprintf("%.2f", s))
                    ndup++
                }
            }
    }
    info("dup_pairs", ndup)
    info("gram_mode", gram)
}

# 2-gram 集合。gram=char 時以字元切（gawk 正確處理 CJK）；
# gram=byte 時退回 byte 3-gram，呼叫端會在報表註明中文為 byte 近似。
function build_grams(i,    s, L, p, g, w) {
    # description 是單行摘要，正常不會超過兩三行字。這裡截斷只是保證
    # gram 數有上界——不設限的話，幾則超長且互相相似的描述就能讓候選對
    # 與常駐索引一起膨脹，把 audit 推出效能預算。
    s = substr(m_desc[i], 1, DESC_CAP)
    w = (gram == "char") ? 2 : 3
    L = length(s)
    GC[i] = 0
    for (p = 1; p <= L - w + 1; p++) {
        g = substr(s, p, w)
        if (!((i, g) in G)) { G[i, g] = 1; GC[i]++ }   # 集合大小要算相異數，重複的 gram 不再計
    }
}

function jaccard(a, b,    s, L, w, p, g, inter, ua, ub) {
    if (GC[a] == 0 || GC[b] == 0) return 0
    w = (gram == "char") ? 2 : 3
    inter = 0; ub = 0
    # 與 build_grams 用同一個截斷長度。少了它，分子那邊算的是截斷後的集合、
    # 分母這邊算的是完整字串，相似度會隨候選對的順序不同而不同——
    # 同一對記憶用 (a,b) 與 (b,a) 算出兩個值。
    s = substr(m_desc[b], 1, DESC_CAP); L = length(s)
    split("", seen)
    for (p = 1; p <= L - w + 1; p++) {
        g = substr(s, p, w)
        if (g in seen) continue
        seen[g] = 1; ub++
        if ((a, g) in G) inter++
    }
    ua = GC[a]
    if (ua + ub - inter == 0) return 0
    return inter / (ua + ub - inter)
}
