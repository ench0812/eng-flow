---
name: mao-brainstorm
description: 設計先行。新功能、需求不清、「我想做…」時使用。禁止未經設計就寫 code。
---

# Design Before Code

<HARD-GATE>
Do NOT write any code, scaffold, or take implementation actions until you have presented a design and the user has approved it. Every project goes through this — "too simple to need a design" is exactly when unexamined assumptions cause the most wasted work.
</HARD-GATE>

## Process

### 1. Explore Context
- Read relevant code, docs, recent commits
- 不熟 / 大型 codebase → `repomix --compress`（或 `--include "<相關模組 glob>"` 打包子集）一次取得全庫上下文，勝過逐檔盲讀。見 `references/repomix.md`
- If request spans multiple independent subsystems → suggest decomposition first
- Each sub-project gets its own spec → plan → implementation cycle

### 2. Clarify (One Question at a Time)
- Prefer multiple choice questions
- Focus on: purpose, constraints, success criteria
- Surface your assumptions before writing anything

### 3. Propose 2-3 Approaches
- Present with trade-offs and your recommendation
- Lead with recommended option and explain why

### 4. Present Design
- Scale each section to its complexity
- Cover: architecture, components, data flow, error handling, testing
- Ask after each section if it looks right

### 5. Write Design Doc
Save to `docs/specs/YYYY-MM-DD-<topic>-design.md`

**Spec Self-Review** (before asking user to review):
1. Placeholder scan — any TBD, TODO, vague requirements? Fix them.
2. Internal consistency — sections contradict each other?
3. Scope check — focused enough for one plan?
4. Ambiguity check — any requirement interpretable two ways? Pick one.

### 6. User Review Gate
> "Spec written to `<path>`. Please review before we proceed."

Wait for approval. If changes requested, fix and re-review.

### 7. Transition
After user approves → invoke `eng-flow:mao-plan` to create implementation plan.

## Anti-Patterns
- Skipping design for "simple" tasks — they're where assumptions bite hardest
- Asking 5 questions at once — one at a time
- Proposing only one approach — always at least 2
- Starting code before user approves design

## Scope Decomposition
If spec covers multiple independent subsystems:
- Break into sub-projects
- Define relationships and build order
- Brainstorm the first sub-project through this full flow
