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
3. Tests:        FULL test suite (project-specific command) — dev-loop commits only ran targeted scopes; this gate is the full-suite checkpoint.
                 Check runtime against the mao-tdd budget (plus the project's runtime ledger where kept — update it inside the merge commit); over → file a test-debt item (debt never blocks this gate)
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

## Merging a PR

A review or a green check is a verdict on one head commit. Bind the merge to it, then prove the merge landed:

1. **Pin the head.** Record the head SHA the review and the gate ran on. If `gh pr view <n> --json headRefOid` no longer matches it, review the delta first. Confirm `baseRefName` is the intended target: the head guard does not catch a retargeted base.
2. **Merge with the guard.** `gh pr merge <n> --match-head-commit <reviewed-sha>` plus the merge-method flag. A push that lands after the review makes the merge fail instead of shipping unreviewed code.
3. **Read it back.** "Merge succeeded" is not proof: on a base that requires a merge queue, `gh pr merge` only enables auto-merge or enqueues the PR, and `--auto` never merges on the spot. Require `gh pr view <n> --json state -q .state` to print `MERGED`, then `git fetch` and `git merge-base --is-ancestor $(gh pr view <n> --json mergeCommit -q .mergeCommit.oid) origin/<base>` to exit 0. For a local merge pushed directly, ask the remote itself: `git ls-remote origin refs/heads/<base>` must print the local branch's SHA (a successful push also rewrites the local `origin/<base>`, so that ref proves nothing).

## Merge Conflict Resolution

When a merge or rebase produces conflicts:

1. **Survey** — run `git status` to see every conflicted file. Don't resolve blind.
2. **Recover intent** — for each conflict, read the commit message, PR description, or linked issue behind both sides before touching the hunk. Diff text alone doesn't tell you *why* a change was made.
3. **Resolve hunk by hunk** — preserve both sides' intent where they're compatible. Where they're not, pick the side that matches the merge's goal and note the trade-off in the commit/PR body. Do not invent new behaviour neither side asked for.
4. **Re-verify** — re-run the same checks as the Verification Iron Gate above; a clean-looking merge can still break the build or tests.
5. **Finish** — commit (merge) or run `git rebase --continue` through to completion (rebase).

Do not use `--abort` to escape a conflict — that's a decision, not a shortcut. Abandoning the merge/rebase requires explicit user confirmation.

## Git Discipline

**Atomic commits:** Each commit is one logical change that builds and passes its targeted tests (affected test file(s) + directly dependent modules). The full suite gates merge/push/release, not every commit.

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

If working in a git worktree, list what removal would destroy before removing it. An empty `git diff` does not mean nothing is lost:
1. **Uncommitted and ignored files.** `git -C <wt> status --porcelain --untracked-files=all --ignored=matching --ignore-submodules=none`. `git worktree remove` deletes ignored files (`!!` lines: `.env`, `settings.local.json`, local data) without warning. List their paths only, never print their contents, and confirm each has a copy elsewhere or can be regenerated.
2. **Commits only this worktree can reach.** The worktree's HEAD and its reflog are deleted with it, so a commit made on a detached HEAD, or on a branch deleted since, loses its last reference. `git -C <wt> reflog --format=%H HEAD | git -C <wt> rev-list --stdin HEAD --not --branches --remotes --tags` counts as clean only when it exits 0, writes nothing to stderr, and prints nothing; any other result means unknown, not clean. Keep each listed commit with `git branch keep/<name> <sha>`.
3. **Submodules.** Their git dirs live under the worktree's admin dir (`.git/worktrees/<name>/modules/`) and are deleted with it, local branches and any `keep/` branch included, and steps 1–2 cannot see inside them. For each path in `git -C <wt> submodule status --recursive`, run step 1 inside it, then `git -C <sm> reflog --format=%H HEAD | git -C <sm> rev-list --stdin HEAD --branches --not --remotes` with step 2's clean criteria: only a commit already on a remote counts as safe. Push what it lists, or stop and ask the user.
4. **Locks.** A worktree marked `locked` in `git worktree list --porcelain` was locked on purpose. Find out why; do not force it.
5. Return to the main workspace in a separate command, then `git worktree remove <wt>`. Use `--force` only when every item steps 1–3 listed is handled (copied elsewhere, regenerable, kept on a `keep/` branch in the main repo, or pushed) or the user confirmed the loss.

## Red Flags
- Merging without running tests
- "Tests probably pass" without evidence
- Force-pushing to shared branches without user approval
- Skipping the change summary
- Leaving worktrees with uncommitted changes
- Merging a PR without `--match-head-commit`, or reporting it merged without reading the state back
