---
name: configuring-codex
description: |
  This skill should be used when the user asks "codex config",
  "codex setup", "codex trust", "AGENTS.md", ".agents/skills",
  "project-scope skill", or encounters Codex CLI skill discovery failures,
  trust misconfiguration, Claude/Codex compatibility issues, or Codex runtime
  behavior differences in nixos-config.
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 범위

- `~/.codex/config.toml` trust 설정
- `AGENTS.md`/`.agents/skills` 투영 구조
- `nrs`(또는 동등 activation) 이후 결과 검증
- Claude Code와 Codex CLI 동작 차이 정리

Claude 전용 플러그인/훅 세부 내용은 `configuring-claude-code` 스킬을 사용합니다.

## 빠른 진단 체크리스트

1. `~/.codex/config.toml`에 대상 프로젝트 `trust_level = "trusted"`가 있는지 확인
2. 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크 확인
3. `.agents/skills/*/SKILL.md`가 심링크가 아닌 일반 파일인지 확인
4. `./scripts/ai/verify-ai-compat.sh` 실행
5. `codex exec`로 런타임에서 스킬 이름이 보이는지 확인

## 핵심 파일

- `modules/shared/programs/codex/default.nix`
- `modules/shared/programs/codex/files/config.toml`
- `scripts/ai/verify-ai-compat.sh`
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## Trust 규칙

`codex-cli 0.98.0` 기준으로 `codex trust` 독립 서브커맨드는 확인되지 않았다.  
실제 신뢰 상태는 `config.toml`의 프로젝트 섹션으로 관리한다.

```toml
[projects."/Users/green/IdeaProjects/nixos-config"]
trust_level = "trusted"
```

이 설정이 없으면 `.agents/skills/`가 존재해도 project-scope 스킬이 무시될 수 있다.

## 투영 아키텍처

```
.claude/skills/<name>/SKILL.md         # 단일 원본
      -> copy
.agents/skills/<name>/SKILL.md         # Codex 발견용 (일반 파일)

.claude/skills/<name>/references        # 원본
      -> symlink
.agents/skills/<name>/references        # 필요 시 링크

.agents/skills/<name>/agents/openai.yaml # SKILL.md frontmatter 기반 자동 생성
```

중요: `SKILL.md`는 일부 Codex 환경 호환성을 위해 심링크가 아니라 복사본으로 투영한다.

## 활성화

원칙은 `nrs` 실행이다.  
환경 제약으로 `nrs`를 실행하지 못하면, Codex 모듈 activation과 동등한 절차로 재생성해도 된다.

## 검증 명령

```bash
# 구조 검증
./scripts/ai/verify-ai-compat.sh

# SKILL.md 타입 검증 (심링크 0, 일반 파일 N)
find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type l | wc -l
find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type f | wc -l

# 런타임 인식 검증
codex -a never exec "Answer YES or NO only: Is a skill named 'configuring-codex' available in this workspace?"
```

## 레퍼런스

- 상세 장애 기록 및 회귀 체크: `references/runbook-codex-compat-2026-02-08.md`
