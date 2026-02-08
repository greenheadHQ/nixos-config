# Codex Compatibility Runbook (2026-02-08)

## 개요

- 발생 일자: 2026년 2월 8일 (Sunday)
- 대상 프로젝트: `/Users/green/IdeaProjects/nixos-config`
- 문제 유형: Codex CLI가 global(user) 스코프 스킬은 인식하지만 project 스코프(`.agents/skills`) 스킬을 안정적으로 인식하지 못함

## 증상

1. Codex에서 `.agents/skills/<name>/SKILL.md` 기반 스킬이 일부/전부 누락됨
2. `verify-ai-compat.sh` 기준으로는 구조가 있어 보이는데 런타임 인식이 불안정함
3. trust 설정이 누락되면 `.agents/skills` 전체가 무시됨

## 재현 조건

- 프로젝트 trust가 `trusted`가 아님
- 또는 `.agents/skills/*/SKILL.md`가 심링크일 때 환경에 따라 project-scope 스캔이 누락됨

## 원인 분석

1. **Trust 전제조건**
- Codex는 프로젝트 신뢰 상태가 충족되어야 project-scope 컨텍스트를 정상적으로 반영한다.
- 관리 지점: `~/.codex/config.toml`의 `[projects."<path>"]`.

2. **SKILL.md 투영 방식**
- 기존 투영은 `.claude/skills/<name>/SKILL.md`를 `.agents/skills/<name>/SKILL.md`로 심링크했다.
- 일부 Codex 환경에서 symlinked `SKILL.md`가 project-scope 발견 과정에서 누락될 수 있었다.

3. **검증 기준 불일치**
- 기존 검증 스크립트가 "심링크여야 정상" 기준으로 작성되어 실제 호환 수정 이후 기준과 충돌했다.

## 해결 내용

### 1) SKILL.md 투영 정책 변경

- 파일: `modules/shared/programs/codex/default.nix`
- 변경: `.agents/skills/<name>/SKILL.md`를 심링크가 아니라 **실파일 복사**로 생성
- 유지: `references`, `scripts`, `assets`는 심링크 유지, `agents/openai.yaml` 자동 생성 유지

### 2) 검증 스크립트 기준 변경

- 파일: `scripts/ai/verify-ai-compat.sh`
- 변경:
  - `SKILL.md`가 일반 파일인지 확인
  - 심링크면 실패 처리
  - 원본과 `cmp`로 내용 일치 확인

### 3) trust 설정 점검

- 파일: `modules/shared/programs/codex/files/config.toml`
- 필수 상태:

```toml
[projects."/Users/green/IdeaProjects/nixos-config"]
trust_level = "trusted"
```

## 검증 절차

```bash
# 1) 구조 검증
./scripts/ai/verify-ai-compat.sh

# 2) SKILL.md 타입 검증
find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type l | wc -l
find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type f | wc -l

# 3) 런타임 인식 검증
codex -a never exec "Answer YES or NO only: Is a skill named 'managing-secrets' available in this workspace?"
```

## 2026-02-08 확인 결과

- 심링크 수: `0`
- 일반 파일 수: `18` (2026-02-08 당시 기준)
- `./scripts/ai/verify-ai-compat.sh`: `검증 완전 통과`
- `codex exec` 런타임 질의:
  - `managing-secrets` 가용성: `YES`
  - project 스킬 목록이 응답에 포함됨

## codex trust 관련 메모

- `codex-cli 0.98.0` 기준 `codex trust` 독립 서브커맨드는 확인되지 않았다.
- trust 관리는 CLI 서브커맨드가 아니라 `config.toml`의 프로젝트 trust 설정으로 본다.

## 회귀 방지 체크리스트

1. 새 스킬 추가/수정 후 `nrs`(또는 동등 activation) 실행
2. `.agents/skills/*/SKILL.md`가 일반 파일인지 확인
3. `./scripts/ai/verify-ai-compat.sh` 통과 확인
4. `codex exec`로 project-scope 스킬 1개 이상 런타임 확인
5. `configuring-codex` 스킬 문서와 실제 구현(`default.nix`, verify script) 간 불일치 여부 점검
6. pre-commit `ai-skills-consistency` 훅 확인 (관련 staged 변경 시 fail, 긴급 우회: `SKIP_AI_SKILL_CHECK=1`)

## 참고 문서

- https://developers.openai.com/blog/eval-skills
- https://developers.openai.com/codex/skills
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-basic
- https://developers.openai.com/codex/config-advanced
- https://developers.openai.com/codex/config-reference
