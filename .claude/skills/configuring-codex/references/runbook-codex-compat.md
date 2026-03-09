# Codex Compatibility Runbook (2026-02-08)

## 개요

- 발생 일자: 2026년 2월 8일 (Sunday)
- 대상 프로젝트: `/Users/green/Workspace/nixos-config`
- 문제 유형: Codex CLI가 global(user) 스코프 스킬은 인식하지만 project 스코프(`.agents/skills`) 스킬을 안정적으로 인식하지 못함

## 증상

1. Codex에서 `.agents/skills/<name>/SKILL.md` 기반 스킬이 일부/전부 누락됨
2. `verify-ai-compat.sh` 기준으로는 구조가 있어 보이는데 런타임 인식이 불안정함
3. 별개로, 권한 승인 프롬프트가 반복적으로 나타남 (정책 기본값 영향)

## 재현 조건

- `.agents/skills/*/SKILL.md`가 심링크일 때 환경에 따라 project-scope 스캔이 누락됨

## 원인 분석

1. **SKILL.md 투영 방식 (근본 원인)**
- 기존 투영은 `.claude/skills/<name>/SKILL.md`를 `.agents/skills/<name>/SKILL.md`로 심링크했다.
- 일부 Codex 환경에서 symlinked `SKILL.md`가 project-scope 발견 과정에서 누락될 수 있었다.

2. **검증 기준 불일치**
- 기존 검증 스크립트가 "심링크여야 정상" 기준으로 작성되어 실제 호환 수정 이후 기준과 충돌했다.

3. **정책/발견 이슈 혼재**
- 승인 프롬프트 문제(`approval_policy`, `sandbox_mode`)와 Skills 발견 문제를 한 원인으로 혼동하기 쉬웠다.
- 실제로 Skills 누락의 근본 원인은 `trust`가 아니라 `SKILL.md` 심링크였다.

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

### 3) 실행 정책 기본값 반영 (권한 프롬프트 대응)

- 파일: `modules/shared/programs/codex/files/config.toml`
- 반영 상태:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

### 4) trust 항목 정리

- 프로젝트별 절대경로 trust 항목은 환경 이식성(`$HOME`/OS 차이) 문제를 만들 수 있어 기본 구성에서 제거했다.
- 필요 시 호스트별/로컬 오버라이드로만 추가한다.

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
- 새 Git 프로젝트에서도 승인 선택지 미노출(`approval_policy = "never"`, `sandbox_mode = "danger-full-access"` 적용 후)

## codex trust 관련 메모

- `codex-cli 0.98.0` 기준 `codex trust` 독립 서브커맨드는 확인되지 않았다.
- trust 관리는 CLI 서브커맨드가 아니라 `config.toml` 프로젝트 엔트리로만 가능하다.
- 본 케이스에서 Skills 누락의 근본 원인으로는 확인되지 않았다(심링크 이슈가 근본 원인).

## 회귀 방지 체크리스트

1. 새 스킬 추가/수정 후 `nrs`(또는 동등 activation) 실행
2. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
3. `./scripts/ai/verify-ai-compat.sh` 통과 확인
4. `codex exec`로 project-scope 스킬 1개 이상 런타임 확인
5. `configuring-codex` 스킬 문서와 실제 구현(`default.nix`, verify script) 간 불일치 여부 점검
6. pre-commit `ai-skills-consistency` 훅 확인 (관련 staged 변경 시 fail, 긴급 우회: `SKIP_AI_SKILL_CHECK=1`)

## 2026-02-19 재검증: 디렉토리 심링크 전환

### 배경

2026-02-08 런북에서 "SKILL.md 심링크 불가 → 실파일 복사" 정책을 수립했으나,
이는 **파일 심링크**에 대한 결론이었다. 커뮤니티 리서치와 소스코드 분석을 통해
Codex CLI가 **디렉토리 심링크**는 공식 지원함을 확인했다.

### 핵심 발견

| 항목 | 기존 (2026-02-08) | 변경 (2026-02-19) |
|------|-------------------|-------------------|
| SKILL.md 투영 | 실파일 복사 | 디렉토리 심링크 |
| references/scripts/assets | 개별 파일 심링크 | 디렉토리 심링크에 포함 |
| openai.yaml | 자동 생성 | 생략 (선택 사항) |
| sync drift | 복사 시점 차이로 발생 가능 | 원천 제거 (단일 소스) |

### 근거

- **Codex CLI 소스코드** (`codex-rs/core/src/skills/loader.rs`):
  디렉토리 심링크는 `follow_links(true)`로 순회, 파일 심링크는 `continue`로 무시
- **PR #8801** (2026-01-07 merged): 디렉토리 심링크 지원 추가
- **OpenAI 공식 답변** (Issue #9365): "We support symlinks to a skill directory, not the SKILL.md file itself"
- **로컬 검증**: 22개 스킬 디렉토리 심링크 전환 후 `codex exec` 런타임 정상 인식 확인

### 최종 정책

- `.agents/skills/<name>` → `../../.claude/skills/<name>` 디렉토리 심링크
- openai.yaml 자동 생성 중단
- `verify-ai-compat.sh`, `warn-skill-consistency.sh`에서 디렉토리 심링크 기준 검증

## 참고 문서

- https://developers.openai.com/blog/eval-skills
- https://developers.openai.com/codex/skills
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-basic
- https://developers.openai.com/codex/config-advanced
- https://developers.openai.com/codex/config-reference
- https://developers.openai.com/codex/security/
- https://github.com/openai/codex/issues/4392
- https://github.com/openai/codex/pull/8801
- https://github.com/openai/codex/pull/9384
- https://github.com/openai/codex/issues/9365
