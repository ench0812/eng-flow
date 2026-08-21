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
