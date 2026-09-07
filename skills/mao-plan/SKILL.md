---
name: mao-plan
description: 任務分解 + 實作計劃撰寫。有 spec 需要拆成可執行步驟時使用。
---

# Task Breakdown & Plan Writing

Write comprehensive implementation plans assuming the engineer has zero codebase context. Every step must contain actual code — no placeholders.

**Length calibration:** Match the plan's length to what it needs. The code blocks *are* the specification — keep them complete and literal. The prose around them is not: no per-task architecture recap, no restating in words what a code block already shows, no closing summary. State each fact once, in the task that owns it.

## Plan Document Format

```markdown
# [Feature] Implementation Plan

> **For agentic workers:** Use eng-flow:mao-execute to implement this plan task-by-task.

**Goal:** [One sentence]
**Architecture:** [2-3 sentences]
**Tech Stack:** [Key technologies]
---
```

## Task Structure

Each task:
````markdown
### Task N: [Title]

**Files:**
- Create: `exact/path/to/file.ext`
- Modify: `exact/path/to/existing.ext:123-145`
- Test: `tests/exact/path/to/test.ext`

- [ ] **Step 1: Write failing test**
```language
// complete test code here
```

- [ ] **Step 2: Run test, verify it fails**
Run: `exact command`
Expected: FAIL with "specific message"

- [ ] **Step 3: Write minimal implementation**
```language
// complete implementation code here
```

- [ ] **Step 4: Run test, verify it passes**
- [ ] **Step 5: Commit**
````

Names and signatures introduced by one task must match verbatim in every later task that consumes them.

## Draft Stage — Fable 5.1 起草骨架

**第一輪的結構由 Fable 5.1 起草，之後它就退出。** 後續的補完、codex 共議、收斂與交付一律由主線模型（Opus）負責——Fable **只在這一步出現一次**，不參與任何後續輪次，也不看 codex 的回覆。

**為什麼是這一步**：切片邊界與依賴順序**沒有快速的驗證迴路**——錯了不會當場報錯，要等實作到一半、或跨服務兩側都蓋完才浮現，而那時的返工成本是本 skill 記錄的 48.5%。判準與成本說明的完整版在 `references/model-routing.md` 的 D 層段落，此處不重述。

**Dispatch**（在 repomix 打包完、你已讀過相關模組之後）:

```
Agent(
  subagent_type: "general-purpose",
  model: "fable",
  description: "Draft plan skeleton",
  prompt: <見下方 brief 規格>
)
```

**Brief 給目標，不要給模板。** D 層的 brief 規則與其他 tier 相反——Fable 5.1 對過度規定的 prompt 反而產出更差，所以**不要**寫欄位模板、逐步指示或行數上限（其他 tier 的 150 行限制是為了壓冷啟成本，這裡不適用）。給它：

- spec 的**路徑**（讓它自己讀，不要貼內容）、要動的模組路徑、已定案的約束、明確的 out-of-scope
- 目標一句話：**把這份 spec 拆成一組任務與它們的依賴關係，讓零上下文的執行者不必回頭問就能開工、也讓接手的主線一眼看得出哪一片切錯了**
  （刻意**不說「序列」**——那個詞預設線性，但垂直切片之間常有可平行的分支，用它會讓起草者不去標出併行機會）
- 判準：本 skill 的 Slice Vertically 與 Size Tasks 兩節（給節名讓它讀本檔，不要複製過去）
- **界線**：產出會由主線補完程式碼，所以**不寫函式本體、測試碼、或任何可執行的實作**；但**型別與函式簽章要寫**——那是介面定案，屬於判斷而不是打字，而且主線接手時本來就要拿它當起點（見下方接手第 2 點）

**自我檢查用的完整性清單**——不是文件結構，**順序也不代表章節順序**，格式由你接手時整理：

- 每個 task 動哪些檔案？相依於哪個 task、為什麼？
- 怎麼驗證它完成了——「誰送什麼 → 誰收到什麼 → 哪裡看得到結果」？
- 這片的風險在哪：跨服務接縫？既有行為？不確定的假設？
- 整體的依賴圖長什麼樣，為什麼這樣切而不是那樣切？
- **哪些片可以併行、併行的前提是什麼**（例如共用的 wire 契約要先定案）？這直接餵給主線接手後的派工顆粒度判斷。
- 哪些東西現在**還定不下來**（照 Fog Rule 的判準：問題能不能精確陳述），該進 `## Not yet specified`？

**你（Opus）接手後做三件事，順序不可調**：
1. **先審骨架再補程式碼**——切片邊界錯了的話，補進去的程式碼全部要重寫。用 `## Planning Process` 的判準檢查：每一片寫不寫得出「誰送什麼 → 誰收到什麼 → 哪裡看得到結果」？有沒有哪片要等另一片才驗得起來（那條界線就切錯了）？
2. **補完每個 task 的完整測試碼與實作碼**，遵守 `## No Placeholders — Ever`。骨架裡的檔案路徑與簽章是你的起點，不是不可改的定案——發現它引用了不存在的檔或簽章就改掉並記一句。
3. **存檔後才進 Codex Co-Design Loop**。那個 loop 是 Opus 與 codex 兩方，Fable 不在裡面。

**兩個硬限制**（詳見 `references/model-routing.md`）：Agent tool 沒有 `effort` 參數，所以這次派工的 effort 繼承 session；Fable 5.1 在 ZDR 組織不可用，會回 400。

**Fable 不可用時**（未開通、ZDR、派工失敗、使用者不要）：直接由 Opus 自己走完 `## Planning Process`，在交付時講一句「本次未經 Fable 起草」。這一步是加速器，不是必要條件——不要因為它不可用就停下來問。

## Planning Process

> 這三步的**初稿**來自上面的 Draft Stage；你的職責是審核、修正、補完，不是重跑一遍。Fable 未參與時才由你從頭做。

> 零上下文規劃前，先 `repomix --include "<要動的模組 glob>"` 打包相關模組，建立全庫理解再拆任務——避免 plan 引用不存在的檔/簽章。見 `references/repomix.md`

### 1. Map Dependencies
Identify what depends on what. Implementation order follows the graph bottom-up.

### 2. Slice Vertically
Build complete feature paths, not horizontal layers.
- **Bad:** all DB → all API → all UI → connect everything
- **Good:** feature A (DB+API+UI) → feature B (DB+API+UI)

**多服務／多 repo 時，「repo」就是層——不要按 repo 切波次**（2026-08-07 加，實測代價見下）：
- **Bad:** W1=契約定案 → W2=整個 backend → W3=整個 gateway → W4=整個前端 → W5=模擬器 → W6=收尾
- **Good:** 片1=「行為 X 端到端」(backend+gateway+驗證) → 片2=「行為 Y 端到端」 → …

按 repo 切等同水平切層，而且**後果比單庫分層更嚴重**：服務之間的接縫（wire 形狀、快照欄位、部署時序）
只有在兩側都蓋完之後才驗得到，此時其他服務已經疊在上面，修一個接縫缺陷要動全部。

> **實測（2026-08-07 單次量測，非持續更新）**：一個五 repo 的識別碼改造照 W1~W6 按 repo 切，11 個 workflow 共 675 分鐘，
> **實作 44%、返工 48.5%**，而返工幾乎都是**同一類接縫缺陷的五個實例**——每一輪都只修掉當下那個實例。
> 四個 agent 全綠、單 repo 複驗也全綠，唯一抓到最後一個實例的是跨服務的契約測試。

**判準（切完自我檢查）**：每一片都要寫得出「誰送什麼 → 誰收到什麼 → 哪裡看得到結果」。
**若某片的產出「要等另一片才驗得起來」，那條界線就切錯了。**
碰到服務接縫的片，**片末就要跑跨接縫驗證**，不可留到收尾。

**Wide refactor exception:** Mechanical but codebase-wide changes (rename a shared column, retype a shared symbol) can't be sliced vertically — no slice can go green on its own. Split into three task types instead:
- **Expand** — old and new forms coexist, no caller breaks. Stays a single sequential task.
- **Migrate** — split by blast radius (per package/directory), one task per batch, depends on expand. Batches touch disjoint files, so each goes green independently and already qualifies as parallel under mao-execute's existing independent-files rule — no extra tagging needed. (Doesn't conflict with mao-execute's "database migrations must be sequential" rule — that covers the expand step's schema change itself, not these caller-side migration batches.)
- **Contract** — remove the old form, depends on all migrate batches finishing.
- If batches can't each go green independently, fall back to a shared integration branch with one final integrate-and-verify task gating all of them.

### 3. Size Tasks

| Size | Files | Scope |
|------|-------|-------|
| XS | 1 | Single function or config |
| S | 1-2 | One component or endpoint |
| M | 3-5 | One feature slice |
| L | 5-8 | Multi-component — consider splitting |
| XL | 8+ | **Must split further** |

**Break down further when:** >2 hours of work, can't describe acceptance in ≤3 bullets, touches 2+ independent subsystems, title contains "and".

**plan／spec 本身的大小也要控制**（2026-08-07 加）：一個功能一份大 spec 會隨裁定累積而膨脹——
實例是一份 spec 長到千行、裁定累積到 D1~D16，**後期裁定還推翻前期段落**，讀者要自己分辨哪些還有效；
而每個執行 agent 每輪都整份讀，token 大量花在重複閱讀。
- **切片後每片一份小 spec**，裁定寫在它所屬那一片裡，不要全部堆進同一份。
- 交給執行 agent 的 brief **控制在 150 行內**，大 spec 只指名要讀的小節。
- **不要把上一輪的完整回報整段貼進下一輪 brief**——回報是給人判斷用的，不是給下一個 agent 當輸入。
- 若某份 spec 已經長到必須靠「這一段已被 Dn 推翻」來閱讀，那是**應該切開而沒切**的訊號。

## No Placeholders — Ever

These are plan failures:
- "TBD", "TODO", "implement later"
- "Add appropriate error handling"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code)
- Steps describing what to do without showing how

## Fog Rule

No Placeholders bans guessing, but a task can legitimately be blocked on a decision that isn't made yet. The test is whether the question **can be stated precisely** right now — not whether it can be answered right now, and not whether you'd simply rather not decide yet.

- Can't state it precisely (e.g. blocked on a third-party API result, load-test numbers) → don't invent a task for it — that's worse than a placeholder, it burns a full implement→review cycle on a guess
- Add a `## Not yet specified` section at the end of the plan: list what's unresolved and what decision it's blocked on
- mao-execute must not dispatch against that section — it should prompt to return to mao-brainstorm instead

Save to: `docs/plans/YYYY-MM-DD-<feature>.md`

Start the plan with a `Spec:` line citing the source design doc path (`docs/specs/...-design.md`), if one exists — downstream spec reviews need it to locate the Out of Scope section.

## Codex Co-Design Loop

The plan handed off must be the **converged result of Claude and Codex co-planning**. Once the plan file is saved, run the same loop protocol as mao-brainstorm's Co-Design Loop:

1. **Consult**:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --doc docs/plans/YYYY-MM-DD-<feature>.md --kind plan --severity <level>
   ```
   `<level>` = your risk assessment of what this plan implements, set once for all rounds (cross-system / security-sensitive / data migration / irreversible → `critical`; normal feature → `required`; small local change → `optional`) — your input, never re-triaged; over-estimate when unsure. The plan prompt directs Codex to follow the leading `Spec:` line and cross-check coverage against the design doc — keep that line accurate.
2. **Triage** each item: adopt (revise the plan) / reject (record why) / user call. Never silently drop.
3. **Log** the round in `## Cross-Check Log` at the very end of the plan, after `## Not yet specified` if present (same table format as brainstorm). The log is process record — mao-execute ignores it.
4. **Converge**: **no consultation cap** — same continue/stop rules as mao-brainstorm's Converge step. Codex ends each reply with `收斂問句:<one question>` (or `無`); record it plus your 續輪/收斂 call under the round's table. Continue only on an adopted Critical/Required change Codex hasn't seen, or a 收斂問句 that is substantive (answering it would change this plan), in scope, and not already dispositioned. Everything else stops the loop — scope-expanding questions become *user call* at handoff, and every extra round must shrink the open-question set (the script prints a non-blocking `警示` once the log holds ≥6 `### Round` entries: force-converge).

If the script answers `[codex-review] RATE_LIMITED:` the consultation did not happen: do not retry it, do not log a `### Round` for it, and hand off the plan as it stands, saying so in one line. A later flow calls codex again as normal.

**Input too large.** If the script answers `[codex-review] FAILED: 輸入過長,未送出`, the consultation did **not** happen and this is *not* a quota problem — the document exceeds codex's input limit, so it will never be reviewed until it is split. Unlike RATE_LIMITED you must not just carry on. Note this is **doc mode**: `--base` is not available here (`--doc` and `--base` are mutually exclusive and the script exits 2) — split the document into sections and consult on each, which is what the script's own message says. Treating it as reviewed is a false pass.

**Cost discipline (v1.17.0).** The script sends the document with the `## Cross-Check Log` **trimmed to its last round only** (earlier rounds still count as settled — the prompt says so). Do not paste earlier rounds back into the body to compensate; that was the exact behaviour that grew one plan's payload from 4,929 to 26,758 characters across 12 rounds. Session resume is **off by default** (measured server-side cache window is only tens of seconds — see `references/model-routing.md`). Identical content twice in a row is refused (`SKIP: 送出內容與上一輪...完全相同`): apply the round's fixes first. Per-call token usage and cache hit rate land in `$CODEX_REVIEW_LOG`; report with `scripts/codex-usage.sh`.

If codex is absent/unauthorized the script self-skips — relay in one line and hand off the solo plan.

## Execution Handoff

After the co-design loop converges — summarize it first (rounds, adopted/rejected counts, each *user call* item with both positions; the user arbitrates) — then offer:
1. **Subagent-Driven** (recommended) — `eng-flow:mao-execute`, fresh subagent per task. It authors a Workflow to orchestrate the tasks whenever the Workflow tool is available — review the generated script before approving on large plans.
   - To run the whole plan unattended, hand the user a `/goal` condition to paste. `/goal` is user-invocable only (Claude cannot set it), and needs auto mode to actually run without interruption. The condition must be **provable from the transcript** — the evaluator does not read files or run commands — and must keep an escape hatch and a turn cap. Template:
     `/goal 依序實作 docs/plans/<file>.md 的每個 task，每完成一個就貼出該 task 驗收指令的實際輸出；全部驗收指令都 exit 0、且最終整合 review 貼出 full test suite 通過的輸出，才算達成。遇到 BLOCKED、「## Not yet specified」、或需要我裁決的項目就停下來問我，或跑滿 30 turns 停。`
2. **Inline** — execute sequentially in current session
