# Codex CLI Project Structure Reference

## Directory Layout

```
project-root/
├── AGENTS.md                    # Main project instructions (= CLAUDE.md symlink or copy)
├── AGENTS.override.md           # Supplementary Codex-specific rules
├── .agents/
│   ├── skills/
│   │   └── <skill-name>/
│   │       ├── SKILL.md         # Real file copy (NOT symlink)
│   │       ├── references/      # Symlink to source
│   │       ├── scripts/         # Symlink to source (if exists)
│   │       ├── assets/          # Symlink to source (if exists)
│   │       └── agents/
│   │           └── openai.yaml  # Auto-generated from frontmatter
│   └── <agent-name>.md          # Agent files (real copies)
├── .codex/
│   └── config.toml              # MCP server config (TOML format)
└── .gitignore                   # Should include AGENTS.md, AGENTS.override.md (.agents/, .codex/ are in global gitignore)
```

## Key Differences from Claude Code

| Aspect | Claude Code | Codex CLI |
|--------|-------------|-----------|
| Instructions | `CLAUDE.md` | `AGENTS.md` + `AGENTS.override.md` |
| Skills dir | `.claude/skills/` | `.agents/skills/` |
| Skill invoke | `/skill-name` | `$skill-name` |
| Agents dir | `.claude/agents/` | `.agents/*.md` |
| MCP config | `.mcp.json` (JSON) | `.codex/config.toml` (TOML) |
| Rules | `rules/*.md` (markdown AI guidelines) | `rules/*.rules` (Starlark execution policy) |
| Plugins | Supported | Not supported |
| Hooks | `hooks.json` | Not supported |

## Critical: SKILL.md Must Be Real File

Codex's project-scope scanner may not follow symlinks for SKILL.md discovery.
Always use file copies, never symlinks, for SKILL.md files.
See: `runbook-codex-compat-2026-02-08.md`

## openai.yaml Format

```yaml
interface:
  display_name: "Skill Display Name"
  short_description: "Brief description (max 128 chars)"
  default_prompt: "Use $skill-name to help with this task."
```

## Known Limitations

- `allowed-tools` frontmatter from SKILL.md has no Codex equivalent. This metadata is present in projected SKILL.md files but silently ignored by Codex CLI.
- Claude Code rules with `alwaysApply: false` are included in AGENTS.override.md but will always be applied (Codex has no conditional rule application). Rules with `alwaysApply: true` behave identically.
- Hooks (`hooks.json`) and plugins are Claude Code-only features with no Codex equivalent.

## Global vs Project Scope

- Global skills: `~/.codex/skills/` (user scope, all projects)
- Project skills: `.agents/skills/` (project scope, this project only)
- Global config: `~/.codex/config.toml`
- Project config: `.codex/config.toml`
