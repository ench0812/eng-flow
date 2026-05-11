---
name: review
description: 五軸 code review。合併前檢查、PR review、code quality 審查時使用。
---

# Five-Axis Code Review

## Approval Standard

Approve when the change **definitely improves overall code health**, even if it isn't perfect. Don't block because it isn't how you'd have written it.

## The Five Axes

### 1. Correctness
- Matches spec/task requirements?
- Edge cases handled (null, empty, boundary)?
- Error paths handled (not just happy path)?
- Tests cover the change adequately?

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

### 4. Security
- User input validated and sanitized?
- Secrets out of code, logs, version control?
- Auth/authz checked where needed?
- Queries parameterized? Outputs encoded?

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

## Change Sizing

- ~100 lines → Good
- ~300 lines → Acceptable if single logical change
- ~1000 lines → Too large, split it

**Splitting strategies:** Stack (sequential deps), By file group (cross-cutting), Horizontal (shared code first), Vertical (smaller full-stack slices).

## Review Process

1. **Understand context** — what is this change trying to accomplish?
2. **Review tests first** — tests reveal intent and coverage
3. **Review implementation** — walk through each file with 5 axes
4. **Categorize findings** — label severity on every comment
5. **Verify verification** — what tests ran? Build pass? Manual check?

## Subagent Dispatch

For automated review, dispatch a reviewer subagent using the template at `execute/code-reviewer-prompt.md`:
- Provide git SHAs (base and head)
- Include task/plan requirements
- List changed files

## Dead Code Hygiene

After refactoring, check for orphaned code. List it explicitly and ask before deleting.

## Red Flags
- PRs merged without review
- "LGTM" without evidence of actual review
- No regression tests with bug fix PRs
- Large PRs that skip proper review
- Accepting "I'll fix it later"
