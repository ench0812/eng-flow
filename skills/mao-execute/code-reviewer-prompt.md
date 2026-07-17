# Code Quality Reviewer Prompt Template

Only dispatch after spec compliance review passes. Use as the `agent()` prompt string in the Workflow code-review stage (or the prompt for an Agent-tool subagent in fallback mode). Replace [bracketed] placeholders. BASE_SHA depends on review scope: per-task review inside mao-execute → the SHA this task started from (the previous task's HEAD), so the diff covers only this task; whole-branch review (mao-review) → the merge-base of the base branch and HEAD (`git merge-base <base> HEAD`), not the base branch tip, to exclude unrelated upstream commits.

---

Review the code changes between BASE_SHA and HEAD_SHA for quality.

## Plan/Requirements
[Task description from plan]

## Review Axes
**1. Correctness** — Does code do what spec says? Edge cases? Error paths? No tautological assertions (expected values from an independent source, not recomputed by the same logic)?
**2. Readability** — Clear names? Straightforward flow? No clever tricks?
**3. Architecture** — Follows existing patterns? Clean boundaries? No duplication? Delete this module — does complexity vanish (pass-through, cut it) or reappear at every caller (earns its keep)? Only one implementation behind this interface — premature abstraction; extract only once a second real one exists.
**4. Security** — Input validated? Secrets safe? Auth checked? No injection?
**5. Performance** — No N+1? No unbounded ops? Async where needed?

Also check:
- Each file has one clear responsibility
- No large files created or significantly grown
- Implementation follows the plan's file structure

## Severity Labels
- **Critical:** Blocks merge (security, data loss, broken functionality)
- **Required:** Should fix before merge
- **Optional:** Nice to have, author may defer
- **Nit:** Style preference, optional

## DO
- Read code; don't trust summaries
- Flag actual bugs and security issues
- Suggest simpler alternatives when code is unnecessarily complex
- Approve when the change improves overall code health

## DON'T
- Rubber-stamp with "LGTM"
- Block on style preferences
- Rewrite working code to match personal taste
- Nitpick formatting that linters should catch

## Report Format (schema: reviewVerdict)
Return an object matching:
- `verdict`: APPROVE | REQUEST_CHANGES
- `strengths`: string (what's done well)
- `issues`: [{ severity: Critical|Required|Optional|Nit, file, line, description }]
