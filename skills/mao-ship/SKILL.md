---
name: mao-ship
description: 分支完成 + 合併流程。準備合併、發布、結束 feature branch 時使用。
---

# Ship: Branch Completion

## Verification Iron Gate

**Before presenting any options, run ALL verification commands and capture output as evidence.** No claims of success without proof.

```bash
# Run these FIRST — no exceptions
1. Build:        project-specific build command
2. Lint:         project-specific lint command
3. Tests:        project-specific test command
4. Git status:   git status + git log --oneline main..HEAD
5. Debug residue (optional, cheap): grep -rn '\[DEBUG-' <changed files>
```

If ANY verification fails → fix before proceeding. Do not present merge options with failing tests.

## Merge Options

After verification passes, present these options:

| Option | When |
|--------|------|
| **Merge locally** | Working on main, or ready to merge feature branch |
| **Push + Create PR** | Need review from others, or want CI to run |
| **Keep as-is** | Not ready yet, will continue later |
| **Discard** | Experiment that didn't work out |

## Merge Conflict Resolution

When a merge or rebase produces conflicts:

1. **Survey** — run `git status` to see every conflicted file. Don't resolve blind.
2. **Recover intent** — for each conflict, read the commit message, PR description, or linked issue behind both sides before touching the hunk. Diff text alone doesn't tell you *why* a change was made.
3. **Resolve hunk by hunk** — preserve both sides' intent where they're compatible. Where they're not, pick the side that matches the merge's goal and note the trade-off in the commit/PR body. Do not invent new behaviour neither side asked for.
4. **Re-verify** — re-run the same checks as the Verification Iron Gate above; a clean-looking merge can still break the build or tests.
5. **Finish** — commit (merge) or run `git rebase --continue` through to completion (rebase).

Do not use `--abort` to escape a conflict — that's a decision, not a shortcut. Abandoning the merge/rebase requires explicit user confirmation.

## Git Discipline

**Atomic commits:** Each commit is one logical change that builds and passes tests.

**Conventional commit types:**
- `feat:` new feature
- `fix:` bug fix
- `refactor:` code change that doesn't fix a bug or add a feature
- `test:` adding or fixing tests
- `docs:` documentation only
- `chore:` maintenance (deps, config)

**Commit message:** First line: short imperative summary. Body: what and why (not how). Include context not visible in the diff.

## Change Summary

Before marking work complete, provide:

```
CHANGES MADE:
- [what was added/modified/removed]

DIDN'T TOUCH:
- [explicitly scope what wasn't changed]

CONCERNS:
- [anything the user should know]
```

## Worktree Cleanup

If working in a git worktree:
1. Verify all changes are committed or intentionally discarded
2. Return to main workspace
3. Clean up worktree directory

## Red Flags
- Merging without running tests
- "Tests probably pass" without evidence
- Force-pushing to shared branches without user approval
- Skipping the change summary
- Leaving worktrees with uncommitted changes
