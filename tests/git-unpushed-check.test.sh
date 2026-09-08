#!/usr/bin/env bash
# hooks/git-unpushed-check.sh 的回歸測試。
#
# 全部在臨時建立的本地 repo 上跑，不碰網路、不碰使用者的實際 repo。
# 用 `git init --bare` 當遠端，這樣 push / 上游追蹤都是真的行為而非 stub。
# Run: bash tests/git-unpushed-check.test.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/git-unpushed-check.sh"
[ -f "$HOOK" ] || { echo "找不到 $HOOK" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "需要 jq" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "需要 git" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
export TMPDIR="$SANDBOX/tmp"    # hook 的「已警告」標記寫這裡，測完即棄
mkdir -p "$TMPDIR"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "$2"; }

# fire <cwd> <session> -> hook stdout
# GIT_GUARD_ALLOW_TEMP=1：fixture 是 mktemp -d 出來的，落在 hook 預設排除的臨時根底下。
# 沒有這個開關，整份測試會被那條規則擋掉（實測 15 條紅）。排除規則本身另有專門案例驗。
fire(){ GIT_GUARD_ALLOW_TEMP=1 jq -cn --arg c "$1" --arg s "$2" '{session_id:$s, cwd:$c}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null; }
# 【所有 helper 都定義在這裡，任何測試呼叫之前】(2026-09-08 踩過): mktr/fire_tr 原本定義在
# 檔案中段（舊 190 行），而新加的測試在 140 行。bash 對「還沒定義的函式」只印一行
# command not found 到 stderr 就繼續，而呼叫端又有 2>/dev/null——結果是 out 變成空字串，
# 斷言以「整個漏掉了」的形式失敗，看起來像被測程式壞掉，實際上被測程式完全正確。
# 診斷花掉的時間遠多於修它。同一個病在 codex-review-args.test.sh 也發生過（7 條靜默失效）。
# 檢查工具：python ~/.claude/scripts/check-shell-call-order.py <path>
mktr(){ # mktr <file> <cwd值>
  jq -cn --arg c "$2" '{cwd:$c, message:{content:[]}}' > "$1"
}
fire_tr(){ # fire_tr <cwd> <session> <transcript>
  jq -cn --arg c "$1" --arg s "$2" --arg t "$3" '{session_id:$s, cwd:$c, transcript_path:$t}' \
    | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null
}
silent(){ [ -z "$(fire "$1" "$2")" ] && ok "$3" || ng "$3" "預期靜默，實際有輸出"; }
warns(){ [ -n "$(fire "$1" "$2")" ] && ok "$3" || ng "$3" "預期有警告，實際靜默"; }

git_q(){ git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# --- 建一個有遠端的 repo ---
REMOTE="$SANDBOX/remote.git"
WORK="$SANDBOX/work"
git init -q --bare "$REMOTE"
git init -q -b main "$WORK"
echo one > "$WORK/a.txt"
git_q "$WORK" add a.txt
git_q "$WORK" commit -qm "first"
git_q "$WORK" remote add origin "$REMOTE"
git_q "$WORK" push -q -u origin main

echo "== 已同步 =="
silent "$WORK" s1 "已推送且乾淨 → 靜默"

echo "== 有未推送 commit =="
echo two > "$WORK/b.txt"
git_q "$WORK" add b.txt
git_q "$WORK" commit -qm "unpushed work"
warns "$WORK" s2 "本機領先上游 → 警告"

# auto 桶要求「本 session 有寫入證據」，cwd 不算（cwd 只表示 session 從那裡啟動）。
# 所以這裡要餵一份含 Write 的 transcript，否則驗不到 auto 桶的分流。
TR_W="$SANDBOX/tr_write.jsonl"
jq -cn --arg c "$WORK" --arg f "$WORK/b.txt" \
  '{cwd:$c, message:{content:[{type:"tool_use", name:"Write", input:{file_path:$f}}]}}' > "$TR_W"
out="$(fire_tr "$WORK" s3 "$TR_W")"
case "$out" in *"unpushed work"*) ok "警告內容含 commit 主旨" ;; *) ng "警告內容含 commit 主旨" "找不到主旨" ;; esac
case "$out" in *"領先"*) ok "警告內容說明領先筆數" ;; *) ng "警告內容說明領先筆數" "無說明" ;; esac
# 2026-09-08 起分流：有上游且 fast-forward 屬「可直接處理」，不再要求逐一確認。
# 舊斷言（一律「不要自行 push」）已隨該裁定作廢，改驗分流有沒有落到正確的桶。
# 斷言改成「repo 出現在 auto 段（ask 段之前）」而非比對段落標題文字——標題措辭改過一次，
# 每改一次就要跟著修測試，那不是這條斷言真正要鎖的行為。
auto_w="${out%%要你先問使用者*}"
case "$auto_w" in *"$(basename "$WORK")"*) ok "有上游+fast-forward+有寫入 → 歸入 auto 桶" ;; *) ng "有上游+fast-forward+有寫入 → 歸入 auto 桶" "沒有落在自動桶" ;; esac
case "$out" in *"要你先問使用者"*) ng "乾淨的 fast-forward 不得落入要問的桶" "誤入 ask 桶" ;; *) ok "乾淨的 fast-forward 不得落入要問的桶" ;; esac
if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "Stop"' >/dev/null 2>&1; then
  ok "輸出符合 Stop hook schema"
else
  ng "輸出符合 Stop hook schema" "JSON 結構不符"
fi

echo "== 不可重複觸發（Stop 迴圈防護）=="
# Stop 的 additionalContext 會讓對話繼續；條件持續存在時若每次都警告就會無限迴圈。
silent "$WORK" s2 "[regression] 同 session 同狀態第二次 → 靜默"
warns  "$WORK" s9 "換 session → 重新警告一次"
echo three > "$WORK/c.txt"
git_q "$WORK" add c.txt
git_q "$WORK" commit -qm "another unpushed"
warns "$WORK" s2 "同 session 但有新 commit → 再次警告"

echo "== 推送後不再警告 =="
git_q "$WORK" push -q origin main
silent "$WORK" s10 "推送完成 → 靜默"

echo "== 未提交數必須是乾淨的數字 =="
# [regression] 舊版用 `grep -c . || echo 0`：工作目錄乾淨時 grep 印 0 卻以
# status 1 結束，`|| echo 0` 再補一個 0，dirty 變成 "0\n0"，警告裡出現亂數字。
echo four > "$WORK/d.txt"
git_q "$WORK" add d.txt
git_q "$WORK" commit -qm "clean tree unpushed"
out="$(fire "$WORK" s15)"
case "$out" in
  *"未提交變更 0 筆"*) ok "[regression] 乾淨工作目錄顯示為 0 筆" ;;
  *) ng "[regression] 乾淨工作目錄顯示為 0 筆" "實得: $(printf '%s' "$out" | grep -o '未提交變更[^筆]*筆' | head -1)" ;;
esac

echo "== 沒有上游追蹤的分支 =="
NOUP="$SANDBOX/noupstream"
git init -q -b main "$NOUP"
echo x > "$NOUP/x.txt"
git_q "$NOUP" add x.txt
git_q "$NOUP" commit -qm "local only"
warns "$NOUP" s11 "無上游追蹤 → 警告"
case "$(fire "$NOUP" s12)" in
  *"無遠端備份"*) ok "真的沒有備份時說法為「無遠端備份」" ;;
  *) ng "真的沒有備份時說法為「無遠端備份」" "訊息不符" ;;
esac
# 2026-09-08 分流：沒有上游代表「推去哪」並不明確，必須留給使用者決定。
out_noup="$(fire "$NOUP" s_noup_bucket)"
case "$out_noup" in *"要你先問使用者"*) ok "沒有上游 → 歸入要問的桶" ;; *) ng "沒有上游 → 歸入要問的桶" "沒有落在 ask 桶" ;; esac
case "$out_noup" in *"可直接處理"*) ng "沒有上游不得落入可直接處理" "誤入 auto 桶" ;; *) ok "沒有上游不得落入可直接處理" ;; esac

echo "== 臨時目錄底下的 repo 不列入 =="
# 這一條【刻意不設 GIT_GUARD_ALLOW_TEMP】——其餘案例都設了那個繞道，若不留一條在
# 真實條件下驗，排除規則壞掉時整份測試仍會全綠（開關把它要保護的行為一起關掉）。
# $NOUP 位於 mktemp -d 底下，本身又是「無上游且無備份」的最該報情境；它若靜默，
# 就只可能是被臨時目錄規則擋下。
out_temp="$(jq -cn --arg c "$NOUP" --arg s "s_temp" '{session_id:$s, cwd:$c}' | bash "$HOOK" 2>/dev/null)"
if [ -z "$out_temp" ]; then ok "臨時目錄底下的 repo 一律不報"; else ng "臨時目錄底下的 repo 一律不報" "仍報出: $(printf '%s' "$out_temp" | head -c 80)"; fi

echo "== 落後遠端（非 fast-forward）不得歸入可直接處理 =="
# 這是「自動推」的安全邊界：ahead>0 但 behind>0 時 push 會被拒，整合方式是使用者的決定。
# 沒有這條測試，該保護就是 fail-open——而它正是本次放寬授權時唯一擋住意外的東西。
# 【用獨立的 remote/work,不共用 $WORK】: 這個案例要 push、fetch 並讓兩邊各自前進,
# 會改變 fixture 狀態。先前共用 $WORK 時弄紅了後面那條 side-branch 的 regression——
# 測試之間不該互相依賴狀態,尤其是這種會動到分支與 tracking ref 的。
DREMOTE="$SANDBOX/div-remote.git"; DWORK="$SANDBOX/div-work"; DCLONE="$SANDBOX/div-clone"
git init -q --bare "$DREMOTE"
git init -q -b main "$DWORK"
echo base > "$DWORK/base.txt"; git_q "$DWORK" add base.txt; git_q "$DWORK" commit -qm "div base"
git_q "$DWORK" remote add origin "$DREMOTE"; git_q "$DWORK" push -q -u origin main
# 【必須明確指定分支】: `git init --bare` 的 HEAD 預設指向 master,而這裡用的是 main。
# 不指定的話 clone 會警告 "remote HEAD refers to nonexistent ref"、工作樹沒有 main,
# 接著的 push 就以 "src refspec main does not match any" 失敗——而那個失敗若被靜默,
# 最後會表現成「遠端沒有前進」,測試於是驗不到它要驗的東西(實際踩過)。
git clone -q "$DREMOTE" "$DCLONE" 2>/dev/null
git_q "$DCLONE" checkout -q -B main origin/main 2>/dev/null
echo remote-moves > "$DCLONE/r.txt"; git_q "$DCLONE" add r.txt; git_q "$DCLONE" commit -qm "remote advances"
git_q "$DCLONE" push -q origin main
echo local-moves > "$DWORK/l.txt"; git_q "$DWORK" add l.txt; git_q "$DWORK" commit -qm "local advances"
git_q "$DWORK" fetch -q origin   # 讓 tracking ref 反映遠端前進；hook 自己不 fetch
out_div="$(fire "$DWORK" s_diverge)"
case "$out_div" in *"要你先問使用者"*) ok "同時 ahead 與 behind → 歸入要問的桶" ;; *) ng "同時 ahead 與 behind → 歸入要問的桶" "沒有落在 ask 桶" ;; esac
case "$out_div" in *"非 fast-forward"*) ok "訊息說明是非 fast-forward" ;; *) ng "訊息說明是非 fast-forward" "訊息未說明原因" ;; esac

echo "== 只讀過的 repo 不得進入自動推送桶 =="
# 【授權與範圍要分開】：範圍收集刻意寬鬆（Read 過的 repo 也納入，多報方向安全），
# 但 auto 桶會讓模型「不問就推」，而 push 是唯一不可逆的動作。只讀過就授權推送，
# 等於把使用者自己留在那個 repo 的 WIP commit 推出去——那不是這次工作產生的。
RONLY="$SANDBOX/readonly-repo"; RREMOTE="$SANDBOX/readonly-remote.git"
git init -q --bare "$RREMOTE"
git init -q -b main "$RONLY"
echo seed > "$RONLY/seed.txt"; git_q "$RONLY" add seed.txt; git_q "$RONLY" commit -qm "seed"
git_q "$RONLY" remote add origin "$RREMOTE"; git_q "$RONLY" push -q -u origin main
# 模擬「使用者自己先前留下的 WIP」：有上游、fast-forward，但不是這次工作做的
echo wip > "$RONLY/wip.txt"; git_q "$RONLY" add wip.txt; git_q "$RONLY" commit -qm "user WIP not mine"
# transcript 只證明「讀過那個 repo 裡的一個檔」，cwd 指向別處
TR_RO="$SANDBOX/tr_readonly.jsonl"
jq -cn --arg c "$WORK" --arg f "$RONLY/seed.txt" \
  '{cwd:$c, message:{content:[{type:"tool_use", name:"Read", input:{file_path:$f}}]}}' > "$TR_RO"
out_ro="$(jq -cn --arg c "$WORK" --arg s s_readonly --arg t "$TR_RO" \
  '{session_id:$s, cwd:$c, transcript_path:$t}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null)"
case "$out_ro" in *"readonly-repo"*) ok "只讀過的 repo 仍納入檢查範圍" ;; *) ng "只讀過的 repo 仍納入檢查範圍" "整個漏掉了" ;; esac
# 關鍵斷言：它必須出現在 ask 段而不是 auto 段。用「該 repo 名稱是否出現在 auto 段之後、
# ask 段之前」不可靠，改為直接檢查 auto 段的內容不含它。
auto_part="${out_ro%%要你先問使用者*}"
case "$auto_part" in *"readonly-repo"*) ng "只讀過的 repo 不得進 auto 桶" "被授權自動推送了" ;; *) ok "只讀過的 repo 不得進 auto 桶" ;; esac
case "$out_ro" in *"沒有寫入證據"*) ok "訊息說明為何留在 ask 桶" ;; *) ng "訊息說明為何留在 ask 桶" "沒有說明原因" ;; esac

# 【codex 複查抓到之一】cwd 本身不得構成寫入證據：在一個有既存 WIP 的 repo 裡開 session
# 做純唯讀工作，cwd 就指向它——若算證據，那些不屬於本次工作的 commit 會被自動推出去。
TR_CWD="$SANDBOX/tr_cwdonly.jsonl"
jq -cn --arg c "$RONLY" '{cwd:$c, message:{content:[]}}' > "$TR_CWD"
out_cwd="$(jq -cn --arg c "$RONLY" --arg s s_cwdonly --arg t "$TR_CWD" \
  '{session_id:$s, cwd:$c, transcript_path:$t}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null)"
case "$out_cwd" in *"readonly-repo"*) ok "cwd-only 的 repo 仍納入範圍" ;; *) ng "cwd-only 的 repo 仍納入範圍" "整個漏掉了" ;; esac
auto_cwd="${out_cwd%%要你先問使用者*}"
case "$auto_cwd" in *"readonly-repo"*) ng "cwd 本身不得構成寫入證據" "只憑 cwd 就被授權自動推送" ;; *) ok "cwd 本身不得構成寫入證據" ;; esac

# 【codex 複查抓到之二】同一筆 message.content 同時有 Write(A) 與 Read(B) 時，
# 只有 A 該被授權。先前用「grep 含 Write 的整行、再抽該行所有 file_path」會把 B 一起授權。
MIXW="$SANDBOX/mix-write"; MIXR="$SANDBOX/mix-read"
for d in "$MIXW" "$MIXR"; do
  b="$SANDBOX/$(basename "$d")-remote.git"; git init -q --bare "$b"; git init -q -b main "$d"
  echo s > "$d/s.txt"; git_q "$d" add s.txt; git_q "$d" commit -qm seed
  git_q "$d" remote add origin "$b"; git_q "$d" push -q -u origin main
  echo w > "$d/w.txt"; git_q "$d" add w.txt; git_q "$d" commit -qm "ahead by one"
done
TR_MIX="$SANDBOX/tr_mixed.jsonl"
jq -cn --arg c "$WORK" --arg fw "$MIXW/w.txt" --arg fr "$MIXR/s.txt" \
  '{cwd:$c, message:{content:[{type:"tool_use", name:"Write", input:{file_path:$fw}},
                              {type:"tool_use", name:"Read",  input:{file_path:$fr}}]}}' > "$TR_MIX"
out_mix="$(jq -cn --arg c "$WORK" --arg s s_mixed --arg t "$TR_MIX" \
  '{session_id:$s, cwd:$c, transcript_path:$t}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null)"
auto_mix="${out_mix%%要你先問使用者*}"
case "$auto_mix" in *"mix-write"*) ok "同筆 content 裡 Write 的 repo 進 auto 桶" ;; *) ng "同筆 content 裡 Write 的 repo 進 auto 桶" "沒進 auto" ;; esac
case "$auto_mix" in *"mix-read"*) ng "同筆 content 裡 Read 的 repo 不得進 auto 桶" "被連坐授權了" ;; *) ok "同筆 content 裡 Read 的 repo 不得進 auto 桶" ;; esac

echo "== 未推 commit 超過 3 筆時不得進 auto 桶 =="
# 【codex 第三輪抓到】訊息只列得出最近 3 筆，而指示要執行者「依列出的 commit 確認是
# 本次工作」。總數超過 3 時更早的（可能是使用者自己的 WIP）會被截掉而看不見，
# push 卻是整批一起推——指示要求確認的東西，資料沒給全。
MANY="$SANDBOX/many"; MANYR="$SANDBOX/many-remote.git"
git init -q --bare "$MANYR"; git init -q -b main "$MANY"
echo s > "$MANY/s.txt"; git_q "$MANY" add s.txt; git_q "$MANY" commit -qm seed
git_q "$MANY" remote add origin "$MANYR"; git_q "$MANY" push -q -u origin main
for i in 1 2 3 4; do echo "c$i" > "$MANY/c$i.txt"; git_q "$MANY" add "c$i.txt"; git_q "$MANY" commit -qm "commit $i"; done
TR_MANY="$SANDBOX/tr_many.jsonl"
jq -cn --arg c "$MANY" --arg f "$MANY/c1.txt" \
  '{cwd:$c, message:{content:[{type:"tool_use", name:"Write", input:{file_path:$f}}]}}' > "$TR_MANY"
out_many="$(jq -cn --arg c "$MANY" --arg s s_many --arg t "$TR_MANY" \
  '{session_id:$s, cwd:$c, transcript_path:$t}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null)"
auto_many="${out_many%%要你先問使用者*}"
case "$auto_many" in *"$(basename "$MANY")"*) ng "4 筆未推 + 有寫入證據 → 仍不得進 auto 桶" "清單會被截斷卻仍授權推送" ;; *) ok "4 筆未推 + 有寫入證據 → 仍不得進 auto 桶" ;; esac
case "$out_many" in *"超過 3 筆"*) ok "訊息說明為何轉 ask" ;; *) ng "訊息說明為何轉 ask" "沒有說明原因" ;; esac
# 對照組：剛好 3 筆仍可進 auto（否則等於把 auto 桶關掉，那不是這條規則的意圖）
THREE="$SANDBOX/three"; THREER="$SANDBOX/three-remote.git"
git init -q --bare "$THREER"; git init -q -b main "$THREE"
echo s > "$THREE/s.txt"; git_q "$THREE" add s.txt; git_q "$THREE" commit -qm seed
git_q "$THREE" remote add origin "$THREER"; git_q "$THREE" push -q -u origin main
for i in 1 2 3; do echo "c$i" > "$THREE/c$i.txt"; git_q "$THREE" add "c$i.txt"; git_q "$THREE" commit -qm "commit $i"; done
TR_THREE="$SANDBOX/tr_three.jsonl"
jq -cn --arg c "$THREE" --arg f "$THREE/c1.txt" \
  '{cwd:$c, message:{content:[{type:"tool_use", name:"Write", input:{file_path:$f}}]}}' > "$TR_THREE"
out_three="$(jq -cn --arg c "$THREE" --arg s s_three --arg t "$TR_THREE" \
  '{session_id:$s, cwd:$c, transcript_path:$t}' | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null)"
auto_three="${out_three%%要你先問使用者*}"
case "$auto_three" in *"$(basename "$THREE")"*) ok "剛好 3 筆仍可進 auto 桶" ;; *) ng "剛好 3 筆仍可進 auto 桶" "邊界過嚴，auto 桶等於被關掉" ;; esac

# [regression] 「沒有上游」不等於「沒有備份」：從既有遠端分支切出、尚未新增
# commit 的本地分支，所有 commit 都已在遠端，不該報成最壞情況——狼來了的
# 警告會被忽略，等於沒有警告。
git_q "$WORK" push -q origin main
git_q "$WORK" checkout -q -b side-branch
out="$(fire "$WORK" s16)"
case "$out" in
  *"尚可確認有備份"*) ok "[regression] HEAD 已被 remote-tracking ref 涵蓋時不報成無備份" ;;
  *"無遠端備份"*)     ng "[regression] HEAD 已被 remote-tracking ref 涵蓋時不報成無備份" "誤報為無備份" ;;
  *)                  ng "[regression] HEAD 已被 remote-tracking ref 涵蓋時不報成無備份" "未出現預期訊息" ;;
esac
git_q "$WORK" checkout -q main

echo "== session 範圍（transcript）=="
# 範圍必須是「本 session 實際碰過的 repo」：
#   只看 cwd → 中途 cd 走或 cwd 不是 repo 就漏掉；
#   掃全機器 → 報出與這次工作無關的專案，而被忽略的警告等於沒有警告。
OTHER="$SANDBOX/unrelated"
git init -q -b main "$OTHER"
echo u > "$OTHER/u.txt"
git_q "$OTHER" add u.txt
git_q "$OTHER" commit -qm "unrelated unpushed work"

# 斷言要用 git 正規化後的路徑：Git for Windows 的 rev-parse --show-toplevel
# 回傳的是 C:/... 形式，而 mktemp 給的是 /tmp/... 形式。拿後者做子字串比對
# 會永遠找不到——那會讓測試在 hook 其實正常時報 FAIL（實測踩過）。
top_of(){ git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
WORK_TOP="$(top_of "$WORK")"
OTHER_TOP="$(top_of "$OTHER")"

TR1="$SANDBOX/t1.jsonl"; mktr "$TR1" "$WORK"
echo five > "$WORK/e.txt"; git_q "$WORK" add e.txt; git_q "$WORK" commit -qm "in-scope unpushed"
out="$(fire_tr "$SANDBOX" s30 "$TR1")"
case "$out" in
  *"$WORK_TOP"*) ok "transcript 的 cwd 指到的 repo 會被檢查（即使 hook cwd 不是 repo）" ;;
  *) ng "transcript 的 cwd 指到的 repo 會被檢查" "未報出 $WORK_TOP" ;;
esac
case "$out" in
  *"$OTHER_TOP"*) ng "[regression] 本 session 沒碰過的 repo 不得出現" "誤報了 $OTHER_TOP" ;;
  *) ok "[regression] 本 session 沒碰過的 repo 不得出現" ;;
esac

# Write/Edit 動到的檔案可能不在 cwd 底下，其所在 repo 也算本 session 碰過。
TR2="$SANDBOX/t2.jsonl"
jq -cn --arg f "$OTHER/u.txt" \
  '{cwd:"/nonexistent", message:{content:[{type:"tool_use", id:"w1", name:"Edit", input:{file_path:$f}}]}}' > "$TR2"
out="$(fire_tr "$SANDBOX" s31 "$TR2")"
case "$out" in
  *"$OTHER_TOP"*) ok "Write/Edit 動過的檔案所屬 repo 會被檢查" ;;
  *) ng "Write/Edit 動過的檔案所屬 repo 會被檢查" "未報出 $OTHER_TOP" ;;
esac

# transcript 不存在或欄位缺漏時，不得整支失效——退回只看 cwd。
out="$(fire_tr "$WORK" s32 "$SANDBOX/no-such-transcript.jsonl")"
case "$out" in
  *"$WORK_TOP"*) ok "transcript 不存在時退回檢查 cwd 的 repo" ;;
  *) ng "transcript 不存在時退回檢查 cwd 的 repo" "未報出 $WORK_TOP" ;;
esac

echo "== 路徑含空格 =="
# [regression] 舊版用 `for x in $(...)` 逐一走訪 repo，會依空白斷詞，
# 路徑含空格的 repo 被切成碎片而永遠檢查不到——正是本 hook 要防的靜默漏檢。
SPACED="$SANDBOX/my projects/repo one"
mkdir -p "$SPACED"
git init -q -b main "$SPACED"
echo s > "$SPACED/s.txt"
git_q "$SPACED" add s.txt
git_q "$SPACED" commit -qm "spaced path commit"
warns "$SPACED" s20 "[regression] 路徑含空格的 repo 仍能被檢查到"

echo "== 非 repo / 異常輸入不得出錯 =="
silent "$SANDBOX" s13 "非 git 目錄 → 靜默"
silent "/no/such/path/at/all" s14 "不存在的路徑 → 靜默"
printf '' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "空輸入 → exit 0" || ng "空輸入 → exit 0" "結束碼非 0"
printf 'not json' | bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "壞輸入 → exit 0" || ng "壞輸入 → exit 0" "結束碼非 0"

echo
echo "結果: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
