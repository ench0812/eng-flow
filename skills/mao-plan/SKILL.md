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

### 1. Map Dependencies
Identify what depends on what. Implementation order follows the graph bottom-up.

### 2. Slice Vertically
Build complete feature paths, not horizontal layers.
- **Bad:** all DB → all API → all UI → connect everything
- **Good:** feature A (DB+API+UI) → feature B (DB+API+UI)

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

## Self-Review

After writing, check:
1. **Spec coverage** — every requirement has a task?
2. **Placeholder scan** — any vague steps?
3. **Type consistency** — names/signatures match across tasks?

Save to: `docs/plans/YYYY-MM-DD-<feature>.md`

## Execution Handoff

After saving, offer:
1. **Subagent-Driven** (recommended) — `eng-flow:mao-execute`, fresh subagent per task
2. **Inline** — execute sequentially in current session
