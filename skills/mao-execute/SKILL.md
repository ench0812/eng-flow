---
name: mao-execute
description: Subagent 驅動執行。有 plan 需要逐 task 實作時使用。每 task 一個 subagent + 兩階段 review。
---

# Subagent-Driven Execution

<SUBAGENT-STOP>
If you are executing a specific task with defined inputs and expected outputs (dispatched via Agent tool OR a Workflow agent()), do NOT author a nested Workflow — nesting is not allowed. Run implement → spec-review → code-review sequentially via Agent tool instead.
</SUBAGENT-STOP>

One fresh subagent per task. Two-stage review after each: spec compliance first, then code quality. Continuous execution — do not pause between tasks; this binds within a single turn / a single Workflow run. A completion condition that spans turns is the user's `/goal` (see mao-plan's Execution Handoff). Provide full task text to subagents — never make them read plan files.

## Process

Before dispatching: if the plan contains a `## Not yet specified` section, confirm scope with the user before proceeding — do not dispatch against it.

Default: author a Workflow that runs each task through a three-stage pipeline (this is the default whenever the Workflow tool is available — it does not depend on `ultracode`). Each stage is one `agent()` call; prompts come from the three templates in this directory; returns are schema-validated.

```
implement    (implementer-prompt.md,   schema: implementerStatus)
  → spec-review  (spec-reviewer-prompt.md, schema: reviewVerdict)
    → code-review (code-reviewer-prompt.md, schema: reviewVerdict)
REQUEST_CHANGES → back to implement → re-review (conditional branch in the same stage)
All tasks done → final integration review: run the FULL test suite first
                 (per-task commits only ran targeted scopes — this is the one
                 place cross-task regressions surface), then review cross-task
                 seams, shared interfaces, and anything no single task's diff
                 could show. A failing full suite is a REQUEST_CHANGES back to
                 the owning task; re-run the full suite after the fix. Do not
                 re-review internals each task's spec-review and code-review
                 already approved. Check the full-suite runtime against
                 the mao-tdd budget (default 10 min; >20% growth where
                 the project keeps a runtime ledger) — over → file a
                 test-debt item in the closing report; never block this
                 integration on it.
```

Model + effort routing (shared rules: `references/model-routing.md` — model and effort are chosen as a pair, always written explicitly):

| Stage | Tier | Dispatch |
|-------|------|----------|
| implement — 複雜商業邏輯 / 演算法 / 跨模組互動 | **B1** | `model:"sonnet"` + `effort:'high'` |
| implement — spec 明確、只是落地 | **B2** | `model:"sonnet"` + `effort:'medium'` |
| spec-review / code-review | **B2** | `model:"sonnet"` + `effort:'medium'` |
| 任何 architecture-level / high-uncertainty / 安全相關的 stage | **A** | omit `model`（inherits session）+ `effort:'high'` |
| 樣板、config、migration、文件這類機械高量 stage | **C** | `model:"haiku"`，`effort` 留空 |

Escalate by moving up a tier (B2 → B1 → A), never by keeping a tier and hand-tuning its effort. Outside tier C, never omit `effort` — an omitted effort silently inherits the session level and the layering stops meaning anything.

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

After the **final integration review** passes (all tasks done, all Required/Critical fixed) — **once**, not per task — run one cross-family second opinion:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --severity <level>
```

Set `<level>` to the **highest original severity** surfaced across this implementation's spec/code reviews (Critical/Required/Optional/Nit/FYI — even if now fixed). The script maps severity → Codex model (Critical→`sol/medium`, Required→`terra/high`, else→`luna/max`; see `references/model-routing.md`). Severity is your input — never let the script re-triage it; over-estimate when unsure (`else` lands on the nano tier — anything that might matter belongs at `required` or above). Output is a pure second opinion: present by severity, do **not** auto-fix, the user decides. Self-skips if codex is absent/unauthorized. **No consultation cap** — codex ends each reply with `收斂問句:<one question>` (or `無`); consult again only if a fix-and-review cycle produced Critical/Required-level fixes codex hasn't seen, or its question is substantive (answering it would change the code), in scope, and not already settled — same convergence rules as mao-review's closing cross-check. A `無`, repeated, or scope-expanding question closes the loop (report scope-expanding ones to the user as open questions).

If the script answers `[codex-review] RATE_LIMITED:`, that consultation did not happen: do not retry it, and close out with what you have, saying so in one line.

**Input too large.** If the script answers `[codex-review] FAILED: 輸入過長,未送出`, the consultation did **not** happen and this is *not* a quota problem — the diff exceeds codex's input limit, so it will never be reviewed until the scope is narrowed. Unlike RATE_LIMITED you must not just carry on: re-run with a tighter `--base` (per-commit or per-theme), or review the high-risk files separately from the test-file bulk. Treating it as reviewed is a false pass.

## Red Flags
- Dispatching multiple agents on overlapping files without worktree isolation
- Skipping spec review ("it looks fine")
- Skipping code review ("spec passed, good enough")
- Ignoring BLOCKED/NEEDS_CONTEXT escalations
- Treating the implementer's DONE report as a substitute for actual review
- Moving to next task while review has open issues
