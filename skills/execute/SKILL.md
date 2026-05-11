---
name: execute
description: Subagent 驅動執行。有 plan 需要逐 task 實作時使用。每 task 一個 subagent + 兩階段 review。
---

# Subagent-Driven Execution

Dispatch one fresh subagent per task. Two-stage review after each: spec compliance first, then code quality. Continuous execution — do not pause between tasks.

## Process

```
Read plan → Extract all tasks with full text → Create task list

Per task:
  Dispatch implementer (./implementer-prompt.md)
    → Handle status (DONE/DONE_WITH_CONCERNS/NEEDS_CONTEXT/BLOCKED)
    → Dispatch spec reviewer (./spec-reviewer-prompt.md)
      → Issues? → Implementer fixes → Re-review
    → Dispatch code reviewer (./code-reviewer-prompt.md)
      → Issues? → Implementer fixes → Re-review
    → Mark task complete
  → Next task

All tasks done → Final review of entire implementation
```

## Model Selection

- **Mechanical tasks** (1-2 files, clear spec): use haiku/sonnet
- **Integration tasks** (multi-file coordination): use sonnet
- **Architecture/design/review tasks**: use opus

## Handling Implementer Status

**DONE:** Proceed to spec review.
**DONE_WITH_CONCERNS:** Read concerns. If correctness/scope issue → address first. If observation → note and proceed.
**NEEDS_CONTEXT:** Provide missing context and re-dispatch.
**BLOCKED:** Assess: context problem → provide context. Task too hard → re-dispatch with better model. Task too large → split. Plan wrong → escalate to user.

## Parallel Dispatch

When multiple tasks are independent (no shared files, no dependency):
- Dispatch up to 3 implementer subagents simultaneously
- Each gets isolated context — no shared state
- Merge results before proceeding to next dependent phase

**Must be sequential:** Tasks sharing files, database migrations, dependency chains.

## Prompt Templates

All templates in this directory:
- `implementer-prompt.md` — task implementation
- `spec-reviewer-prompt.md` — spec compliance check
- `code-reviewer-prompt.md` — quality review (five-axis)

Provide full task text to subagents — never make them read plan files.

## Red Flags
- Dispatching multiple agents on overlapping files
- Skipping spec review ("it looks fine")
- Skipping code review ("spec passed, good enough")
- Ignoring BLOCKED/NEEDS_CONTEXT escalations
- Letting implementer self-review replace actual review
- Moving to next task while review has open issues
