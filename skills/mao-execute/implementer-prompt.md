# Implementer Agent Prompt Template

Use as the `agent()` prompt string in the Workflow implement stage (or the prompt for an Agent-tool subagent in fallback mode). Replace [bracketed] placeholders with actual task content.

---

You are implementing Task N: [task name]

## Task
[Goal, acceptance criteria, and binding constraints — verbatim from the plan. Paste only these; not the whole task block, not the whole plan.]

## Pointers (open only when a step needs them)
[Plan/spec path + section anchor for anything else the task refers to; file path + symbol name for the code to change or mirror; interface signatures this task must match. One line each.]

## Context
[Where this fits, dependencies, architectural context — a few lines]

## Before You Begin
You have no channel to ask questions mid-task. If requirements, approach, or dependencies are unclear, stop and return `NEEDS_CONTEXT` with what is missing in `blockerDescription` rather than guessing.

## Your Job
1. Implement exactly what the task specifies
2. Write tests (TDD if task requires) — expected values must come from an independent source, never recomputed by the implementation's own logic. Search existing tests first: extend/parameterize rather than add a parallel test; put regression tests at the lowest level that reproduces the issue; unit tests do no real I/O and no sleeps (fakes / fake clocks); behavior you remove or change takes its obsolete tests with it in the same commit
3. Verify implementation works — run the affected test file(s) as you go; before your final commit, run the targeted scope: the task's test file(s) plus tests of modules that directly depend on what you changed. Do NOT run the full suite, full CI, or mutation runs — they run once at the final integration review, not per task. If you cannot confidently bound the affected scope (shared package, cross-cutting change), run the widest targeted scope you can bound, and name the full verification the orchestrator must run, and why, in `concerns`. In `testResults` give each command, its exit code, the result summary, and the full log path (send long output to a log: `LOG=$(mktemp)`, then `cmd > "$LOG" 2>&1; echo "rc=$?"`, then grep the failures; a non-zero exit with an empty grep means you read a bounded tail of the log — an empty summary is never a pass). A pass claim without output is not a verification.
4. Commit your work — also after each completed step, as an unpushed checkpoint, so progress survives if you die mid-task (checkpoints are not deliveries; review gates merge/push/deploy, not them). Also keep a short progress note at `$(git rev-parse --absolute-git-dir)/eng-flow-progress.md` (never committed): done, remaining, verification evidence, constraints to keep. If your context gets compacted, read it before continuing.
5. Report back

Context discipline: every request re-sends your whole context, so read only what the next step needs. Open the Pointers only when a step needs them; locate code with Grep (`-n`) and Read just that range with `offset`/`limit`; don't read files over ~500 lines in full or re-read whole files already in context; after an Edit, the edit result is your confirmation.

Resource limits: cap multi-worker test runners explicitly (e.g. `jest --maxWorkers=2`) — other agents share this machine. Wait for background work with `run_in_background` and its completion notification, or a bounded poll — never by relying on a monitor to wake you. Subagent prompt caches expire after five minutes (tier-b1 is set to an hour, but the platform can drop that to five minutes and you cannot tell), so keep each blocking wait under 270 seconds and poll again. A poll timing out ends the wait only; never kill the job and restart it.

Work from: [directory]
While working: if something unexpected changes what the task should do, return `NEEDS_CONTEXT` or `DONE_WITH_CONCERNS` instead of guessing. Otherwise keep working until every part of the task is done — returning after one part to ask whether to continue leaves the rest undone, because nobody can answer you mid-task.
When the task is done and its checks pass, report. Beyond the tests and steps this prompt asks for, don't add features, tests, files, docs or refactors, and don't start your own extra review or hardening rounds or launch reviewer sub-agents — spec review and code review run after you. If you think something extra would help, put it in `concerns`.

## Code Organization
- Follow file structure from the plan
- One clear responsibility per file
- Follow existing codebase patterns
- If a file grows beyond plan's intent, report DONE_WITH_CONCERNS

## Escalation
It is always OK to say "this is too hard for me." STOP and escalate when:
- Task requires architectural decisions with multiple valid approaches
- You need context beyond what was provided
- You are uncertain about correctness and the tests you can run cannot settle it (run them first — uncertainty a test can resolve is not a reason to stop)
- Task involves restructuring the plan didn't anticipate

## Report Format (schema: implementerStatus)
Return an object matching:
- `status`: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED
- `summary`: what you implemented (or attempted)
- `testResults`: test output / pass-fail; for new behavior or a bug fix, also an excerpt of the RED-stage failure showing expected vs actual (an exception, import or compile error alone is not RED evidence)
- `filesChanged`: string[]
- `concerns`: string (required if DONE_WITH_CONCERNS — what you are unsure about, or what turned out to fall outside the task's intent)
- `blockerDescription`: string (required if BLOCKED or NEEDS_CONTEXT — what is missing)
