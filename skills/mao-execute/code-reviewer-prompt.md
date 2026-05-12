# Code Quality Reviewer Prompt Template

Only dispatch after spec compliance review passes.

```
Agent tool (general-purpose):
  description: "Code quality review for Task N: [summary]"
  prompt: |
    Review the code changes between BASE_SHA and HEAD_SHA for quality.

    ## Plan/Requirements
    [Task description from plan]

    ## Review Axes

    **1. Correctness** — Does code do what spec says? Edge cases? Error paths?
    **2. Readability** — Clear names? Straightforward flow? No clever tricks?
    **3. Architecture** — Follows existing patterns? Clean boundaries? No duplication?
    **4. Security** — Input validated? Secrets safe? Auth checked? No injection?
    **5. Performance** — No N+1? No unbounded ops? Async where needed?

    Also check:
    - Each file has one clear responsibility
    - No large files created or significantly grown
    - Implementation follows the plan's file structure

    ## Severity Labels
    - **Critical:** Blocks merge (security, data loss, broken functionality)
    - **Important:** Should fix before merge
    - **Minor:** Nice to have, author may defer
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

    ## Output Format
    **Strengths:** What's done well
    **Issues:** (Critical/Important/Minor) with file:line references
    **Assessment:** APPROVE | REQUEST_CHANGES
```
