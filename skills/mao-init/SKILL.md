---
name: mao-init
description: 工作流分發器。映射任務類型到對應技能，設定核心行為準則。每次對話開始時自動注入。
---

<SUBAGENT-STOP>
If you are executing a specific task with defined inputs and expected outputs (rather than responding to a user request) — whether dispatched via Agent tool or a Workflow agent() — skip this skill entirely.
</SUBAGENT-STOP>

# eng-flow 工作流分發器

有 1% 機會適用的 skill 就必須調用。用 Skill tool 以 `eng-flow:<name>` 格式調用。

## 任務→技能映射

| 使用者意圖 | Skill | 說明 |
|-----------|-------|------|
| 模糊想法、需求不清、「我想做…」 | `mao-brainstorm` | 設計先行，不寫 code |
| 有 spec，需要拆任務 | `mao-plan` | 任務分解 + plan 撰寫 |
| 有 plan，開始實作 | `mao-execute` | Subagent 逐 task 執行 |
| Bug、測試失敗、非預期行為 | `mao-debug` | 根因調查優先 |
| 新邏輯、修 bug 的實作 | `mao-tdd` | Red-Green-Refactor |
| 合併前檢查、PR review | `mao-review` | 五軸審查 |
| 分支完成、準備合併/發布 | `mao-ship` | 驗證 + 合併流程 |
| 輸入驗證、認證、資料安全 | `mao-secure` | 安全加固 |
| ISO 27001 合規查核、稽核、部署合規 gate | `mao-comply` | ISO 27001 自檢 + 專案 gate |
| 效能問題、響應慢 | `mao-optimize` | 量測優先 |

## 核心行為準則

1. **假設先表面化** — 非 trivial 工作前，列出你的假設讓使用者確認
2. **困惑就停下問** — 不猜測，不假裝理解
3. **有問題就推回** — 方案有明確缺陷時直說，不迎合
4. **只動要求的範圍** — scope discipline，不加料
5. **驗證才算完成** — 跑完指令、看到輸出，才能宣稱結果

## Skill 類型

**剛性** (mao-tdd, mao-debug): 嚴格遵守，不因「太簡單」跳過。
**柔性** (mao-brainstorm, mao-plan, mao-review): 依情境調整深度。
