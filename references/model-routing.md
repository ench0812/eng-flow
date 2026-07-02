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
