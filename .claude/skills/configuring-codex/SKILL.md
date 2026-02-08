---
name: configuring-codex
description: |
  This skill should be used when the user asks "codex config",
  "codex setup", "codex trust", "AGENTS.md", ".agents/skills",
  "project-scope skill", or encounters Codex CLI skill discovery failures,
  approval/sandbox policy issues, Claude/Codex compatibility issues, or Codex runtime
  behavior differences in nixos-config.
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 범위

- `~/.codex/config.toml` 실행 정책(`approval_policy`, `sandbox_mode`) 및 모델 설정
- `AGENTS.md`/`.agents/skills` 투영 구조
- `.agents/skills/*/SKILL.md` 복사본/심링크 판별
- `nrs`(또는 동등 activation) 이후 결과 검증
- Claude Code와 Codex CLI 동작 차이 정리

Claude 전용 플러그인/훅 세부 내용은 `configuring-claude-code` 스킬을 사용합니다.

## 빠른 진단 체크리스트

1. `.agents/skills/*/SKILL.md`가 심링크가 아닌 일반 파일인지 먼저 확인
2. 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크 확인
3. `./scripts/ai/verify-ai-compat.sh` 실행
4. `codex exec`로 런타임에서 스킬 이름이 보이는지 확인
5. 권한 프롬프트 이슈는 `approval_policy`, `sandbox_mode` 설정으로 분리 진단

## 핵심 파일

- `libraries/packages/codex-cli.nix` — Nix 패키지 (pre-built 바이너리)
- `modules/shared/programs/codex/default.nix` — 설정 및 스킬 투영
- `modules/shared/programs/codex/files/config.toml` — 실행 정책/모델 설정
- `scripts/update-codex-cli.sh` — 버전 자동 업데이트
- `scripts/ai/verify-ai-compat.sh` — 구조 검증
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## 패키지 설치

Codex CLI는 Nix derivation으로 관리된다 (`libraries/packages/codex-cli.nix`).
GitHub releases에서 플랫폼별 pre-built 바이너리를 가져온다.

- macOS: `aarch64-darwin`
- NixOS: `x86_64-linux` (musl 정적 링크)

버전 업데이트:

```bash
./scripts/update-codex-cli.sh
```

## 진단 우선순위 (중요)

Skills 누락 이슈의 1차 원인은 `trust`보다 `SKILL.md` 투영 방식이다.  
실제 회귀 기록(2026-02-08) 기준으로, `.agents/skills/*/SKILL.md`가 심링크일 때 누락이 재현되었고, **실파일 복사**로 바꾸면 해결됐다.

## 실행 정책 / Trust 메모

`codex-cli 0.98.0` 기준으로 `codex trust` 독립 서브커맨드는 확인되지 않았다.  
권한 프롬프트 동작은 전역 실행 정책으로 제어한다.

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

`trust_level` 프로젝트 엔트리는 경로별 세부 제어가 필요할 때만 추가한다.

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
