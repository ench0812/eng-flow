# eng-flow

Streamlined engineering workflow skills for Claude Code — merged from [superpowers](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/superpowers) + [agent-skills](https://github.com/AiDD-Agents/claude-agent-skills), optimized for token efficiency (~93% reduction).

## Skills

| Skill | Description |
|-------|-------------|
| `mao-init` | Meta-dispatcher — maps task types to skills, core behavior rules |
| `mao-brainstorm` | Design-first exploration with HARD-GATE, 2-3 approaches, spec output |
| `mao-plan` | Task breakdown with checkboxes, no-placeholder discipline, vertical slicing |
| `mao-execute` | Subagent-driven execution with two-stage review (spec + quality) |
| `mao-debug` | Root-cause debugging — Iron Law + 6-step triage |
| `mao-tdd` | Red-Green-Refactor with DAMP > DRY, mock preference order |
| `mao-review` | Five-axis code review with severity labels |
| `mao-ship` | Branch completion — verification iron gate + merge options |
| `mao-secure` | Three-tier security boundary (Always / Ask First / Never) |
| `mao-optimize` | Measure-first performance optimization |
| `mao-comply` | ISO 27001 compliance self-check + git hook / CI gate deployment |

## References

`references/repomix.md` — when to use [repomix](https://github.com/yamadashy/repomix) to pack codebase context for an LLM/subagent (explore unfamiliar code, bundle a diff for a reviewer, trace a regression), the common commands, and the ISO 27001 / privacy rules. `mao-init`, `mao-brainstorm`, `mao-plan`, `mao-review`, and `mao-debug` point here. Requires the `repomix` CLI (`npm i -g repomix`).

`references/model-routing.md` — shared model-routing rules (opus for judgment, sonnet for execution stages, haiku for mechanical volume), plus the Codex cross-family consultation routing (`scripts/codex-review.sh`): diff second opinion at mao-review / mao-execute closing, spec/plan co-design loops in mao-brainstorm / mao-plan. Consultations are convergence-gated, not capped: every codex reply ends with one 收斂問句 (its most important open question, or 無), and Claude continues only while answering it would still change the artifact — the doc-mode script warns (non-blocking) at 6+ rounds. A `RATE_LIMITED` reply is not a consultation: no retry, no round logged, carry on. `mao-execute` and `mao-review` point here.

## Hooks

`hooks/iso-scan-write.sh` (PreToolUse Write|Edit) and `hooks/iso-scan-bash.sh` (PreToolUse Bash) — block hardcoded secrets, banned crypto, `--no-verify`, and remote-content-piped-to-shell; ask before destructive git operations. Both need `jq` on PATH — **without it they fail open and scan nothing**.

`hooks/git-unpushed-check.sh` (Stop) — catches work that is committed locally but never pushed, at the moment the risk becomes real: the end of a turn. Reports the repo, how far ahead it is, and the commit subjects; it never pushes on its own.

Guarantees that matter:

- **No network.** Compares against the local remote-tracking ref only, so no fetch, no credential prompt. Ordinary staleness (someone else pushed, you have not fetched) can only make it *over*-report. **Known blind spot, accepted deliberately:** if the remote branch was force-pushed over or deleted, the local tracking ref still contains `HEAD`, the check stays quiet, and those commits are in fact no longer on the remote. Closing that gap requires a fetch on every turn — network round-trip plus credential prompts — which is not a trade worth making for a background safety net.
- **Warns once per state.** A Stop hook's `additionalContext` continues the conversation, so re-warning on an unchanged condition would loop forever. Keyed on (session, repo, HEAD) — a new commit warns again, an unchanged one stays quiet.
- **No upstream is reported by severity, not as worst case.** A branch cut from `origin/main` with no tracking set still has all its commits on the remote; saying "no backup" there is crying wolf, and warnings that cry wolf get ignored. The hook checks whether `HEAD` is contained in any remote-tracking ref and words the message accordingly.

**Scope is the set of repos this session actually touched** — read from the transcript: every `cwd` that appeared, plus the directory of every file a Write/Edit acted on. Neither extreme works: checking only the current directory misses work you `cd`'d away from (or gives nothing when the cwd is not a repo), while scanning every repo on the machine reports projects unrelated to this session — and a warning that fires about things you are not working on gets ignored, which is the same as no warning at all.

Measured ~700 ms per turn against a 4.7 MB transcript, and it scales with transcript size rather than with how many repos exist on disk. `~/.claude/git-guard-roots` still works (one root per line, scanned to depth 3) but is now an explicit *addition* for repos you want watched whether or not you touched them — most setups do not need it.

## Tools

`scripts/memory.sh` — governance for Claude Code's memory stores. Memory degrades as it accumulates, and every failure mode is silent: one index line standing in for a file that holds ten separate facts, staleness written as prose that nothing can query, references to memories that no longer exist, and a "check for duplicates before saving" rule that depends entirely on remembering to check.

```bash
memory.sh audit  [--home PATH] [--today YYYY-MM-DD]
memory.sh index  [--check|--write] [--home PATH]
memory.sh search <keyword> [--home PATH]
```

Scans `<home>/memory/` plus `<home>/projects/*/memory/`. Exit `0` clean, `1` governance problems found, `2` usage error. `INFO`/`SUGGEST` go to stdout and never change the exit code — candidate heuristics that could fail the run would make "clean" an unstable target; `WARN` goes to stderr and does.

The `TOPICS` block is the one part kept by hand and copied through untouched, with one normalisation: trailing blank lines inside it are dropped, so the first `--write` after adding them reports drift once and then stays stable.

`index --check` and `audit` answer different questions and neither substitutes for the other: `--check` asks whether the index matches what the sources render to right now, `audit` asks whether the sources themselves are sound. A store with a malformed memory can pass `--check` — the renderer excludes it, and the index correctly reflects that exclusion. Run `audit` for governance, `--check` for sync.

**The resident index is generated, not maintained.** `MEMORY.md` holds the pinned memories' text between `PINNED:BEGIN/END` markers, rendered from the memory files themselves. `index --check` compares byte-for-byte, so editing a pinned memory without regenerating is caught rather than silently drifting. Nothing in the template varies with the number of memories — no counts, no audit summary — which is what makes the next claim hold.

**Resident cost is set by how many memories are pinned, not how many exist.** Measured on a 500-memory fixture: the index is byte-identical at 9 memories and at 500 (463 bytes both times), and pinning one more grows it by exactly the item marker plus that memory's body. `tests/memory.test.sh --only scale` asserts this, so a later change that reintroduces an N-dependent field fails the suite.

**Superseded memories are excluded structurally.** `supersedes`/`superseded_by` must agree in both directions; a one-sided edit is reported rather than guessed at. Superseded memories leave the index and the search results, so a plain `grep` — which would happily return the outdated fact — is the wrong tool and the index says so.

The generated index ends with two commands that reference `~/.claude/scripts/memory`, not the plugin path. Create that file as a two-line wrapper that resolves the installed plugin and runs `bash .../memory.sh "$@"` — invoked through `bash`, matching how every other script in this repo is called, so none of them carry an execute bit — the index is a resident document read on every session, so baking `plugins/cache/<marketplace>/eng-flow/<version>/scripts/memory.sh` into it would make every upgrade rewrite it and every stale copy point at a version that no longer exists.

The only file it ever writes inside the memory store is `MEMORY.md`, and only inside the tree `--home` names. (Scratch files go to the system temp directory through `mktemp` and are removed on exit; they hold ids, paths, descriptions and metadata — not memory bodies.) A bank whose path crosses a symlink below that root is refused outright rather than resolved, because the only file this tool ever writes is the index and its write boundary should be checkable at a glance; `--home` itself may be a symlink, since that is the root the caller declared. Paths containing control characters are refused for a separate reason: the internal model is delimited by `US`, and a control character in a filename shifts every field after it, so `pin` and `superseded_by` get read as something else entirely.

`index --write` is transactional: source-data errors block the whole run before anything is touched, every bank is staged first, each replace keeps a backup, and any failure restores all of them — including deleting an index that did not exist before, rather than leaving an empty one behind. `INT`/`TERM`/`HUP` roll back the same way, so a Ctrl-C between two banks does not leave a half-applied state. Staging and backup files are created with `mktemp` inside the target directory rather than from a `$PID`-derived name, which removes the check-then-open gap that a predictable name forces and the stale-file collisions that PID reuse causes. It does not make the write path race-proof against a process running as the same user — shell has no way to keep the descriptor `mktemp` opened — and it is not trying to: anyone who can win that race can also just write the index directly. What is *not* covered is `SIGKILL` or a power loss mid-`mv`; recovering from those means the backups left in the bank, which is why a failed rollback keeps them instead of cleaning up.

A failure anywhere in reading the sources stops the run rather than proceeding with less: an unreadable bank, a symlinked memory file, a path with control characters in it, or a checks pass that could not complete. The reason is that all of those look identical to "there is less here" downstream, and `--write` acting on that view would rewrite the index without the pinned bodies it could not read.

Case-insensitive search covers ASCII only (awk's `tolower`); CJK is unaffected since it has no case. CJK 2-gram similarity needs a character-oriented awk — gawk qualifies, mawk does not, and the audit prints which mode it used instead of silently degrading.

The two awk stages deliberately run under different locales, because they measure different things. Sizes are bytes, so the parser runs under `LC_ALL=C` and its `bytes=` matches `wc -c`; left in a multibyte locale, gawk's `length()` returns *characters* and a 3.7 KB Chinese memory reports as 1.2 KB — under the 2048-byte split threshold, so the one check that exists to catch overgrown memories goes quiet exactly where memories are written in Chinese. Similarity is about characters, so the checks stage stays in the ambient locale and slices 2-grams on character boundaries. Neither stage uses gawk-only constructs, and the suite asserts that, since a construct like `ENDFILE` fails silently under mawk rather than erroring.


`scripts/output-audit.sh` — offline analysis of Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) that quantifies how much context each tool and command actually consumes, and simulates what any candidate truncation threshold *would* have saved. Read-only, zero runtime cost, no hook.

```bash
bash scripts/output-audit.sh --days 14        # also: --top N, --bytes-per-token R
```

Why offline rather than a `PostToolUse` hook: the transcript already records every `tool_use`/`tool_result`, so a hook is duplicate collection that charges every single command — a measured 570 ms per Bash call at 86 KB of output. Claude Code also already persists oversized output to `tool-results/*.txt` and feeds the model a preview, so that layer does not need rebuilding.

Reads sizes as *what the model actually received*, which is the definition of context cost. Token counts are labelled estimates (fixed bytes/token ratio); threshold rows are an upper bound on what could be withheld, **not** net savings — retrieval and re-run costs are not in them, and the report prints the natural re-run rate as the baseline to compare against. Command previews are redacted (`Authorization` / `Bearer` / `token` / `api_key` / `password` / `secret`, including quoted values); no command text is ever written to a file.

Use it to decide *before* adding any lossy compression layer whether one is worth it — and note that the most actionable output is usually the per-command table, since changing the command itself is lossless.

## Install

### Method 1: Add marketplace + install (recommended)

First, add the marketplace source (one-time setup):

```
/plugin marketplace add https://github.com/ench0812/eng-flow.git
```

Then install:

```
/plugin install eng-flow
```

### Method 2: Direct GitHub URL

```
/plugin install --url https://github.com/ench0812/eng-flow.git
```

### Method 3: Manual (edit JSON)

Add to `~/.claude/plugins/installed_plugins.json`:

```json
"eng-flow@ench0812-plugins": [
  {
    "scope": "user",
    "installPath": "<path-to-cached-clone>",
    "version": "1.0.0",
    "installedAt": "2026-05-11T00:00:00.000Z",
    "lastUpdated": "2026-05-11T00:00:00.000Z"
  }
]
```

## Uninstall

```
/plugin uninstall eng-flow
```

## License

MIT
