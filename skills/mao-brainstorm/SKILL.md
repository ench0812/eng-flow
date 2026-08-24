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
- Cover: architecture, components, data flow, error handling, testing, out of scope (explicitly list what's deliberately not being done; it must be disjoint from the covered requirements)
- Ask after each section if it looks right

### 5. Write Design Doc
Save to `docs/specs/YYYY-MM-DD-<topic>-design.md`

Write it complete and self-consistent in one pass — no TBD, TODO, or vague requirements, and no section contradicting another. Keep it focused enough for one plan. Match length to the design's complexity; do not pad with filler sections, redundant summaries, or boilerplate.

### 6. Codex Co-Design Loop

The spec the user reviews must be the **converged result of Claude and Codex co-designing** — not Claude's solo draft. Once the doc is saved, loop (each script call is **at most** one consultation — the script refuses a repeat whose payload is byte-identical to the previous round; apply the round's fixes first, or set `CODEX_REVIEW_FORCE=1` to deliberately re-ask the same content):

1. **Consult** — one cross-family co-design pass on the saved doc:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --doc docs/specs/YYYY-MM-DD-<topic>-design.md --kind spec --severity <level>
   ```
   Set `<level>` **once** by your own risk assessment of this design and keep it for every round (severity is your input — never let the script re-triage it; over-estimate when unsure): cross-system / security-sensitive / data migration / irreversible operations → `critical`; normal feature → `required`; small local design → `optional`.
2. **Triage** — for each Codex item decide: **adopt** (revise the spec), **reject** (record why), or **user call** (genuine judgment call you can't settle). Never silently drop an item.
3. **Log** — append the round to a `## Cross-Check Log` section at the very end of the spec, one table per round, closed by the round's convergence line:
   ```markdown
   ### Round 1 — YYYY-MM-DD（<model>/<effort>）
   | # | Codex 提議（嚴重度） | 處置 | 理由 |
   |---|---------------------|------|------|

   > 收斂問句:<Codex 的問句> → 續輪 / 收斂（一句理由）
   ```
   The log is the loop's only state: Codex reads it next round, won't re-raise settled items, and may dissent once on a rejection (marked `[異議]`) — a dissent you can't resolve becomes *user call*. Keep the log after approval (decision record).
4. **Converge** — **no consultation cap.** Codex ends every reply with one line, `收斂問句:<its single most important open question>` (or `無`). That question plus this round's adoptions drive your continue/stop call each round — and the loop's default is to stop:
   - **Continue** another round only if (a) this round adopted a Critical/Required change Codex hasn't seen yet, or (b) the 收斂問句 is substantive (answering it would change this spec), in scope, and not already dispositioned in the Cross-Check Log.
   - **Stop** in every other case: Codex replies「無重大補充」or 收斂問句 is 無; the question repeats a settled item; it expands scope beyond the spec's goal (record it as *user call* or out-of-scope — don't chase it); or answering it wouldn't change the doc.
   - **Convergence duty is yours, not Codex's:** every extra round must shrink the open-question set, never widen it. If Codex opens a new front unrelated to prior rounds, don't follow — log it, force-converge, hand the remainder to the user. The script prints a non-blocking `警示` once the Cross-Check Log holds ≥6 `### Round` entries; treat it as "force-converge now".

If the script answers `[codex-review] RATE_LIMITED:` the consultation did not happen: do not retry it, do not log a `### Round` for it, and go straight to the Gate with the spec as it stands. Say so in one line. A later flow calls codex again as normal.

**Input too large.** If the script answers `[codex-review] FAILED: 輸入過長,未送出`, the consultation did **not** happen and this is *not* a quota problem — the document exceeds codex's input limit, so it will never be reviewed until it is split. Unlike RATE_LIMITED you must not just carry on. Note this is **doc mode**: `--base` is not available here (`--doc` and `--base` are mutually exclusive and the script exits 2) — split the document into sections and consult on each, which is what the script's own message says. Treating it as reviewed is a false pass.

**Cost discipline (v1.17.0).** The script sends the document with the `## Cross-Check Log` **trimmed to its last round only** (earlier rounds still count as settled — the prompt says so). Do not paste earlier rounds back into the body to compensate; that was the exact behaviour that grew one plan's payload from 4,929 to 26,758 characters across 12 rounds. Session resume is **off by default** (measured server-side cache window is only tens of seconds — see `references/model-routing.md`). Identical content twice in a row is refused (`SKIP: 送出內容與上一輪...完全相同`): apply the round's fixes first. Per-call token usage and cache hit rate land in `$CODEX_REVIEW_LOG`; report with `scripts/codex-usage.sh`.

If codex is absent/unauthorized the script self-skips (`[codex-review] SKIP:`) — relay in one line and go to the Gate with the solo spec.

### 7. User Review Gate
> "Spec written to `<path>` — co-designed with Codex over N round(s): X adopted, Y rejected (reasons in Cross-Check Log), Z for your call. Please review."

Present each *user call* item with both positions — the user is the final arbiter. Wait for approval. If changes requested, fix and re-review; a substantive redesign takes one more co-design round before re-presenting — it counts as a Critical/Required-level change Codex hasn't seen, and the same continue/stop rules govern any rounds after it.

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
- Following a scope-expanding 收斂問句 into another round — new fronts are *user call* material, not a reason to keep consulting

## Scope Decomposition
If spec covers multiple independent subsystems:
- Break into sub-projects
- Define relationships and build order
- Brainstorm the first sub-project through this full flow
