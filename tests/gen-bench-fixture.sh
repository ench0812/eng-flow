#!/usr/bin/env bash
# 產生 500 則的 benchmark fixture（9 則基準 + 491 則 bench），供 T6 的
# 常駐成本與效能驗收使用。輸出到指定的臨時目錄，**不污染共用 fixture**。
#
# 用法: bash tests/gen-bench-fixture.sh <outdir>
#
# 可重現性：description 用**確定性的字串攪拌**產生 hex 串（非密碼學雜湊）。
# 需求只有兩個——每次跑出來一樣、彼此 2-gram 重疊夠低。用 sha256 會讓
# 491 則各開一個子行程（Windows/Git Bash 每個約 30ms ≈ 15 秒），
# 而這裡要量的正是「有沒有 per-item 子行程」，工具本身就不該犯同樣的錯。
set -uo pipefail

OUT="${1:-}"
[ -n "$OUT" ] || { echo "用法: gen-bench-fixture.sh <outdir>" >&2; exit 2; }
BANK="$OUT/memory"
mkdir -p "$BANK" || exit 2

# 9 則基準記憶（模擬現況規模），其中 2 則 pin
awk -v bank="$BANK" '
BEGIN {
    n = split("alpha bravo charlie delta echo foxtrot golf hotel india", ids, " ")
    split("部署與環境的現況裁定|測試假紅假綠的排除清單|GitHub 組織與倉庫盤點|複查制度與收尾順序|安全姿態的刻意不收緊|工作區佈局與遺失文件|工具試用追蹤與重評日|沙箱修復的根因紀錄|鐵律考古重建結果", desc, "|")
    for (i = 1; i <= n; i++) {
        id = ids[i]
        f = bank "/" id ".md"
        pin = (i <= 2) ? "  pin: true\n" : ""
        # 描述必須彼此差異夠大：全部寫成「基準記憶 X 的用途說明」時，
        # 9 則之間的 2-gram 重疊會讓 dup_candidate 誤報 69 對（實測）。
        printf "---\nname: %s\ndescription: %s\nmetadata:\n  node_type: memory\n  type: project\n%s---\n", id, desc[i], pin > f
        printf "%s 的第一段內容，描述背景與現況。\n\n%s 的第二段，說明限制。\n", id, id > f
        close(f)
    }
}'

# 491 則 bench 記憶
awk -v bank="$BANK" '
# 確定性攪拌 → base-36 字串。
# **不可用 hex**：16 種字元的 2-gram 只有 256 種可能，491 則之間必然大量重疊，
# 於是 dup_candidate 爆出三萬多筆——fixture 自己違反了它要驗證的「dup=0」條件
# （實測 34,038 筆）。base-36 的 2-gram 有 1296 種，重疊率降到可忽略。
# 用 srand(seed)+rand() 產生 base-36 串：確定性（同 seed 同結果）且相鄰 seed
# 的輸出互不相關。自寫的 djb2 式雜湊沒有雪崩效應——實測相鄰 id 產出
# 81q2lvqd... / 81q2lvqe... 這種共享長前綴的字串，dup_candidate 因此爆掉。
function mix(seed,   i, out) {
    srand(seed)
    out = ""
    for (i = 0; i < 12; i++) out = out substr(A36, int(rand() * 36) + 1, 1)
    return out
}
BEGIN {
    A36 = "0123456789abcdefghijklmnopqrstuvwxyz"
    body200 = ""
    for (i = 0; i < 40; i++) body200 = body200 "abcde"      # 200 bytes
    for (i = 1; i <= 491; i++) {
        id = sprintf("bench-%04d", i)
        d = "benchmark " mix(i * 7919) " " mix(i * 104729 + 13)
        f = bank "/" id ".md"
        printf "---\nname: %s\ndescription: %s\nmetadata:\n  node_type: memory\n  type: project\n---\n", id, d > f
        printf "%s\n\n%s\n\n%s\n", body200, body200, body200 > f
        close(f)
    }
}'

# manifest：檔名 + 大小，用來確認重跑產生 byte 相同的 fixture。
# 不用 `find -printf` 與 `md5sum`——兩者都是 GNU 專屬，BSD/macOS 沒有，
# 而 README 拿這份 fixture 當「常駐成本與 N 無關」的證據；證據跑不起來就不是證據。
# `wc -c` 與 `cksum` 都在 POSIX 裡。
for f in "$BANK"/*.md; do
  [ -f "$f" ] || continue
  printf '%s %s\n' "${f##*/}" "$(wc -c < "$f" | tr -d ' ')"
done | LC_ALL=C sort > "$OUT/manifest.txt"
printf 'files=%s\n' "$(grep -c . "$OUT/manifest.txt")"
printf 'manifest_cksum=%s\n' "$(cksum < "$OUT/manifest.txt" | cut -d' ' -f1)"
