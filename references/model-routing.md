# Model Routing (eng-flow shared rules)

Two knobs per `agent()` / Agent-tool dispatch, not per skill — **model**（能力）與 **effort**（推理預算）。**兩者成對選定、一律明寫**（2026-08-06 校準）：挑 tier 就把該 tier 的 effort 一起帶上，不靠 omit 繼承 session。Sonnet 分兩檔，是這張表的重點——降成本先在 B1→B2 之間動，不是急著降到 haiku。

| Tier | Model | Effort | 用途 | How |
|------|-------|--------|------|-----|
| **Session** | 主線（settings.json `model`） | `high`（settings.json `effortLevel`） | 編排、架構決策、需求拆解 | 不由 `agent()` 設定；改 settings |
| **A** | opus（繼承主線） | `high` | 平行深度任務、跨模組驗證 — **節制使用** | Omit `model` + `effort:'high'` |
| **B1** | sonnet | `high` | 複雜商業邏輯、演算法 — 執行層首選工程師 | `model:"sonnet"` + `effort:'high'` |
| **B2** | sonnet | `medium` | Spec 明確的實作、標準重構 | `model:"sonnet"` + `effort:'medium'` |
| **C** | haiku | **不設** | 樣板、config、migration、文件 | `model:"haiku"`，`effort` 留空 |

B1 vs B2 的判準是**任務不確定性**，不是任務大小：要自己想出解法（演算法、跨模組互動、狀態機、並行/交易邏輯）→ B1；解法已寫在 spec/plan 裡、只是落地成 code → B2。C 層刻意不設 effort——樣板與文件不需要推理預算，交給模型自己的預設。

## Rules

- **mao-execute pipeline**: implement 依任務性質選 B1 或 B2（plan 標記 architecture-level / high-uncertainty 的升 A）；spec-review / code-review 走 B2，安全 / 認證 / 資料完整性相關的升 A。
- **mao-review reviewer dispatch**: default B2（`model:"sonnet"` + `effort:'medium'`）。High-risk changes (security, auth, data integrity) → A（omit `model` + `effort:'high'`）。
- **Named user-level agents** (`~/.claude/agents/`): senior-reviewer=A, root-cause-debugger=A, implementer=B2（其定義就是「依明確 spec 落地」）, mechanical-scanner=C。These apply to Agent-tool dispatch only — Workflow `agent()` does NOT consult them; route Workflow stages explicitly with the table above.
- **Effort 寫在哪**：Workflow `agent()` 用 `opts.effort`；`~/.claude/agents/*.md` 用 frontmatter `effort:`。除 C 層外一律明寫——session 有自己的 effortLevel，omit 會讓 stage 悄悄繼承它、失去分層的意義。
- When unsure: 升 tier（B2→B1→A），不要拆開 model 與 effort 的配對去單獨拉 effort；也不要用降 model 來省成本（能力降級是反向操作）。確定機械化才進 C。
- **沿革**：2026-08-05 曾把 implement stage 單獨校準為 `effort:'high'`（理由：high→xhigh 對範疇明確任務邊際效益遞減、每輪思考延遲照付，平行化省下的時間不該被吃回去）。該結論已被本版吸收成 **B1**——差別是現在由「任務不確定性」決定 implement 走 B1 還是 B2，而不是整條 implement stage 一律 high。

## Codex Cross-Family Consultation (gpt-5.6)

`scripts/codex-review.sh` is stateless — one call, one consultation. Two modes, two semantics:

| Mode | Semantics / caller | Invocation | Severity source |
|------|--------------------|------------|-----------------|
| diff (default) | **Second opinion** at mao-review / mao-execute closing, after all Required/Critical fixed — once per review round, extra rounds convergence-gated (see below) | `--severity <level> [--base <branch>]` | Highest original severity from the first-pass five-axis review (even if already fixed) |
| spec | **Co-design loop** in mao-brainstorm, once the design doc is saved, before the User Review Gate (convergence-gated; loop state lives in the doc's `## Cross-Check Log`) | `--doc <spec.md> --kind spec --severity <level>` | Claude's design-risk self-assessment: cross-system / security / data migration / irreversible → critical; normal feature → required; small local → optional |
| plan | **Co-design loop** in mao-plan, once the plan file is saved, before Execution Handoff; Codex follows the plan's `Spec:` line to cross-check coverage against the design doc | `--doc <plan.md> --kind plan --severity <level>` | Same design-risk self-assessment |

**Convergence protocol — no consultation caps (any mode).** Every consultation prompt makes codex end its reply with a single line, `收斂問句:<its most important open question>` — or `收斂問句:無` when nothing left would change the artifact. Claude judges continue/stop each round, and stop is the default: continue **only** when the round adopted Critical/Required changes codex hasn't seen, or the question is substantive (answering it would change the doc/code) AND in scope AND not already settled. A `無`, repeated, or scope-expanding question ends the loop (scope-expanding ones become *user call* / open questions for the user — never another round). Every extra round must shrink the open-question set. Tripwire: in doc mode the script prints a non-blocking `警示` at ≥6 `### Round` entries in the Cross-Check Log — read it as "force-converge now". Per-skill wording lives in mao-brainstorm / mao-plan / mao-review / mao-execute.

**Rate limit.** If codex reports a usage/credit limit the script prints `[codex-review] RATE_LIMITED:` and exits 0. That consultation did not happen: do **not** retry it, do **not** log a round for it, and carry straight on with whatever came next. The next time a consultation is due, call the script again as normal — being rate-limited once never disables codex for the rest of the flow.

Severity is an **input decided by the source** — never re-triaged by a weaker model. When in doubt, over-estimate — under-calling sends work that deserves deep review to a fast terra scan. Model mapping (all modes):

| Source severity | Codex model / effort |
|---------------------|----------------------|
| Critical | `gpt-5.6-sol` / max |
| Required | `gpt-5.6-sol` / high |
| Optional / Nit / FYI | `gpt-5.6-terra` / medium |
| (unspecified) | fallback `gpt-5.6-sol` / high |

Doc mode skips the base-branch / empty-diff gates; outside a git repo it continues with `--skip-git-repo-check` (sandbox is read-only — codex merely loses repo context). A missing `--doc` file or contradictory flags is a caller bug → exit 2, loud (environment gaps SKIP with exit 0, never blocking). Requires codex client >= 0.144.x + GPT-5.6 access; self-skips when codex is absent/unauthorized.
