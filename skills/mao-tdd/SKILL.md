---
name: mao-tdd
description: 測試驅動開發。實作新邏輯或修 bug 時使用。Iron Law：沒有失敗的測試就不寫 production code。
---

# Test-Driven Development

<SUBAGENT-STOP>
If you are a subagent executing a specific task dispatched by mao-execute (via Agent tool OR a Workflow agent()), your prompt template already embeds the TDD requirements — do NOT re-invoke this skill; follow your prompt.
</SUBAGENT-STOP>

## Iron Law

**NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST.** No exceptions without explicit user approval.

## Red-Green-Refactor Cycle

### 1. RED — Write a failing test
```
- Search existing tests first — if the behavior area is already covered,
  extend or parameterize that test instead of adding a parallel one
- One failing test at a time — not a batch
- Test describes the desired behavior
- Run it — it MUST fail
- If it passes, your test is wrong or the feature already exists
- "It went red" is not evidence: an exception, import error, empty result or compile failure all show red. Only an expected/actual mismatch whose difference is the behavior being fixed proves the test measures it. Quote that expected/actual in the RED evidence, not just the assertion line.
- Legitimate forms: for a new function or type, first add a stub or signature so it compiles/imports, then let the test fail on behavior. For a test expecting an exception or expecting something not to happen, use the expected exception type and message against the actual behavior as expected/actual.
```

### 2. GREEN — Write minimal code to pass
```
- Only enough code to make the test pass
- No extra features, no "while I'm here" improvements
- Run the affected test file(s) — new one passes, existing ones still pass
```

### 3. REFACTOR — Clean up (tests still pass)
```
- Improve code quality without changing behavior
- Run the affected test file(s) after every change
- Before committing, run the targeted scope: affected test file(s) plus tests of modules directly depending on the change. The full suite is deferred to the integration point (mao-execute final integration review / mao-ship gate) — run it now only if you cannot confidently bound the affected scope
- Commit when clean
```

## Test Quality Guidelines

**DAMP over DRY:** Tests should be self-contained and readable. Duplication in tests is acceptable — shared setup that hides test intent is not.

**AAA Pattern:** Arrange → Act → Assert. One concept per test.

**Mock Preference Order:** Real implementations > Fakes > Stubs > Mocks. Use the least fake thing that makes the test fast and reliable.

**Name tests by behavior:** `should reject expired tokens` not `testValidateToken3`.

**No Tautological Assertions:** Expected values must come from an independent source of truth — a known-good literal, a worked example, or the spec. Never recompute the expected value using the same logic as the code under test — it then passes by construction and proves nothing.

**Known-bad controls for checkers:** When writing a check, comparison or gate tool (verification script, diff script, CI gate), plant one known-bad input for every class of error it claims to catch and confirm it is reported. Missing required input must be refused or answered "cannot determine" — never "match" or "pass".

**Probes must need the new artifact:** A verification probe has to depend on behavior only the new build can produce, not on identity fields the old build also reports (the same version string or SHA).

## The Prove-It Pattern (Bug Fixes)

1. Write a test that reproduces the bug (RED)
2. Verify it fails for the right reason (RED evidence per step 1) and keep an excerpt of that failing-before output for the final report
3. Fix the bug (GREEN)
4. Verify the targeted scope passes — the new test plus affected test file(s); the full suite runs at the integration/ship gate

This guarantees the bug is actually fixed and won't recur.

## Negative Controls (Mutation Checks)

A green test proves nothing about a guard until you have seen it go red when the guard is broken. For a bug-fix regression test, a security/validation gate, a checker or gate tool, or a refactor you claim is covered, break the **code under test** on purpose and confirm the right test goes red. Not for every test: each mutation costs one test run, so spend them where "this test guards X" will be reported as evidence.

```
python ${CLAUDE_PLUGIN_ROOT}/scripts/mutate.py --file src/guard.py --find "if age < 18:" --replace "if age < 0:" \
  --cmd "python -m pytest -q" --expect-fail test_rejects_minors
python ${CLAUDE_PLUGIN_ROOT}/scripts/mutate.py --spec mutations.json --cmd "go test -count=1 ./..."   # several mutations, each from the original
```

Verdict per mutation (exit 0 only if all are `RED`): `RED` ran and failed (the expected test, if `--expect-fail`); `GREEN` ran and passed — nothing noticed; `RED_WRONG` failed, but not the test you meant to prove; `NOT_RUN` the tests did not run to completion (syntax or build error, timeout, no summary) so the exit code is ignored; `BASELINE_*` the unmutated run was not green-and-ran, so no mutation was applied. Built-in runner rules: pytest, go, unittest (checked against real output); vitest, jest (written from the documented format, not checked against real output — pass `--ran-pattern` if they misread). Any other runner needs `--ran-pattern`.

What the script already does, so do not redo it by hand: demands exactly one byte-exact match; edits bytes only (a `write_text` round trip flips LF files to CRLF on Windows while a `read_text` comparison still passes); gives every run a fresh `PYTHONPYCACHEPREFIX` (a pyc that matches on mtime-in-seconds and size silently runs the previous mutation); restores only the mutated segment and verifies SHA-256 (never `git checkout <file>`, which also discards uncommitted real fixes); restores on Ctrl+C / SIGTERM and kills the test process tree.

What stays on you:
- **Mutate only the code under test.** Never the test file or the probe/hook the test observes: that proves the instrument sees a difference, not that a broken implementation is caught (the script refuses test-looking paths unless `--allow-test-file`).
- **One mutation per claim, designed to change behavior on the existing test data** (flip a boundary, drop a branch, reverse a direction). On `GREEN`, first hand-check that the mutation really changes behavior for these inputs (a no-op-equivalent mutation means fix the mutation, not the test); only then suspect the test. On `RED_WRONG` or many unrelated reds, the mutation was too coarse: split it so exactly the intended test goes red.
- **A negative control cannot see a test that is broken by itself** (an assertion that compares a value to itself, a baseline captured after the state change). Read the test, not just the colors.
- Git Bash rewrites arguments that look like Unix paths and the Bash tool halves backslashes: pass strings with `/`, `\`, newlines or a leading `-` through `--spec` JSON.

## When Stuck

| Situation | Action |
|-----------|--------|
| Can't write the test | You don't understand the requirement — clarify first |
| Test is hard to set up | The design has too many dependencies — simplify |
| Test is brittle | You're testing implementation, not behavior — rewrite |
| Too many mocks | The code is too coupled — refactor boundaries |

## Test Pyramid

| Level | Speed | Scope | When |
|-------|-------|-------|------|
| Unit | Fast | Single function/class | Always |
| Integration | Medium | Multiple components | API boundaries, DB queries |
| E2E | Slow | Full system | Critical user flows only |

Prefer more unit tests, fewer integration tests, fewest E2E tests.

## Suite Growth Discipline（測試時間預算）

Tests are code with a runtime cost that compounds: every test added slows every future loop for the project's whole life. Balance coverage against suite time deliberately — the goal is a suite whose runtime stays roughly flat while coverage grows:

- **One behavior, one test.** Before RED, search for an existing test of the behavior; extend or parameterize it instead of duplicating. A bug's regression test goes at the **lowest pyramid level that reproduces it** (unit > integration > E2E).
- **Tests share the behavior's lifecycle.** Behavior removed or changed → delete or rewrite its tests in the same commit. An obsolete test is dead code that still bills runtime on every run.
- **Push coverage down.** Integration/E2E must not re-assert branch logic a unit test already proves — they cover seams and critical happy paths only. Before adding an E2E, name what a unit or integration test cannot express about it; no answer → no E2E.
- **Speed red lines** (the three suite killers): unit tests do no real I/O (network / disk / DB → fakes), no `sleep` (fake clocks / injected time), heavyweight fixtures built once and shared **only if immutable** — mutable fixture state gets reset or rebuilt per test (shared mutable fixtures breed order-dependent flakes and parallel-run races). A test breaking a red line either gets fixed or explicitly moves to a slower tier; it does not stay in the unit tier.
- **Time budget with a tripwire.** Defaults (override per project in its AGENTS.md; older projects may still use CLAUDE.md): targeted scope ≤ ~30s, full suite ≤ 10 min. The absolute budget is stateless — check it whenever the full suite runs at an integration point; over budget → file a **test-debt item** for the user (merge duplicates, push levels down, fix red-line offenders). Growth detection (>20% since the last run) is **opt-in per project**: it needs a runtime ledger — one line in the project's AGENTS.md (older projects may still keep it in CLAUDE.md), `full suite: <duration> @<date>`. Where the ledger exists, read the previous value and compare **before** overwriting it, folding the update into the integration's own commit — never a standalone ledger-only commit. Don't create the ledger uninvited; propose it in the first test-debt item instead. The tripwire schedules cleanup — it never blocks the merge at hand.

## Red Flags
- Writing production code before the test
- Test that passes on first run (test is wrong)
- "I'll add tests later" (later never comes)
- Testing implementation details instead of behavior
- Mocking everything (tests prove nothing)
- Skipping the RED step ("I know it'll fail")
- Tautological assertions — expected value recomputed via the same logic as the code
- Adding a parallel test for a behavior an existing test already covers
- Unit tests doing real I/O or sleeping — that's how suites get slow
- Deleting a behavior but leaving its tests behind
