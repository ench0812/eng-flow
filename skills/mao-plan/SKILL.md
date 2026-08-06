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

## Planning Process

> 零上下文規劃前，先 `repomix --include "<要動的模組 glob>"` 打包相關模組，建立全庫理解再拆任務——避免 plan 引用不存在的檔/簽章。見 `references/repomix.md`

### 1. Map Dependencies
Identify what depends on what. Implementation order follows the graph bottom-up.

### 2. Slice Vertically
Build complete feature paths, not horizontal layers.
- **Bad:** all DB → all API → all UI → connect everything
- **Good:** feature A (DB+API+UI) → feature B (DB+API+UI)

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

If codex is absent/unauthorized the script self-skips — relay in one line and hand off the solo plan.

## Execution Handoff

After the co-design loop converges — summarize it first (rounds, adopted/rejected counts, each *user call* item with both positions; the user arbitrates) — then offer:
1. **Subagent-Driven** (recommended) — `eng-flow:mao-execute`, fresh subagent per task. It authors a Workflow to orchestrate the tasks whenever the Workflow tool is available — review the generated script before approving on large plans.
   - To run the whole plan unattended, hand the user a `/goal` condition to paste. `/goal` is user-invocable only (Claude cannot set it), and needs auto mode to actually run without interruption. The condition must be **provable from the transcript** — the evaluator does not read files or run commands — and must keep an escape hatch and a turn cap. Template:
     `/goal 依序實作 docs/plans/<file>.md 的每個 task，每完成一個就貼出該 task 驗收指令的實際輸出；全部驗收指令都 exit 0、且最終整合 review 貼出 full test suite 通過的輸出，才算達成。遇到 BLOCKED、「## Not yet specified」、或需要我裁決的項目就停下來問我，或跑滿 30 turns 停。`
2. **Inline** — execute sequentially in current session
