---
name: mao-review
description: 五軸 code review。合併前檢查、PR review、code quality 審查時使用。
---

# Five-Axis Code Review

## When to Use Which Review
- Quick working-tree diff review → built-in `/code-review`
- GitHub PR lifecycle review → built-in `/review` or the code-review plugin command
- This skill: five axes + ISO 27001 tags + severity taxonomy shared with mao-execute (merge gate)

## Approval Standard

Approve when the change **definitely improves overall code health**, even if it isn't perfect. Don't block because it isn't how you'd have written it.

## The Five Axes

### 1. Correctness
- Matches spec/task requirements?
- Edge cases handled (null, empty, boundary)?
- Error paths handled (not just happy path)?
- Tests cover the change adequately?
- Tests avoid tautological assertions (expected values from an independent source, not recomputed by the same logic)?

### 2. Readability & Simplicity
- Names descriptive and consistent?
- Control flow straightforward?
- Could this be done in fewer lines?
- Abstractions earning their complexity?
- Dead code artifacts? (no-op vars, backwards-compat shims, `// removed` comments)

### 3. Architecture
- Follows existing patterns or justifies new ones?
- Clean module boundaries maintained?
- Code duplication that should be shared?
- Dependencies flowing correctly (no circular)?
- Deletion test — imagine deleting this module/function entirely. Complexity vanishes → it was just a pass-through, cut it. Complexity reappears at each call site → it was earning its keep.
- Single-implementation interfaces/wrappers are premature abstraction — don't extract yet. Only introduce one once two real, behaviorally-different implementations/cases exist.

### 4. Security & ISO 27001 Compliance
- User input validated and sanitized? Queries parameterized? Outputs encoded? [A.8.28]
- Secrets out of code, logs, version control? No PII/secrets in logs? [A.8.24/A.8.15]
- Auth/authz checked server-side where needed (not UI-only)? [A.8.3/A.8.5]
- TLS 1.2+ / AES-256, no banned crypto? [A.8.24]
- New/changed deps pinned + SCA-clean (no high/critical CVE)? [A.8.7/A.8.8]
- No `--no-verify`, no unmasked prod data in tests, no manual prod change? [A.8.32/A.8.33]
- Deeper pass → invoke `mao-comply` self-check.

### 5. Performance
- N+1 query patterns?
- Unbounded loops or data fetching?
- Synchronous ops that should be async?
- Large objects in hot paths?

## Severity Labels

| Prefix | Meaning | Author Action |
|--------|---------|---------------|
| *(none)* | Required | Must fix before merge |
| **Critical:** | Blocks merge | Security, data loss, broken functionality |
| **Nit:** | Optional | Author may ignore |
| **Optional:** | Suggestion | Worth considering |
| **FYI** | Informational | No action needed |

Deprecated: `Important`/`Minor` — do not reintroduce these words when editing any reviewer prompt.

## Change Sizing

- ~100 lines → Good
- ~300 lines → Acceptable if single logical change
- ~1000 lines → Too large, split it

**Splitting strategies:** Stack (sequential deps), By file group (cross-cutting), Horizontal (shared code first), Vertical (smaller full-stack slices).

## Review Process

1. **Understand context** — what is this change trying to accomplish? Find the spec, in order: commit message references → user-provided path → `docs/specs/*-design.md` → `docs/plans/*.md` → ask the user. If none found, state upfront "no spec available — Correctness axis reviewed against the code's own logic only."
2. **Review tests first** — tests reveal intent and coverage
3. **Review implementation** — walk through each file with 5 axes
4. **Categorize findings** — label severity on every comment
5. **Verify verification** — what tests ran? Build pass? Manual check?

## Closing Cross-Check (Codex second opinion)

After the five axes are complete AND the author has fixed all Required/Critical findings — **once per review round**, not per file or per fix — run one cross-family second opinion:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --severity <level>
```

Set `<level>` to the **highest original severity this review assigned** to the change (Critical/Required/Optional/Nit/FYI — even if now fixed; the risk area remains). The script maps severity → Codex model (Critical→`sol/max`, Required→`sol/high`, else→`terra/medium`; see `references/model-routing.md`). Severity is your input from this review — never let the script re-triage it. Over-estimate when unsure.

Treat the output as a **pure second opinion**: present findings by severity, do **not** auto-fix, the user decides. If codex is absent/unauthorized the script self-skips (`[codex-review] SKIP:`) — relay the reason in one line, do not install anything.

**Loop cap:** the [Claude]→[Codex]→[Claude] cycle runs **at most 3 rounds per review flow**. If the 3rd consultation's findings trigger yet another fix-and-review round, Claude closes that round — and everything after it — alone, with no further codex-review calls. (Diff mode is stateless, so this cap is yours to enforce; track the count in the review flow.)

## Subagent Dispatch

**Pre-dispatch check (orchestrator runs this, before spawning the reviewer):**
- `git rev-parse <base>` and `git rev-parse HEAD` — invalid ref → stop, report to the user, do not dispatch
- Compute `git merge-base <base> HEAD` — this is BASE_SHA (the true comparison point, not the base branch tip)
- `git diff <BASE_SHA>..HEAD --stat` — empty diff → stop, report to the user, do not dispatch

For automated review, run a reviewer via Workflow `agent()` (or Agent tool directly for a single-file review) using the template at `mao-execute/code-reviewer-prompt.md`:
- Model: default `model:"sonnet"` (same routing as mao-execute; see `references/model-routing.md`). High-risk changes (security/auth/data) → omit `model` to inherit the session model
- Provide git SHAs (BASE_SHA from the merge-base above, and HEAD)
- Include task/plan requirements
- List changed files
- List the repo's documented standards file paths (CONTRIBUTING / CODING_STANDARDS / CLAUDE.md), if present
- 大型 / 跨檔改動：`repomix --include-diffs --include "<相關檔 glob>"` 把 diff + 周邊上下文打成單檔餵給 reviewer agent()，勝過只給 SHA 讓它逐檔撈。見 `references/repomix.md`

## Dead Code Hygiene

After refactoring, check for orphaned code. List it explicitly and ask before deleting.

## Red Flags
- PRs merged without review
- "LGTM" without evidence of actual review
- No regression tests with bug fix PRs
- Large PRs that skip proper review
- Accepting "I'll fix it later"
