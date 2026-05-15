# Pre-Merge E2E 테스트 가이드 작성 규칙

PR 머지 전에 LLM이 직접 실행하여 변경을 검증하는 가이드의 작성 규칙.
PR 본문의 8번째 섹션으로 포함된다.

## Phase 구조

### Phase 0: 정적 검증

파일 존재, 값 반영, old 값 부재를 CLI 명령으로 확인한다.
빌드나 런타임 없이 수행 가능한 검증이다.

작성 패턴:

```bash
# 1. 새 값 존재 확인
grep -q "<expected_pattern>" <target_file>
# 기대: exit 0

# 2. old 값 부재 확인 (Negative 검증)
! grep -q "<old_pattern>" <target_file>
# 기대: exit 0 (패턴이 없어야 성공)

# 3. 파일 존재 확인
ls <expected_file>
# 기대: exit 0
```

핵심 원칙 — Negative 검증 의무화:
새 값이 존재하는지만 확인하면 불충분하다. 반드시 old 값이 더 이상 존재하지 않는지도 확인한다.
예를 들어 경로가 `/old/path` → `/new/path`로 변경되었으면:
- `grep -q "/new/path"` (새 값 존재) + `! grep -q "/old/path"` (old 값 부재)
두 가지를 모두 검증한다.

핵심 원칙 — Literal 검증은 fixed-string:
ANSI escape sequence, `[` / `]`, `.` / `*` 처럼 regex metacharacter를 포함한 출력은 literal로 검증한다.
이 경우 `grep -q` 대신 `grep -Fq`를 사용한다. Regex가 필요한 검증은 `grep -qE` 또는 `grep -q`를 명시적으로 사용한다.

```bash
# ANSI cyan escape가 출력에 포함되는지 literal로 확인
printf '%s' "$preview_out" | grep -Fq $'\x1b[1;36m'
# 기대: exit 0
```

### Phase 1-N: 기능별 검증

변경의 핵심 기능을 각각 독립적으로 검증한다.
각 Phase는 하나의 기능 또는 시나리오에 대응한다.

작성 패턴:

````markdown
### Phase N: <기능명>

> "<이 Phase가 검증하는 내용을 자연어로 기술>"

```bash
<검증 명령>
```

- **기대**: <정상 동작 시 예상 결과>
- **실패 시**: <디버깅 방향 — 어디를 확인해야 하는지>
````

작성 규칙:
- 각 Phase에 자연어 설명(blockquote)을 반드시 포함한다. 무엇을 검증하는지 맥락을 제공한다.
- 검증 명령은 구체적이고 실행 가능해야 한다. "동작을 확인한다"는 금지.
- 실패 시 진단 방향을 반드시 포함한다. "실패하면 수정한다"는 금지.
- 한 Phase에 3개 이상의 검증 명령이 필요하면 Phase를 분할한다.

### Phase N+1: Cross-Skill/인접 기능 Regression

변경이 인접 기능을 깨뜨리지 않았는지 검증한다.
의도적으로 혼동 가능한 쿼리나 시나리오를 사용한다.

작성 패턴:

````markdown
### Phase N+1: Regression

> "인접 기능이 이번 변경에 의해 깨지지 않았는지 확인"

#### 라우팅 경계 테스트 (스킬 변경 시)

| 쿼리 | 기대 스킬 | 이번 PR 영향 |
|------|----------|-------------|
| "<인접 스킬 트리거 쿼리>" | <인접 스킬명> | 무영향이어야 함 |
| "<경계 쿼리 — 두 스킬 모두 해당될 수 있는>" | <정확한 스킬명> | 올바르게 라우팅 |

#### 기능 Regression (코드 변경 시)

```bash
# 기존 기능 A가 여전히 동작하는지 확인
<기존 기능 검증 명령>
# 기대: <기존 동작 유지>
```
````

작성 규칙:
- 스킬 변경 PR에서는 라우팅 경계 테스트를 반드시 포함한다.
- 코드 변경 PR에서는 수정하지 않은 인접 기능의 동작 확인을 포함한다.
- "인접 기능"의 범위: 같은 모듈, 같은 설정 파일, 같은 서비스에 속하는 기능.

## 결과 보고 형식

테스트 실행 후 결과를 다음 형식으로 보고한다.

### 요약 테이블

```markdown
| Phase | 테스트명 | 결과 |
|-------|---------|------|
| 0 | 새 값 존재 확인 | PASS |
| 0 | old 값 부재 확인 | PASS |
| 1 | blocklist 매칭 검증 | PASS |
| 2 | trivial derivation 무경고 확인 | FAIL |
| 3 | Regression — 인접 기능 동작 확인 | PASS |
```

### 실패 항목 상세

```markdown
#### FAIL: Phase 2 — trivial derivation 무경고 확인

**실행 명령**: `nrs --dry-run 2>&1 | grep "warning"`
**실제 결과**: `warning: activation-script detected as heavy`
**기대 결과**: 경고 없음
**원인 분석**: `heavy_packages` 배열에 `activation-script`이 포함되어 있음
**수정 필요**: `heavy_packages`에서 `activation-script` 항목을 제거
```

## 참고 패턴 (PR #254 기반)

PR #254의 Pre-Merge E2E 테스트에서 관찰된 효과적인 패턴:

### Phase 기반 3단 검증
Phase 0(정적) → Phase 1-N(기능) → Phase N+1(Regression)의 3단 구조를 준수한다.
각 Phase가 독립적으로 실행 가능하여, 실패 지점을 빠르게 특정할 수 있다.

### 라우팅 경계 테스트
스킬 변경 시 인접 스킬의 트리거와 혼동되는 쿼리를 의도적으로 사용하여 라우팅 정확성을 검증한다.
예: "PR 코멘트 처리해줘"가 review-pr-feedback으로 라우팅되고, create-pr로 오라우팅되지 않는지 확인.

### Negative 검증
"새 값이 있다"뿐 아니라 "old 값이 없다"까지 확인하는 양방향 검증.
리네임/교체 시 old 아티팩트가 잔존하는 흔한 실수를 방지한다.
