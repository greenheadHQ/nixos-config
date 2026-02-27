# Codex CLI Project Structure Reference

## Directory Layout

```
project-root/
├── AGENTS.md                    # Main project instructions (= CLAUDE.md symlink or copy)
├── AGENTS.override.md           # Supplementary Codex-specific rules
├── .agents/
│   ├── skills/
│   │   └── <skill-name>/       # Directory symlink → ../../.claude/skills/<skill-name>
│   │       ├── SKILL.md         # (via symlink — real file lives in .claude/skills/)
│   │       ├── references/      # (via symlink — real dir lives in .claude/skills/)
│   │       ├── scripts/         # (via symlink, if exists)
│   │       └── assets/          # (via symlink, if exists)
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

## Critical: Directory-Level Symlinks Only

Codex CLI는 **디렉토리 심링크**를 따라가지만 **파일 심링크**는 무시한다 (PR #8801).
`.agents/skills/<name>`은 반드시 디렉토리 심링크여야 하며, 파일 단위 심링크는 사용 불가.
See: `runbook-codex-compat.md`

## openai.yaml (Optional)

Codex CLI는 SKILL.md frontmatter만으로 스킬을 발견하므로 openai.yaml은 선택 사항이다.
디렉토리 심링크 전환 이후 자동 생성하지 않는다.

```yaml
# 수동 생성 시 형식:
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
