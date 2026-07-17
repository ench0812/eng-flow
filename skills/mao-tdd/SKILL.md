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
- Test describes the desired behavior
- Run it — it MUST fail
- If it passes, your test is wrong or the feature already exists
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
- Run the full suite once before committing
- Commit when clean
```

## Test Quality Guidelines

**DAMP over DRY:** Tests should be self-contained and readable. Duplication in tests is acceptable — shared setup that hides test intent is not.

**AAA Pattern:** Arrange → Act → Assert. One concept per test.

**Mock Preference Order:** Real implementations > Fakes > Stubs > Mocks. Use the least fake thing that makes the test fast and reliable.

**Name tests by behavior:** `should reject expired tokens` not `testValidateToken3`.

**No Tautological Assertions:** Expected values must come from an independent source of truth — a known-good literal, a worked example, or the spec. Never recompute the expected value using the same logic as the code under test — it then passes by construction and proves nothing.

## The Prove-It Pattern (Bug Fixes)

1. Write a test that reproduces the bug (RED)
2. Verify it fails for the right reason
3. Fix the bug (GREEN)
4. Verify all tests pass

This guarantees the bug is actually fixed and won't recur.

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

## Red Flags
- Writing production code before the test
- Test that passes on first run (test is wrong)
- "I'll add tests later" (later never comes)
- Testing implementation details instead of behavior
- Mocking everything (tests prove nothing)
- Skipping the RED step ("I know it'll fail")
- Tautological assertions — expected value recomputed via the same logic as the code
