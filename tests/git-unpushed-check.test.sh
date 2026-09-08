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

out="$(fire "$WORK" s3)"
case "$out" in *"unpushed work"*) ok "警告內容含 commit 主旨" ;; *) ng "警告內容含 commit 主旨" "找不到主旨" ;; esac
case "$out" in *"領先"*) ok "警告內容說明領先筆數" ;; *) ng "警告內容說明領先筆數" "無說明" ;; esac
# 2026-09-08 起分流：有上游且 fast-forward 屬「可直接處理」，不再要求逐一確認。
# 舊斷言（一律「不要自行 push」）已隨該裁定作廢，改驗分流有沒有落到正確的桶。
case "$out" in *"可直接處理"*) ok "有上游且 fast-forward → 歸入可直接處理" ;; *) ng "有上游且 fast-forward → 歸入可直接處理" "沒有落在自動桶" ;; esac
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

mktr(){ # mktr <file> <cwd值>
  jq -cn --arg c "$2" '{cwd:$c, message:{content:[]}}' > "$1"
}
fire_tr(){ # fire_tr <cwd> <session> <transcript>
  jq -cn --arg c "$1" --arg s "$2" --arg t "$3" '{session_id:$s, cwd:$c, transcript_path:$t}' \
    | GIT_GUARD_ALLOW_TEMP=1 bash "$HOOK" 2>/dev/null
}
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
