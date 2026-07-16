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

## Codex Second-Opinion Review (cross-family, gpt-5.6)

The eng-flow closing cross-check (`scripts/codex-review.sh`, run once after mao-review / mao-execute final review) picks its OpenAI Codex model by the **source severity** — the highest original severity the first-pass five-axis review assigned to this change (even if already fixed). Severity is an input decided by the source, never re-triaged by a weaker model.

| Source max severity | Codex model / effort |
|---------------------|----------------------|
| Critical | `gpt-5.6-sol` / max |
| Required | `gpt-5.6-sol` / high |
| Optional / Nit / FYI | `gpt-5.6-terra` / medium |
| (unspecified) | fallback `gpt-5.6-sol` / high |

Pass it via `--severity <critical|required|optional|nit|fyi>`. When in doubt, over-estimate — under-calling sends a change that deserves deep review to a fast terra scan. Requires codex client >= 0.144.x + a plan with GPT-5.6 access; the script self-skips if codex is absent/unauthorized.
