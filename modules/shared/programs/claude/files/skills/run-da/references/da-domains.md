# DA reviewer bundle 상세 정의

기본 FULL path는 4개 reviewer bundle을 사용한다. 각 bundle은 두 개의 세부 도메인을 묶어
중복 fan-out을 줄이고, 각 finding에는 실제로 문제를 포착한 세부 관점을 함께 표기한다.

명시적 exhaustive override(`run-da ... MAX`)가 필요할 때만 bundle을 세부 도메인 단위로 확장한다.

## 공통 출력 형식

모든 DA reviewer는 다음 형식으로 결과를 반환한다.

문제 발견 시:

```text
## [reviewer bundle] 문제 발견: [count]건

### 1. [문제 제목]
- **ID**: {PREFIX}-{순번} (아래 "finding ID 문법" 참조. 치환 규칙은 "공통 프롬프트 구조" 섹션 경고 블록 참조)
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
정적으로 판정 가능한 관점(예: CLEAN_CODE, READABILITY, 다수의 HALLUCINATION/CONSISTENCY 질문)은 PoC를 수행하지 말고 파일:줄·코드 인용과 문서 근거로만 답하라. "코드를 읽으면 답이 나오는" 질문을 런타임 재현으로 바꾸지 마라 — 런타임 재현은 비용일 뿐 아니라, 재현물을 잘못 작성하면 원본과 반대 결론을 낼 정확성 위험이 있다.
codex exec fallback 경로처럼 read-only sandbox에서 실행 중이면 파일 증거, 문서 인용, diff 확인, git read-only 조회(`git log`/`blame`/`show`)만 사용하라.
PoC는 정적 근거만으로 판정이 불가능한 경우에 한해서만 수행한다. 현재 런타임이 out-of-repo write를 허용하더라도 먼저 "이 질문이 정적으로 답 가능한가"를 자문하고, 가능하면 PoC 대신 인용으로 답하라. PoC가 정말 필요하면 `umask 077` 아래에서 `mktemp -d`로 만든 repo 밖 private scratch 디렉토리에서만 수행한다.
tracked workspace write, branch mutation, commit/push, GitHub write, main-agent-only command, host mutation은 explicit delegation 없이는 금지다.
위 규칙을 위반했거나 금지된 작업이 필요하면 finding 대신 `VIOLATION` 형식으로 반환하라.

리뷰 모드가 `for_plan`이면 아직 구현되지 않은 계획을 검토한다. 현재 코드에 변경이 반영되지 않았거나 git diff가 비어 있는 것은 당연하며, finding의 기각 근거가 아니다. "사실 정확성"은 지적한 기술적 메커니즘이 실제로 존재하는지, "변경 연관성"은 계획이 실행되면 해당 문제가 도입되는지를 기준으로 검토하라.

작업이 의도적으로 제거·축소·교체하는 동작은 regression/side-effect가 아니다. 변경 의도(diff가 향하는 방향)와 일치하는 동작 소멸은 위반으로 보고하지 마라. 제거가 의도인지 diff/컨텍스트로 불확실하면 위반으로 단정하지 말고 그 불확실성을 finding에 명시하라.
반대로, 과거에 의도적으로 내린 결정(방어 로직, 트레이드오프 선택, 기각한 대안)을 그 도입 근거를 모른 채 되돌리는 것은 회귀다(decision regression). 주입된 "의사결정 컨텍스트 팩"과 git read-only 조회(`git log -S`/`blame`/`show`)로 이번 변경이 과거 결정과 충돌하는지 점검하고, 충돌하면 과거 결정의 출처(commit SHA / PR# / issue#)를 finding에 첨부하라(출처 없는 추상적 우려는 기각된다). 줄 수가 많다는 이유만으로 방어 로직을 "군살"로 단정하지 마라. 또한 `mv`/rename/in-place write가 기존 파일의 symlink(다른 레이어가 관리)·mode/권한·owner 속성을 보존하는지 확인하라. 회귀로 판정하기 전 증거 시점 이후의 수정 커밋을 대조하라(시계열 게이트).

실존 결함·마찰만 보고하라. "있으면 좋을" 추가 기능·방어·최적화 제안은 finding이 아니다 (명백한 에러/오류/오타와 사용자가 실제 겪는 UX/DX 마찰은 실존 결함·마찰이다).
극단적·이론상 입력이나 환경을 가정한 지적은 현실적 발생 경로를 함께 제시하지 못하면 보고하지 마라. 단 SECURITY 관점은 취약점 유형별 threat path(injection/입력 기반, 노출/유출, 인가 결함, 네트워크 표면)가 성립하면 현실적 경로로 본다 — 유형별 성립 조건의 정의와 최종 판정은 Arbiter 소관이므로([`arbiter-prompt.md`](arbiter-prompt.md)의 "SECURITY threat path" 섹션) 성립이 의심되면 유형명을 표기해 보고하라.

다른 bundle({OTHER_BUNDLES})의 우려는 언급하지 마라.
문제가 없으면 CLEAR를 반환하라.

[공통 출력 형식에 따라 결과를 반환하라]
```

## finding ID 문법

finding ID 문법의 정본이다 — 문법 선언은 이 절이 소유하고, 배포 경계상 각 소비자(검증기·세션 분석기)가 구현 정규식을 소유한다. 선언을 바꾸면 소비자 구현을 함께 갱신한다 (아래 manual sync contract — 소비 문서는 정규식을 재서술하지 않고 이 절을 참조한다).

- 형식: `{PREFIX}-{순번}` (순번은 각 reviewer 결과 안에서 1부터, 중복 없이). 다중 라운드 문맥에서 라운드 구분이 필요한 소비자(라운드 요약·세션 내 기각 이력·분석)는 선택적 라운드 suffix를 붙인 `{PREFIX}-{순번}-r{라운드}` 형태를 쓸 수 있다 — suffix 부여 주체는 메인 에이전트다. 부여 시점·범위: 메인이 라운드 요약·세션 내 기각 이력 등 라운드 경계를 넘는 기록에 finding을 지칭할 때 원본 ID에 그 finding이 나온 라운드 번호를 붙인다. Arbiter 입력·`--expect-findings` manifest·검증기 대조는 원본 ID를 그대로 사용한다 (exact-set 대조 유지 — suffix는 기록·서술 축이지 검증 축이 아니다). reviewer는 spawn 격리 실행이라 자기 라운드 번호를 모르므로 suffix 없는 기본형만 산출한다 (라운드 축이 문법에 없어 자연 표기가 위반이 되고, 이를 피하려는 ID 개명이 검증 우회로 이어진 실측이 도입 근거 — #1259).
- `{PREFIX}` namespace는 실행 경로에 따라 다르며 둘 다 적법하다: 기본 bundle fan-out은 bundle 이름(`Correctness-1`, `Design-2`), exhaustive override(`MAX`)는 세부 관점 이름(`SECURITY-2`, `CLEAN_CODE-1`).
- 허용 문자: prefix는 영문자와 `_`, 순번은 숫자 (기본형 정규식 `[A-Za-z_]+-[0-9]+`). live 검증 경로 전체 — reviewer 원본·Arbiter 입력·`--expect-findings` manifest — 는 기본형만 적법하다 (reviewer 원본에 suffix가 있으면 spawn 격리 위반 신호 — reviewer는 라운드를 모른다). 라운드 suffix 확장형(`[A-Za-z_]+-[0-9]+(-r[0-9]+)?`)의 기계 소비자는 세션 분석기뿐이다. 이 제약의 목적은 namespace 검증이 아니라 shell-safe 보장이다 — reviewer가 만든 ID는 비신뢰 입력인데 이후 `--expect-findings` 셸 인자로 전달된다.
- 검증기 구현은 `fleiss-kappa.py`의 `SAFE_FINDING_ID_PATTERN`(기본형 — reviewer·Arbiter·manifest 공통)이고, 세션 분석기(`analyzing-da-sessions`의 `analyze.py`)의 `HUMAN_VERDICT_HEADER`가 확장형 문법을 별도 정규식으로 소비한다. 문법을 바꾸면 이 절과 두 소비자를 함께 갱신한다 (manual sync contract — 정규식의 기계 판정 구현은 각 소비자가, 문법 선언은 본 절이 소유한다. 배포 경계가 달라 공유 상수로 중앙화할 수 없다).

## 기본 reviewer bundle 정의

| reviewer bundle | 세부 관점 | 핵심 질문 | 집중 대상 |
|-----------------|----------|----------|----------|
| Correctness | `HALLUCINATION`, `SECURITY` | "이 변경이 실제로 존재하는 동작인가, 그리고 안전한가?"를 검증하라 | 존재하지 않는 API/CLI 플래그/경로, 잘못된 시그니처/인자, trust boundary 오판, 인증/인가 우회, 입력 검증 부재, 과도한 네트워크 노출 |
| Design | `YAGNI`, `NGMI` | "지금 필요하지 않은 복잡성을 만들거나, 구조적 막다른 길을 만들지 않는가?"를 판단하라 | 사용처 없는 인터페이스/추상화, 미래 대비 과설계, 가정 붕괴 시 전면 재작성 필요한 구조, 잘못된 책임 분리, 확장 경로 차단된 데이터/모듈 경계 |
| Regression | `SIDE_EFFECT`, `CONSISTENCY` | "기존 동작이나 프로젝트 관례를 의도치 않게 조용히 깨지 않는가?"를 추적하라 (의도된 제거·축소는 위반 아님; 단 과거 의도적 결정을 근거 없이 되돌리면 decision regression) | 공유 상태의 암묵적 변경, 인터페이스 계약 변경, 환경 변수/경로/포트 변경, import/export 파급, 네이밍/디렉토리/설정 규칙 위반, 기존 패턴 무시 재구현, 과거 결정/기각 대안의 무근거 되돌림([`decision-regression-audit.md`](decision-regression-audit.md)), `mv`/rename이 symlink·mode·owner 속성 파괴 |
| Maintainability | `READABILITY`, `CLEAN_CODE` | "다음 개발자(LLM 포함)가 이 변경을 빠르게 이해하고 안전하게 수정할 수 있는가?"를 판단하라 | 함수/변수명과 동작 불일치, why 주석 부재, 복잡한 제어 흐름, 복사-붙여넣기 중복, 매직넘버/매직스트링, 죽은 코드, 방치된 TODO/HACK |

## 명시적 exhaustive override 매핑

`run-da ... MAX`는 기본 bundle fan-out을 세부 도메인으로 확장한다. 이 경로는
기본값이 아니라 exhaustive override이며, reviewer 수를 늘리는 대신 recall을 우선한다.
`NGMI`와 `CLEAN_CODE` 관점은 기본 FULL bundle 내부에 남지만, 독립 exhaustive review unit에서는 제외한다.

| reviewer bundle | exhaustive override로 확장되는 세부 도메인 |
|-----------------|------------------------------------------|
| Correctness | `HALLUCINATION`, `SECURITY` |
| Design | `YAGNI` |
| Regression | `SIDE_EFFECT`, `CONSISTENCY` |
| Maintainability | `READABILITY` |
