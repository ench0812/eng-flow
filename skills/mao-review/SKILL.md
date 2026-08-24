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
- New tests at the lowest pyramid level that expresses them — no duplicate coverage of what an existing/lower-level test already asserts, no obsolete tests left behind?

**跨服務接縫（改動觸及兩個以上服務/程序時必查，2026-08-07 加）**
單側全綠是已知的假綠形態——A 服務測「我送出的形狀是這樣」、B 服務測「我收到這個形狀會正確處理」，
兩邊都測對了，但兩邊假設的形狀不同，中間沒有測試跨過去。mutation、`-race`、full suite 在設計上都攔不住。
- **有沒有任何一項驗證真的跨過了服務邊界？** 若「各服務都綠」是唯一證據，那還沒被驗證。
- **fixture 是不是消費端自造的？** 自造的 fixture 證明的只是「我對對端的假設自洽」；認證軸上等於沒證明。
  輸入必須來自對端實際產生的 bytes（golden fixture 由對端匯出）或真正的 e2e。
- **「欄位省略」與「送空字串」在對端會解成同一件事嗎？** 常見分歧：`nil` vs 指向空字串的指標 → SQL `NULL` vs `''`。
- **新增的契約欄位在消費端是不是無條件 fail-closed？** 「欄位不存在」會等同「尚未升級的對端」，
  部署順序一顛倒就全面拒收。readiness 要綁在「該功能是否真的啟用」，不是綁在欄位存在與否。
- **一端的判斷是否依賴另一端某個值的形狀**，而該形狀從未被同一份 bytes 驗證過？

> 實測依據（2026-08-07 單次量測，非持續更新）：一輪跨五 repo 的改造裡，這一類缺陷出現**五個實例**（欄位頂替、空字串 vs 省略、
> 快照鍵與查表鍵不一致、別名缺席語意、新欄位 readiness 的跨版本時序），返工佔總工時 48.5%。

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
5. **Verify verification** — what tests ran? Build pass? Manual check? Evidence scales with the checkpoint: per-task/dev-loop changes need targeted results (affected test file(s) + directly dependent modules, output pasted) — do not demand a full-suite run per commit. Full-suite evidence is required only at integration points (final integration review, merge/push/release gate).

## Closing Cross-Check (Codex second opinion)

After the five axes are complete AND the author has fixed all Required/Critical findings — **once per review round**, not per file or per fix — run one cross-family second opinion:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --severity <level>
```

Set `<level>` to the **highest original severity this review assigned** to the change (Critical/Required/Optional/Nit/FYI — even if now fixed; the risk area remains). The script maps severity → Codex model (Critical→`sol/medium`, Required→`terra/high`, else→`luna/max`; see `references/model-routing.md`). Severity is your input from this review — never let the script re-triage it. Over-estimate when unsure (`else` lands on the nano tier — anything that might matter belongs at `required` or above).

Treat the output as a **pure second opinion**: present findings by severity, do **not** auto-fix, the user decides. If codex is absent/unauthorized the script self-skips (`[codex-review] SKIP:`) — relay the reason in one line, do not install anything.

**Convergence (no consultation cap):** codex ends each reply with a single line, `收斂問句:<its most important open question>` (or `無`). One consultation per review **round** is the default — *round*, not per file and not per fix: apply every Required/Critical fix from this round first, then consult once on the combined result; consult **again** only if a fix-and-review round produced Critical/Required-level fixes codex hasn't seen, or that question is substantive (answering it would change this change), in scope, and not already settled in this review. Otherwise close the review: 收斂問句 of `無`, a repeated/settled question, or a scope-expanding one (report it to the user as an open question instead of chasing it) all end the loop. Every extra consultation must shrink the open-question set, never widen it.

**Cost discipline (v1.17.0).** The script now keeps a per-review-line round ledger and prints a **non-blocking** warning from the 3rd consultation on the same base: `[codex-review] 警示: 這條複查線(diff:<base>)本次是第 N 次諮詢`. That warning means you are consulting per fix instead of per round — the correct response is to finish **all** of this round's Required/Critical fixes and consult once, not to consult again immediately. Two related behaviours: identical content twice in a row is refused outright (`SKIP: 送出內容與上一輪...完全相同`), session resume exists but is **off by default** (measured: the server-side cache window is only tens of seconds, so at a normal review cadence resuming costs more than a fresh call — see `references/model-routing.md`). Token usage per call, including cache hit rate, is appended to `$CODEX_REVIEW_LOG`; `scripts/codex-usage.sh` reports it.

**Rate limit:** if the script answers `[codex-review] RATE_LIMITED:`, that consultation did not happen — do not retry it, and close the review with the findings you already have, saying so in one line. The next review calls codex again as normal.

**Input too large.** If the script answers `[codex-review] FAILED: 輸入過長,未送出`, the consultation did **not** happen and this is *not* a quota problem — the diff exceeds codex's input limit, so it will never be reviewed until the scope is narrowed. Unlike RATE_LIMITED you must not just carry on: re-run with a tighter `--base` (per-commit or per-theme), or review the high-risk files separately from the test-file bulk. Treating it as reviewed is a false pass.

## Subagent Dispatch

**Pre-dispatch check (orchestrator runs this, before spawning the reviewer):**
- `git rev-parse <base>` and `git rev-parse HEAD` — invalid ref → stop, report to the user, do not dispatch
- Compute `git merge-base <base> HEAD` — this is BASE_SHA (the true comparison point, not the base branch tip)
- `git diff <BASE_SHA>..HEAD --stat` — empty diff → stop, report to the user, do not dispatch

For automated review, run a reviewer via Workflow `agent()` (or Agent tool directly for a single-file review) using the template at `mao-execute/code-reviewer-prompt.md`:
- Model & effort: default **B2** = `model:"sonnet"` + `effort:'medium'` (same routing as mao-execute; see `references/model-routing.md`). High-risk changes (security/auth/data) → **A** = omit `model` (inherits the session model) + `effort:'high'`
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
