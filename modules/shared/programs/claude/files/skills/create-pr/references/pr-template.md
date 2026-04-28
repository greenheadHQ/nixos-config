# 8섹션 PR 본문 템플릿

## 1. Summary

### 작성 규칙
- 핵심 변경을 1-3개 bullet point로 요약한다.
- 관련 이슈가 있으면 `Closes #N`을 포함한다 (GitHub 자동 링크).
- 변경의 "무엇"보다 "왜"에 초점을 맞춘다.

### 예시

```markdown
## Summary
- Pre-flight 체크를 known-trivial allowlist에서 known-heavy blocklist로 전환하여 false positive를 근본적으로 제거한다.
- 새 무거운 패키지 추가 시 blocklist에 수동 등록이 필요하지만, 사용자 경험이 압도적으로 개선된다.

Closes #115
```

### 흔한 실수
- 파일 변경 목록만 나열하고 변경 이유를 생략하는 것.
- `Closes` 대신 `Fixes`를 사용하는 것 자체는 문제없으나, 프로젝트 컨벤션에 맞춰 통일한다.
- Summary에 구현 상세를 장황하게 쓰는 것 — 3줄 이내로 유지한다.

## 2. 기존 문제/배경

### 작성 규칙
- 이 PR이 해결하는 pain point를 기술한다.
- 현재 동작(AS-IS)과 문제점을 명확히 서술한다.
- 가능하면 구체적 사례(에러 메시지, 재현 시나리오)를 포함한다.

### 예시

```markdown
## 기존 문제/배경

현재 `nrs`의 pre-flight 체크는 known-trivial allowlist 방식을 사용한다. 소스 빌드가 필요한 패키지를 감지하기 위해 "trivial"로 판단되는 derivation을 allowlist에 등록하고, 나머지를 heavy로 간주한다.

**문제**: 새로운 trivial derivation(예: `activation-script.drv`, `rebuild-common.sh`)이 추가될 때마다 allowlist에 패턴을 추가해야 한다. 두더지 잡기식 유지보수가 필요하며, 미등록 trivial derivation은 false positive로 사용자에게 불필요한 경고를 발생시킨다.
```

### 흔한 실수
- 문제를 기술하지 않고 바로 솔루션을 설명하는 것.
- "사용자 요청으로 변경"처럼 배경 설명 없이 작성하는 것.

## 3. CIR (Change Intent Record)

### 작성 규칙
- 변경 과정에서 검토한 대안들과 방향 전환 이력을 시간순으로 기록한다.
- 각 버전에 안정 식별자(PR 번호 `#N` 또는 머지된 commit SHA)를 포함한다. 본인 PR의 mid-flight partial hash는 사용하지 않는다 — squash 머지 후 dangling 위험.
- 예외: PR 생성 전 초안 시점의 **현재 작업 중인 버전**은 PR 번호가 아직 없으므로 `(이번 변경)`으로 표기한다 (PR 본문에 그대로 게시 — 머지 후에는 자기 PR로 자명).
- 검토 라운드 번호, finding ID(`Correctness-1`, `CORR-2` 등)는 CIR에 포함하지 않는다 (휘발성 보고용).
- 최종 결정의 trade-off를 솔직하게 명시한다.
- 단순 변경이면 "해당 없음 — 단순 변경"으로 간소화한다.

### 예시

```markdown
## CIR (Change Intent Record)

- **v1** (PR #112): known-heavy blocklist 방식 구상 → 관리 부담 우려로 known-trivial allowlist 채택
- **v2** (PR #115): `activation-script` 등 false positive 발생, trivial 패턴 추가로 대응
- **v3** (이번 변경): allowlist 방식이 두더지 잡기(끝없는 패턴 추가)임을 확인, 원래 구상대로 known-heavy blocklist로 회귀

**trade-off**: 새 무거운 패키지 추가 시 수동 등록 필요하지만, false positive를 근본적으로 제거하여 사용자 경험이 압도적으로 개선됨.
```

### 흔한 실수
- 최종 결정만 기록하고 검토 과정을 생략하는 것.
- trade-off를 감추거나 장점만 부각하는 것.
- 커밋 해시/PR 번호 없이 "이전 방식"이라고만 쓰는 것.

## 4. ADR (Architecture Decision Record)

### 작성 규칙
- 검토한 대안들을 비교 테이블로 정리한다.
- 채택은 ✅, 기각은 ❌로 표시한다.
- 대안이 1개뿐이면 테이블을 간소화하거나 CIR과 통합한다.

### 예시

```markdown
## ADR

| 대안 | 설명 | 장점 | 단점 | 결정 |
|------|------|------|------|------|
| known-trivial allowlist | trivial derivation을 등록, 나머지를 heavy 간주 | 초기 구현 단순 | 패턴 무한 증가, false positive | ❌ |
| known-heavy blocklist | heavy 패키지만 등록, 나머지를 trivial 간주 | false positive 제로, 유지보수 최소 | 새 heavy 패키지 수동 등록 필요 | ✅ |
| 빌드 시간 측정 기반 | 실제 빌드 시간으로 heavy/trivial 판별 | 자동 분류, 수동 관리 불필요 | 구현 복잡, 첫 빌드 필수, 캐시 상태 의존 | ❌ |
```

### 흔한 실수
- 채택한 대안만 기술하고 기각한 대안을 생략하는 것.
- 장단점을 비워두거나 "없음"으로 채우는 것.
- 테이블이 아닌 산문 형식으로 장황하게 쓰는 것.

## 5. 구현 상세

### 작성 규칙
- 변경 파일 목록을 테이블로 정리한다 (파일명/변경 유형/변경 내용).
- 핵심 로직 변경에 대해 코드 스니펫을 포함한다.
- 설정값 변경이면 BEFORE/AFTER를 명시한다.

### 예시

````markdown
## 구현 상세

| 파일 | 변경 | 내용 |
|------|------|------|
| `modules/shared/rebuild.sh` | 수정 | allowlist → blocklist 로직 전환 |
| `modules/shared/rebuild.sh` | 수정 | `heavy_packages` 배열 추가 |
| `tests/rebuild-test.sh` | 추가 | blocklist 검증 테스트 |

### 핵심 코드

```bash
# BEFORE: known-trivial allowlist
local trivial_patterns=("activation-script" "rebuild-common" ...)
# 패턴에 매치되지 않으면 heavy로 간주 → false positive 발생

# AFTER: known-heavy blocklist
local heavy_packages=("anki" "mise")
# 등록된 패키지만 heavy, 나머지는 모두 trivial → false positive 제로
```
````

### 흔한 실수
- 모든 파일을 나열하되 변경 내용을 생략하는 것.
- 코드 스니펫 없이 "로직을 수정했다"라고만 쓰는 것.

## 6. 참고 레퍼런스

### 작성 규칙
- 관련 PR, 이슈, 외부 링크를 나열한다.
- 각 항목에 안정 식별자(PR 번호 `#N`, 이슈 번호 `#N`, 또는 머지된 commit SHA) + 1줄 설명을 포함한다.
- 본인 PR의 mid-flight commit hash 또는 squash 전 partial hash chain은 박제하지 않는다 — squash 머지 후 dangling 위험.
- 레퍼런스가 없으면 "해당 없음"으로 명시한다.

### 예시

```markdown
## 참고 레퍼런스

- PR #112 — pre-flight 체크 최초 구현
- PR #115 — known-trivial allowlist 도입
- Issue #118 — `activation-script` false positive 보고
- [Nix pills: derivation basics](https://nixos.org/guides/nix-pills/our-first-derivation.html) — derivation 판별 로직 참고
```

### 흔한 실수
- "관련 PR 참조"처럼 구체적 번호 없이 모호하게 쓰는 것.
- 설명 없이 링크만 나열하는 것.
- 본인 PR의 mid-flight commit hash chain을 참고 레퍼런스에 박는 것 (squash 후 무효).

## 7. Human Test Plan

### 작성 규칙
- 사람이 수동으로 검증할 수 있는 단계별 절차를 기술한다.
- 각 단계에 기대동작을 명시한다.
- 실패 시 진단 방법을 포함한다.

### 예시

```markdown
## Human Test Plan

### 정상 동작 검증

1. `nrs`를 실행한다.
   - **기대**: pre-flight 체크가 heavy_packages에 등록된 패키지만 경고한다.
   - **실패 시**: `heavy_packages` 배열 내용과 실제 derivation 이름을 비교한다.

2. 새 trivial derivation이 추가된 상태에서 `nrs`를 실행한다.
   - **기대**: false positive 경고가 발생하지 않는다.
   - **실패 시**: blocklist 매칭 로직의 regex 패턴을 확인한다.

### 엣지 케이스

3. `heavy_packages` 배열이 비어있는 상태에서 `nrs`를 실행한다.
   - **기대**: pre-flight 체크가 모든 패키지를 trivial로 간주하고 경고 없이 진행한다.
```

### 흔한 실수
- "동작을 확인한다"처럼 기대동작을 생략하는 것.
- 실패 시 진단 방법을 포함하지 않는 것.
- 정상 케이스만 나열하고 엣지 케이스를 누락하는 것.

## 8. Pre-Merge E2E 테스트 가이드

### 작성 규칙
- LLM이 직접 실행하여 PR 머지 전에 검증할 수 있는 자동화된 절차를 기술한다.
- Phase 기반 구조를 따른다: Phase 0(정적) → Phase 1-N(기능) → Phase N+1(Regression).
- 상세 작성 규칙은 `references/pre-merge-guide.md` 참조.

### 예시

````markdown
## Pre-Merge E2E 테스트 가이드

### Phase 0: 정적 검증

```bash
# 1. blocklist 배열 존재 확인
grep -q "heavy_packages=" modules/shared/rebuild.sh
# 기대: exit 0

# 2. old allowlist 패턴 부재 확인
! grep -q "trivial_patterns=" modules/shared/rebuild.sh
# 기대: exit 0 (패턴이 없어야 성공)
```

### Phase 1: 기능 검증

> "pre-flight 체크가 blocklist에 등록된 패키지만 heavy로 판별하는지 확인"

```bash
# anki가 heavy로 판별되는지 확인
nrs --dry-run 2>&1 | grep -q "heavy.*anki"
```
- **기대**: anki가 heavy 패키지로 감지된다.
- **실패 시**: `heavy_packages` 배열에 "anki"가 포함되어 있는지, regex 매칭 로직이 올바른지 확인한다.

### Phase 2: Regression

> "기존 trivial derivation이 false positive를 발생시키지 않는지 확인"

- `activation-script`, `rebuild-common.sh` 등 기존 trivial derivation에 대해 경고가 발생하지 않는지 확인한다.
````

### 흔한 실수
- Phase 0 없이 바로 기능 검증으로 들어가는 것 — 정적 검증으로 기본 전제를 먼저 확인해야 한다.
- Regression 검증을 생략하는 것.
- 실패 시 진단을 포함하지 않는 것.
