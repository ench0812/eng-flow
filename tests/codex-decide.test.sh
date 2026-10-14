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

# === TMP-PREAMBLE-BEGIN ===
# 暫存目錄: TMPDIR 若設成 Windows 路徑(例如 D:/Temp),mktemp 會回「D:/Temp/tmp.xxx」,含冒號,
# 放進 PATH 會被切斷(見 need_tmp)。有 cygpath(Git Bash／MSYS)就轉成 /d/Temp/… 形式。
# 【轉換失敗不能讓路徑變成空字串】(2026-10-14 codex 收尾抓到): 舊版直接把 $(cygpath …) 賦值給路徑,
# cygpath 失敗或印空時 tmpd 仍回傳成功、路徑為空,於是 "$T/bin/codex" 變成 /bin/codex,stub 被寫進
# 系統目錄、覆寫既有程式。所以: 轉換成功【且非空】才取代原路徑;最終路徑必須是存在、且【空的】目錄
# (剛建立的暫存目錄一定是空的;非空代表轉換拿到了別的東西,例如 /bin),否則回非 0。
tmpd() { local d u; d="$(mktemp -d)" || return 1
  case "$d" in *:*)
    if command -v cygpath >/dev/null 2>&1; then
      u="$(cygpath -u "$d" 2>/dev/null)" && [ -n "$u" ] && d="$u"
    fi ;;
  esac
  [ -n "$d" ] && [ -d "$d" ] || return 1
  [ -z "$(ls -A "$d" 2>/dev/null)" ] || return 1
  printf '%s\n' "$d"
}
# 在任何寫入之前檢查 tmpd 的結果: 空字串／不是目錄／含冒號一律 FATAL 中止。
# 含冒號: PATH 的分隔符是冒號,"$T/bin:$PATH" 會被切斷,stub 不在 PATH 上,command -v codex 就會找到
# 【真的 codex】——測試會真的送出諮詢。
need_tmp() { # $1=tmpd 的結果 $2=變數名稱
  if [ -z "$1" ] || [ ! -d "$1" ]; then
    echo "FATAL: 暫存目錄 $2 建立或轉換失敗(值 '$1'),中止——空路徑會讓 \"\$$2/bin/codex\" 變成 /bin/codex" >&2; exit 1
  fi
  case "$1" in *:*) echo "FATAL: 暫存目錄 $2='$1' 含冒號,PATH 會被切斷、可能叫到真的 codex" >&2; exit 1 ;; esac
}
T="$(tmpd)"; need_tmp "$T" T
# === TMP-PREAMBLE-END ===
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo"
( cd "$T/repo" && git init -q . )
printf '# Q\n\n選項 A／B\n\n## 安全與可逆性聲明\n可逆。\n' > "$T/q.md"

# === TMPD-SELFCHECK-BEGIN ===
# --- tmpd／need_tmp 自我檢查(2026-10-14 codex 收尾抓到) ---
# 舊版 cygpath 失敗或印空時 tmpd 仍回傳成功且路徑為空 → "$T/bin/codex" 變成 /bin/codex。這裡用假 mktemp
# (回一個含冒號、不存在的路徑)與各種壞掉的假 cygpath 驗證 tmpd 一律回非 0;探針目錄都在 $T 底下,
# 全程不碰系統目錄。TP 底下的 mk 放假 mktemp,cy-* 各放一種假 cygpath。
TP="$T/tmpd-probe"; mkdir -p "$TP/mk" "$TP/ok-dir" "$TP/busy-dir" "$TP/cy-empty" "$TP/cy-fail" "$TP/cy-gone" "$TP/cy-busy" "$TP/cy-ok"
printf 'x' > "$TP/busy-dir/file"
printf '#!/usr/bin/env bash\necho "D:/Temp/fake.dir"\n' > "$TP/mk/mktemp"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TP/cy-empty/cygpath"                     # 印空字串、exit 0
printf '#!/usr/bin/env bash\nexit 1\n' > "$TP/cy-fail/cygpath"                      # 失敗
printf '#!/usr/bin/env bash\necho "%s"\n' "$TP/gone-dir" > "$TP/cy-gone/cygpath"    # 回一個不存在的路徑
printf '#!/usr/bin/env bash\necho "%s"\n' "$TP/busy-dir" > "$TP/cy-busy/cygpath"    # 回一個存在但非空的目錄(不是新建的暫存目錄)
printf '#!/usr/bin/env bash\necho "%s"\n' "$TP/ok-dir" > "$TP/cy-ok/cygpath"        # 回一個存在的空目錄(正常轉換)
chmod +x "$TP"/mk/mktemp "$TP"/cy-*/cygpath
tmpd_probe() { # $1=假 cygpath 的目錄名 → 印「rc=<tmpd 的離開碼> path=<它印出的路徑>」
  ( export PATH="$TP/mk:$TP/$1:$PATH"; p=$(tmpd); echo "rc=$? path=<$p>" ); }
ok "tmpd: cygpath 印空字串 → 回非 0、不印路徑"      test "$(tmpd_probe cy-empty)" = 'rc=1 path=<>'
ok "tmpd: cygpath 失敗 → 回非 0、不印路徑"          test "$(tmpd_probe cy-fail)" = 'rc=1 path=<>'
ok "tmpd: cygpath 回不存在的路徑 → 回非 0"          test "$(tmpd_probe cy-gone)" = 'rc=1 path=<>'
ok "tmpd: cygpath 回非空的既有目錄 → 回非 0"        test "$(tmpd_probe cy-busy)" = 'rc=1 path=<>'
ok "tmpd: 對照組 cygpath 正常轉換 → 成功並回該路徑" test "$(tmpd_probe cy-ok)" = "rc=0 path=<$TP/ok-dir>"
need_tmp_rc() { ( need_tmp "$1" X ) >/dev/null 2>&1; echo $?; }
ok "need_tmp: 空字串 → 中止"                        test "$(need_tmp_rc "")" = 1
ok "need_tmp: 不存在的目錄 → 中止"                  test "$(need_tmp_rc "$TP/gone-dir")" = 1
ok "need_tmp: 含冒號 → 中止"                        test "$(need_tmp_rc "D:/Temp/x")" = 1
ok "need_tmp: 對照組 正常目錄 → 通過"               test "$(need_tmp_rc "$TP/ok-dir")" = 0
# 每個 tmpd 呼叫點都在【同一行】帶 need_tmp(寫入之前就檢查)。pattern 用跳脫寫法,不會比對到這一行自己
ok "每個 tmpd 呼叫點都帶 need_tmp"                  test "$(grep -E '="\$\(tmpd\)"' "$0" | grep -vc 'need_tmp')" -eq 0
# 端到端: 把檔頭【實際的】tmpd／need_tmp／呼叫點(TMP-PREAMBLE 標記之間)抽出來,在假 mktemp＋壞掉的假 cygpath
# 下執行,必須在印 REACHED(代表後面的寫入會開始)之前就 FATAL 中止。抽出的片段只有定義與賦值,不寫任何檔。
for bad in cy-empty cy-fail cy-gone cy-busy; do
  pre_out="$(PATH="$TP/mk:$TP/$bad:$PATH" bash -c "$(sed -n '/^# === TMP-PREAMBLE-BEGIN/,/^# === TMP-PREAMBLE-END/p' "$0"); echo REACHED" 2>&1)"; pre_rc=$?
  ok "檔頭在 $bad 下於寫入前 FATAL 中止"            test "$pre_rc" -ne 0 -a "$(printf '%s' "$pre_out" | grep -c 'FATAL')" -ge 1 -a "$(printf '%s' "$pre_out" | grep -c 'REACHED')" -eq 0
done
# === TMPD-SELFCHECK-END ===

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
o=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && o="\$a"; prev="\$a"; done
# JSON 模式(EVENTS 指到一份 JSONL): 忠實模擬真 codex --json —— stdout 只有 JSONL 事件流,
# 最終訊息寫進 -o 指定的檔。JSON_ERR 非空 → 以 error 事件(只在 stdout、stderr 空)失敗。
if [ -n "\${EVENTS:-}" ]; then
  if [ -n "\${JSON_ERR:-}" ]; then
    # 先印事件檔(可含 agent_message 等),再印失敗事件。TURN_FAILED=1 → 只有 turn.failed 事件帶訊息
    # (沒有獨立的 error 事件)
    cat "\$EVENTS"
    if [ -n "\${TURN_FAILED:-}" ]; then printf '{"type":"turn.failed","error":{"message":"%s"}}\n' "\$JSON_ERR"
    else printf '{"type":"error","message":"%s"}\n' "\$JSON_ERR"; fi
    exit 1
  fi
  if [ -n "\${REJECT:-}" ] && [ "\$model" = "\$REJECT" ]; then
    if [ -n "\${TURN_FAILED:-}" ]; then printf '{"type":"turn.failed","error":{"message":"model_not_found: %s"}}\n' "\$model"
    else printf '{"type":"error","message":"model_not_found: %s"}\n' "\$model"; fi
    exit 1
  fi
  # 真 codex 的 -o 檔最後沒有結尾換行(NO_EOL=1 時照做);NO_O=1 → 完全不寫 -o 檔(exit 0 但沒有最終訊息)
  if [ -n "\$o" ] && [ -z "\${NO_O:-}" ]; then
    if [ -n "\${NO_EOL:-}" ]; then printf '裁定:A\n信心:高\n依據:%s\n理由:x\n異議:無' "\${STUB_BASIS:-已讀}" > "\$o"
    else printf '裁定:A\n信心:高\n依據:%s\n理由:x\n異議:無\n' "\${STUB_BASIS:-已讀}" > "\$o"; fi
  fi
  cat "\$EVENTS"; exit 0
fi
# 純文字模式(舊行為): 裁定印在 stdout,不寫 -o 檔 —— 腳本須退回 stdout
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

# cygpath 失敗或印出空字串 → 保留原路徑、覆寫仍生效(直接賦值 $(cygpath …) 會讓 NO_LOCALAPPDATA
# 變空,codex_cmd 走不覆寫的分支,覆寫靜默失效)。假 cygpath 排在 PATH 最前面。
mkdir -p "$T/bincyg-empty" "$T/bincyg-fail"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bincyg-empty/cygpath"; chmod +x "$T/bincyg-empty/cygpath"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bincyg-fail/cygpath";  chmod +x "$T/bincyg-fail/cygpath"
run_env PATH="$T/bincyg-empty:$T/bin:$PATH"; rc=$?
ok "cygpath 印空字串: 照常 rc=0"                    test "$rc" -eq 0
ok "cygpath 印空字串: 覆寫仍生效(保留原路徑)"        laa_overridden 1
run_env PATH="$T/bincyg-fail:$T/bin:$PATH"; rc=$?
ok "cygpath 失敗(exit 1): 照常 rc=0"                test "$rc" -eq 0
ok "cygpath 失敗(exit 1): 覆寫仍生效(保留原路徑)"    laa_overridden 1

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

# === LAUNCHFAIL-BEGIN ===
# --- codex shell 啟動失敗 → 一律無共識 exit 3(2026-10-14) ---
# 背景: shell 起不來時 codex 不會中止,拿問題檔繼續作答,格式完整、五行契約齊全、exit 0,甚至把依據標
# 成已讀;而本腳本的離開碼決定能不能逕行,沒有查證的裁定不能當共識。偵測只認 `codex exec --json`
# 事件流的結構(樣本取自 codex 0.162.1 的真實 stdout,欄位順序同真實樣本;五個條件與理由見
# codex-review.sh 與 codex-review-args.test.sh 的同名區塊): 缺一不可,所以每個「不偵測」案例各自
# 只違反其中一個條件,負控組(拿掉對應條件)才會只紅對應那一則。
# 「不偵測」的斷言必須先確認腳本真的走到共識(印了「共識成立」): 否則任何其他原因的 exit 3／FAILED
# 都會讓「沒被擋」的斷言恆真。
LF_ERR='Failed to create unified exec process: helper_unknown_error: setup refresh had errors'
lf_item() { # $1=aggregated_output $2=exit_code $3=status [$4=item.type=command_execution] [$5=event type=item.completed]
  printf '{"type":"%s","item":{"id":"item_1","type":"%s","command":"pwsh -Command Get-Content x","aggregated_output":"%s","exit_code":%s,"status":"%s"}}\n' \
    "${5:-item.completed}" "${4:-command_execution}" "$1" "$2" "$3"
}
lf_events() { # stdin=item 行 → $T/ev.jsonl(帶頭尾事件)
  { echo '{"type":"thread.started","thread_id":"t-1"}'; echo '{"type":"turn.started"}'; cat
    echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}'
  } > "$T/ev.jsonl"
}
lf_rc=0
lf_run() { # 環境變數(JSON_ERR／REJECT)由呼叫端用前綴帶入;離開碼存 lf_rc,輸出存 $T/out.txt
  rm -f "$T/calls.log" "$T/laa.log"
  # LF_EXTRA: 額外參數(例如 --allow-inference);刻意不加引號,讓它在空值時完全消失
  ( cd "$T/repo" && EVENTS="$T/ev.jsonl" PATH="$T/bin:$PATH" bash "$SCRIPT" --question "$T/q.md" --prefer A --severity required ${LF_EXTRA:-} >"$T/out.txt" 2>&1 )
  lf_rc=$?
}
lf_agreed()  { [ "$lf_rc" -eq 0 ] && grep -q '共識成立' "$T/out.txt"; }
lf_blocked() { [ "$lf_rc" -eq 3 ] && grep -q '無共識: codex 的 shell 啟動失敗' "$T/out.txt"; }
lf_out_has() { grep -q -- "$1" "$T/out.txt"; }
lf_out_lacks() { ! grep -qE -- "$1" "$T/out.txt"; }

ok "PATH 最前面的 codex 是 stub(不會叫到真的 codex)" test "$(PATH="$T/bin:$PATH" command -v codex)" = "$T/bin/codex"
# 警示塊的錯誤類型行(scripts 以 uniq -c 印成「4 個空白 + 次數 + 類型」)
lf_types() { grep -E '^    [0-9]+ (Failed to create unified exec process|CreateProcess)' "$T/out.txt"; }

# 基準: 全部 shell 呼叫正常 → 共識成立。同時鎖住 JSON 模式的呼叫形狀(--json 與 -o 各一次)
lf_item "PROBE-OK" 0 completed | lf_events; lf_run
ok "基準: shell 正常 → 共識成立 rc=0"          lf_agreed
ok "基準: 呼叫帶 --json"                       test "$(grep -cx -- '--json' "$T/calls.log")" -eq 1
ok "基準: 呼叫帶 -o"                           test "$(grep -cx -- '-o' "$T/calls.log")" -eq 1
# 事件流裡的 JSONL 不得被當成裁定印出來(最終訊息來自 -o 檔)
ok "基準: stdout 不含 JSONL 事件"              lf_out_lacks '"type":"thread.started"'
# 真 codex 的 -o 檔沒有結尾換行 → stdout 仍須以換行結尾(維持舊版從 stdout 捕獲時的輸出形狀;
# 只取 stdout,2>&1 合併的 out.txt 看不出來)
( cd "$T/repo" && NO_EOL=1 EVENTS="$T/ev.jsonl" PATH="$T/bin:$PATH" bash "$SCRIPT" --question "$T/q.md" --prefer A --severity required >"$T/stdout-only.txt" 2>/dev/null )
ok "基準: -o 檔缺結尾換行 → stdout 補上"         test "$(tail -c1 "$T/stdout-only.txt" | od -An -c | tr -d ' ')" = '\n'
ok "基準: 補換行後內容完整(五行契約都在)"        test "$(grep -c '^異議:無$' "$T/stdout-only.txt")" -eq 1

# (a) 真實形狀的失敗 item → 無共識 exit 3,理由行帶錯誤類型
lf_item "$LF_ERR" -1 failed | lf_events; lf_run
ok "(a) 啟動失敗 → exit 3 且理由是 shell 啟動失敗" lf_blocked
ok "(a) 理由行帶錯誤類型"                       lf_out_has 'helper_unknown_error: setup refresh had errors'
ok "(a) 不印共識成立"                           lf_out_lacks '共識成立'
# (a2) 部分失敗也一律無共識(沒有查證的裁定不能當共識,哪怕還有指令起來了)
{ lf_item "$LF_ERR" -1 failed; lf_item "PROBE-OK" 0 completed; } | lf_events; lf_run
ok "(a2) 部分失敗 → 仍 exit 3"                  lf_blocked
ok "(a2) 訊息如實寫出正常啟動數"                lf_out_has '啟動失敗 1 次(另有 1 次正常啟動)'
# (a3) 第二種啟動錯誤字樣
lf_item "CreateProcessAsUserW failed: 5" -1 failed | lf_events; lf_run
ok "(a3) CreateProcess*W failed → exit 3"       lf_blocked
ok "(a3) 理由行帶 OS 錯誤碼"                    lf_out_has 'CreateProcessAsUserW failed: 5'

# (a4) 啟動失敗即使帶 --allow-inference 也是 exit 3(--allow-inference 只放行「本來就沒有程式碼可讀」,
# 不放行「讀了但讀失敗」)。對照組: 同樣的旗標與 依據:推論,shell 正常 → 共識成立(證明旗標確實有作用)
lf_item "PROBE-OK" 0 completed | lf_events; STUB_BASIS=推論 LF_EXTRA=--allow-inference lf_run
ok "(a4) 對照: --allow-inference＋依據推論＋shell 正常 → 共識成立" lf_agreed
lf_item "$LF_ERR" -1 failed | lf_events; STUB_BASIS=推論 LF_EXTRA=--allow-inference lf_run
ok "(a4) --allow-inference＋依據推論＋啟動失敗 → 仍 exit 3"      lf_blocked

# (b) 成功的 item 輸出剛好以該字串開頭 → 不偵測
lf_item "$LF_ERR" 0 completed | lf_events; lf_run
ok "(b) completed／exit 0 印出該字串 → 照常共識" lf_agreed
# (b') 只違反 status 條件
lf_item "$LF_ERR" -1 completed | lf_events; lf_run
ok "(b') status=completed → 不偵測"              lf_agreed
# (c) agent_message 引用該字串 → 不偵測(codex 失敗後的回覆真的會這樣引用)
{ echo '{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"SHELL-FAILED\nexec_command failed: CreateProcess { message: \"Rejected(\\\"Failed to create unified exec process: helper_unknown_error\\\")\" }"}}'
  echo '{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"{\"type\":\"command_execution\",\"aggregated_output\":\"Failed to create unified exec process\",\"exit_code\":-1,\"status\":\"failed\"}"}}'; } | lf_events; lf_run
ok "(c) agent_message 引用該字串 → 不偵測"       lf_agreed
# (c') 只違反 type 條件
lf_item "$LF_ERR" -1 failed agent_message | lf_events; lf_run
ok "(c') item 類型非 command_execution → 不偵測" lf_agreed
# (d) 指令真的跑過、exit 1 失敗 → 不偵測
lf_item "$LF_ERR" 1 failed | lf_events; lf_run
ok "(d) exit_code=1 的失敗 → 不偵測"             lf_agreed
# (e) 字串在輸出中段 → 不偵測
lf_item "warning: earlier attempt said Failed to create unified exec process" -1 failed | lf_events; lf_run
ok "(e) 字串在輸出中段 → 不偵測"                 lf_agreed
# (g) 只違反 event type 條件(item.started)
lf_item "$LF_ERR" -1 failed command_execution item.started | lf_events; lf_run
ok "(g) item.started → 不偵測"                   lf_agreed

# (f) 理由行不得含 cwd=／cmd=／命令列內容(可能帶 token,安全鐵律 #2)
lf_item "$LF_ERR | cwd=C:\\\\Users\\\\markh\\\\secret-dir | cmd=pwsh -Command Get-Content token=abc123" -1 failed | lf_events; lf_run
ok "(f) 含 cwd／cmd 的失敗 → exit 3"             lf_blocked
ok "(f) 輸出不含 cwd=／cmd=／路徑／token"         lf_out_lacks 'cwd=|cmd=|secret-dir|abc123'
# (f3) 「 | 」之後不是 cwd=／cmd= 而是別的內容 → 一樣整段丟掉
lf_item "$LF_ERR | extra=secret-dir3" -1 failed | lf_events; lf_run
ok "(f3) 「 | 」之後的任何內容 → exit 3"          lf_blocked
ok "(f3) 輸出不含「 | 」之後的內容"               lf_out_lacks 'secret-dir3'
# (f2) 沒有「 | 」分隔、直接黏著 cwd=／cmd= 的變體(縱深防禦)
lf_item "Failed to create unified exec process: boom cwd=C:\\\\secret-dir2 cmd=tool --token=zzz9" -1 failed | lf_events; lf_run
ok "(f2) 無分隔符的 cwd／cmd → exit 3"            lf_blocked
ok "(f2) 輸出不含 cwd=／cmd=／路徑／token"         lf_out_lacks 'cwd=|cmd=|secret-dir2|zzz9'

# (f4) JSON 逸出序列(2026-10-14 A 層審查抓到): 擷取若用 [^"]* 會跨過 \n 把後面的命令列與 token 整段印出。
# 錯誤類型只能停在第一個反斜線之前。fixture 內的 \n／\r\n／\" 都是 JSON 的字面逸出(兩個字元)。
lf_item 'Failed to create unified exec process: boom\nrunning: pwsh -c Get-Secret --token=SEKRET99' -1 failed | lf_events; lf_run
ok "(f4) \\n 後接命令列與 token → exit 3"         lf_blocked
ok "(f4) 輸出不含 \\n 之後的命令列與 token"        lf_out_lacks 'SEKRET99|Get-Secret|running:'
ok "(f4) 錯誤類型停在反斜線之前"                   test "$(lf_types)" = '    1 Failed to create unified exec process: boom'
# (f5) 結尾的 \r\n 字面不得殘留
lf_item 'Failed to create unified exec process: helper_unknown_error: setup refresh had errors\r\n' -1 failed | lf_events; lf_run
ok "(f5) 結尾 \\r\\n 字面不殘留"                    test "$(lf_types)" = '    1 Failed to create unified exec process: helper_unknown_error: setup refresh had errors'
# (f6) 跳脫引號 \" 不得在尾端殘留反斜線
lf_item 'Failed to create unified exec process: bad \"quote\"' -1 failed | lf_events; lf_run
ok "(f6) \\\" 尾端不殘留反斜線"                     test "$(lf_types)" = '    1 Failed to create unified exec process: bad'
# (f7) 沒有反斜線、也沒有 cwd=/cmd=,但錯誤文字裡帶 key=value:值不得印出(停在 = 之前)
lf_item 'Failed to create unified exec process: spawn pwsh -c Get-Secret --token=SEKRET55' -1 failed | lf_events; lf_run
ok "(f7) key=value 的值不印出"                    lf_out_lacks 'SEKRET55'

# --json 之後錯誤只出現在 stdout 的 error 事件(stderr 空),仍要走對各自的分支——
# 先前純文字模式下這些訊息在 stderr,改 --json 後若不併入就會被誤判成別的失敗:
# 額度被擋 → RATE_LIMITED exit 4(不是 FAILED exit 1)
lf_item "PROBE-OK" 0 completed | lf_events
JSON_ERR="You've hit your usage limit. Upgrade to Pro" lf_run
ok "額度被擋只在 stdout error 事件 → exit 4"       test "$lf_rc" -eq 4
ok "額度被擋只在 stdout error 事件 → RATE_LIMITED"  lf_out_has 'RATE_LIMITED'
# 模型不可用 → 退回舊模型重問一次(先問主模型再問退路,最後共識成立)
REJECT=gpt-6.1-sol lf_run
ok "模型不可用只在 stdout error 事件 → 退回舊模型"  test "$(models)" = "gpt-6.1-sol gpt-6-luna"
ok "模型不可用只在 stdout error 事件 → 退回後共識"  lf_agreed
# turn.failed 事件(error.message,沒有獨立的 error 事件)也要併入(2026-10-14 A 層審查):
# 否則只有 turn.failed 帶額度訊息時會被分成 FAILED(exit 1)而不是 RATE_LIMITED(exit 4)
TURN_FAILED=1 JSON_ERR="You've hit your usage limit. Upgrade to Pro" lf_run
ok "額度被擋只在 turn.failed → exit 4"             test "$lf_rc" -eq 4
ok "額度被擋只在 turn.failed → RATE_LIMITED"        lf_out_has 'RATE_LIMITED'
TURN_FAILED=1 REJECT=gpt-6.1-sol lf_run
ok "模型不可用只在 turn.failed → 退回舊模型"        test "$(models)" = "gpt-6.1-sol gpt-6-luna"
ok "模型不可用只在 turn.failed → 退回後共識"        lf_agreed
# 一般失敗(不是額度、不是模型不可用) → FAILED exit 1,不退回
JSON_ERR=boom lf_run
ok "一般 error 事件 → FAILED exit 1"                test "$lf_rc" -eq 1 -a "$(grep -c 'FAILED:' "$T/out.txt")" -eq 1
ok "一般 error 事件 → 不重問(只呼叫一次)"           test "$(models)" = "gpt-6.1-sol"
# 只併 error／turn.failed 事件行,不併整份 JSONL: agent_message 引用額度字樣或 model_not_found
# 都不得把一般失敗誤判成 RATE_LIMITED／觸發舊模型退回(模型回覆內容不能帶進判定)
{ lf_item "PROBE-OK" 0 completed
  echo '{"type":"item.completed","item":{"id":"item_8","type":"agent_message","text":"You'\''ve hit your usage limit. Upgrade to Pro"}}'
  echo '{"type":"item.completed","item":{"id":"item_9","type":"agent_message","text":"model_not_found: gpt-6.1-sol"}}'; } | lf_events
JSON_ERR=boom lf_run
ok "agent_message 引用字樣 + 一般失敗 → 仍是 FAILED exit 1" test "$lf_rc" -eq 1 -a "$(grep -c 'FAILED:' "$T/out.txt")" -eq 1
ok "agent_message 引用字樣 → 不得判成 RATE_LIMITED"   lf_out_lacks 'RATE_LIMITED'
ok "agent_message 引用 model_not_found → 不得退回舊模型" test "$(models)" = "gpt-6.1-sol"

# 守門: stdout 是 JSONL、-o 檔沒寫出、codex exit 0 → FAILED exit 1。不是把 JSONL 當裁定解析
# (那會變成「缺少契約行」的 exit 3,看起來像模型沒照格式而不是諮詢根本沒拿到結果)
lf_item "PROBE-OK" 0 completed | lf_events
NO_O=1 lf_run
ok "-o 沒寫出(JSONL 在 stdout、exit 0) → FAILED exit 1" test "$lf_rc" -eq 1 -a "$(grep -c 'FAILED:' "$T/out.txt")" -eq 1
ok "-o 沒寫出 → 不是缺契約行的無共識"              lf_out_lacks '缺少契約行'
# === LAUNCHFAIL-END ===

# 不得再出現已退出的 gpt-5.6(2026-10-08 使用者裁定最低 gpt-6)
ok "映射不含 gpt-5.6" bash -c "! grep -qE 'MODEL=\"gpt-5\.6' '$SCRIPT'"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
