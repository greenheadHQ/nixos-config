---
name: documenting-intent
description: |
  This skill should be used when the user asks to document intent, record
  decision rationale, write a CIR (Change Intent Record), ADR (Architecture
  Decision Record), capture why an alternative was rejected, or look up
  past decision history for a piece of code or architecture.
  Use this skill whenever the user mentions intent documentation, decision
  history, trade-off recording, asks "why did we do it this way", or wants
  to find/retrieve/search existing CIR/ADR records — even if they don't
  explicitly say "CIR" or "ADR".
  Triggers: "의도 기록", "CIR", "CIR 작성", "ADR", "의사결정 기록",
  "왜 이렇게 했는지 기록", "change intent", "decision record",
  "대안 거부 이유", "intent documentation", "결정 근거", "의사결정 이력",
  "trade-off 기록", "번복 이력", "의도 남겨", "intent record",
  "decision rationale", "rejected alternative",
  "왜 이렇게 했는지 찾아봐", "의사결정 히스토리 조회",
  "이 설계 이유", "CIR 찾아줘", "결정 이력 검색",
  "여기 구조가 이렇게 된 이유", "이전 방향 전환 이력".
---

# Intent Documentation (CIR/ADR)

의사결정 이력을 체계적으로 기록하는 스킬.
코드는 재생성 가능하지만 의도(intent)는 기록하지 않으면 사라진다.
이 스킬은 "왜 A를 시도했다가 B로 갔다가 다시 A로 돌아왔는지"를 시스템적으로 보존한다.

## 핵심 원칙

- **CIR 작성 기준**: 합리적 대안이 거부된 경우에만 작성한다. 단순 버그 수정이나 명확한 변경에는 불필요.
- **CIR/ADR 구분 없이 통합**: 변경 규모에 따라 자동으로 기록 수준을 조절한다.
- **기존 워크플로우 비침습**: `/commit`이나 PR 워크플로우를 방해하지 않는다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| CIR 템플릿 (인라인 주석 + 커밋 메시지) | `references/templates.md` |
| 설계 철학 및 레퍼런스 | `references/philosophy.md` |

## 2단계 워크플로우

### Phase 1: 구현 중 실시간 기록

구현 과정에서 의사결정이 발생하면 즉시 맥락을 포착한다.

**기록할 시점 판단 — 다음 중 하나라도 해당하면 기록한다:**

1. 방향을 변경했다 (A 방식 → B 방식 전환)
2. 합리적 대안을 검토한 뒤 거부했다
3. trade-off를 의식적으로 감수했다
4. 이전 결정을 번복했다 (v1 → v2 → v3 같은 이력)

**포착할 내용:**
- 어떤 대안들을 검토했는가
- 각 대안을 선택/거부한 이유
- 감수하는 trade-off는 무엇인가
- 관련 참조 (아래 우선순위 순으로, 있는 것만 포함):
  1. PR 번호/링크 — squash merge 후에도 영속적 참조 (예: `PR #121`)
  2. 커밋 해시 — PR 전이면 단축 해시 사용 (예: `b9cd235`)
  3. 참조 없음 — 로컬 미커밋 작업이면 `v1`, `v2`만으로 충분

### Phase 2: 커밋/PR 시 정리

커밋이나 PR 작성 시점에 Phase 1에서 포착한 내용을 정리하여 적절한 위치에 기록한다.

## 규모별 기록 수준

변경의 복잡도에 따라 기록 수준을 자동 판단한다.

| 규모 | 판단 기준 | 기록 방식 |
|------|----------|----------|
| **소규모** | 대안 1개 거부, 단일 trade-off | 코드 인라인 주석만 (`# CIR: ...` 한두 줄) |
| **중규모** | 대안 2개 이상 거부, 또는 방향 전환 1회 | 인라인 주석 + 커밋 메시지 CIR 섹션 |
| **대규모** | 방향 전환 2회 이상, 또는 아키텍처 수준 결정 | 인라인 주석 + 커밋 메시지 CIR 섹션 + PR 본문 CIR 섹션 |

소규모 예시: `# CIR: regex 대신 string split 선택 — 이 패턴에서는 regex가 과도함`
중/대규모는 `references/templates.md`의 정형 템플릿을 따른다.

## CIR 작성 절차

사용자가 CIR 작성을 요청하면 다음 순서로 진행한다:

### 1. 현재 세션 맥락 수집

현재 대화에서 의사결정 이력을 추출한다:
- 변경 과정에서 검토한 대안들
- 각 방향 전환의 이유
- 최종 결정의 trade-off

git log와 PR 이력으로 관련 참조를 수집한다:
```bash
git log --oneline -20       # 관련 커밋 해시 식별
gh pr list --state merged   # squash merge된 PR 번호 확인 (가능하면)
```
참조 우선순위: PR 번호 > 커밋 해시 > 없음 (로컬 작업 중이면 생략 가능)

### 2. 규모 판단

위 "규모별 기록 수준" 테이블에 따라 적절한 기록 방식을 결정한다.
판단이 애매하면 사용자에게 확인한다.

### 3. CIR 초안 생성

`references/templates.md`의 템플릿을 사용하여 초안을 생성한다.

**인라인 코드 주석 CIR**: 의사결정이 발생한 코드 위치에 직접 기록한다.
해당 언어의 주석 문법을 사용한다 (# for shell/python, // for JS/TS, -- for SQL 등).

**커밋 메시지 CIR 섹션**: 커밋 메시지 본문에 `## Change Intent Record` 섹션을 추가한다.
버전별 이력을 시간순으로 기록하고, 최종 trade-off를 명시한다.

### 4. 사용자 확인

생성한 CIR 초안을 사용자에게 제시하여 검토를 받는다.
사용자가 수정을 요청하면 반영한다.

### 5. 적용

확인된 CIR을 코드와 커밋 메시지에 적용한다.
이미 커밋된 코드라면 인라인 주석만 별도 커밋으로 추가할 수 있다.

## CIR 조회 절차

사용자가 과거 의사결정 이력을 찾아달라고 요청하면 다음 순서로 검색한다.

### 1. 검색

3개 레이어를 순서대로 검색한다 (squash merge 환경에서 생존 확률 순):

```bash
# 1) 코드 주석 (가장 안정적 — squash 영향 없음)
grep -rn "CIR:" <대상 파일/디렉토리>
grep -rn "Change Intent Record" <대상 파일/디렉토리>

# 2) 커밋 메시지 (squash 시 PR desc에서 유입된 것만 생존)
git log --all --grep="Change Intent Record" --oneline
git log --all --grep="CIR:" --oneline

# 3) PR 본문 (GitHub에 영속적으로 보존)
gh pr list --state merged --search "Change Intent Record" --limit 20
```

사용자가 특정 파일/기능을 지정하면 해당 범위로 좁혀 검색한다.

### 1-1. Fallback 검색 (CIR 미사용 이력 대응)

위 검색에서 결과가 없으면, CIR/ADR 포맷 없이 작성된 의사결정 이력을 발굴한다:

```bash
# 파일 변경 이력 추적
git log --oneline --follow -- <대상 파일>

# 커밋 메시지에서 의사결정 힌트 검색 (방향 전환, 롤백, 대안 관련 키워드)
git log --all --grep="revert\|rollback\|대신\|instead\|trade-off\|workaround" --oneline -- <대상 파일>

# PR 본문에서 해당 파일/기능 관련 논의 검색
gh pr list --state merged --search "<파일명 또는 기능 키워드>" --limit 10
```

이 경우 결과를 표시할 때, 정형 CIR이 아닌 커밋/PR에서 추출한 의사결정 맥락임을 명시한다.

### 2. 결과 표시

`references/templates.md`의 **조회 결과 표시 템플릿**을 사용하여 일관된 포맷으로 표시한다.
항상 Summary 테이블 먼저, 사용자가 원하면 Detail 타임라인을 추가 표시한다.

## Git Trailer (선택적)

중/대규모 CIR에서 커밋 메시지 끝에 git trailer를 추가하면 기계적 검색이 용이하다.

```
CIR: <식별자>
```

예시:
```
refactor(rebuild): allowlist → blocklist 전환

## Change Intent Record
- v1 (b9cd235): blocklist 구상 → 관리 부담 우려로 allowlist 채택
- v2 (이번): allowlist 한계 확인, blocklist 회귀

trade-off: 수동 등록 필요하지만 false positive 제로.

CIR: rebuild-preflight-blocklist
```

trailer는 `git log --format="%(trailers:key=CIR)"` 로 검색 가능하다.
squash merge 시 trailer 보존은 보장되지 않으므로, 코드 인라인 주석과 PR 본문이 주된 영속 레이어이고 trailer는 보조 수단이다.

## 주의사항

- **과도한 문서화 방지**: CIR은 의사결정 맥락이 있을 때만 작성한다. 모든 변경에 CIR을 넣으면 노이즈가 되어 가치가 떨어진다.
- **커밋 워크플로우 비침습**: 사용자가 `/commit` 시 CIR 추가를 강제하지 않는다. 별도 요청이 있을 때만 CIR을 생성한다.
- **프로젝트 중립**: 프로젝트 특화 용어는 CIR 본문에 자연스럽게 사용하되, 템플릿 자체는 범용으로 유지한다.
- **LLM 맥락 전달**: CIR의 핵심 가치는 미래의 LLM 세션에 "왜"를 전달하는 것이다. git log와 코드 주석을 통해 다음 세션의 LLM이 동일한 실수를 반복하지 않도록 한다.

## 참조 자료

- **`references/templates.md`** — CIR 인라인 주석 / 커밋 메시지 / PR 본문 템플릿 + 조회 결과 표시 템플릿 + PR #121 canonical example
- **`references/philosophy.md`** — 5개 레퍼런스 글 요약과 이 스킬의 설계 근거
