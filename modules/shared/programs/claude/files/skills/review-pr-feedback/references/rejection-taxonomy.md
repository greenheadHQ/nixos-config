# 기각 분류 체계 (Rejection Taxonomy)

리뷰 피드백을 기각할 때 사용하는 7개 카테고리의 정본.
SKILL.md는 이 파일을 1-2문장 요약 + 링크로만 참조한다.

## 기각 시 공통 포맷

기각 답글에는 다음 4필드를 모두 포함한다.

| 필드 | 필수 | 설명 |
|------|------|------|
| **기각 분류** | ✅ | 아래 7개 중 택1 |
| **검증 방법** | ✅ | 직접 읽은 파일:줄, 로컬 재현 명령, API 실측 결과 중 하나 |
| **기술적 근거** | ✅ | 1문장 이상. "불필요합니다" 금지 |
| **신뢰도** | ✅ | HIGH / MEDIUM / LOW. LOW이면 질문 도구로 사용자 판단 위임 (런타임별 매핑은 [run-da의 "런타임 도구 매핑" 표](../../run-da/SKILL.md#런타임-도구-매핑) 참조) |

## 7개 카테고리

### HALLUCINATION — 존재하지 않는 문제

리뷰어가 실제로는 없는 코드·동작·API를 지적한 경우.

- **정답 패턴**: 리뷰어가 `foo()` 함수의 반환값 검증 누락을 지적했으나, 해당 파일에 `foo()`가 존재하지 않거나 이미 반환값을 검증하는 코드가 명시돼 있다.
- **오분류 방지**: 코드가 "이미 수정되어 사라진" 경우는 `HALLUCINATION`이 아니다 → `STALE_REVIEW`.
- **답글 템플릿**:
  ```text
  기각 분류: HALLUCINATION
  검증 방법: `<file>:<line>`을 직접 확인. 지적된 `foo()` 호출 지점이 존재하지 않음.
  기술적 근거: 현재 코드에는 해당 경로가 없으며, `bar()`를 통해 검증을 거친 뒤 호출된다.
  신뢰도: HIGH
  ```

### STALE_REVIEW — 이미 해결된 지적

리뷰 시점과 현재 diff가 달라 이미 반영되었거나 더 이상 문제가 아닌 지적.

- **정답 패턴**: AI 리뷰어가 stale snapshot으로 지적 → 이미 해당 라인은 수정 완료. `isOutdated=true` 상태인 경우가 많다.
- **오분류 방지**: "리뷰어가 거짓말했다" 식의 `HALLUCINATION`과 다르다. 리뷰 자체는 해당 시점에는 사실이었다.
- **답글 템플릿**:
  ```text
  기각 분류: STALE_REVIEW
  검증 방법: 커밋 `<hash>`에서 해당 라인을 이미 수정 (`<이전 코드>` → `<현재 코드>`).
  기술적 근거: 리뷰 시점 diff와 현재 상태가 다릅니다.
  신뢰도: HIGH
  ```

### WRONG_REFERENCE — 잘못된 경로/파일 참조

리뷰어가 실제로는 존재하지 않는 파일 경로·심볼·라인 번호를 지적한 경우.

- **정답 패턴**: `path/to/foo.nix` 파일이 저장소에 없거나, 지적된 라인이 주석 또는 범위 밖이다.
- **오분류 방지**: 경로는 맞고 지적 내용 자체가 틀렸다면 `HALLUCINATION`.
- **답글 템플릿**:
  ```text
  기각 분류: WRONG_REFERENCE
  검증 방법: `<path>`를 직접 확인 (예: `rg -n <pattern> <path>` / `sed -n <line>p <path>` / `git diff -- <path>`).
  기술적 근거: 해당 파일 또는 줄은 존재하지 않습니다. (예: 파일 이름 오타 / 라인 범위 초과)
  신뢰도: HIGH
  ```

### SCOPE_DEFERRAL — 이번 PR 범위 밖

지적 자체는 유효하나 현재 PR의 변경 범위 밖이며 별도 이슈로 처리해야 하는 경우.

- **정답 패턴**: 이번 PR은 수집 단계 변경. 리뷰어가 답글 UX 개선을 요구 → 별도 이슈.
- **오분류 방지**: 현재 변경된 파일 안에서의 문제라면 `SCOPE_DEFERRAL`이 아니라 해당 PR에서 처리해야 한다.
- **답글 템플릿**:
  ```text
  기각 분류: SCOPE_DEFERRAL
  검증 방법: `git diff main...HEAD -- <path>` 결과 해당 영역이 이번 PR에 포함되지 않음.
  기술적 근거: 지적은 타당하나 이번 PR의 범위 밖입니다. 별도 이슈 #<NNN>으로 분리.
  신뢰도: HIGH
  ```

### VERIFIED_FALSE_POSITIVE — 검증 후 거짓 양성

리뷰어 지적을 로컬에서 재현 시도했으나 실제로는 문제가 발생하지 않는 경우.

- **정답 패턴**: 리뷰어가 "regex가 빈 매치를 돌려줄 것"이라고 지적 → 로컬에서 같은 입력으로 실행해보니 정상 매치. 린터 false positive 포함.
- **오분류 방지**: 코드가 존재하는가 자체의 문제는 `HALLUCINATION`. 여기서는 코드는 있지만 지적된 동작이 발생하지 않는다.
- **답글 템플릿**:
  ```text
  기각 분류: VERIFIED_FALSE_POSITIVE
  검증 방법: 로컬 재현 `<command>` → `<결과 출력>`.
  기술적 근거: 지적된 동작이 실제 실행에서는 발생하지 않습니다.
  신뢰도: HIGH
  ```

### DESIGN_TRADEOFF — 의도된 설계 선택

지적의 사실은 맞지만 프로젝트가 의식적으로 채택한 트레이드오프.

- **정답 패턴**: "에러 핸들링이 단순하다"는 지적 → CLAUDE.md/CIR에 "내부 스크립트는 단순성 우선"이 문서화되어 있음.
- **오분류 방지**: 의도가 기록돼 있지 않은 경우는 이 분류를 쓰지 말고 먼저 근거를 찾거나 `/documenting-intent`로 기록한다.
- **답글 템플릿**:
  ```text
  기각 분류: DESIGN_TRADEOFF
  검증 방법: 관련 CIR/ADR `<path>` 또는 CLAUDE.md `<section>`.
  기술적 근거: 이번 프로젝트는 X 이유로 Y를 선택했습니다. 문서 링크 참고.
  신뢰도: HIGH
  ```

### TECHNICAL_DISAGREEMENT — 기술적 견해 차이

같은 사실을 두고 해석이 다를 때. `DESIGN_TRADEOFF`와의 차이는 "문서화된 의도"의 유무.

- **정답 패턴**: "TypeScript strict mode 권장" 지적 → 본 레포는 이미 Nix로 타입 안전성을 확보하고 있어 불필요.
- **오분류 방지**: LOW 신뢰도이면 사용자 판단에 위임한다.
- **답글 템플릿**:
  ```text
  기각 분류: TECHNICAL_DISAGREEMENT
  검증 방법: `<근거 파일 또는 외부 레퍼런스>`.
  기술적 근거: 지적된 방향도 합리적이나, 본 레포는 X 이유로 Y를 유지합니다.
  신뢰도: MEDIUM
  ```

## 오분류 흔한 실수 (요약)

| 상황 | 올바른 분류 | 흔한 오분류 |
|------|------------|------------|
| 존재하지 않는 코드 지적 | `HALLUCINATION` | — |
| 이미 수정된 코드 지적 | `STALE_REVIEW` | ~~HALLUCINATION~~ |
| 잘못된 경로/라인 참조 | `WRONG_REFERENCE` | ~~HALLUCINATION~~ |
| 범위 밖 지적 | `SCOPE_DEFERRAL` | ~~nitpick~~ 또는 ~~HALLUCINATION~~ |
| 로컬에서 재현 안 됨 | `VERIFIED_FALSE_POSITIVE` | ~~HALLUCINATION~~ |
| 기술적 견해 차이 | `TECHNICAL_DISAGREEMENT` | ~~HALLUCINATION~~ |

특히 CodeRabbit 같은 AI 리뷰어는 stale diff 기반으로 지적하는 빈도가 높다.
"이미 수정된 항목에 대한 지적"을 `HALLUCINATION`으로 분류하면 안 된다.
리뷰 자체는 해당 시점에서 사실이었으므로 `STALE_REVIEW`가 맞다.

## 실제 사례 (PR #399)

이 스킬이 강화되기 전 PR #399에서 겪은 실제 리뷰 스레드 2건. 원문 위치는
다음 쿼리로 즉시 찾을 수 있다.

```bash
gh api graphql -f owner=greenheadHQ -f repo=nixos-config -F pr=399 -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            isResolved path
            comments(first: 5) { nodes { author { login } bodyText } }
          }
        }
      }
    }
  }' | jq '.data.repository.pullRequest.reviewThreads.nodes'
```

### 사례 1: regex escaping 지적 (CodeRabbit)

- **원 지적**: DA harness 플랜 문서의 Python 예시에서 raw string의 `\\n`, `\\b`가 literal 백슬래시로 들어가 regex 의도와 다르게 동작. f-string의 `\\t`도 literal로 출력.
- **처리**: 로컬에서 `loc_re.findall`, `domain_re.findall`, tab 출력을 직접 실행하여 문제를 재현 (수정 전 `loc_matches=[]`, 수정 후 `loc_matches=['foo/bar.txt:12']`).
- **분류 결과**: 기각이 아니라 반영. 답글에 재현 결과와 수정 커밋 해시를 남긴 뒤 resolve.

### 사례 2: 누락된 `os` import 지적 (CodeRabbit)

- **원 지적**: 같은 문서의 Python heredoc 스니펫이 `os.path.expanduser()`를 쓰면서 `import os`를 누락.
- **처리**: 스니펫을 직접 읽고 `import os`를 추가. `git diff --check`로 문서 무결성 재확인 후 답글에 검증 내역 기록, resolve.
- **분류 결과**: 기각이 아니라 반영.

이 두 사례는 "기각 예시"가 아닌 **반영 후 답글 기록의 모범 사례**로도 사용할 수 있다.
답글에는 `- confirmed <file>`, `- added <fix>`, `- re-ran <verification>` 형태로 검증 내역을 남긴다.
