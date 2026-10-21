# Codex 轉接（1.44.0）

Codex manifest 與 Claude manifest 分開；Claude hooks 沒有 host 參數時維持原協議。
Codex command 明確帶 `--host codex`，不可從 stdin 欄位猜宿主。

## 啟動與信任

透過官方 `codex plugin marketplace add` 與 `codex plugin add` 安裝，並在新 session
用 `/hooks` 審查、信任當前 hook 定義。確認來源是 Codex manifest、7 個 handlers 都有
Codex host 參數；安裝成功不等於 hooks 已執行。hook host 需要 Python、Bash、jq 與 GNU timeout
（本機由 Git Bash 提供 Bash/timeout）。

本機 0.163.0 實測：`--ignore-user-config` 會略過本次已安裝 hooks，即使另外用
`-c` 啟用 plugin 也一樣。受 eng-flow 保護的編輯工作 session 必須正常載入設定；
既有唯讀 Codex review 腳本用該旗標隔離桌面版設定，不能直接用來執行受保護的編輯工作。
關閉 code-mode host 不會修復這個問題，反而讓目前模型的工具無法執行。

未信任、停用 hooks/plugin、或 hook interpreter 本身無法啟動，都是宿主層限制；
plugin 無法替宿主強制執行自己。轉接 wrapper 已將 Python 啟動失敗轉為 exit 2，
adapter 內的依賴、解析、子程序錯誤則回支援的 deny，不輸出未受支援的 ask。
整次 adapter（含多檔 patch）由 GNU timeout 限制為 24 秒，再留 1 秒強制終止寬限，
早於宿主的 30 秒取消；缺 timeout 或逾時均回 exit 2，不把逐檔上限誤當總上限。

## 長期安裝來源與更新

repo 自帶 `.agents/plugins/marketplace.json`，marketplace 名稱為 `eng-flow`，
唯一 plugin 的 local source 為 `./`，指向 repo 根目錄。本機 0.163.0 已實測可安裝。
正式來源是長期保留的普通 clone `~/.codex/plugin-sources/eng-flow`，不是 feature worktree
或 symlink；origin 為 `https://github.com/ench0812/eng-flow.git`。
這樣不必改動 Claude 正在載入的 marketplace 工作樹，也能獨立更新 Codex cache。

首次註冊與安裝（修改設定前先備份 `~/.codex/config.toml`，只用官方指令）：

```powershell
codex plugin marketplace add C:/Users/markh/.codex/plugin-sources/eng-flow --json
codex plugin add eng-flow@eng-flow --json
```

交付期間此 clone 停在報告列出的本機待審 commit；尚未合併發佈前不要切回舊版 main。
本次合併發佈後，以及之後每次 eng-flow 發版，都執行以下指令：

```powershell
git -C C:/Users/markh/.codex/plugin-sources/eng-flow fetch origin main
git -C C:/Users/markh/.codex/plugin-sources/eng-flow switch --detach origin/main
codex plugin add eng-flow@eng-flow --json
```

local marketplace 的 git 來源更新由前兩行完成；`plugin add` 會重新安裝並更新 cache，
不是只做第一次安裝。`marketplace upgrade` 是 Git 類型 marketplace snapshot 的指令，
不能代替這個 local clone 的 fetch。若 clone 有未提交變更，先查明來源，不要強制覆寫。
安裝前後保存 config 備份與 diff，再以 Git Bash 執行以下位元組比對，任何缺檔或差異均失敗：

```bash
python - <<'PY'
import json, subprocess
from pathlib import Path
source = Path.home() / '.codex/plugin-sources/eng-flow'
version = json.loads((source / '.codex-plugin/plugin.json').read_bytes())['version']
cache = Path.home() / '.codex/plugins/cache/eng-flow/eng-flow' / version
raw = subprocess.check_output(['git', '-C', str(source), 'ls-files', '-z'])
files = [name.decode('utf-8') for name in raw.split(b'\0') if name]
assert files, '來源清單是空的，不能宣稱通過'
bad = [name for name in files if not (cache/name).is_file()
       or (source/name).read_bytes() != (cache/name).read_bytes()]
assert not bad, 'cache 與來源不同：' + repr(bad)
print(f'逐位元組相同：{len(files)} 個追蹤檔案；version={version}')
PY
```

重啟 Codex，在 `/hooks` 審查並信任新來源或新定義，再用無 remote 的暫存 repo
確認破壞性 git 指令被 hook 擋下。來源名稱或路徑改變可能需要重新信任；
不要用修改 trust 狀態檔或 `--ignore-user-config` 取代此步驟。

## 掃描與已知範圍

Codex 的 Bash 與 apply_patch 都從 tool_input.command 讀取。patch 逐檔只掃新增行，
context、刪除行不會提供 ignore 豁免；一個檔案的 ignore 不影響其他檔案。
新增內容即使在文件、測試、fixture 路徑也掃描；Claude 原有低風險路徑豁免保持不變。
既有 secret/crypto regex 與 gitleaks 行為仍由共用 scanner 決定，不宣稱可識別所有 secrets。
ignore 維持既有「同一份送掃內容中有標記即豁免」的語意；Codex 的送掃單位是一個檔案的新增行。

shell 寫檔（例如 PowerShell `Set-Content` 或 `>` 重導向）不會觸發 iso-scan-write；
`node_repl` 等可執行任意程式碼的 MCP 工具也不會命中 Bash matcher。
這和 Claude 端 Bash 寫檔不掃的既有限制相同：這些 hooks 是護欄，並非完整安全邊界。
legacy scanner 只要輸出 stderr，Codex adapter 就會拒絕該次操作；未來相依工具若新增
警告訊息，也可能造成可用性影響。這裡刻意維持 fail-closed，不能將警告靜默忽略。

Stop 將 Codex transcript 的已知 cwd 與原生 function_call 的 workdir/cwd 轉成唯讀範圍，
不將 Codex tool records 假裝成 Claude Write/Edit 寫入授權。無法解析 code-mode JavaScript
中的任意路徑，該情況只涵蓋已知 cwd；跨工作目錄範圍仍有這個限制。
Stop 提醒會用 Codex 支援的 decision:block/reason 續一回合，stop_hook_active 時不再形成迴圈。
本任務「只 commit、不 push」優先於原 guard 的一般推送建議。

## 記憶與全域規則

規則入口是 ~/.claude/scripts/generate-codex-agents.py，支援 --check；
只從來源第一級標題明列抽取，不截斷，保留至少 8 KiB 專案規則空間。
產生器在 claude-config 的獨立分支，不在本 plugin 內。

本機 sandbox memory search 無法啟動既有 Python；localhost 的 PG/Ollama port 可連。
針對當次 memory search 逐次核准在 sandbox 外執行即可命中已知記憶，不需修改設定檔。
Codex memories 維持啟用。詳細命令與原始輸出見本次 handoff 報告。

Claude 與 Codex manifest 共用版本 1.44.0；本次審查 R2 只放寬 Claude manifest 的
version 欄位。`scripts/check-plugin.sh` 的 version-sync 規則會核對兩者相同，
同時適用工作樹與 pre-push 指定的 main tip；無法讀取版本時拒絕判定通過。
