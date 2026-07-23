---
name: mao-execute
description: Subagent 驅動執行。有 plan 需要逐 task 實作時使用。每 task 一個 subagent + 兩階段 review。
---

# Subagent-Driven Execution

<SUBAGENT-STOP>
If you are executing a specific task with defined inputs and expected outputs (dispatched via Agent tool OR a Workflow agent()), do NOT author a nested Workflow — nesting is not allowed. Run implement → spec-review → code-review sequentially via Agent tool instead.
</SUBAGENT-STOP>

One fresh subagent per task. Two-stage review after each: spec compliance first, then code quality. Continuous execution — do not pause between tasks. Provide full task text to subagents — never make them read plan files.

## Process

Before dispatching: if the plan contains a `## Not yet specified` section, confirm scope with the user before proceeding — do not dispatch against it.

Default (ultracode): author a Workflow that runs each task through a three-stage pipeline. Each stage is one `agent()` call; prompts come from the three templates in this directory; returns are schema-validated.

```
implement    (implementer-prompt.md,   schema: implementerStatus)
  → spec-review  (spec-reviewer-prompt.md, schema: reviewVerdict)
    → code-review (code-reviewer-prompt.md, schema: reviewVerdict)
REQUEST_CHANGES → back to implement → re-review (conditional branch in the same stage)
All tasks done → final review of the whole implementation
```

Model routing (shared rules: `references/model-routing.md`): implement / spec-review / code-review stages default to `model:"sonnet"`. Omit `model` (inherit the session model) only for tasks flagged architecture-level or high-uncertainty. Set `model:"haiku"` for genuinely mechanical high-volume stages.

**Fallback:** if the Workflow tool is not in your available tools, fall back to the legacy flow — dispatch implement → spec-review → code-review sequentially via Agent tool per task.

## Parallel vs Sequential

**Parallel** (via `pipeline()`/`parallel()`): tasks with independent files AND independent type/interface contracts. Use `isolation:'worktree'` when parallel agents write to overlapping paths. Workflow manages concurrency natively (cap 16, excess queued) — no manual cap needed.

**Must be sequential:** tasks sharing files, database migrations, dependency chains, or where task B's spec depends on task A's output types/interfaces.

## Handling Implementer Status

**DONE:** Proceed to spec review.
**DONE_WITH_CONCERNS:** Read concerns. If correctness/scope issue → address first. If observation → note and proceed.
**NEEDS_CONTEXT:** Provide missing context and re-dispatch.
**BLOCKED:** Assess: context problem → provide context. Task too large → split. Plan wrong → escalate to user.

## Prompt Templates

All templates in this directory (use as the `agent()` prompt string; replace [bracketed] placeholders):
- `implementer-prompt.md` — task implementation
- `spec-reviewer-prompt.md` — spec compliance check
- `code-reviewer-prompt.md` — quality review (five-axis)

## Closing Cross-Check (Codex second opinion)

After the **final review of the whole implementation** passes (all tasks done, all Required/Critical fixed) — **once**, not per task — run one cross-family second opinion:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --severity <level>
```

Set `<level>` to the **highest original severity** surfaced across this implementation's spec/code reviews (Critical/Required/Optional/Nit/FYI — even if now fixed). The script maps severity → Codex model (Critical→`sol/max`, Required→`sol/high`, else→`terra/medium`; see `references/model-routing.md`). Severity is your input — never let the script re-triage it; over-estimate when unsure. Output is a pure second opinion: present by severity, do **not** auto-fix, the user decides. Self-skips if codex is absent/unauthorized. If findings trigger further fix-and-review cycles, the [Claude]→[Codex]→[Claude] loop is capped at **3 consultations for the whole flow** — past the cap, Claude closes out alone with no further codex-review calls (diff mode is stateless; you enforce this count).

## Red Flags
- Dispatching multiple agents on overlapping files without worktree isolation
- Skipping spec review ("it looks fine")
- Skipping code review ("spec passed, good enough")
- Ignoring BLOCKED/NEEDS_CONTEXT escalations
- Letting implementer self-review replace actual review
- Moving to next task while review has open issues
