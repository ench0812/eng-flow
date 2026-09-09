---
name: mao-issue
description: 從看板領一張 issue 開工。把 issue 從「待處理」搬到「進行中」時使用——先讓 codex 對 issue 本身提修正建議並收斂，才開始實作。
---

# Issue Intake

**觸發時機：把一張 issue 從「待處理」搬到「進行中」的那一刻。** 不是實作到一半、也不是實作完，就是搬欄位那一刻。

## 為什麼審的是 issue 而不是 code

既有的 codex 複查全部發生在**寫完之後**（`mao-review` 的 diff 模式、`mao-execute` 的兩階段 review），它們能抓的是「這段程式碼有沒有做對」。**抓不到「這件事本身要求錯了」**——需求寫錯時，review 只會確認你精準地實作了一個錯的東西，而且全綠。

那類錯誤的代價是一整輪實作。把第二意見前移到開工前，代價是一次諮詢。

## 流程

```
領取 issue → dump 成檔 → codex doc 模式共議 → 逐項處置並寫回 issue
   → 更新看板為「進行中」 → 才進 mao-plan / mao-execute
```

### 1. Dump

把 issue 全文（含後續留言，那裡常有推翻正文的裁定）寫成一個檔案：

```bash
gh issue view <N> -R <owner/repo> --json number,title,body,comments \
  --jq '"# #\(.number) \(.title)\n\n\(.body)\n\n" + ([.comments[] | "\n---\n\n## 留言（\(.createdAt[0:10])）\n\n\(.body)"] | join("\n"))' \
  > <scratchpad>/issue-<N>.md
```

**留言不可省**：issue 正文常常已被後來的留言推翻（本工作區的既有慣例就是把裁定寫在留言裡）。只送正文會讓 codex 針對一份過期的需求提建議。

### 2. 共議

```bash
bash <plugin>/scripts/codex-review.sh --severity required --doc <scratchpad>/issue-<N>.md --kind spec
```

**`--kind` 用 `spec`**（腳本只接受 `spec|plan`）。issue 在這裡的角色就是 design spec，而 spec 那組的檢查面向逐條對得上要問的事：需求完整性、內部一致性、模糊語義、技術可行性、安全與資料、可測試性、Out of Scope。

嚴重度預設 `required`。issue 涉及認證／授權／資料完整性時用 `critical`。

### 3. 處置

每一項都要有結論，三種之一：**採納**（改 issue）／**不採納**（寫理由）／**移出範圍**（另開 issue）。

**把處置寫回 issue**，不要只留在對話裡——下一個讀這張 issue 的人（可能是幾週後的你、也可能是 subagent）看到的是 GitHub 上那份，不是這次的 session。採納的修正直接改 body 或補一則留言；`gh issue comment --body-file`（Windows 的 heredoc 對多 byte UTF-8 會截斷，中文一律走檔案）。

**續輪判斷沿用既有的收斂問句機制**（見 CLAUDE.md「Codex 交叉複查」段）：**停是預設**。只有在「本輪採納了 codex 沒看過的 Critical/Required 修改」或「問句實質、在範圍內、且未處置過」時才續。

多輪時把處置紀錄寫成 `## Cross-Check Log` ＋ `### Round N` 段落放在 dump 檔尾端——腳本的 `trim_crosscheck_log` 認這兩個標題，只送最後一輪。**沒有這個結構的話每輪都重送全文**，payload 會一路長大。

### 4. 才開始做

處置完成後才更新看板欄位、才進 `mao-plan`（需要拆解時）或直接 `mao-execute`。

## 三種「沒問成」要分開處置

- `完成(…)` → 真的問到了。
- `RATE_LIMITED`（exit 0）→ 額度擋下。**不重試、不計輪次**，直接繼續開工；下次照常再叫。
- `FAILED`（exit 1）→ **複查根本沒發生**。不得視為已複查、不得據此放行；排除原因後重跑，或明講這一輪沒做成。

## 這條流程不做的事

**不改變「卡片狀態以 GitHub 為準」的既有裁定**——本 skill 只規定「搬到進行中之前要先做什麼」，不規定看板怎麼同步。

**不對每一張 issue 都適用。** 純機械性的 issue（改一個字串、調一個常數、補一張截圖）跑這一輪的收益接近零，直接做。判準與派工下限同一條：**這張 issue 有沒有「可能整件事的方向就錯了」的空間**——有設計決策、有跨 repo 接縫、有安全/資料面、或驗收條件寫得出兩種解讀的，才值得。判不準時就跑，一次諮詢比一輪返工便宜。
