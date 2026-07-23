---
name: mao-plan
description: 任務分解 + 實作計劃撰寫。有 spec 需要拆成可執行步驟時使用。
---

# Task Breakdown & Plan Writing

Write comprehensive implementation plans assuming the engineer has zero codebase context. Every step must contain actual code — no placeholders.

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

## Self-Review

After writing, check:
1. **Spec coverage** — every requirement has a task?
2. **Placeholder scan** — any vague steps?
3. **Type consistency** — names/signatures match across tasks?
4. **Undecided decisions** — any task built on a decision that isn't made yet?

Save to: `docs/plans/YYYY-MM-DD-<feature>.md`

Start the plan with a `Spec:` line citing the source design doc path (`docs/specs/...-design.md`), if one exists — downstream spec reviews need it to locate the Out of Scope section.

## Codex Co-Design Loop

The plan handed off must be the **converged result of Claude and Codex co-planning**. After the Self-Review passes and the plan file is saved, run the same loop protocol as mao-brainstorm's Co-Design Loop:

1. **Consult**:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --doc docs/plans/YYYY-MM-DD-<feature>.md --kind plan --severity <level>
   ```
   `<level>` = your risk assessment of what this plan implements, set once for all rounds (cross-system / security-sensitive / data migration / irreversible → `critical`; normal feature → `required`; small local change → `optional`) — your input, never re-triaged; over-estimate when unsure. The plan prompt directs Codex to follow the leading `Spec:` line and cross-check coverage against the design doc — keep that line accurate.
2. **Triage** each item: adopt (revise the plan) / reject (record why) / user call. Never silently drop.
3. **Log** the round in `## Cross-Check Log` at the very end of the plan, after `## Not yet specified` if present (same table format as brainstorm). The log is process record — mao-execute ignores it.
4. **Converge**: repeat only if the round adopted any Critical/Required change; stop on「無重大補充」, nothing above Optional adopted, or 3 rounds (**hard cap**, script-enforced via the Cross-Check Log — a 4th consultation gets `[codex-review] STOP:`). At the cap Claude takes over solo: remaining disagreements go to the user at handoff, no further codex calls in this flow.

If codex is absent/unauthorized the script self-skips — relay in one line and hand off the solo plan.

## Execution Handoff

After the co-design loop converges — summarize it first (rounds, adopted/rejected counts, each *user call* item with both positions; the user arbitrates) — then offer:
1. **Subagent-Driven** (recommended) — `eng-flow:mao-execute`, fresh subagent per task. Under ultracode it authors a Workflow to orchestrate the tasks — review the generated script before approving on large plans.
2. **Inline** — execute sequentially in current session
