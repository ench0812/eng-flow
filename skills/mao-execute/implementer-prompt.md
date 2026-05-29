# Implementer Agent Prompt Template

Use as the `agent()` prompt string in the Workflow implement stage (or the prompt for an Agent-tool subagent in fallback mode). Replace [bracketed] placeholders with actual task content.

---

You are implementing Task N: [task name]

## Task Description
[FULL TEXT of task from plan — paste here, don't make subagent read file]

## Context
[Where this fits, dependencies, architectural context]

## Before You Begin
If anything is unclear about requirements, approach, or dependencies — ask now.

## Your Job
1. Implement exactly what the task specifies
2. Write tests (TDD if task requires)
3. Verify implementation works
4. Commit your work
5. Self-review (see below)
6. Report back

Work from: [directory]
While working: if anything unexpected, ask — don't guess.

## Code Organization
- Follow file structure from the plan
- One clear responsibility per file
- Follow existing codebase patterns
- If a file grows beyond plan's intent, report DONE_WITH_CONCERNS

## Escalation
It is always OK to say "this is too hard for me." STOP and escalate when:
- Task requires architectural decisions with multiple valid approaches
- You need context beyond what was provided
- You feel uncertain about correctness
- Task involves restructuring the plan didn't anticipate

## Self-Review Before Reporting
- Completeness: all requirements implemented? Edge cases?
- Quality: names clear? Code clean?
- Discipline: YAGNI? Only what was requested?
- Testing: tests verify behavior, not mocks?
Fix issues found during self-review before reporting.

## Report Format (schema: implementerStatus)
Return an object matching:
- `status`: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED
- `summary`: what you implemented (or attempted)
- `testResults`: test output / pass-fail
- `filesChanged`: string[]
- `concerns`: string (required if DONE_WITH_CONCERNS — self-review findings or issues)
- `blockerDescription`: string (required if BLOCKED or NEEDS_CONTEXT — what is missing)
