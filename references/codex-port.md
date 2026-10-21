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

## 掃描與已知範圍

Codex 的 Bash 與 apply_patch 都從 tool_input.command 讀取。patch 逐檔只掃新增行，
context、刪除行不會提供 ignore 豁免；一個檔案的 ignore 不影響其他檔案。
新增內容即使在文件、測試、fixture 路徑也掃描；Claude 原有低風險路徑豁免保持不變。
既有 secret/crypto regex 與 gitleaks 行為仍由共用 scanner 決定，不宣稱可識別所有 secrets。
ignore 維持既有「同一份送掃內容中有標記即豁免」的語意；Codex 的送掃單位是一個檔案的新增行。

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

Claude manifest 仍為 1.43.0，因本任務明確禁止修改該目錄。Codex manifest 為 1.44.0；
既有 main pre-push 仍從 Claude manifest 讀版本，合併前須由 Claude 審查並解決此版本約束。
