#!/usr/bin/env bash
# scripts/check-plugin.sh 的行為測試（離線，不需要 Claude Code）。
#
# 為什麼每條檢查都要有一個會讓它失敗的 fixture：一條什麼都沒比對到的檢查，外表和「通過」
# 一模一樣（regex 寫錯、掃描範圍是空的、環境缺指令被當成沒問題）。所以這裡分三組：
#   1. 正控組：對真實 repo 跑一次必須 exit 0；基底 fixture 本身也必須 exit 0——否則下面的
#      負控組量到的是「基底壞了」而不是「植入的錯誤被抓到」。
#   2. 負控組：在 mktemp 的暫存樹裡植入一個已知錯誤，斷言 exit 1，並斷言輸出指名了那一條
#      規則與正確的檔案（不只看離開碼）。放行標記、fenced block、不同寫法順序這類
#      「不該擋」的案例放在基底裡，由基底通過來證明。
#   3. pre-push：用暫存 git repo + bare remote 實際 commit，涵蓋版本核對的各種推送形狀。
#
# CRLF 的涵蓋範圍（2026-10-18 對 check-plugin.sh 逐行刪掉清 \r 的處理做 mutation，結果如下）：
#   - 有鑑別力（刪掉就紅；在「CRLF」那一節與 pre-push 的 stdin 兩行測試）：
#     AWK_FRONTMATTER 的 sub(/\r$/)、AWK_DOCSCAN 的 sub(/\r$/)、pre_push 的 line="${line%$'\r'}"。
#     這台的 MSYS gawk 讀檔時自己就把 \r\n 當換行，所以 CRLF 那一節用 BINMODE=3 的 awk shim 讓 \r 原樣保留；
#     這台的 bash 會清掉 $(cat) 結果最後一行的尾端 \r，所以 stdin 測試要兩行、有事要做的放第一行。
#   - 沒有任何測試能證明有用（刪掉仍全綠）：cmd、HJ、plugin_version 的 v、tier 解析的 fm、AWK_PROSE 的 sub(/\r$/)。
#     原因各自不同（ref_re 與 prose 的反引號 span 本來就吃不到 \r；HJ 只做子字串找行號；Git Bash 的 $(...) 會先清掉
#     尾端 \r；fm 前面還有 AWK_FRONTMATTER 的清除），它們是保險，不是被驗證過的行為。所以 hooks.json 的
#     「不存在的 hook 排在前面那筆」fixture 只代表「不是最後一筆也抓得到」，不要拿來宣稱涵蓋了 CRLF。
#
# Run: bash tests/check-plugin.test.sh   (exit 0 = all pass)
set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-plugin.sh"
WRAP="$ROOT/githooks/pre-push"
pass=0; fail=0

command -v jq >/dev/null 2>&1 || { echo "FAIL: 需要 jq（沒有 jq 時測試不能 SKIP 後回 0）"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FAIL: 需要 git"; exit 2; }
bash -n "$CHECK" || { echo "SYNTAX ERROR in $CHECK"; exit 1; }
bash -n "$WRAP"  || { echo "SYNTAX ERROR in $WRAP"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT

ok() { pass=$((pass + 1)); }
ng() { echo "  FAIL  $1"; echo "        $2"; fail=$((fail + 1)); }

OUT=""; RC=0
run_check() { # run_check <dir> [args...]
  local d="$1"; shift
  OUT="$(bash "$CHECK" --root "$d" "$@" 2>&1)"; RC=$?
}
# check_out <name> <期望 rc> [grep -E pattern...]：離開碼要對，輸出要含每個 pattern
check_out() {
  local name="$1" want="$2" p; shift 2
  if [ "$RC" != "$want" ]; then
    ng "$name" "期望 rc=$want，實得 $RC；輸出：$(printf '%s' "$OUT" | head -c 500)"; return
  fi
  for p in "$@"; do
    printf '%s\n' "$OUT" | grep -Eq -- "$p" || { ng "$name" "輸出缺少 /$p/；輸出：$(printf '%s' "$OUT" | head -c 500)"; return; }
  done
  ok
}
check_absent() { # check_absent <name> <pattern>
  if printf '%s\n' "$OUT" | grep -Eq -- "$2"; then ng "$1" "輸出不該含 /$2/；輸出：$(printf '%s' "$OUT" | head -c 500)"; else ok; fi
}
# fix <name> <rc> <pattern...>：對 $T 這棵樹跑檢查並斷言
fix() { local name="$1" want="$2"; shift 2; run_check "$T" ; check_out "$name" "$want" "$@"; }

# ---------------------------------------------------------------------
# 基底 fixture：最小但完整的 plugin 樹，必須通過。
# ---------------------------------------------------------------------
mk_agent() { # mk_agent <dir> <name> <model> <effort>
  printf -- '---\nname: %s\ndescription: %s tier（%s + effort %s）。測試用。\nmodel: %s\neffort: %s\n---\n\nbody\n' \
    "$2" "$2" "$3" "$4" "$3" "$4" > "$1/agents/$2.md"
}
hooks_json() { # hooks_json <file> <hook 檔名>... ：每個檔名一支 command，順序即註冊順序
  local f="$1" n first=1; shift
  {
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":['
    for n in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}\\"/hooks/%s"}' "$n"
    done
    printf ']}]}}\n'
  } > "$f"
}
build_base() {
  local d="$1"
  mkdir -p "$d/agents" "$d/skills/demo" "$d/references" "$d/hooks" "$d/tests" "$d/scripts" "$d/.claude-plugin"
  mk_agent "$d" tier-b1 sonnet xhigh
  mk_agent "$d" tier-b2 sonnet medium
  mk_agent "$d" tier-c haiku low
  cat > "$d/skills/demo/SKILL.md" <<'EOF'
# demo skill
Workflow: `agentType:'eng-flow:tier-b1'` + `model:"sonnet"` + `effort:'xhigh'`; Agent tool: `subagent_type:"eng-flow:tier-b2"`.
Object form: { agentType: 'eng-flow:tier-c', model: 'haiku', effort: 'low' }
Reversed order: { effort: 'medium', model: 'sonnet', agentType: 'eng-flow:tier-b2' }
JSON keys: {"subagent_type": "eng-flow:tier-b1", "model": "sonnet", "effort": "xhigh"} and {"effort": "medium", "model": "sonnet", "subagent_type": "eng-flow:tier-b2"}
Counter-example: writing `model:"sonnet"` directly inherits the session effort. <!-- check-plugin: allow dispatch -->
Mixed line: `agentType:'eng-flow:tier-b2'` + `model:"sonnet"` + `effort:'medium'` in Workflow; for high risk use A = omit `model` + `effort:'high'`
Other model: Agent(subagent_type: "general-purpose", model: "fable")
Prose paths: `references/demo.md`, `bash scripts/foo.sh --x`, `agents/tier-*.md`, `skills/<name>/SKILL.md`, `~/.claude/scripts/user-only.sh`, `scripts/foo.sh:12`, `references/demo.md#section`
User project path: `tests/some/where.ts` <!-- check-plugin: allow path -->

```bash
bash scripts/not-in-this-plugin.sh
```
EOF
  cat > "$d/references/demo.md" <<'EOF'
# demo reference
| Tier | Model | Effort | How |
|---|---|---|---|
| **Session** | main | `high` | settings |
| **B1** | Sonnet | `xhigh` | `agentType:'eng-flow:tier-b1'` + `model:"sonnet"` + `effort:'xhigh'` |
| **B2** | sonnet | `Medium` |`agentType:'eng-flow:tier-b2'` + `model:"sonnet"` + `effort:'medium'` |
| **C** | haiku（Haiku 5.5） | low | `agentType:'eng-flow:tier-c'` + `model:"haiku"` + `effort:'low'` |
EOF
  printf '# fx\n\nSee `scripts/foo.sh`.\n' > "$d/README.md"
  printf '#!/bin/sh\n' > "$d/scripts/foo.sh"
  # 三支註冊的 hook：測試檔三種命名各一（<name>.test.sh、test_<name 的 - 換成 _>.py、明文例外表）；
  # 另有一支 lib（在腳本的 HOOK_LIBS 清單）不需要註冊也不需要測試。
  for h in alpha beta-two no-heredoc-backslashes iso-secret-lib; do printf '#!/bin/sh\n' > "$d/hooks/$h.sh"; done
  # no-heredoc-backslashes.sh 會呼叫同名的 .py（真實 repo 的樣子）：.py 沒有自己的註冊，不能因此報成未註冊
  printf '#!/bin/sh\npython "$DIR/no-heredoc-backslashes.py"\n' > "$d/hooks/no-heredoc-backslashes.sh"
  printf '# py\n' > "$d/hooks/no-heredoc-backslashes.py"
  hooks_json "$d/hooks/hooks.json" alpha.sh beta-two.sh no-heredoc-backslashes.sh
  printf '#!/bin/sh\n' > "$d/tests/alpha.test.sh"
  printf '# t\n' > "$d/tests/test_beta_two.py"
  printf '# t\n' > "$d/tests/test_heredoc_backslashes.py"
  printf '{"name":"fx","version":"1.0.0"}\n' > "$d/.claude-plugin/plugin.json"
}
BASE="$tmp/base"
build_base "$BASE"
jq -e . "$BASE/hooks/hooks.json" >/dev/null 2>&1 || { echo "FAIL: 測試自己產的 hooks.json 不是合法 JSON"; exit 1; }
new_tree() { T="$tmp/$1"; rm -rf "${T:?}"; cp -r "$BASE" "$T"; }

# =====================================================================
echo "== 正控組 =="
# 真實 repo 必須通過；HOME 指到空目錄，順便確認沒有偷讀 ~/.claude 之類的外部檔案才會過
mkdir -p "$tmp/emptyhome"
OUT="$(HOME="$tmp/emptyhome" bash "$CHECK" 2>&1)"; RC=$?
check_out "真實 repo" 0 '^check-plugin: OK'
T="$BASE"; fix "基底 fixture 通過（負控組的前提）" 0 '^check-plugin: OK'

# =====================================================================
echo "== 規則 1：tier 一致性 =="
new_tree t1; sed -i '/^effort:/d' "$T/agents/tier-b2.md"
fix "tier-frontmatter：缺 effort" 1 '^agents/tier-b2\.md:1: \[tier-frontmatter\].*effort'
new_tree t1b; sed -i '/^model:/d' "$T/agents/tier-c.md"
fix "tier-frontmatter：缺 model" 1 '^agents/tier-c\.md:1: \[tier-frontmatter\].*model'
new_tree t1c; rm -f "$T"/agents/tier-*.md
fix "tier-frontmatter：沒有任何 tier agent" 1 '\[tier-frontmatter\]'

new_tree t2; sed -i 's/effort xhigh）/effort high）/' "$T/agents/tier-b1.md"
fix "tier-desc：description 括號的 effort 與 frontmatter 不符" 1 '^agents/tier-b1\.md:3: \[tier-desc\].*high'
new_tree t2b; sed -i 's/（sonnet + effort medium）/（opus + effort medium）/' "$T/agents/tier-b2.md"
fix "tier-desc：description 括號的 model 與 frontmatter 不符" 1 '^agents/tier-b2\.md:3: \[tier-desc\].*opus'
new_tree t2c; sed -i 's/（haiku + effort low）//' "$T/agents/tier-c.md"
fix "tier-desc：description 沒有括號標示" 1 '^agents/tier-c\.md:3: \[tier-desc\]'

new_tree t3; sed -i "s/effort:'xhigh'/effort:'medium'/" "$T/skills/demo/SKILL.md"
fix "tier-line：+ 相連寫法的 effort 不符" 1 '^skills/demo/SKILL\.md:2: \[tier-line\].*tier-b1.*effort.*medium'
new_tree t3b; sed -i "s/model: 'haiku'/model: 'sonnet'/" "$T/skills/demo/SKILL.md"
fix "tier-line：物件寫法 tier 在前、model 不符" 1 '^skills/demo/SKILL\.md:3: \[tier-line\].*tier-c.*model.*sonnet'
new_tree t3c; sed -i "s/effort: 'medium', model/effort: 'low', model/" "$T/skills/demo/SKILL.md"
fix "tier-line：物件寫法 tier 在後（順序不影響）" 1 '^skills/demo/SKILL\.md:4: \[tier-line\].*tier-b2.*effort.*low'
new_tree t3d; printf '%s\n' "Both: \`agentType:'eng-flow:tier-b1'\` + \`agentType:'eng-flow:tier-b2'\` + \`model:\"sonnet\"\`" >> "$T/skills/demo/SKILL.md"
fix "tier-line：同一組寫法混了兩個 tier" 1 '^skills/demo/SKILL\.md:[0-9]+: \[tier-line\].*混了多個 tier'
new_tree t3e; printf '%s\n' "- 範例 agentType:'eng-flow:tier-b1', model:'haiku'" >> "$T/agents/tier-b1.md"
fix "tier-line：agents/ 底下的檔案也要掃" 1 '^agents/tier-b1\.md:[0-9]+: \[tier-line\]'

new_tree t4; sed -i 's/| `xhigh` |/| `high` |/' "$T/references/demo.md"
fix "tier-table：B1 列的 effort 欄不符" 1 '^references/demo\.md:5: \[tier-table\].*effort'
new_tree t4b; sed -i 's/| haiku（Haiku 5.5） |/| sonnet（x） |/' "$T/references/demo.md"
fix "tier-table：C 列的 model 欄不符" 1 '^references/demo\.md:7: \[tier-table\].*model'
# N8：欄位大小寫不影響比對（基底裡 B1 的 model 寫 Sonnet、B2 的 effort 寫 Medium 必須通過）；寫成別的值照樣抓
new_tree t4c; printf '%s\n' '| **B2** | Opus | Medium | x |' >> "$T/references/demo.md"
fix "tier-table：大小寫不同但值也不同（Opus）→ 拒絕，並以小寫回報" 1 '^references/demo\.md:[0-9]+: \[tier-table\].*B2.*model 欄是「opus」'
new_tree t4d; printf '%s\n' '| **B1** | SONNET | `High` | x |' >> "$T/references/demo.md"
fix "tier-table：model 大寫相符、effort 值不符（High）→ 只報 effort" 1 '^references/demo\.md:[0-9]+: \[tier-table\].*B1.*effort 欄是「high」'
check_absent "tier-table：大寫的 SONNET 不被誤報成 model 不符" 'B1.*model 欄是'

new_tree t5; printf '%s\n' "Stale: \`agentType:'eng-flow:tier-d'\`" >> "$T/skills/demo/SKILL.md"
fix "tier-unknown：引用不存在的 tier agent" 1 '^skills/demo/SKILL\.md:[0-9]+: \[tier-unknown\].*tier-d'

# =====================================================================
echo "== 規則 2：派工寫法 lint =="
new_tree d1; printf '%s\n' "Dispatch with \`model:\"haiku\"\` for scanning." >> "$T/skills/demo/SKILL.md"
fix "dispatch-model：haiku 同一行沒有 eng-flow:tier-" 1 '^skills/demo/SKILL\.md:[0-9]+: \[dispatch-model\].*haiku'
new_tree d1b; printf '%s\n' "Use model: sonnet here." >> "$T/references/demo.md"
fix "dispatch-model：references/ 也要掃、無引號寫法" 1 '^references/demo\.md:[0-9]+: \[dispatch-model\].*sonnet'
new_tree d1c; printf '%s\n' "Dispatch with \`model:\"haiku\"\` for scanning. <!-- check-plugin: allow dispatch -->" >> "$T/skills/demo/SKILL.md"
fix "dispatch-model：同行放行標記有效" 0 '^check-plugin: OK'
new_tree d1d; printf '%s\n' "Dispatch with \`model:\"haiku\"\`. <!-- check-plugin: allow path -->" >> "$T/skills/demo/SKILL.md"
fix "dispatch-model：path 標記不能放行 dispatch（標記各管各的規則）" 1 '\[dispatch-model\]'

new_tree d2; printf '%s\n' "Agent(subagent_type: \"tier-b1\", prompt: x)" >> "$T/skills/demo/SKILL.md"
fix "dispatch-prefix：subagent_type 缺 eng-flow: 前綴" 1 '^skills/demo/SKILL\.md:[0-9]+: \[dispatch-prefix\]'
new_tree d2b; printf '%s\n' "agent({ agentType:'tier-c', model:'haiku', effort:'low' })" >> "$T/references/demo.md"
fix "dispatch-prefix：agentType 缺前綴（references/）" 1 '^references/demo\.md:[0-9]+: \[dispatch-prefix\]'
new_tree d2c; printf '%s\n' "Use subagent_type \"tier-b2\" to dispatch." >> "$T/agents/tier-b2.md"
fix "dispatch-prefix：agents/ 底下、無冒號寫法" 1 '^agents/tier-b2\.md:[0-9]+: \[dispatch-prefix\]'

# S6：JSON 的鍵是帶引號的（"subagent_type": "tier-b1"）。基底裡已放兩行正確的 JSON 寫法（必須通過）。
new_tree j1; printf '%s\n' '{"subagent_type": "tier-b1", "model": "sonnet"}' >> "$T/skills/demo/SKILL.md"
fix "JSON 鍵帶引號：缺 eng-flow: 前綴、model 又沒走 tier agent" 1 '^skills/demo/SKILL\.md:[0-9]+: \[dispatch-prefix\]' '^skills/demo/SKILL\.md:[0-9]+: \[dispatch-model\].*sonnet'
new_tree j2; printf '%s\n' '{"subagent_type": "general-purpose", "model": "haiku"}' >> "$T/references/demo.md"
fix "JSON 鍵帶引號：model 直接寫 haiku → dispatch-model" 1 '^references/demo\.md:[0-9]+: \[dispatch-model\].*haiku'
new_tree j3; printf '%s\n' '{"subagent_type": "eng-flow:tier-b1", "model": "haiku", "effort": "xhigh"}' >> "$T/skills/demo/SKILL.md"
fix "JSON 鍵帶引號：tier-b1 的 model 寫成 haiku → tier-line" 1 '^skills/demo/SKILL\.md:[0-9]+: \[tier-line\].*tier-b1.*model.*haiku'
new_tree j4; printf '%s\n' '{"effort": "high", "subagent_type": "eng-flow:tier-b2", "model": "sonnet"}' >> "$T/skills/demo/SKILL.md"
fix "JSON 鍵帶引號：tier-b2 的 effort 寫成 high（順序顛倒）→ tier-line" 1 '^skills/demo/SKILL\.md:[0-9]+: \[tier-line\].*tier-b2.*effort.*high'
new_tree j5; printf '%s\n' '{"subagent_type": "tier-b1", "model": "sonnet"} <!-- check-plugin: allow dispatch -->' >> "$T/skills/demo/SKILL.md"
fix "JSON 鍵帶引號：同行放行標記有效" 0 '^check-plugin: OK'

# =====================================================================
echo "== 規則 3：hooks.json =="
new_tree h0; printf '{ not json' > "$T/hooks/hooks.json"
fix "hooks-json：不是合法 JSON" 1 '^hooks/hooks\.json:1: \[hooks-json\]'
new_tree h0b; rm -f "$T/hooks/hooks.json"
fix "hooks-json：hooks.json 不存在" 1 '^hooks/hooks\.json:1: \[hooks-json\]'

# 兩筆以上，不存在的排在前面那筆、也排在最後那筆各測一次（不要只測最後一筆）。
# 輸出不帶 CR 是對最終結果的檢查（本機 jq 輸出 CRLF）；它不是清 \r 那行程式的 mutation 證據，見檔頭說明。
new_tree h1; hooks_json "$T/hooks/hooks.json" ghost.sh alpha.sh beta-two.sh no-heredoc-backslashes.sh
fix "hooks-missing：排在前面那筆引用的檔案不存在" 1 '^hooks/hooks\.json:[0-9]+: \[hooks-missing\].*hooks/ghost\.sh 不存在$'
check_absent "hooks-missing：輸出不帶 CR" $'\r'
new_tree h1b; hooks_json "$T/hooks/hooks.json" alpha.sh beta-two.sh no-heredoc-backslashes.sh ghost.sh
fix "hooks-missing：排在最後那筆也抓得到" 1 '\[hooks-missing\].*hooks/ghost\.sh'
check_absent "hooks-missing：存在的 hook 沒被誤報" 'hooks/alpha\.sh.*不存在'

new_tree h2; printf '#!/bin/sh\n' > "$T/hooks/orphan.sh"
fix "hooks-unregistered：hooks/*.sh 沒註冊也不在 lib 清單" 1 '^hooks/orphan\.sh:1: \[hooks-unregistered\]'
check_absent "hooks-unregistered：lib 清單內的 iso-secret-lib.sh 不誤報" '^hooks/iso-secret-lib\.sh'

# N9：hooks/*.py 要有人用——hooks.json 直接引用，或已註冊的 .sh 會呼叫它（基底裡 no-heredoc-backslashes.py 就是後者，必須通過）
new_tree h2b; printf '# py\n' > "$T/hooks/orphan.py"
fix "hooks-unregistered：hooks/*.py 沒人註冊也沒人呼叫" 1 '^hooks/orphan\.py:1: \[hooks-unregistered\]'
check_absent "hooks-unregistered：被已註冊的 .sh 呼叫的 .py 不誤報" 'no-heredoc-backslashes\.py'
new_tree h2c; printf '# py\n' > "$T/hooks/helper.py"; printf '#!/bin/sh\npython helper.py\n' > "$T/hooks/lonely.sh"
fix "hooks-unregistered：只被「未註冊的 .sh」提到的 .py 仍算未註冊（.sh 本身也報）" 1 '^hooks/helper\.py:1: \[hooks-unregistered\]' '^hooks/lonely\.sh:1: \[hooks-unregistered\]'
new_tree h2d; printf '# py\n' > "$T/hooks/helper.py"; printf 'python helper.py\n' >> "$T/hooks/alpha.sh"
fix "hooks-unregistered：被已註冊的 alpha.sh 呼叫的 .py → 放行" 0 '^check-plugin: OK'
new_tree h2e; printf '# py\n' > "$T/hooks/direct.py"; printf '# t\n' > "$T/tests/test_direct.py"
hooks_json "$T/hooks/hooks.json" alpha.sh beta-two.sh no-heredoc-backslashes.sh direct.py
fix "hooks-unregistered：hooks.json 直接引用的 .py（有測試檔）→ 放行" 0 '^check-plugin: OK'
new_tree h2f; printf '# py\n' > "$T/hooks/direct.py"
hooks_json "$T/hooks/hooks.json" alpha.sh beta-two.sh no-heredoc-backslashes.sh direct.py
fix "hooks-no-test：hooks.json 直接引用的 .py 沒有測試檔 → 拒絕" 1 '\[hooks-no-test\].*direct'

new_tree h3; rm -f "$T/tests/alpha.test.sh"
fix "hooks-no-test：<name>.test.sh 不存在" 1 '^hooks/hooks\.json:[0-9]+: \[hooks-no-test\].*alpha'
new_tree h3b; rm -f "$T/tests/test_beta_two.py"
fix "hooks-no-test：test_<name 的 - 換成 _>.py 不存在" 1 '\[hooks-no-test\].*beta-two'
new_tree h3c; rm -f "$T/tests/test_heredoc_backslashes.py"
fix "hooks-no-test：明文例外表（no-heredoc-backslashes）的測試檔不存在" 1 '\[hooks-no-test\].*no-heredoc-backslashes'

# =====================================================================
echo "== 規則 4：散文路徑 =="
new_tree p1; printf '%s\n' "Also see \`scripts/ghost.sh\`." >> "$T/README.md"
fix "prose-path：README.md 裡不存在的路徑" 1 '^README\.md:[0-9]+: \[prose-path\].*scripts/ghost\.sh'
new_tree p1b; printf '%s\n' "Run \`bash scripts/ghost.sh --x\` first." >> "$T/skills/demo/SKILL.md"
fix "prose-path：命令 span 內的第二個 token" 1 '^skills/demo/SKILL\.md:[0-9]+: \[prose-path\].*scripts/ghost\.sh'
new_tree p1c; printf '%s\n' "Read \`\${CLAUDE_PLUGIN_ROOT}/references/missing.md\`." >> "$T/references/demo.md"
fix "prose-path：\${CLAUDE_PLUGIN_ROOT}/ 前綴也要驗" 1 '^references/demo\.md:[0-9]+: \[prose-path\].*references/missing\.md'
new_tree p1d; printf '%s\n' "Template \`scripts/nodir/<x>.sh\` and \`hooks/ghost.sh:12\`." >> "$T/skills/demo/SKILL.md"
fix "prose-path：佔位符只驗到目錄、:行號會被去掉" 1 '\[prose-path\].*scripts/nodir/<x>\.sh' '\[prose-path\].*hooks/ghost\.sh:12'
new_tree p1e; printf '%s\n' "Pattern \`agents/nothing-*.md\` matches nothing." >> "$T/skills/demo/SKILL.md"
fix "prose-path：萬用字元沒有任何符合" 1 '\[prose-path\].*agents/nothing-\*\.md'
new_tree p1f; printf '%s\n' "Outside plugin: \`scripts/ghost.sh\` <!-- check-plugin: allow path -->" >> "$T/skills/demo/SKILL.md"
fix "prose-path：同行放行標記有效" 0 '^check-plugin: OK'

# =====================================================================
echo "== CRLF =="
# .md 是 CRLF（Windows 的 autocrlf checkout）：frontmatter 的 --- 判斷、agents 內 model: 行的略過、表格與派工寫法
# 都靠 awk 內清掉行尾 \r（刪掉 AWK_FRONTMATTER 或 AWK_DOCSCAN 的 sub(/\r$/, ...) 會變紅；AWK_PROSE 那條測不出來，見檔頭說明）。
# 這台的 MSYS gawk 讀檔時自己就把 \r\n 當成換行，不加 shim 的話這一節在這台量不到任何東西；
# shim 用 BINMODE=3 讓 awk 原樣保留 \r（和 Linux 的 awk 一樣），所以這一節在任何平台都有鑑別力。
REAL_AWK="$(command -v awk)"
mkdir -p "$tmp/awkshim"
printf '#!/bin/sh\nexec "%s" -v BINMODE=3 "$@"\n' "$REAL_AWK" > "$tmp/awkshim/awk"
chmod +x "$tmp/awkshim/awk"
OLD_PATH="$PATH"; PATH="$tmp/awkshim:$PATH"
crlf_md() { find "$T" -name '*.md' -exec sed -i 's/$/\r/' {} +; }
new_tree c0; printf 'a\r\n' > "$T/probe.txt"
if [ "$(awk '{ print ($0 == "a") }' "$T/probe.txt")" = 0 ]; then ok; else ng "CRLF 的前提：shim 之下 awk 看得到行尾 \\r" "shim 沒有生效，這一節的測試不具鑑別力"; fi
new_tree c1; crlf_md
fix "CRLF 的 .md：基底照樣通過（frontmatter 與 agents 的 model: 行不被誤判）" 0 '^check-plugin: OK'
new_tree c2; crlf_md; sed -i 's/| `xhigh` |/| `high` |/' "$T/references/demo.md"
fix "CRLF 的 .md：tier-table 錯誤照樣抓到" 1 '^references/demo\.md:5: \[tier-table\].*effort'
check_absent "CRLF 的 .md：輸出不帶 CR" $'\r'
new_tree c3; crlf_md; sed -i 's/effort xhigh）/effort high）/' "$T/agents/tier-b1.md"
fix "CRLF 的 agent：tier-desc 錯誤照樣抓到" 1 '^agents/tier-b1\.md:3: \[tier-desc\].*high'
new_tree c4; crlf_md; printf 'Dispatch with `model:"haiku"` for scanning.\r\n' >> "$T/skills/demo/SKILL.md"
fix "CRLF 的 .md：dispatch-model 照樣抓到" 1 '^skills/demo/SKILL\.md:[0-9]+: \[dispatch-model\].*haiku'
new_tree c5; crlf_md; printf 'Also see `scripts/ghost.sh`.\r\n' >> "$T/README.md"
fix "CRLF 的 .md：prose-path 照樣抓到" 1 '^README\.md:[0-9]+: \[prose-path\].*scripts/ghost\.sh'
check_absent "CRLF 的 .md：prose-path 的路徑不帶 CR" $'\r'
PATH="$OLD_PATH"

# =====================================================================
echo "== 環境不足（fail-closed，exit 2）=="
OUT="$(CHECK_PLUGIN_JQ=jq-does-not-exist bash "$CHECK" --root "$BASE" 2>&1)"; RC=$?
check_out "缺 jq → exit 2 而不是 SKIP 後回 0" 2 '環境不足.*jq'
mkdir -p "$tmp/empty"; run_check "$tmp/empty"
check_out "掃描零個檔案 → exit 2（空掃描不能算通過）" 2 '環境不足'
run_check "$BASE" --no-such-flag
check_out "不認得的參數 → exit 2" 2 '不認得的參數'
OUT="$(CHECK_PLUGIN_GIT=git-does-not-exist bash "$CHECK" --root "$BASE" --pre-push </dev/null 2>&1)"; RC=$?
check_out "--pre-push 缺 git → exit 2" 2 '環境不足.*git'

# =====================================================================
echo "== 規則 5：--pre-push 版本核對 =="
Z=0000000000000000000000000000000000000000
mkdir -p "$tmp/nohooks"
mk_repo() { # mk_repo <name> [extra：1 = 把 check-plugin.sh 與 githooks/pre-push 一起放進 repo，給 e2e 用]
  local r="$tmp/$1"; mkdir -p "$r"
  git init -q --bare -b main "$r/remote.git"
  W="$r/work"; cp -r "$BASE" "$W"
  if [ "${2:-}" = 1 ]; then
    mkdir -p "$W/githooks"; cp "$CHECK" "$W/scripts/check-plugin.sh"; cp "$WRAP" "$W/githooks/pre-push"
  fi
  git init -q -b main "$W"
  git -C "$W" config user.name t; git -C "$W" config user.email t@example.com
  git -C "$W" config commit.gpgsign false; git -C "$W" config core.autocrlf false
  git -C "$W" config core.hooksPath "$tmp/nohooks"          # 蓋掉使用者全域的 hooksPath
  git -C "$W" remote add origin "$r/remote.git"
  git -C "$W" add -A; git -C "$W" commit -q -m base
  git -C "$W" push -q origin main 2>&1
}
head_sha() { git -C "$W" rev-parse HEAD; }
edit_commit() { # edit_commit <相對路徑> ：附加一行並 commit（不碰 plugin.json 的 version）
  mkdir -p "$(dirname "$W/$1")"; printf 'edit %s\n' "$RANDOM" >> "$W/$1"
  git -C "$W" add -A; git -C "$W" commit -q -m "edit $1"
}
bump_commit() { # bump_commit <version>
  sed -i "s/\"version\":\"[^\"]*\"/\"version\":\"$1\"/" "$W/.claude-plugin/plugin.json"
  git -C "$W" add -A; git -C "$W" commit -q -m "bump $1"
}
PP_ARGS=(origin url-ignored)      # git 呼叫 pre-push 時的 $1（remote 名稱）與 $2（url）；測試可暫時改掉
pp() { # pp <stdin 的多行，以 | 分隔> → 對 $W 跑 --pre-push
  OUT="$(printf '%s\n' "$1" | tr '|' '\n' | bash "$CHECK" --root "$W" --pre-push ${PP_ARGS[@]+"${PP_ARGS[@]}"} 2>&1)"; RC=$?
}
reset_to() { git -C "$W" reset -q --hard "$1"; }

mk_repo pp
B0="$(head_sha)"
edit_commit skills/demo/SKILL.md; C1="$(head_sha)"
pp "refs/heads/main $C1 refs/heads/main $B0"
check_out "改 skill 沒 bump → 拒絕" 1 '^\.claude-plugin/plugin\.json:1: \[version-bump\].*skills/demo/SKILL\.md.*1\.0\.0'

reset_to "$B0"; edit_commit skills/demo/SKILL.md; sed -i 's/"version":"1.0.0"/"version":"1.0.1"/' "$W/.claude-plugin/plugin.json"
git -C "$W" add -A; git -C "$W" commit -q --amend --no-edit; C2="$(head_sha)"
pp "refs/heads/main $C2 refs/heads/main $B0"
check_out "改 skill 同時 bump → 放行" 0 '^check-plugin: OK.*版本核對'

reset_to "$B0"; bump_commit 1.0.2; edit_commit skills/demo/SKILL.md; C3="$(head_sha)"
pp "refs/heads/main $C3 refs/heads/main $B0"
check_out "先 bump 再改、一次推送 → 放行（不能用「自上次 bump 以來」判準）" 0 '^check-plugin: OK'

git -C "$W" push -q origin main 2>&1                                  # 遠端現在在 1.0.2
edit_commit skills/demo/SKILL.md; C4="$(head_sha)"
pp "refs/heads/main $C4 refs/heads/main $C3"
check_out "上次已 bump、這次只改不 bump → 拒絕" 1 '\[version-bump\].*1\.0\.2'
REMOTE_TIP="$C3"

# S3：version 要「嚴格變大」，不只是「不同」。遠端目前是 1.0.2。
reset_to "$REMOTE_TIP"; bump_commit 1.0.1; edit_commit skills/demo/SKILL.md; CV="$(head_sha)"
pp "refs/heads/main $CV refs/heads/main $REMOTE_TIP"
check_out "降版（1.0.2 → 1.0.1）→ 拒絕" 1 '\[version-bump\].*從 1\.0\.2 降到 1\.0\.1'
reset_to "$REMOTE_TIP"; bump_commit 1.0.2.0; edit_commit skills/demo/SKILL.md; CV="$(head_sha)"
pp "refs/heads/main $CV refs/heads/main $REMOTE_TIP"
check_out "字串不同但數值相同（1.0.2 → 1.0.2.0）→ 拒絕" 1 '\[version-bump\].*數值相同'
reset_to "$REMOTE_TIP"; bump_commit 1.0.10; edit_commit skills/demo/SKILL.md; CV="$(head_sha)"
pp "refs/heads/main $CV refs/heads/main $REMOTE_TIP"
check_out "逐段比數字：1.0.2 → 1.0.10 → 放行（字串比較會判成變小）" 0 '^check-plugin: OK'
reset_to "$REMOTE_TIP"; bump_commit 1.0.2.1; edit_commit skills/demo/SKILL.md; CV="$(head_sha)"
pp "refs/heads/main $CV refs/heads/main $REMOTE_TIP"
check_out "多一段（1.0.2 → 1.0.2.1）→ 放行" 0 '^check-plugin: OK'
reset_to "$REMOTE_TIP"; bump_commit 1.1.0-rc1; edit_commit skills/demo/SKILL.md; CV="$(head_sha)"
pp "refs/heads/main $CV refs/heads/main $REMOTE_TIP"
check_out "版本格式不是純數字點分、字串又不同 → fail-closed（exit 2），不猜大小" 2 '1\.1\.0-rc1'

for p in tests/x-probe.txt README.md .gitattributes githooks/x-probe.txt dist/x-probe.txt; do
  reset_to "$REMOTE_TIP"; edit_commit "$p"; C="$(head_sha)"
  pp "refs/heads/main $C refs/heads/main $REMOTE_TIP"
  check_out "只動 $p → 放行（不需要 bump）" 0 '^check-plugin: OK'
done
for p in skills/x-probe.txt hooks/x-probe.txt agents/x-probe.txt scripts/x-probe.txt references/x-probe.txt templates/x-probe.txt .claude-plugin/x-probe.txt; do
  reset_to "$REMOTE_TIP"; edit_commit "$p"; C="$(head_sha)"
  pp "refs/heads/main $C refs/heads/main $REMOTE_TIP"
  check_out "動 $p 沒 bump → 拒絕" 1 "\\[version-bump\\].*${p//./\\.}"
done

reset_to "$REMOTE_TIP"; edit_commit skills/demo/SKILL.md; CN="$(head_sha)"
pp "refs/heads/feature $CN refs/heads/main $Z"
check_out "新建遠端 main、沒 bump → 拒絕（以 origin/main 求基準）" 1 '\[version-bump\]'
reset_to "$REMOTE_TIP"; bump_commit 1.0.3; edit_commit skills/demo/SKILL.md; CB="$(head_sha)"
pp "refs/heads/feature $CB refs/heads/main $Z"
check_out "新建遠端 main、有 bump → 放行" 0 '^check-plugin: OK'
SAVED_ORIGIN_MAIN="$(git -C "$W" rev-parse refs/remotes/origin/main)"
git -C "$W" update-ref -d refs/remotes/origin/main
pp "refs/heads/feature $CB refs/heads/main $Z"
check_out "新建遠端 main、求不出比較基準 → fail-closed（exit 2）" 2 'merge-base|比較基準' 'git fetch'
git -C "$W" update-ref refs/remotes/origin/main "$SAVED_ORIGIN_MAIN"

# S4：新建遠端 main 的比較基準是 refs/remotes/<git 傳進來的 remote 名稱>/main，不是寫死的 origin
git -C "$W" remote rename origin up >/dev/null 2>&1
PP_ARGS=(up url-ignored)
reset_to "$REMOTE_TIP"; edit_commit skills/demo/SKILL.md; CN2="$(head_sha)"
pp "refs/heads/feature $CN2 refs/heads/main $Z"
check_out "remote 改名為 up、新建 main、沒 bump → 以 refs/remotes/up/main 求基準並拒絕" 1 '\[version-bump\]'
PP_ARGS=(origin url-ignored)
pp "refs/heads/feature $CN2 refs/heads/main $Z"
check_out "傳進來的名稱是 origin 但 origin/main 已不存在 → fail-closed，訊息指名 refs/remotes/origin/main" 2 'refs/remotes/origin/main' 'git fetch origin'
PP_ARGS=()
pp "refs/heads/feature $CN2 refs/heads/main $Z"
check_out "沒收到 remote 名稱、又要新建 main → fail-closed，不猜 origin" 2 'remote 名稱'
pp "refs/heads/feature $CN2 refs/heads/feature $Z"
check_out "沒收到 remote 名稱、但不需要比較基準（推非 main）→ 放行" 0 '^check-plugin: OK'
PP_ARGS=(a b c)
pp "refs/heads/feature $CN2 refs/heads/feature $Z"
check_out "多於 2 個位置參數 → exit 2" 2 '不認得的參數'
PP_ARGS=(origin url-ignored)
git -C "$W" remote rename up origin >/dev/null 2>&1
run_check "$BASE" extra-positional
check_out "非 --pre-push 模式不接受位置參數 → exit 2" 2 '不認得的參數'


pp "refs/heads/feature $CN refs/heads/feature $Z|refs/heads/main $CN refs/heads/main $REMOTE_TIP"
check_out "多個 ref：違規的 main 排第二 → 拒絕" 1 '\[version-bump\]'
pp "refs/heads/main $CN refs/heads/main $REMOTE_TIP|refs/heads/feature $CN refs/heads/feature $Z"
check_out "多個 ref：違規的 main 排第一 → 拒絕" 1 '\[version-bump\]'
pp "refs/heads/main $CB refs/heads/main $REMOTE_TIP|refs/heads/feature $CN refs/heads/feature $Z"
check_out "多個 ref：main 有 bump、另一個非 main → 放行" 0 '^check-plugin: OK'
pp "refs/heads/main $CN refs/heads/main $REMOTE_TIP|(delete) $Z refs/heads/old $C1"
check_out "多個 ref：違規的 main 加一個刪除 → 仍拒絕" 1 '\[version-bump\]'

pp "(delete) $Z refs/heads/main $REMOTE_TIP"
check_out "刪除 main → 略過版本核對" 0 '^check-plugin: OK'
pp "(delete) $Z refs/heads/old $REMOTE_TIP"
check_out "刪除非 main → 略過" 0 '^check-plugin: OK'

pp "refs/heads/main $CN refs/heads/main deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
check_out "remote sha 本機不存在 → fail-closed（exit 2）並提示 git fetch" 2 'git fetch' 'deadbeef'
pp "refs/heads/main $CN"
check_out "stdin 格式不是 4 欄 → fail-closed（exit 2）" 2 '4 欄'

# 假 git：遇到指定的子指令就失敗（exit 128），其餘原樣轉給真 git。給 fail-closed 分支的負控組用。
mk_failgit() { # mk_failgit <path> <子指令>
  cat > "$1" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "$2" ] && { echo "fatal: simulated failure" >&2; exit 128; }; done
exec git "\$@"
EOF
  chmod +x "$1"
}

# R1：git diff 失敗不能被當成「沒有變動」而放行。舊寫法 `git diff | tr` 的離開碼取的是 tr，
# 失敗被吞掉、changed 變空字串、直接 continue。先用真 git 確認同一輸入會被擋（排除「輸入本身就放行」），
# 再換成會讓 diff 失敗的 git，期望 exit 2。
mk_failgit "$tmp/git-fail-diff" diff
reset_to "$REMOTE_TIP"; edit_commit skills/demo/SKILL.md; CD="$(head_sha)"
pp "refs/heads/main $CD refs/heads/main $REMOTE_TIP"
check_out "git diff 失敗的對照組：真 git 同一輸入 → 拒絕" 1 '\[version-bump\]'
CHECK_PLUGIN_GIT="$tmp/git-fail-diff" pp "refs/heads/main $CD refs/heads/main $REMOTE_TIP"
check_out "git diff 失敗 → fail-closed（exit 2），不是放行" 2 'git diff'

# R2：--pre-push 的檢查 1～4 看的是「被推送的 commit」，不是工作樹。
# 做法是把每個被推送的 sha 用 read-tree + checkout-index 解到暫存目錄再檢查（輸出以 <sha7>: 開頭）。
# 這一組的前提：工作樹（HEAD）永遠是乾淨的或與被推送的 commit 不同，所以看錯對象的實作會得到相反的結果。
reset_to "$REMOTE_TIP"
OUT="$(bash "$CHECK" --root "$W" --pre-push </dev/null 2>&1)"; RC=$?
check_out "空 stdin：沒有要推的 ref，不看工作樹 → 放行" 0 '^check-plugin: OK'

# (a) 壞內容已 commit，修正只留在工作樹：舊實作看工作樹，會放行一個壞 commit
reset_to "$REMOTE_TIP"
printf '%s\n' "Bad \`scripts/ghost.sh\`." >> "$W/README.md"
git -C "$W" add -A; git -C "$W" commit -q -m "broken path"; CBAD="$(head_sha)"
git -C "$W" show "$REMOTE_TIP:README.md" > "$W/README.md"           # 工作樹是乾淨版本，但沒有 commit
pp "refs/heads/main $CBAD refs/heads/main $REMOTE_TIP"
check_out "已 commit 的壞路徑、修正只在工作樹 → 拒絕，並指名被推送的 commit" 1 "^${CBAD:0:7}:README\\.md:[0-9]+: \\[prose-path\\].*scripts/ghost\\.sh"

# (b) git push origin side:main：被推送的不是 HEAD
reset_to "$REMOTE_TIP"
git -C "$W" checkout -q -b side
printf '%s\n' "Bad \`scripts/ghost2.sh\`." >> "$W/README.md"
git -C "$W" add -A; git -C "$W" commit -q -m "side broken"; CSIDE="$(head_sha)"
git -C "$W" checkout -q main                                         # HEAD 回到乾淨的遠端 tip
pp "refs/heads/side $CSIDE refs/heads/main $REMOTE_TIP"
check_out "推非 HEAD 的壞 commit 到 main → 拒絕" 1 "^${CSIDE:0:7}:README\\.md:[0-9]+: \\[prose-path\\].*ghost2"

# (c) 非 main 的 ref 一律放行、什麼都不檢查：內容故意放壞路徑（CBAD，同時沒 bump），
# 對照組是同一個 commit 推 main 會被拒絕（(a) 已涵蓋）。
reset_to "$REMOTE_TIP"
pp "refs/heads/feature $CBAD refs/heads/feature $Z"
check_out "推壞 commit 到非 main 的新分支（feature branch）→ 放行" 0 '^check-plugin: OK'
git -C "$W" tag -a vbad -m bad "$CBAD"; TBAD="$(git -C "$W" rev-parse vbad)"
pp "refs/tags/vbad $TBAD refs/tags/vbad $Z"
check_out "推指向壞 commit 的 annotated tag → 放行" 0 '^check-plugin: OK'
pp "refs/tags/vlight $CBAD refs/tags/vlight $Z"
check_out "推指向壞 commit 的 lightweight tag → 放行" 0 '^check-plugin: OK'

# (d) 反方向：工作樹有未提交的半成品，被推送的 commit 是乾淨的
reset_to "$REMOTE_TIP"; edit_commit tests/x-probe.txt; CCLEAN="$(head_sha)"
printf '%s\n' "Half-done \`scripts/wip-ghost.sh\`." >> "$W/README.md"
pp "refs/heads/main $CCLEAN refs/heads/main $REMOTE_TIP"
check_out "工作樹有未提交的壞路徑、被推送的 commit 乾淨 → 放行" 0 '^check-plugin: OK'
git -C "$W" checkout -q -- README.md
git -C "$W" branch -q -D side

# (e) export-ignore 不能把壞檔案藏起來：被推送的 commit 自己的 .gitattributes（或本機 .git/info/attributes）
# 標了 export-ignore 的檔案，git archive 會略過，但安裝的人拿到的 git 內容裡有它。
# 同一個 commit 新增含壞路徑的 references/bad.md、用 export-ignore 蓋掉它、同時 bump 版本（讓版本核對也過）。
# 展開改用 read-tree + checkout-index（不套用 gitattributes）；修正前這則實得 rc=0（放行）。
reset_to "$REMOTE_TIP"
mkdir -p "$W/references"
printf '%s\n' "Bad \`scripts/ghost-export.sh\`." > "$W/references/bad.md"
printf '%s\n' "references/bad.md export-ignore" >> "$W/.gitattributes"
sed -i 's/"version":"[^"]*"/"version":"1.0.9"/' "$W/.claude-plugin/plugin.json"
git -C "$W" add -A; git -C "$W" commit -q -m "hide bad file with export-ignore"; CEXP="$(head_sha)"
pp "refs/heads/main $CEXP refs/heads/main $REMOTE_TIP"
check_out "export-ignore 藏起來的壞路徑 → 仍拒絕（不套用 gitattributes）" 1 "^${CEXP:0:7}:references/bad\\.md:[0-9]+: \\[prose-path\\].*ghost-export"
# 本機 .git/info/attributes 的 export-ignore 同樣不能生效（對照：同一個 commit 在 .gitattributes 之外也被蓋）
reset_to "$REMOTE_TIP"
mkdir -p "$W/references"
printf '%s\n' "Bad \`scripts/ghost-info.sh\`." > "$W/references/bad2.md"
sed -i 's/"version":"[^"]*"/"version":"1.0.9"/' "$W/.claude-plugin/plugin.json"
git -C "$W" add -A; git -C "$W" commit -q -m "bad file 2"; CEXP2="$(head_sha)"
printf '%s\n' "references/bad2.md export-ignore" >> "$W/.git/info/attributes"
pp "refs/heads/main $CEXP2 refs/heads/main $REMOTE_TIP"
check_out "本機 info/attributes 的 export-ignore 也不能藏壞檔案 → 拒絕" 1 "^${CEXP2:0:7}:references/bad2\\.md:[0-9]+: \\[prose-path\\].*ghost-info"
: > "$W/.git/info/attributes"

# S5：fail-closed 分支的負控組。每一條都是「無法判斷 → exit 2，不放行」；
# 每條都先有一個同形狀、但條件正常的輸入通過（前面的測試已涵蓋：改 skill 同時 bump → 放行），
# 才能說 exit 2 是被植入的條件造成的。
reset_to "$REMOTE_TIP"
pp "refs/heads/main $CN refs/heads/main $REMOTE_TIP extra-field"
check_out "stdin 一行有 5 欄 → exit 2（不是 4 欄）" 2 '4 欄'
pp "refs/heads/main zzzz refs/heads/main $REMOTE_TIP"
check_out "local sha 格式不合法 → exit 2" 2 '不是合法的 sha'
pp "refs/heads/main abc123 refs/heads/main $REMOTE_TIP"
check_out "local sha 太短 → exit 2" 2 '不是合法的 sha'
pp "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main $REMOTE_TIP"
check_out "local sha 格式正確但不在本機物件庫 → exit 2" 2 '不在本機物件庫'

# plugin.json 讀不到版本（不存在或不是合法 JSON），在被推送端與基準端各一組。內容必須有變動才會走到版本核對。
reset_to "$REMOTE_TIP"; printf '{ bad' > "$W/.claude-plugin/plugin.json"; edit_commit skills/demo/SKILL.md; CPJ1="$(head_sha)"
pp "refs/heads/main $CPJ1 refs/heads/main $REMOTE_TIP"
check_out "被推送端 plugin.json 不是合法 JSON → exit 2" 2 "讀不到 $CPJ1 的"
reset_to "$REMOTE_TIP"; git -C "$W" rm -q .claude-plugin/plugin.json; edit_commit skills/demo/SKILL.md; CPJ2="$(head_sha)"
pp "refs/heads/main $CPJ2 refs/heads/main $REMOTE_TIP"
check_out "被推送端沒有 plugin.json → exit 2" 2 "讀不到 $CPJ2 的"
git -C "$W" checkout -q "$REMOTE_TIP" -- .claude-plugin/plugin.json; bump_commit 1.0.5; CPJ3="$(head_sha)"
pp "refs/heads/main $CPJ3 refs/heads/main $CPJ2"
check_out "基準端（遠端現況）沒有 plugin.json → exit 2" 2 "讀不到 $CPJ2 的"
reset_to "$REMOTE_TIP"; printf '{ bad' > "$W/.claude-plugin/plugin.json"; git -C "$W" add -A; git -C "$W" commit -q -m "bad json"; CPJ4="$(head_sha)"
git -C "$W" checkout -q "$REMOTE_TIP" -- .claude-plugin/plugin.json; bump_commit 1.0.6; CPJ5="$(head_sha)"
pp "refs/heads/main $CPJ5 refs/heads/main $CPJ4"
check_out "基準端 plugin.json 不是合法 JSON → exit 2" 2 "讀不到 $CPJ4 的"

# read-tree／checkout-index 失敗：沒辦法取得被推送的內容就不能宣稱它通過檢查。對照組先證明同一輸入在 git 正常時放行。
reset_to "$REMOTE_TIP"; edit_commit tests/x-probe.txt; CA="$(head_sha)"
pp "refs/heads/main $CA refs/heads/main $REMOTE_TIP"
check_out "展開失敗的對照組：同一輸入 git 正常 → 放行" 0 '^check-plugin: OK'
mk_failgit "$tmp/git-fail-readtree" read-tree
CHECK_PLUGIN_GIT="$tmp/git-fail-readtree" pp "refs/heads/main $CA refs/heads/main $REMOTE_TIP"
check_out "git read-tree 失敗 → fail-closed（exit 2）" 2 'read-tree'
mk_failgit "$tmp/git-fail-checkout" checkout-index
CHECK_PLUGIN_GIT="$tmp/git-fail-checkout" pp "refs/heads/main $CA refs/heads/main $REMOTE_TIP"
check_out "git checkout-index 失敗 → fail-closed（exit 2）" 2 'checkout-index'

# 被推送的樹本身讓檢查「無法判斷」（這裡是掃描不到任何文件）：子檢查回 exit 2，外層也要回 2，不能吞成放行或當成一般問題
reset_to "$REMOTE_TIP"; git -C "$W" rm -rq skills references agents; git -C "$W" commit -q -m "gut docs"; CG="$(head_sha)"
pp "refs/heads/main $CG refs/heads/main $REMOTE_TIP"
check_out "被推送的樹掃描不到任何文件 → exit 2，輸出指名那個 commit" 2 "^${CG:0:7}:check-plugin: 環境不足" '無法判斷'

# stdin 是 CRLF（行尾 \r 不能黏在最後一欄的 sha 上）。一定要兩行以上、而且有事要做的放第一行：
# 這台的 bash 會把 $(cat) 結果最後一行的尾端 \r 一起清掉，單行輸入量不到「逐行清 \r」那一行；
# 排在前面的行才保留 \r（對 `line="${line%$'\r'}"` 做 mutation 驗證過，刪掉它這兩則會變紅）。
reset_to "$REMOTE_TIP"
OUT="$(printf 'refs/heads/main %s refs/heads/main %s\r\n(delete) %s refs/heads/gone %s\r\n' "$CA" "$REMOTE_TIP" "$Z" "$REMOTE_TIP" | bash "$CHECK" --root "$W" --pre-push origin 2>&1)"; RC=$?
check_out "stdin 是 CRLF（兩行）：第一行乾淨的 commit → 放行" 0 '^check-plugin: OK'
OUT="$(printf 'refs/heads/main %s refs/heads/main %s\r\n(delete) %s refs/heads/gone %s\r\n' "$CN" "$REMOTE_TIP" "$Z" "$REMOTE_TIP" | bash "$CHECK" --root "$W" --pre-push origin 2>&1)"; RC=$?
check_out "stdin 是 CRLF（兩行）：第一行沒 bump 的 commit → 拒絕" 1 '\[version-bump\]'


# ---- e2e：真的 git push，經過 githooks/pre-push 轉交 stdin 與離開碼 ----
mk_repo e2e 1
E0="$(head_sha)"
git -C "$W" config core.hooksPath githooks
edit_commit skills/demo/SKILL.md
OUT="$(git -C "$W" push origin main 2>&1)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'version-bump' && [ "$(git -C "$tmp/e2e/remote.git" rev-parse main)" = "$E0" ]; then ok
else ng "e2e：沒 bump 的 push 被 githooks/pre-push 擋下且遠端沒變" "rc=$RC；輸出：$(printf '%s' "$OUT" | head -c 400)"; fi
bump_commit 1.0.9
OUT="$(git -C "$W" push origin main 2>&1)"; RC=$?
if [ "$RC" = 0 ] && [ "$(git -C "$tmp/e2e/remote.git" rev-parse main)" = "$(head_sha)" ]; then ok
else ng "e2e：bump 後的 push 放行且遠端更新" "rc=$RC；輸出：$(printf '%s' "$OUT" | head -c 400)"; fi
# 被推送的是 side 上的壞 commit（版本有 bump），HEAD 留在乾淨的 main：舊實作看工作樹，會放行
E1="$(git -C "$tmp/e2e/remote.git" rev-parse main)"
git -C "$W" checkout -q -b side
printf '%s\n' "Bad \`scripts/ghost.sh\`." >> "$W/README.md"
bump_commit 1.0.10
git -C "$W" checkout -q main
OUT="$(git -C "$W" push origin side:main 2>&1)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'prose-path' && [ "$(git -C "$tmp/e2e/remote.git" rev-parse main)" = "$E1" ]; then ok
else ng "e2e：git push origin side:main 的壞 commit 被擋下且遠端沒變" "rc=$RC；輸出：$(printf '%s' "$OUT" | head -c 400)"; fi
# hook 要把 git 傳的 remote 名稱（$1）轉交給腳本：推到一個空的、名叫 other 的 remote（新建 main），
# 比較基準就該找 refs/remotes/other/main（沒有 → 擋下並指名它）；寫死 origin 的實作會找到 origin/main 而放行
git -C "$W" branch -q -D side
git init -q --bare -b main "$tmp/e2e/other.git"
git -C "$W" remote add other "$tmp/e2e/other.git"
OUT="$(git -C "$W" push other main 2>&1)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'refs/remotes/other/main' && [ -z "$(git -C "$tmp/e2e/other.git" for-each-ref refs/heads)" ]; then ok
else ng "e2e：hook 轉交 remote 名稱（push 到 other 的新 main 以 refs/remotes/other/main 求基準）" "rc=$RC；輸出：$(printf '%s' "$OUT" | head -c 400)"; fi

# ---------------------------------------------------------------------
echo
echo "check-plugin.test: $pass passed, $fail failed"
[ "$fail" = 0 ]
