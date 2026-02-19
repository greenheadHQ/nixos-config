---
name: maintaining-skills
description: |
  This skill should be used when the user needs to audit, update, or maintain
  Claude Code skills -- checking quality, routing consistency, and structure.
  Triggers: "스킬 감사", "스킬 점검", "스킬 리뷰", "스킬 최신화",
  "스킬 유지보수", "skill audit", "skill review", "skill maintenance",
  "스킬 품질 확인", "스킬 정리", "skill cleanup", "routing table 점검",
  skill split/merge analysis, skill inventory.
---

# 스킬 유지보수

Claude Code 스킬의 품질, 일관성, 라우팅 정합성을 감사하고 유지보수하는 절차.

## 감사 범위 결정

### 프로젝트 유형 감지

현재 프로젝트가 nixos-config인지 판별하여 감사 범위를 결정한다.

| 조건 | 프로젝트 유형 | 감사 대상 |
|------|-------------|----------|
| `modules/shared/programs/claude/files/skills/` 존재 | nixos-config | 글로벌 스킬 소스 + `.claude/skills/` 프로젝트 스킬 |
| 위 디렉토리 없음 | 일반 프로젝트 | `.claude/skills/` 프로젝트 스킬만 |

nixos-config에서는 글로벌 스킬의 소스가 `modules/shared/programs/claude/files/skills/`에 있다.
이 디렉토리를 ground truth로 사용한다 (`~/.claude/skills/`는 심링크).
일반 프로젝트에서는 `~/.claude/skills/`를 글로벌 스킬 경로로 사용한다.

### 스킬 인벤토리 수집

각 스킬 디렉토리에서 SKILL.md와 references/ 하위 파일을 모두 읽는다.
수집 결과를 테이블로 정리한다:

| 항목 | 수집 내용 |
|------|----------|
| 스킬명 | 디렉토리명 |
| 스코프 | 글로벌 / 프로젝트 |
| SKILL.md 줄 수 | wc -l 결과 |
| references/ 파일 수 | 하위 .md 파일 수 |
| frontmatter | name, description 파싱 |

## Phase 1: 개별 스킬 분석

스킬마다 아래 항목을 검사한다. 상세 기준은 `references/quality-criteria.md` 참조.

### 1.1 구조 검사

- SKILL.md 파일 존재 여부
- YAML frontmatter 유효성 (`---` 구분자, `name`, `description` 필수)
- `name` 값이 디렉토리명과 일치하는지
- `description`이 3인칭 형식이며 `Triggers:` 구문을 포함하는지

### 1.2 내용 품질

- 명령형/서술형 문체 사용 여부 (2인칭 "you should" 지양)
- SKILL.md 크기: 200-1200단어 권장, 1500단어 초과 시 경고
- 구조 패턴 준수: Purpose → 빠른 참조 → 핵심 절차 → FAQ → 참조
- 참조 파일 링크가 유효한지 (`references/*.md` 경로 존재 확인)

### 1.3 프로그레시브 디스클로저

- SKILL.md에 핵심 절차만 기술되어 있는지
- 상세 내용(트러블슈팅, 설정 상세, 히스토리)이 references/에 분리되어 있는지
- references/ 없이 SKILL.md가 800단어 이상이면 분리 권장

### 1.4 유효성 검증

- SKILL.md에서 참조하는 파일 경로가 코드베이스에 실제로 존재하는지
- 언급된 명령어/서비스/도구가 현재 환경에서 유효한지
- nixos-config: Nix 모듈 경로, homeserver 옵션명, constants.nix 참조 등 확인

## Phase 2: 전역 정합성 점검

### 2.1 라우팅 테이블 일관성

CLAUDE.md 라우팅 테이블이 존재하는 파일을 모두 수집한다:

- nixos-config: `modules/shared/programs/claude/files/CLAUDE.md` (글로벌) + 프로젝트 루트 `CLAUDE.md` (프로젝트)
- 일반 프로젝트: 프로젝트 루트 `CLAUDE.md`

점검 항목:
- **누락**: 스킬 디렉토리는 있지만 라우팅 테이블에 미등록 → FAIL
- **고아**: 라우팅 테이블에 있지만 스킬 디렉토리 없음 → FAIL
- **키워드 충돌**: 두 스킬이 같은 키워드를 점유 → WARN
- **키워드 부족**: 라우팅 키워드가 description Triggers와 불일치 → WARN

### 2.2 스킬 범위 분석

- **분할 후보**: SKILL.md + references/ 합계 5000단어 초과, 독립 서비스 2개 이상 포함
- **병합 후보**: 트리거 키워드 50% 이상 중복, 하나의 작업에 두 스킬 참조 필요
- **신규 스킬 후보**: 코드베이스 주요 영역 중 스킬 미커버
- **제거 후보**: 참조 서비스가 코드베이스에서 완전 제거됨

### 2.3 Nix 등록 정합성 (nixos-config 전용)

글로벌 스킬에 한해:
- `modules/shared/programs/claude/default.nix`의 `mkOutOfStoreSymlink` 항목과 실제 스킬 디렉토리가 매칭되는지

## Phase 3: 보고서 생성

감사 결과를 구조화된 마크다운 보고서로 출력한다.

### 보고서 구조

```markdown
# 스킬 감사 보고서

## 요약
| 항목 | 수치 |
|------|------|
| 전체 스킬 수 | N |
| 글로벌 / 프로젝트 | N / N |
| PASS / WARN / FAIL | N / N / N |

## 개별 스킬 결과
### [스킬명] — [PASS|WARN|FAIL]
- 문제점: (있으면 나열)
- 권장 조치: (있으면 나열)

## 전역 점검 결과
### 라우팅 테이블
- 누락/고아/충돌 항목

### 범위 분석
- 분할/병합/신규/제거 후보

## 권장 조치 목록
| # | 심각도 | 대상 | 조치 | 상세 |
|---|--------|------|------|------|
```

### 심각도 분류

| 심각도 | 기준 | 예시 |
|--------|------|------|
| FAIL | 스킬 발견/트리거 불가, 필수 파일 누락 | frontmatter 없음, 라우팅 미등록 |
| WARN | 품질 기준 미달, 개선 필요 | Triggers 부족, 크기 초과, 참조 깨짐 |
| INFO | 개선 가능한 권장사항 | 프로그레시브 디스클로저 미흡, 스타일 불일치 |

## Phase 4: 변경 적용

보고서를 사용자에게 제시한 뒤 권장 조치를 **항목별로** 승인/거부 받는다.

### 적용 절차

1. 보고서 전체를 먼저 출력
2. 사용자에게 항목별 승인/거부를 확인한다
3. 승인된 항목만 순차적으로 적용
4. 적용 결과 요약 출력

### 적용 가능한 변경 유형

| 변경 유형 | 대상 파일 |
|----------|----------|
| frontmatter 수정 | SKILL.md |
| 본문 구조 개선 | SKILL.md |
| references/ 파일 생성/수정 | references/*.md |
| 라우팅 테이블 항목 추가/수정/제거 | CLAUDE.md |
| Nix 등록 항목 추가 | default.nix (nixos-config) |
| 새 스킬 디렉토리 생성 | .claude/skills/ 또는 modules/ |

**자동 적용 금지 원칙**: 사용자 확인 없이 스킬 파일을 수정하거나 삭제하지 않는다.
삭제가 필요한 경우, 파일 목록과 사유를 명시하고 명시적 승인을 받은 후에만 실행한다.

## 상세 품질 기준

`references/quality-criteria.md` 참조 — frontmatter 규칙, description 작성 가이드,
내용 품질 루브릭, 크기 가이드라인, 트리거 구문 효과성 기준, 스코프 분석 기준의 상세 정의.
