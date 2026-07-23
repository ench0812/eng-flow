# Model Routing (eng-flow shared rules)

Three tiers — chosen per `agent()` / Agent-tool dispatch, not per skill:

| Tier | When | How |
|------|------|-----|
| **opus** (inherit) | Architecture-level decisions, high-uncertainty tasks, security-critical review | Omit `model` in `agent()` — inherits the session model |
| **sonnet** (default for execution) | Standard implement / spec-review / code-review stages, scoped multi-step tasks | `model:"sonnet"` |
| **haiku** | Genuinely mechanical high-volume: scanning, format conversion, log analysis, simple lookups | `model:"haiku"` |

## Rules

- **mao-execute pipeline** (implement / spec-review / code-review): default `model:"sonnet"` on all three stages. Escalate a stage to inherit (omit `model`) only when its task is flagged architecture-level or high-uncertainty in the plan.
- **mao-review reviewer dispatch**: default `model:"sonnet"`. High-risk changes (security, auth, data integrity) → omit `model` to escalate.
- **Named user-level agents** (`~/.claude/agents/`): senior-reviewer=opus, root-cause-debugger=opus, implementer=sonnet, mechanical-scanner=haiku. These apply to Agent-tool dispatch only — Workflow `agent()` does NOT consult them; route Workflow stages explicitly with the table above.
- When unsure: `sonnet` for execution, inherit for judgment.

## Codex Cross-Family Consultation (gpt-5.6)

`scripts/codex-review.sh` is stateless — one call, one consultation. Two modes, two semantics:

| Mode | Semantics / caller | Invocation | Severity source |
|------|--------------------|------------|-----------------|
| diff (default) | One-shot **second opinion** at mao-review / mao-execute closing, after all Required/Critical fixed — once per review round | `--severity <level> [--base <branch>]` | Highest original severity from the first-pass five-axis review (even if already fixed) |
| spec | **Co-design loop** in mao-brainstorm, after Spec Self-Review, before the User Review Gate (≤3 rounds; loop state lives in the doc's `## Cross-Check Log`) | `--doc <spec.md> --kind spec --severity <level>` | Claude's design-risk self-assessment: cross-system / security / data migration / irreversible → critical; normal feature → required; small local → optional |
| plan | **Co-design loop** in mao-plan, after Self-Review, before Execution Handoff; Codex follows the plan's `Spec:` line to cross-check coverage against the design doc | `--doc <plan.md> --kind plan --severity <level>` | Same design-risk self-assessment |

Severity is an **input decided by the source** — never re-triaged by a weaker model. When in doubt, over-estimate — under-calling sends work that deserves deep review to a fast terra scan. Model mapping (all modes):

| Source severity | Codex model / effort |
|---------------------|----------------------|
| Critical | `gpt-5.6-sol` / max |
| Required | `gpt-5.6-sol` / high |
| Optional / Nit / FYI | `gpt-5.6-terra` / medium |
| (unspecified) | fallback `gpt-5.6-sol` / high |

Doc mode skips the base-branch / empty-diff gates; outside a git repo it continues with `--skip-git-repo-check` (sandbox is read-only — codex merely loses repo context). A missing `--doc` file or contradictory flags is a caller bug → exit 2, loud (environment gaps SKIP with exit 0, never blocking). Requires codex client >= 0.144.x + GPT-5.6 access; self-skips when codex is absent/unauthorized.
