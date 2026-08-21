# shell-lint.awk — 找出**引號外**的字面 `\n`。
#
# 為什麼需要它：`cmd || \n    next` 這種被工具鏈吃掉一個字元的續行，
# `bash -n` 完全看不出來——bash 會把它讀成「執行一個叫 n 的命令」，語法完全合法。
# 實測後果是 search 的排序守衛整段變成死碼，而測試照樣全綠
#（注入旗標那條路徑仍然會走到，於是「有測到」是假的）。
#
# 作法：先拿掉成對的單/雙引號字串，再拿掉註解，剩下還看得到 `\n` 就是可疑。
# 順序不可顛倒——先砍註解的話，字串裡的 # 會把該行攔腰切斷，留下不成對的引號。
#
# 已知限制：跨行的引號字串（例如多行 printf 格式）逐行看會判成不成對，
# 內容裡的 \n 會被誤報；雙引號字串裡的撇號（例如 "You\'ve"）會讓成對判斷錯位而誤報。
# 這支 lint 只用在本次新增的檔案上，不當通用工具，所以不為此加狀態機。
#
# 用法: awk -f shell-lint.awk <shell 檔...>；有輸出即為可疑行。

BEGIN {
    BS = sprintf("%c", 92)
    SQ = sprintf("%c", 39)
    DQ = sprintf("%c", 34)
    TARGET = BS "n"
}

# 去掉 s 裡所有成對的 q 引號字串。落單的引號原樣留著（跨行字串是常態，
# 對它硬做狀態機只會製造誤報）。
function strip(s, q,    a, b) {
    while ((a = index(s, q)) > 0) {
        b = index(substr(s, a + 1), q)
        if (b == 0) break
        s = substr(s, 1, a - 1) substr(s, a + b + 1)
    }
    return s
}

{
    line = strip(strip($0, SQ), DQ)
    sub(/#.*$/, "", line)
    if (index(line, TARGET) > 0) printf "%s:%d: %s\n", FILENAME, FNR, $0
}
