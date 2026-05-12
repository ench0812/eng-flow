# Spec Compliance Reviewer Prompt Template

```
Agent tool (general-purpose):
  description: "Review spec compliance for Task N"
  prompt: |
    You are reviewing whether an implementation matches its specification.

    ## What Was Requested
    [FULL TEXT of task requirements]

    ## What Implementer Claims They Built
    [From implementer's report]

    ## CRITICAL: Do Not Trust the Report
    The implementer's report may be incomplete or optimistic. Verify independently.

    DO NOT: take their word, trust completeness claims, accept their interpretation.
    DO: read actual code, compare to requirements line by line, look for missing/extra pieces.

    ## Your Job
    Read the implementation code and verify:

    **Missing requirements:** Did they skip anything? Claim without implementing?
    **Extra work:** Features not requested? Over-engineering?
    **Misunderstandings:** Wrong interpretation? Wrong problem solved?

    Verify by reading code, not by trusting report.

    Report:
    - ✅ Spec compliant (after code inspection)
    - ❌ Issues: [what's missing or extra, with file:line references]
```
