# 설계 철학 및 레퍼런스

이 스킬의 설계 근거를 형성하는 5개 레퍼런스와 핵심 통찰.

## 핵심 통찰

> 코드는 일회용이 될 수 있지만, 의도 기록은 영구적이다.
> CIR/ADR은 LLM에게 "거기 있었던 팀원"의 맥락을 제공하는 유일한 방법이다.

LLM 기반 개발에서 세션 간 맥락은 단절된다. git log는 "무엇이 변경되었는지"를 보여주지만,
"왜 A를 시도했다가 B로 갔다가 다시 A로 돌아왔는지"는 기록되지 않는다.
CIR은 이 갭을 메운다.

## 1. ADR을 써야 하는 이유

**출처**: GeekNews #2665 → GitHub Blog

- ADR은 의사결정 시점의 맥락을 보존한다
- 거부된 대안과 그 이유가 선택된 방안만큼 중요하다
- ADR 없이 코드만 읽는 LLM은 구조 뒤의 의도에 접근할 수 없어, 기존 제약을 무의식적으로 위반할 수 있다

**이 스킬과의 연결**: CIR의 버전별 이력(v1→v2→v3)이 바로 "거부된 대안의 기록"이다.

## 2. Why Write ADRs

**출처**: GitHub Blog (github.blog/engineering/architecture-optimization/why-write-adrs/)

- ADR은 3개 청중을 동시에 서비스한다: 미래의 나, 현재 팀원, 미래 팀원
- 작성 비용은 낮고, 잃어버린 맥락을 재구성하는 비용은 높다
- PR description만으로는 시스템 수준의 결정을 전달할 수 없다

**이 스킬과의 연결**: LLM 세션은 "미래 팀원"과 동일하다. CIR이 없으면 매 세션마다 맥락을 처음부터 재구성해야 한다.

## 3. Change Intent Records (Bryan Liles)

**출처**: blog.bryanl.dev/posts/change-intent-records/

- AI 기반 개발이 만든 새로운 문서화 갭: "왜 AI에게 그렇게 지시했는가"의 제약, 거부된 대안, 대화 속 추론이 기록되지 않는다
- CIR의 5개 섹션: Intent(목표), Behavior(given/when/then), Constraints(제약), Decisions(거부된 대안과 이유), Date
- ADR = 아키텍처 수준, CIR = 기능 수준 구현 추론

**이 스킬과의 연결**: 이 스킬은 ADR/CIR을 통합하되, Bryan Liles의 "Decisions" 섹션(거부된 대안과 이유)을 핵심으로 삼는다. 규모에 따라 자동으로 기록 수준을 조절한다.

## 4. 코드를 읽지 않는 것에 대한 옹호

**출처**: GeekNews #26966 → Ben Shoemaker 블로그

- AI 생성 코드의 검증은 라인별 리뷰가 아니라 사양(spec), 자동 테스트, 정적 분석, 프로덕션 시그널에 의존해야 한다
- 코드는 점점 구현 세부사항이 되고, 엔지니어의 역할은 검증 하네스 설계로 이동한다
- 코드를 직접 읽지 않는다면, 의도 기록(ADR/CIR)이 사실상 진짜 진실 원천(source of truth)이 된다

**이 스킬과의 연결**: CIR은 "코드를 읽지 않아도 의사결정 맥락을 파악할 수 있는" 인터페이스다.

## 5. In Defense of Not Reading the Code

**출처**: Ben Shoemaker (benshoemaker.us/writing/in-defense-of-not-reading-the-code/)

- 어셈블리→C 전환과 유사한 추상화 계층 변화: AI 코드 생성 포함
- 추상화 계층을 신뢰할 수 있는 검증 인프라가 있으면 코드 자체를 읽는 것은 예외가 된다
- 의도, 제약, 의사결정 근거가 인간이 실제로 유지·검토하는 새로운 source of truth가 된다

**이 스킬과의 연결**: 이 스킬이 생성하는 CIR은 "인간이 유지·검토하는 source of truth"의 구체적 구현이다.

## 실현 동기: PR #121 사례

PR #121 (pre-flight allowlist → blocklist 전환)에서 CIR을 수동으로 작성하면서,
매번 의식적으로 기억해야 하는 것이 아니라 시스템적으로 체계화되어야 한다는 필요성을 체감했다.

3단계 의사결정 번복 이력:
- v1: blocklist 구상 → 관리 부담 우려로 allowlist 채택
- v2: allowlist에서 false positive 발생 → 패턴 추가로 대응
- v3: allowlist 방식의 근본적 한계 확인 → 원래 구상대로 blocklist 회귀

이 이력은 코드만 보면 알 수 없다. CIR이 없었다면 미래의 LLM 세션은
"왜 blocklist인가?"에 대한 맥락 없이 같은 실수(allowlist 시도)를 반복할 수 있다.
