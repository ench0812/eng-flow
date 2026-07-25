# Model Routing (eng-flow shared rules)

Two knobs per `agent()` / Agent-tool dispatch, not per skill — **model**（能力）與 **effort**（推理預算）。`ultracode` 把 session effort 釘在 xhigh，任何沒指定 effort 的 stage 都繼承 xhigh；省成本先動 effort，model 只在任務確實機械化時才降。

Model tiers:

| Tier | When | How |
|------|------|-----|
| **opus** (inherit) | Architecture-level decisions, high-uncertainty tasks, security-critical review | Omit `model` in `agent()` — inherits the session model |
| **sonnet** (default for execution) | Standard implement / spec-review / code-review stages, scoped multi-step tasks | `model:"sonnet"` |
| **haiku** | Genuinely mechanical high-volume: scanning, format conversion, log analysis, simple lookups | `model:"haiku"` |

## Rules

- **mao-execute pipeline** (implement / spec-review / code-review): default `model:"sonnet"` on all three stages. Escalate a stage to inherit (omit `model`) only when its task is flagged architecture-level or high-uncertainty in the plan.
- **mao-review reviewer dispatch**: default `model:"sonnet"`. High-risk changes (security, auth, data integrity) → omit `model` to escalate.
- **Named user-level agents** (`~/.claude/agents/`): senior-reviewer=opus, root-cause-debugger=opus, implementer=sonnet, mechanical-scanner=haiku. These apply to Agent-tool dispatch only — Workflow `agent()` does NOT consult them; route Workflow stages explicitly with the table above.
- **Effort**（Workflow `agent()` 用 `opts.effort`；`~/.claude/agents/*.md` 用 frontmatter `effort:`）：機械高量 stage → `effort:'low'`；spec-review / code-review → `effort:'medium'`（官方實測 Opus 5 review 準確度在低 effort 仍維持）；implement 與架構級判斷 → omit，繼承 session。安全 / 認證 / 資料完整性相關的 review 一律 omit。這組值是依官方指引訂的第一版起點，跑過一輪真實 plan 後再校。
- When unsure: omit `model`（harness 的預設就是繼承主線，不確定時降能力是反向操作）；要省成本就把 effort 降一階，不要用降模型來省。已經確定機械化的 stage 才明寫 `model:"sonnet"` / `"haiku"`。

## Codex Cross-Family Consultation (gpt-5.6)

`scripts/codex-review.sh` is stateless — one call, one consultation. Two modes, two semantics:

| Mode | Semantics / caller | Invocation | Severity source |
|------|--------------------|------------|-----------------|
| diff (default) | **Second opinion** at mao-review / mao-execute closing, after all Required/Critical fixed — once per review round, **≤2 per code review**, counted independently of other stages | `--severity <level> [--base <branch>]` | Highest original severity from the first-pass five-axis review (even if already fixed) |
| spec | **Co-design loop** in mao-brainstorm, once the design doc is saved, before the User Review Gate (**≤4 consultations**; loop state lives in the doc's `## Cross-Check Log`) | `--doc <spec.md> --kind spec --severity <level>` | Claude's design-risk self-assessment: cross-system / security / data migration / irreversible → critical; normal feature → required; small local → optional |
| plan | **Co-design loop** in mao-plan, once the plan file is saved, before Execution Handoff; Codex follows the plan's `Spec:` line to cross-check coverage against the design doc | `--doc <plan.md> --kind plan --severity <level>` | Same design-risk self-assessment |

**Consultation caps — per stage, no cross-flow total.** spec and plan co-design get **4** consultations each; every code review — a mao-review round, or mao-execute's closing cross-check — gets **2**. At its cap Claude takes over and continues solo, with no further codex calls for that stage. Doc mode is script-enforced: the script counts `### Round` entries in the doc's `## Cross-Check Log` and answers any call past the cap with `[codex-review] STOP:` + exit 0. Diff mode is stateless, so the caller (mao-review / mao-execute) counts its own 2.

**Rate limit.** If codex reports a usage/credit limit the script prints `[codex-review] RATE_LIMITED:` and exits 0. That consultation did not happen: do **not** retry it, do **not** count it against the stage's cap, and carry straight on with whatever came next. The next time a consultation is due, call the script again as normal — being rate-limited once never disables codex for the rest of the flow.

Severity is an **input decided by the source** — never re-triaged by a weaker model. When in doubt, over-estimate — under-calling sends work that deserves deep review to a fast terra scan. Model mapping (all modes):

| Source severity | Codex model / effort |
|---------------------|----------------------|
| Critical | `gpt-5.6-sol` / max |
| Required | `gpt-5.6-sol` / high |
| Optional / Nit / FYI | `gpt-5.6-terra` / medium |
| (unspecified) | fallback `gpt-5.6-sol` / high |

Doc mode skips the base-branch / empty-diff gates; outside a git repo it continues with `--skip-git-repo-check` (sandbox is read-only — codex merely loses repo context). A missing `--doc` file or contradictory flags is a caller bug → exit 2, loud (environment gaps SKIP with exit 0, never blocking). Requires codex client >= 0.144.x + GPT-5.6 access; self-skips when codex is absent/unauthorized.
