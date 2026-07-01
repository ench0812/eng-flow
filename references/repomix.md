# repomix — codebase 上下文打包

把整個 repo（或子集）打包成單一 AI 友善檔（XML/Markdown/JSON），含目錄樹、token 計數、可選 Tree-sitter 壓縮。全域已裝（CLI `repomix`，v≥1.16）；全域預設設定在 `%LOCALAPPDATA%\Repomix\repomix.config.json`（security check 已開、已 ignore secrets/keys）。

## 何時用

把「一批既有程式碼」當上下文餵給 LLM / subagent 時用它，勝過手動貼多檔或讓 subagent 逐檔盲讀：

- 探索不熟 / 大型 codebase（`mao-brainstorm` 探索、`mao-plan` 建立全庫理解）
- 打包 diff + 周邊上下文給 reviewer subagent（`mao-review`）
- 給除錯用的「最近改了什麼」上下文（`mao-debug` regression 溯源）

**不要用在**：單檔小改、已知精確位置的 targeted 編輯——直接讀那個檔即可，別為了一行改動打包整庫。

## 常用指令

```bash
repomix                                  # 打包當前 repo → repomix-output.xml（套全域預設）
repomix --include "src/auth/**"          # 只打包相關子集（可重複 --include，縮小 token）
repomix --compress                       # Tree-sitter 壓縮，大型 repo 省 ~70% token
repomix --include-diffs                  # 附 git diff（review 改動用）
repomix --include-logs                   # 附最近 commit log（regression 溯源用）
repomix --remote <owner/repo>            # 打包遠端公開 repo（本機 clone）
repomix --stdout                         # 輸出到 stdout（接管線 / 直接貼進 prompt）
repomix --token-count-tree               # 各檔 token 分佈，抓體積熱點
```

**給 subagent 時**：先打包成檔，把檔路徑（或 `--stdout` 內容）放進 `agent()` 的 prompt，勝過讓 agent 逐檔 read——省 round-trip、上下文更完整。

## ISO 27001 / 隱私鐵律（與 `mao-comply` 紅線一致）

- **只用 CLI，絕不用 repomix.com 網頁版**處理 proprietary / kiosk / payment 程式碼（網頁版會暫存上傳、含 GA/Cloudflare，屬不同信任邊界）。
- 打包輸出常會送進雲端 LLM = **資料離開邊界**。送出前**人工掃一眼** output。
- 內建 Secretlint 會把命中密鑰的檔**排除**在 output 外，全域設定也 ignore 了 `*.pem`/`*.key`/`.env*`/`*.p12` 等——但這是**安全網、非審查替代品**（會白名單已知範例金鑰，未必攔到所有 secret；且 diff/log 內容只警告不排除）。
- 別把 `--remote-branch` 等 CLI 參數餵不可信輸入（webhook payload、PR 標題）——歷史上有參數注入 RCE（CVE-2026-49987，≥1.14.1 已修）。
