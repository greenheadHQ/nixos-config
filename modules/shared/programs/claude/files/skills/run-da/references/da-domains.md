# DA reviewer bundle 상세 정의

기본 FULL path는 4개 reviewer bundle을 사용한다. 각 bundle은 두 개의 세부 도메인을 묶어
중복 fan-out을 줄이고, 각 finding에는 실제로 문제를 포착한 세부 관점을 함께 표기한다.

명시적 exhaustive override(`run-da ... full`)가 필요할 때만 bundle을 세부 도메인 단위로 확장한다.

## 공통 출력 형식

모든 DA reviewer는 다음 형식으로 결과를 반환한다.

문제 발견 시:

```text
## [reviewer bundle] 문제 발견: [count]건

### 1. [문제 제목]
- **ID**: {BUNDLE}-{순번} (예: `Correctness-1`. 치환 규칙은 "공통 프롬프트 구조" 섹션 경고 블록 참조)
- **세부 관점**: {SUBDOMAIN}
- **위치**: [파일:줄] 또는 [계획 항목 번호]
- **문제**: 구체적 문제 기술
- **근거**: PoC 또는 레퍼런스
- **심각도**: CRITICAL / HIGH / MEDIUM / LOW
- **권장 수정**: 구체적 수정 방향
```

문제 미발견 시:

```text
[reviewer bundle]: CLEAR
```

계약 위반 또는 금지된 작업 필요 시:

```text
## [reviewer bundle] 위반 상태: VIOLATION

- **유형**: RECOVERABLE / STATEFUL
- **이유**: 어떤 규칙을 왜 위반했는지
- **필요 작업**: RECOVERABLE이면 `N/A` 또는 설명을 적고, STATEFUL이면 `run-da` canonical contract의 stateful-violation 정의에서 실제로 발생한 항목 (`tracked write`, `branch mutation`, `commit/push`, `GitHub write`, `main-agent-only command`, `host mutation`)을 그대로 적는다
- **정리 대상**: RECOVERABLE이면 `N/A`, STATEFUL이면 이번 실행이 만든 scratch dir, 임시 ref/branch, 기타 산출물처럼 cleanup 범위를 특정하는 정보를 적는다
- **로컬 정리 필요**: YES / NO
```

`{SUBDOMAIN}`은 bundle 내부에서 실제로 해당 finding을 포착한 세부 관점이다.
예: `Correctness` bundle에서 `SECURITY`, `Maintainability` bundle에서 `READABILITY`.

## 심각도별 행동 의무

| 심각도 | 행동 | 설명 |
|---|---|---|
| CRITICAL | 진행 차단 | 이 지적이 해결될 때까지 다음 라운드로 진행 불가 |
| HIGH | 수정 필수 | 반드시 수정하되, 라운드 내에서 해결 |
| MEDIUM | 수정 권장 | 기술적 근거를 들어 기각 가능 |
| LOW | 선택적 | 수용/기각 모두 가능, 근거만 명시 |

## 공통 프롬프트 구조

각 DA reviewer에게 아래 구조의 프롬프트를 전달한다.
`{BUNDLE}`, `{SUBDOMAINS}`, `{FOCUS_QUESTION}`, `{FOCUS_TARGETS}`, `{OTHER_BUNDLES}`를 bundle별로 치환한다.

> ⚠️ 이 플레이스홀더는 셸 변수가 아니다. 조립 절차는 [`../modes/for_plan.md`](../modes/for_plan.md) / [`../modes/for_pr.md`](../modes/for_pr.md)를 참조한다.
> `{BUNDLE}` / `{SUBDOMAINS}` / `{FOCUS_QUESTION}` 등의 UPPERCASE 표기는 LLM 텍스트 치환 플레이스홀더 관용이며, 치환 값은 아래 bundle 정의 표의 원문을 대소문자 변환 없이 그대로 사용한다 (bundle 이름은 Title Case, 세부 관점은 UPPERCASE). Bash tool(zsh) 의 case modification 제약은 repo 루트 `CLAUDE.md` "Bash tool 환경" 섹션 참조.
> `{OTHER_BUNDLES}`는 현재 bundle을 제외한 reviewer bundle 이름의 쉼표 구분 목록이다.

```text
당신은 {BUNDLE} reviewer bundle이다. 세부 관점은 {SUBDOMAINS}다.
오직 {BUNDLE} 범위 안에서만 리뷰하고, 각 finding에는 가장 적절한 세부 관점 하나를 붙여라.
{FOCUS_QUESTION}

집중 대상:
{FOCUS_TARGETS}

Self-verification을 위해 nested `codex exec` 또는 `codex-exec-supervised`를 호출하지 마라.
codex exec fallback 경로처럼 read-only sandbox에서 실행 중이면 파일 증거, 문서 인용, diff 확인만 사용하라.
PoC가 필요하고 현재 런타임이 out-of-repo write를 허용하면 `umask 077` 아래에서 `mktemp -d`로 만든 repo 밖 private scratch 디렉토리에서만 수행하라.
tracked workspace write, branch mutation, commit/push, GitHub write, main-agent-only command, host mutation은 explicit delegation 없이는 금지다.
위 규칙을 위반했거나 금지된 작업이 필요하면 finding 대신 `VIOLATION` 형식으로 반환하라.

다른 bundle({OTHER_BUNDLES})의 우려는 언급하지 마라.
문제가 없으면 CLEAR를 반환하라.

[공통 출력 형식에 따라 결과를 반환하라]
```

## 기본 reviewer bundle 정의

| reviewer bundle | 세부 관점 | 핵심 질문 | 집중 대상 |
|-----------------|----------|----------|----------|
| Correctness | `HALLUCINATION`, `SECURITY` | "이 변경이 실제로 존재하는 동작인가, 그리고 안전한가?"를 검증하라 | 존재하지 않는 API/CLI 플래그/경로, 잘못된 시그니처/인자, trust boundary 오판, 인증/인가 우회, 입력 검증 부재, 과도한 네트워크 노출 |
| Design | `YAGNI`, `NGMI` | "지금 필요하지 않은 복잡성을 만들거나, 구조적 막다른 길을 만들지 않는가?"를 판단하라 | 사용처 없는 인터페이스/추상화, 미래 대비 과설계, 가정 붕괴 시 전면 재작성 필요한 구조, 잘못된 책임 분리, 확장 경로 차단된 데이터/모듈 경계 |
| Regression | `SIDE_EFFECT`, `CONSISTENCY` | "기존 동작이나 프로젝트 관례를 조용히 깨지 않는가?"를 추적하라 | 공유 상태의 암묵적 변경, 인터페이스 계약 변경, 환경 변수/경로/포트 변경, import/export 파급, 네이밍/디렉토리/설정 규칙 위반, 기존 패턴 무시 재구현 |
| Maintainability | `READABILITY`, `CLEAN_CODE` | "다음 개발자(LLM 포함)가 이 변경을 빠르게 이해하고 안전하게 수정할 수 있는가?"를 판단하라 | 함수/변수명과 동작 불일치, why 주석 부재, 복잡한 제어 흐름, 복사-붙여넣기 중복, 매직넘버/매직스트링, 죽은 코드, 방치된 TODO/HACK |

## 명시적 exhaustive override 매핑

`run-da ... full`은 기본 bundle fan-out을 세부 도메인으로 확장한다. 이 경로는
기본값이 아니라 exhaustive override이며, reviewer 수를 늘리는 대신 recall을 우선한다.

| reviewer bundle | exhaustive override로 확장되는 세부 도메인 |
|-----------------|------------------------------------------|
| Correctness | `HALLUCINATION`, `SECURITY` |
| Design | `YAGNI`, `NGMI` |
| Regression | `SIDE_EFFECT`, `CONSISTENCY` |
| Maintainability | `READABILITY`, `CLEAN_CODE` |
