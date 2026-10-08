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
cat >/dev/null
if [ -n "\${REJECT:-}" ] && [ "\$model" = "\$REJECT" ]; then
  echo "model_not_found: \$model" >&2; exit 1
fi
printf '裁定:A\n信心:高\n依據:已讀\n理由:x\n異議:無\n'
EOF
chmod +x "$T/bin/codex"

run() { # $1=severity ; REJECT 由呼叫端環境帶入
  rm -f "$T/calls.log"
  ( cd "$T/repo" && PATH="$T/bin:$PATH" bash "$SCRIPT" --question "$T/q.md" --prefer A --severity "$1" >"$T/out.txt" 2>&1 )
}
models() { awk 'p=="-m"{print} {p=$0}' "$T/calls.log" | tr '\n' ' ' | sed 's/ $//'; }
efforts() { grep -o 'model_reasoning_effort=.*' "$T/calls.log" | sed 's/model_reasoning_effort=//' | tr '\n' ' ' | sed 's/ $//'; }
memflags() { grep -cx 'features.memories=false' "$T/calls.log"; }

for row in "critical gpt-6.1-sol medium" "required gpt-6.1-sol medium" "optional gpt-6-luna high" "nit gpt-6-luna high" "bogus gpt-6.1-sol medium"; do
  set -- $row
  run "$1"; rc=$?
  ok "$1: 共識成立 rc=0"            test "$rc" -eq 0
  ok "$1: 模型 $2"                  test "$(models)" = "$2"
  ok "$1: effort $3"                test "$(efforts)" = "$3"
  ok "$1: 帶 memories off"          test "$(memflags)" -eq 1
done

# 執行期退回: 主模型被拒 → 用該檔的舊模型與其 effort 重問一次,兩次呼叫都帶 memories off
for row in "required gpt-6.1-sol gpt-6-luna high" "optional gpt-6-luna gpt-6-astra low"; do
  set -- $row
  REJECT="$2" run "$1"; rc=$?
  ok "$1 退回: rc=0"                       test "$rc" -eq 0
  ok "$1 退回: 先問 $2 再問 $3"             test "$(models)" = "$2 $3"
  ok "$1 退回: 退路 effort $4"              test "$(efforts | awk '{print $2}')" = "$4"
  ok "$1 退回: 兩次都帶 memories off"       test "$(memflags)" -eq 2
done

# 不得再出現已退出的 gpt-5.6(2026-10-08 使用者裁定最低 gpt-6)
ok "映射不含 gpt-5.6" bash -c "! grep -qE 'MODEL=\"gpt-5\.6' '$SCRIPT'"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
