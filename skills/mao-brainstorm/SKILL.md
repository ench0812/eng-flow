---
name: mao-brainstorm
description: 設計先行。新功能、跨元件/跨系統設計、需求不清時使用；單檔小改動、機械性修改、明確 bug fix 不適用。禁止未經設計就寫 code。
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

### 2. Clarify (Batch by Dependency, Not One at a Time)
- Build a dependency tree of open questions. Each round, ask via AskUserQuestion every question whose prerequisites are already resolved (in chunks of ≤4 per call — the tool's limit), each with a suggested default. Questions depending on an unresolved answer wait for the next round.
- Facts you can check yourself (codebase/tools) — check them; only ask the user about decisions. Dispatch a subagent for lookups only when the volume is large.
- For critical requirement boundaries, construct a concrete edge-case scenario and let the user resolve it — don't self-select an interpretation.
- Focus on: purpose, constraints, success criteria
- Surface your assumptions before writing anything

### 3. Propose 2-3 Approaches
- Present with trade-offs and your recommendation
- Lead with recommended option and explain why

### 4. Present Design
- Scale each section to its complexity
- Cover: architecture, components, data flow, error handling, testing, out of scope (explicitly list what's deliberately not being done)
- Ask after each section if it looks right

### 5. Write Design Doc
Save to `docs/specs/YYYY-MM-DD-<topic>-design.md`

**Spec Self-Review** (before asking user to review):
1. Placeholder scan — any TBD, TODO, vague requirements? Fix them.
2. Internal consistency — sections contradict each other?
3. Scope check — focused enough for one plan?
4. Ambiguity check — any requirement interpretable two ways? Construct a concrete scenario and put it to the user via the User Review Gate — don't self-select an interpretation.
5. Out of Scope check — explicitly lists what's deliberately not being done, disjoint from (no overlap with) the covered requirements?

### 6. Codex Co-Design Loop

The spec the user reviews must be the **converged result of Claude and Codex co-designing** — not Claude's solo draft. After the Spec Self-Review passes, loop (each script call is one stateless consultation):

1. **Consult** — one cross-family co-design pass on the saved doc:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --doc docs/specs/YYYY-MM-DD-<topic>-design.md --kind spec --severity <level>
   ```
   Set `<level>` **once** by your own risk assessment of this design and keep it for every round (severity is your input — never let the script re-triage it; over-estimate when unsure): cross-system / security-sensitive / data migration / irreversible operations → `critical`; normal feature → `required`; small local design → `optional`.
2. **Triage** — for each Codex item decide: **adopt** (revise the spec), **reject** (record why), or **user call** (genuine judgment call you can't settle). Never silently drop an item.
3. **Log** — append the round to a `## Cross-Check Log` section at the very end of the spec, one table per round:
   ```markdown
   ### Round 1 — YYYY-MM-DD（<model>/<effort>）
   | # | Codex 提議（嚴重度） | 處置 | 理由 |
   ```
   The log is the loop's only state: Codex reads it next round, won't re-raise settled items, and may dissent once on a rejection (marked `[異議]`) — a dissent you can't resolve becomes *user call*. Keep the log after approval (decision record).
4. **Converge** — repeat from step 1 only if this round adopted any Critical/Required change. Stop when Codex replies「無重大補充」, a round adopts nothing above Optional, or after 3 rounds (remaining disagreements become *user call*).

If codex is absent/unauthorized the script self-skips (`[codex-review] SKIP:`) — relay in one line and go to the Gate with the solo spec.

### 7. User Review Gate
> "Spec written to `<path>` — co-designed with Codex over N round(s): X adopted, Y rejected (reasons in Cross-Check Log), Z for your call. Please review."

Present each *user call* item with both positions — the user is the final arbiter. Wait for approval. If changes requested, fix and re-review; a substantive redesign takes one more co-design round before re-presenting.

### 8. Transition
After user approves → invoke `eng-flow:mao-plan` to create implementation plan.

## Anti-Patterns
- Skipping design for "simple" tasks — they're where assumptions bite hardest
- Cramming interdependent questions into the same round before their prerequisites are answered
- Splitting independent questions across multiple rounds when they could be batched
- Asking the user a fact they could have looked up themselves
- Proposing only one approach — always at least 2
- Starting code before user approves design
- Auto-adopting Codex suggestions without dispositioning them in the Cross-Check Log — every item gets adopt / reject / user call

## Scope Decomposition
If spec covers multiple independent subsystems:
- Break into sub-projects
- Define relationships and build order
- Brainstorm the first sub-project through this full flow
