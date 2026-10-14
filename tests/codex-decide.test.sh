#!/usr/bin/env bash
# scripts/codex-decide.sh 的映射回歸測試(stub codex,不打 API)。
# 鎖住: 各 severity 送出的 -m／model_reasoning_effort、每次都帶 -c features.memories=false
# (2026-10-08 實測: 注入 7.3k Memory 區塊、luna 會因此讀工作根以外的檔),以及執行期
# 「模型不可用」時退回舊模型重問一次。這支腳本的離開碼決定能不能逕行,映射改錯不能沒有反應。
# Run: bash tests/codex-decide.test.sh   (exit 0 = all pass)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/codex-decide.sh"
pass=0; fail=0
ok() { local desc="$1"; shift
  if "$@"; then pass=$((pass+1)); else echo "FAIL [$desc]"; fail=$((fail+1)); fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
( cd "$T/repo" && git init -q . )
printf '# Q\n\n選項 A／B\n\n## 安全與可逆性聲明\n可逆。\n' > "$T/q.md"

# stub: 每次 exec 把參數附加到 calls.log(以 ---- 分隔);REJECT 指定的模型回「模型不可用」。
cat > "$T/bin/codex" <<EOF
#!/usr/bin/env bash
case "\$1" in
  login) exit 0 ;;
  --version) echo "codex-cli 0.160.1"; exit 0 ;;
esac
model=""; prev=""
for a in "\$@"; do [ "\$prev" = "-m" ] && model="\$a"; prev="\$a"; done
{ printf '%s\n' "\$@"; echo "----"; } >> "$T/calls.log"
echo "\${LOCALAPPDATA-<unset>}" >> "$T/laa.log"
cat >/dev/null
if [ -n "\${REJECT:-}" ] && [ "\$model" = "\$REJECT" ]; then
  echo "model_not_found: \$model" >&2; exit 1
fi
printf '裁定:A\n信心:高\n依據:已讀\n理由:x\n異議:無\n'
EOF
chmod +x "$T/bin/codex"

run() { # $1=severity ; REJECT 由呼叫端環境帶入
  rm -f "$T/calls.log" "$T/laa.log"
  ( cd "$T/repo" && PATH="$T/bin:$PATH" bash "$SCRIPT" --question "$T/q.md" --prefer A --severity "$1" >"$T/out.txt" 2>&1 )
}
models() { awk 'p=="-m"{print} {p=$0}' "$T/calls.log" | tr '\n' ' ' | sed 's/ $//'; }
efforts() { grep -o 'model_reasoning_effort=.*' "$T/calls.log" | sed 's/model_reasoning_effort=//' | tr '\n' ' ' | sed 's/ $//'; }
memflags() { grep -cx 'features.memories=false' "$T/calls.log"; }
isoflags() { grep -cx -- '--ignore-user-config' "$T/calls.log"; }
# LOCALAPPDATA 覆寫(2026-10-14): 0.162.1 的 sandbox setup refresh 會走訪
# %LOCALAPPDATA%\OpenAI\Codex\runtimes,桌面版常駐的 helper 鎖住其中的 dll → os error 32 → shell 全失敗。
# Windows 上子程序必須拿到一個【不存在】的 LOCALAPPDATA,【原本有沒有設都一樣】(沒設時上游會退回
# %USERPROFILE%\AppData\Local,又走回同一棵樹);非 Windows 什麼都不做。
# 判斷看 OS／uname,所以測試明確帶 OS=Windows_NT(任何主機都走 Windows 分支),非 Windows 分支用假 uname。
FAKE_LAA="C:/fake/Local/Windows"
laa_overridden() { # 逐行檢查 laa.log: 每次呼叫的值都不是原值、以 no-localappdata 結尾、路徑不存在
  local n=0 v
  while IFS= read -r v; do
    v="${v%$'\r'}"; n=$((n+1))
    [ "$v" != "$FAKE_LAA" ] && [ "$v" != "<unset>" ] || return 1
    case "$v" in *eng-flow-no-localappdata) ;; *) return 1 ;; esac
    [ ! -e "$v" ] || return 1
  done < "$T/laa.log"
  [ "$n" -eq "$1" ]
}
# 假 CODEX_HOME: [windows] 前面故意放別段的 sandbox 鍵(段落判斷寫錯就會帶成 "wrong")
mkdir -p "$T/codexhome"
printf 'notes = """\n[windows]\nsandbox = "wrong"\n"""\n[other]\nsandbox = "wrong"\n[windows] # backend\nsandbox = "elevated" # chosen\n' > "$T/codexhome/config.toml"
export CODEX_HOME="$T/codexhome"
export LOCALAPPDATA="$FAKE_LAA"
export OS=Windows_NT
# 假 uname(只在非 Windows 案例排到 PATH 最前面)
mkdir -p "$T/binlinux"
printf '#!/usr/bin/env bash\necho Linux\n' > "$T/binlinux/uname"; chmod +x "$T/binlinux/uname"

for row in "critical gpt-6.1-sol medium" "required gpt-6.1-sol medium" "optional gpt-6-luna high" "nit gpt-6-luna high" "bogus gpt-6.1-sol medium"; do
  set -- $row
  run "$1"; rc=$?
  ok "$1: 共識成立 rc=0"            test "$rc" -eq 0
  ok "$1: 模型 $2"                  test "$(models)" = "$2"
  ok "$1: effort $3"                test "$(efforts)" = "$3"
  ok "$1: 帶 memories off"          test "$(memflags)" -eq 1
  ok "$1: 帶 --ignore-user-config"  test "$(isoflags)" -eq 1
  ok "$1: windows.sandbox 原值帶回" test "$(grep -cx 'windows.sandbox="elevated"' "$T/calls.log")" -eq 1
  ok "$1: codex 子程序拿到不存在的 LOCALAPPDATA" laa_overridden 1
done

# 執行期退回: 主模型被拒 → 用該檔的舊模型與其 effort 重問一次,兩次呼叫都帶 memories off
for row in "required gpt-6.1-sol gpt-6-luna high" "optional gpt-6-luna gpt-6-astra low"; do
  set -- $row
  REJECT="$2" run "$1"; rc=$?
  ok "$1 退回: rc=0"                       test "$rc" -eq 0
  ok "$1 退回: 先問 $2 再問 $3"             test "$(models)" = "$2 $3"
  ok "$1 退回: 退路 effort $4"              test "$(efforts | awk '{print $2}')" = "$4"
  ok "$1 退回: 兩次都帶 memories off"       test "$(memflags)" -eq 2
  ok "$1 退回: 兩次都帶 --ignore-user-config" test "$(isoflags)" -eq 2
  ok "$1 退回: 兩次都覆寫 LOCALAPPDATA"       laa_overridden 2
done

run_env() { # "$@"=env 的參數(VAR=val 或 -u VAR),其餘同 run required
  rm -f "$T/calls.log" "$T/laa.log"
  ( cd "$T/repo" && env "$@" bash "$SCRIPT" --question "$T/q.md" --prefer A --severity required >"$T/out.txt" 2>&1 )
}
# Windows 但 LOCALAPPDATA 沒設 → 仍要覆寫(判斷 Windows 不能看 LOCALAPPDATA 有沒有值)
run_env -u LOCALAPPDATA PATH="$T/bin:$PATH"; rc=$?
ok "Windows 無 LOCALAPPDATA: 照常 rc=0"            test "$rc" -eq 0
ok "Windows 無 LOCALAPPDATA: 子程序仍被覆寫"       laa_overridden 1
# 非 Windows(OS 沒有、uname=Linux)→ 不覆寫: 有值就原樣、沒值就仍是 unset,不憑空造一個
run_env -u OS PATH="$T/binlinux:$T/bin:$PATH"; rc=$?
ok "非 Windows 有 LOCALAPPDATA: 照常 rc=0"         test "$rc" -eq 0
ok "非 Windows 有 LOCALAPPDATA: 原值不動"          test "$(tr -d '\r' < "$T/laa.log")" = "$FAKE_LAA"
run_env -u OS -u LOCALAPPDATA PATH="$T/binlinux:$T/bin:$PATH"
ok "非 Windows 無 LOCALAPPDATA: 子程序仍是 unset"  test "$(tr -d '\r' < "$T/laa.log")" = "<unset>"

# 覆寫只掛在 codex 子程序上、不外溢到腳本自己的環境: 用假 grep 當探針——腳本在 codex 呼叫【之後】
# 還會跑 grep(RATE_PAT 判定等),它記下自己看到的 LOCALAPPDATA 再轉交真 grep。若有人把覆寫改成
# 腳本層級的 export LOCALAPPDATA=...,探針會看到被覆寫的值而變紅;同一輪 exec 子程序仍須被覆寫。
REAL_GREP="$(command -v grep)"
mkdir -p "$T/binspy"
printf '#!/usr/bin/env bash\necho "${LOCALAPPDATA-<unset>}" >> "%s/laa-spy.log"\nexec "%s" "$@"\n' "$T" "$REAL_GREP" > "$T/binspy/grep"; chmod +x "$T/binspy/grep"
rm -f "$T/laa-spy.log"; run_env PATH="$T/binspy:$T/bin:$PATH"
ok "覆寫不外溢: 探針有被跑到(否則下一條沒意義)"        test -s "$T/laa-spy.log"
ok "覆寫不外溢: 腳本自己的 grep 全程看到原 LOCALAPPDATA" test "$(tr -d '\r' < "$T/laa-spy.log" | sort -u)" = "$FAKE_LAA"
ok "覆寫不外溢: 同一輪 exec 子程序確實被覆寫"           laa_overridden 1

# 不得再出現已退出的 gpt-5.6(2026-10-08 使用者裁定最低 gpt-6)
ok "映射不含 gpt-5.6" bash -c "! grep -qE 'MODEL=\"gpt-5\.6' '$SCRIPT'"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
