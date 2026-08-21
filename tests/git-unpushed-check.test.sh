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
fire(){ jq -cn --arg c "$1" --arg s "$2" '{session_id:$s, cwd:$c}' | bash "$HOOK" 2>/dev/null; }
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
case "$out" in *"不要自行 push"*) ok "明確要求不得自行 push" ;; *) ng "明確要求不得自行 push" "缺少該指示" ;; esac
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
