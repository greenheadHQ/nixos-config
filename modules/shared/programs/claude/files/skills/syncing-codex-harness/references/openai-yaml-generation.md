# openai.yaml Generation

> **Deprecation Notice (2026-02-19)**: 디렉토리 심링크 전환 이후 openai.yaml 자동 생성은
> 더 이상 수행되지 않는다. Codex CLI는 SKILL.md frontmatter만으로 스킬을 발견하므로
> openai.yaml은 선택 사항이다. `generate-openai-yaml` 서브커맨드는 수동 생성용으로 유지.

## Overview

Codex CLI discovers skills via `.agents/skills/*/agents/openai.yaml`.
This file was previously auto-generated from each SKILL.md's YAML frontmatter.

## Source: SKILL.md Frontmatter

```yaml
---
name: styling-colors
description: |
  Guide for applying design system colors using Tailwind CSS utility classes.
  Use when styling components with brand colors.
allowed-tools: Bash(*)
---
```

## Generated: agents/openai.yaml

```yaml
interface:
  display_name: "Styling Colors"
  short_description: "Guide for applying design system colors using Tailwind CSS utility cl"
  default_prompt: "Use $styling-colors to help with this task."
```

## Field Mapping

| Source (SKILL.md) | Target (openai.yaml) | Transform |
|---|---|---|
| `name` | `display_name` | kebab-case -> Title Case (`tr '-' ' '` + capitalize) |
| `description` | `short_description` | First 128 characters of description text |
| `name` | `default_prompt` | `"Use $<name> to help with this task."` |

## AWK Extraction Logic

The `sync.sh` script contains AWK code ported from `modules/shared/programs/codex/default.nix:86-139`.

### Name extraction
- Reads YAML frontmatter (between `---` markers)
- Finds `name:` key, strips whitespace
- Falls back to directory name if not found

### Description extraction
- Handles both inline (`description: text`) and block (`description: |`) formats
- Also handles folded block scalar (`description: >-`)
- For block format: concatenates lines until next key or end of frontmatter
- Truncates to 128 characters (character-based via `${var:0:128}`, not byte-based `printf '%.128s'` — important for CJK/multibyte text)

### Title Case conversion
- Splits on `-`, capitalizes first letter of each word
- Example: `migrating-legacy-colors` -> `Migrating Legacy Colors`
