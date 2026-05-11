# eng-flow

Streamlined engineering workflow skills for Claude Code — merged from [superpowers](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/superpowers) + [agent-skills](https://github.com/AiDD-Agents/claude-agent-skills), optimized for token efficiency (~93% reduction).

## Skills

| Skill | Description |
|-------|-------------|
| `init` | Meta-dispatcher — maps task types to skills, core behavior rules |
| `brainstorm` | Design-first exploration with HARD-GATE, 2-3 approaches, spec output |
| `plan` | Task breakdown with checkboxes, no-placeholder discipline, vertical slicing |
| `execute` | Subagent-driven execution with two-stage review (spec + quality) |
| `debug` | Root-cause debugging — Iron Law + 6-step triage |
| `tdd` | Red-Green-Refactor with DAMP > DRY, mock preference order |
| `review` | Five-axis code review with severity labels |
| `ship` | Branch completion — verification iron gate + merge options |
| `secure` | Three-tier security boundary (Always / Ask First / Never) |
| `optimize` | Measure-first performance optimization |

## Install

```bash
# In Claude Code
/plugin install from local path: C:\Users\markh\.claude\plugins\local\eng-flow
```

Or add to `~/.claude/plugins/installed_plugins.json` manually.

## License

MIT
