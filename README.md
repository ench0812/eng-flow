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
