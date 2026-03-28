# Skill Writing Guide — Best Practices & Anti-Patterns

> 30개 병렬 조사 에이전트, 200+ URL, 50+ 학술 논문, 실증 데이터를 종합한 가이드.
> 대상: 이 nixos-config 프로젝트의 Claude Code 스킬 작성/개선 시 참조.

---

## 목차

1. [스킬 필요성 판단](#1-스킬-필요성-판단)
2. [Description 작성법](#2-description-작성법)
3. [Body 콘텐츠 작성법](#3-body-콘텐츠-작성법)
4. [구조와 분류 기준](#4-구조와-분류-기준)
5. [다국어 트리거 최적화](#5-다국어-트리거-최적화)
6. [스킬 라이프사이클](#6-스킬-라이프사이클)
7. [자동화 파이프라인](#7-자동화-파이프라인)
8. [안티패턴 카탈로그](#8-안티패턴-카탈로그)
9. [레퍼런스](#9-레퍼런스)

---

## 1. 스킬 필요성 판단

### 핵심 질문: "이것을 스킬로 만들어야 하는가?"

#### 1.1 판단 프레임워크

| 신호                                     | 행동                               |
| ---------------------------------------- | ---------------------------------- |
| 같은 실수를 **2번 이상** 교정함          | 규칙으로 인코딩                    |
| PR 리뷰에서 LLM이 만든 패턴 위반 발견    | instruction 추가                   |
| 코드를 읽으면 알 수 있지만 **>50%** 틀림 | instruction 추가                   |
| 린터/포매터/타입체커로 강제 가능         | instruction 불필요 — 도구 사용     |
| 표준 언어 컨벤션 (PEP 8, gofmt 등)       | instruction 불필요 — LLM이 이미 앎 |
| **프로젝트 고유**의 표준 이탈            | instruction 필요 — LLM이 추측 불가 |
| instruction 제거해도 LLM 행동 변화 없음  | **삭제**                           |

> **출처**: Builder.io CLAUDE.md guide, HumanLayer blog, CMU underspecification 연구

#### 1.2 "유추 가능 ≠ 실제로 매번 정확히 유추함" 경계

CMU 연구 (arXiv:2505.13360)에 따르면:

- LLM의 underspecification 해소 성공률은 **41.1%**에 불과
- 모델 버전 간 **20%+ 변동** 발생 — 지금 되더라도 다음 버전에서 깨질 수 있음
- "모든 것을 명시하면 오히려 성능 저하" — 긴 instruction을 따르는 능력 한계 때문

**실전 결론**: "유추 가능"과 "명시 필요" 사이의 경계는 **실증적으로만 판단 가능**.

1. 스킬 없이 대표 작업 실행
2. 실패 패턴 기록
3. 최소한의 instruction으로 실패 해결
4. 반복 검증

#### 1.3 Instruction 수의 수학적 한계

**"Curse of Instructions" 공식** (OpenReview, GitHub 2,500+ repos 분석):

```
P(모든 instruction 준수) = P(개별 instruction 준수)^n
```

개별 준수율 90%일 때:

- 3개 instruction → 73% 전체 준수
- 10개 → 35%
- 20개 → 12%

**실측치**: Claude Code 시스템 프롬프트가 이미 ~50개 instruction 소모.
사용자 instruction 예산은 **100-150개**가 한계.

**실전 의미**: 매 스킬의 매 줄이 이 예산을 소모한다.
"이 줄을 제거하면 Claude가 실수하는가?" — No이면 삭제.

#### 1.4 6가지 판단 프레임워크

| 프레임워크              | 핵심 원칙                                               | 출처                  |
| ----------------------- | ------------------------------------------------------- | --------------------- |
| **Start Minimal**       | 최소 프롬프트로 시작 → 실패 모드 기반 추가              | Augment Code, OpenAI  |
| **Diminishing Returns** | 처음 5시간 35% 개선, 다음 20시간 5%, 다음 40시간 1%     | Softcery              |
| **Context Budget**      | 시스템 프롬프트에 총 context의 5-10%만 할당             | Anthropic             |
| **New Employee Test**   | 똑똑한 신입에게 필요한 정보인가, 코드에서 알 수 있는가? | Anthropic             |
| **3-Strike Rule**       | 같은 실패 패턴 3회 반복 → hook 또는 instruction 생성    | 68 failures QA system |
| **10-Iteration Test**   | 10번 수정해도 안 고쳐지면 프롬프트가 아닌 아키텍처 문제 | Softcery              |

#### 1.5 CLAUDE.md vs Skill vs Rules vs Hooks 배치 기준

| 배치 위치          | 조건                                               | 로딩 방식          |
| ------------------ | -------------------------------------------------- | ------------------ |
| **CLAUDE.md**      | 매 세션 적용. 위반 시 실질적 문제 발생             | 항상 로딩          |
| **Skill**          | 특정 작업에만 관련. 참조 자료 또는 호출형 워크플로 | 필요 시 로딩       |
| **.claude/rules/** | 특정 파일 타입/디렉토리에만 적용                   | paths 매칭 시 로딩 |
| **Hooks**          | 준수가 **보장**되어야 하는 규칙 (보안, 포맷팅)     | 이벤트 시 실행     |

> **원칙**: "Never send an LLM to do a linter's job."
> 결정론적으로 검증 가능한 것은 hooks/pre-commit으로 강제하라.

#### 1.4 스킬로 만들면 안 되는 것

- 코드 구조를 읽으면 즉시 알 수 있는 정보 (파일 위치, import 패턴)
- 표준 언어/프레임워크 컨벤션
- 자주 변하는 정보 (버전 번호, API 엔드포인트) — 링크로 대체
- 코드에 인라인된 문서를 복제한 것
- 린터/포매터가 강제할 수 있는 스타일 규칙

---

## 2. Description 작성법

### 핵심 발견: Description이 유일한 라우팅 신호

Claude Code의 스킬 라우팅은 **순수 LLM 추론**이다.
알고리즘적 키워드 매칭, 임베딩, 분류기가 아니다.
Claude는 startup 시 모든 스킬의 `name` + `description`을 읽고,
transformer forward pass로 어떤 스킬을 호출할지 결정한다.

### 2.1 실증 데이터

**650회 실험** (Ivan Seleznov, 2025):

| Description 스타일 | 활성화율 |
|-------------------|---------|
| 수동형 ("This skill handles X") | **77%** |
| 지시형 ("Use this skill when...") + 부정 제약 | **100%** |
| `keywords` frontmatter 필드 | **측정 가능한 효과 없음** |

**Scott Spence 테스트**:

| 접근 | 활성화율 |
|------|---------|
| 모호한 description | ~20% |
| 명시적 트리거 문구 추가 | ~50% |
| 예시 추가 | ~72-90% |

### 2.2 Description 작성 공식

```
[무엇을 하는가] — 1문장
[언제 사용하는가 / 트리거 조건] — 1-2문장 (지시형: "Use when...")
[핵심 제약 또는 부정 라우팅] — 1문장 ("NOT for X, use Y instead")
```

**규칙**:

- 3인칭 사용 ("This skill should be used when...")
- **1024자** 이내 (Agent Skills 스펙 제한)
- 워크플로를 **요약하지 말 것** — 요약하면 Claude가 body를 읽지 않음
- 사용자가 실제로 입력할 문구를 포함
- `<`, `>` 금지 (YAML 파싱 오류)

### 2.3 Good vs Bad 예시

**Good**:

> This skill should be used when the user asks about Podman/Docker containers,
> homeserver services (immich, uptime-kuma, copyparty, vaultwarden, karakeep),
> container OOM, service updates, or database backups.
> Use when: "update immich", "서비스 업데이트", container OOM, service-lib.
> NOT for service-specific workflows (use hosting-anki, hosting-copyparty, etc).

**Bad**:

> Helps with containers and services.

**Bad** (워크플로 요약 — body 스킵 유발):

> Use for container management - check version, pull image, stop container,
> start container, verify health, clean up old images.

### 2.4 Anthropic 공식 권장: "약간 pushy하게"

> Claude는 스킬을 **undertrigger하는 경향**이 있다. description을 "약간 pushy하게" 작성하라.
> 예: "How to build a dashboard" → "How to build a dashboard. **Make sure to use
> this skill whenever the user mentions dashboards, data visualization, internal
> metrics, or wants to display any kind of data.**"

### 2.5 Description 최적화 루프 (skill-creator)

1. 20개 eval 쿼리 생성 (should-trigger / should-not-trigger 혼합)
2. 60% train / 40% test 분할
3. 현재 description 평가 (쿼리당 3회 실행)
4. 개선된 description 반복 제안 (최대 5회)
5. **test 점수** 기준 best 선택 (train 아님 — 과적합 방지)

---

## 3. Body 콘텐츠 작성법

### 3.1 크기 제약

| 메트릭              | 권장                                      | 근거                              |
| ------------------- | ----------------------------------------- | --------------------------------- |
| SKILL.md 줄 수      | **< 500줄**                               | Anthropic 공식, Agent Skills 스펙 |
| SKILL.md 토큰       | **< 5,000 토큰**                          | Progressive disclosure 아키텍처   |
| 참조 파일 깊이      | **1단계**                                 | SKILL.md → refs/. 중첩 금지       |
| 총 description 예산 | context window의 **2%** (fallback: 16K자) | 초과 시 조용히 제외됨             |

**연구 근거**: 3,000 토큰 이상에서 추론 성능 눈에 띄게 저하 (arXiv:2402.14848).
500개 동시 instruction에서 최선 모델도 68% 정확도 (arXiv:2507.11538).

### 3.2 구조 원칙

**Primacy & Recency Effect**: LLM은 문서 **처음**과 **끝**에 가장 잘 주의함.
중간부 정보는 30%+ 리콜 저하 ("Lost in the Middle", Stanford).

```markdown
# [스킬 이름] (Korean) ← 최상단: 가장 중요한 정보

## 빠른 참조 ← 핵심 명령어/경로 (높은 빈도 참조)

| 명령어 | 설명 |
| ------ | ---- |

## 핵심 절차 ← 주요 워크플로 (중간)

## 자주 발생하는 문제 ← 트러블슈팅 (중간-하단)

## 레퍼런스 ← 참조 파일 포인터 (최하단: recency 활용)

- `references/detailed-guide.md` — [설명]
```

### 3.3 콘텐츠 압축 기법

| 기법                                          | 토큰 절감 | 품질 영향          |
| --------------------------------------------- | --------- | ------------------ |
| Filler 제거 (please, try to, it is important) | 20-30%    | 중립~긍정          |
| 산문 → 불릿/테이블                            | 30-40%    | 긍정 (스캔성)      |
| 긍정 지시 ("Do X" not "Don't do Y")           | 10-15%    | 긍정 (명확성)      |
| 중복/겹치는 instruction 제거                  | 15-25%    | 긍정 (혼동 감소)   |
| "알면 좋은" 컨텍스트 제거                     | 20-50%    | 긍정 (산만함 감소) |
| Verbose 초안 → 핵심 아이디어로 증류           | 40-60%    | 주의하면 중립      |

**Pink Elephant Problem**: "하지 마라" 지시는 오히려 해당 행동을 유발한다.
항상 긍정형으로 전환: "Do not use markdown" → "Use smoothly flowing prose paragraphs."

### 3.4 예시 (Few-shot) 가이드라인

| 질문           | 답                                               |
| -------------- | ------------------------------------------------ |
| 예시 포함 여부 | 구조화된 출력, 스타일이 중요할 때 포함           |
| 몇 개?         | **2-3개** (max 5). Anthropic 공식도 3개 사용     |
| 긍정 vs 부정   | **긍정 우선**. 부정 필요 시 반드시 정답과 쌍으로 |
| 순서           | 가장 대표적인 예시를 **마지막**에 (recency bias) |
| 생략 조건      | 추론 작업, 탐색 워크플로, 단순/명확한 규칙       |

### 3.5 Degrees of Freedom 매칭

| 자유도 | 형식                         | 사용 시                            |
| ------ | ---------------------------- | ---------------------------------- |
| 높음   | 텍스트 지침                  | 여러 접근이 유효, 맥락에 따라 판단 |
| 중간   | 의사코드/스크립트 + 파라미터 | 선호 패턴 존재, 일부 변형 허용     |
| 낮음   | 정확한 스크립트/명령어       | 작업이 취약, 일관성 필수           |

> "절벽이 양쪽에 있는 좁은 다리" → 낮은 자유도 (정확한 스크립트)
> "위험 없는 열린 들판" → 높은 자유도 (텍스트 지침)

---

## 4. 구조와 분류 기준

### 4.1 쪼개야 할 때

1. **500줄 초과**: SKILL.md가 500줄을 넘으면 분할
2. **부분 적용**: 콘텐츠의 일부만 특정 작업에 관련
3. **Reference + Task 혼합**: 참조 지식과 단계별 워크플로가 한 파일에
4. **빈도 차이**: 일부는 매 세션, 나머지는 드물게 사용
5. **모호한 라우팅**: Claude가 잘못된 스킬을 선택 → 스코프가 겹침

### 4.2 합쳐야 할 때

1. **항상 함께 호출**: 두 스킬이 모든 유스케이스에서 같이 사용
2. **구분 불가**: description으로 차이를 설명할 수 없음
3. **너무 작음**: 단독으로 의미 없는 크기
4. **예산 압박**: description이 16K자 예산을 초과

### 4.3 Sweet Spot

| 메트릭                        | 권장                         |
| ----------------------------- | ---------------------------- |
| 상시 로딩 (핵심)              | 3-5개                        |
| 특별한 처리 불필요            | < 10개                       |
| Description 기반 검색 필요    | 10+                          |
| Progressive disclosure로 가능 | 100+                         |
| 스킬당 크기                   | < 500줄 / ~5,000 토큰        |
| 전체 description 예산         | context window의 2% (~16K자) |

### 4.4 현재 프로젝트 진단

| 문제                      | 해당 스킬                             | 권장 조치                            |
| ------------------------- | ------------------------------------- | ------------------------------------ |
| 코드에서 유추 가능        | (삭제됨: managing-vscode, #329)       | 삭제 완료                            |
| 트리거 키워드 중첩        | immich(2), Pushover(3), update(4+)    | 부정 라우팅 보강                     |
| Description 스타일 불일치 | 9개 "This skill..." vs 11개 직접 설명 | 지시형으로 통일                      |
| 부정 라우팅 누락          | 6/22 스킬                             | "NOT for" 추가                       |

---

## 5. 다국어 트리거 최적화

### 5.1 연구 결과

- **한국어 본문 + 영어 기술 용어 = 최적 패턴**: 비영어 텍스트에 영어 토큰 삽입 시
  LLM 이해도 향상 (arXiv:2506.14012)
- **역방향은 성능 저하**: 영어 텍스트에 한국어 삽입은 일관되게 성능 하락
- **한국어 토큰 비용**: 영어 대비 **~2.36x** — 모든 트리거 양어 복제는 예산 압박
- **네이티브 언어 프롬프트**: 해당 언어 콘텐츠 처리 시 25-35% 처리 시간 절감

### 5.2 실전 전략

| 용어 유형                           | 전략                 | 예시                                 |
| ----------------------------------- | -------------------- | ------------------------------------ |
| 한국어 유저가 한국어로 말할 용어    | **양어 복제**        | `이슈`, `비밀번호 관리자`, `시크릿`  |
| 기술 용어 (한국어 유저도 영어 사용) | **영어만**           | SSH, Podman, tmux, Hammerspoon       |
| 명령어/CLI                          | **영어만**           | `nrs`, `agenix -e`, `mise install`   |
| 혼합 사용 가능                      | **고빈도 언어 선택** | `업데이트` + `update` (둘 다 사용됨) |

### 5.3 현재 프로젝트 최적화 기회

현재 스킬의 트리거 중 영어 비율이 ~60%이지만, 사용자는 항상 한국어로 프롬프트.
**기술 용어를 제외한 일반 영어 트리거**는 토큰 낭비일 가능성이 높음.

예: `"container OOM"` — 유지 (기술 용어)
예: `"service updates"` — `"서비스 업데이트"`만으로 충분할 수 있음
(Claude의 semantic matching이 한국어 → 영어 description도 매칭 가능하므로)

---

## 6. 스킬 라이프사이클

### 6.1 전체 주기

```
생성 → 테스트 → 배포 → 모니터링 → 리뷰 → 업데이트/폐기
```

| 단계         | 핵심 활동                                                   | 주기      |
| ------------ | ----------------------------------------------------------- | --------- |
| **생성**     | 스킬 없이 실패 확인 → eval 작성 BEFORE 문서 → 최소 SKILL.md | 필요 시   |
| **테스트**   | 대표 작업으로 baseline vs with-skill 비교. 모델별 테스트    | 배포 전   |
| **배포**     | Progressive disclosure. metadata만 preload                  | 머지 시   |
| **모니터링** | 활성화 빈도 추적. 실패/회귀 기록. 모델 업데이트 감시        | 상시      |
| **리뷰**     | 전체 통독. 모순/구식/boomer prompt 확인                     | 2-4주마다 |
| **업데이트** | 단일 변수 변경. A/B 가능 시 테스트                          | 필요 시   |
| **폐기**     | 아래 6가지 신호 기준                                        | 리뷰 시   |

### 6.2 폐기 신호 6가지 + 측정 방법

| #   | 신호                            | 자동화 수준     | 측정 방법                                               |
| --- | ------------------------------- | --------------- | ------------------------------------------------------- |
| 1   | 여러 리뷰 주기에서 활성화 안 됨 | **완전 자동화** | PreToolUse hook으로 스킬별 카운트 로깅                  |
| 2   | 스킬 없이도 정확히 처리         | **반자동화**    | Eval 데이터셋 + A/B (스킬 on/off). 테스트 케이스는 수동 |
| 3   | 다른 스킬/CLAUDE.md와 모순      | **자동화 가능** | LLM-as-judge로 스킬 쌍 교차 검사                        |
| 4   | 토큰 비용 > 개선 효과           | **완전 자동화** | wc 토큰수 + 활성화 빈도 → cost-per-activation           |
| 5   | 수정된 모델 약점의 우회책       | **자동화 곤란** | 모델 changelog + CIR 기록 대조                          |
| 6   | 존재 이유 불명                  | **반자동화**    | git blame + CIR/ADR 기록 존재 여부 확인                 |

### 6.3 Prompt Rot 예방

> Prompt rot: 누적된 instruction, 교정, 엣지 케이스 처리가 에이전트 정체성을 희석시킴.

**예방 수칙**:

- 2-4주마다 전체 스킬 파일 통독
- 제거해도 행동 변화 없는 instruction → 삭제
- 모순되는 instruction → 즉시 해결
- "Boomer prompts" 감지 (이전 모델 약점 우회책 → 현재 모델에서 불필요)

---

## 7. 자동화 파이프라인

### 7.1 실현 가능한 6단계 파이프라인

```
1. Capture  → Claude Code hooks로 에러/활성화 로깅
2. Cluster  → LLM으로 에러 패턴 군집화
3. Generate → SCOPE/SIMBA 스타일 자기 성찰로 후보 규칙 생성
4. Evaluate → 홀드아웃 실패 케이스로 후보 규칙 테스트
5. Review   → 사람이 승인/거부/수정
6. Deploy   → 승인된 규칙을 스킬 문서에 병합
```

### 7.2 "3-Strike Rule" 패턴

68개 문서화된 실패에서 도출된 실전 휴리스틱:

> "같은 실패 패턴이 3회 발생하면, hook을 만들어라."

각 문서화된 실패에 포함할 것:

- 무엇이 잘못되었는가
- 왜 Claude가 그렇게 했는가
- 무엇을 해야 했는가
- 어떤 자동 검사가 이제 이것을 잡는가

> **주의**: PostToolUse hook은 Claude에게 보이는 컨텍스트를 주입할 수 없음 (#18427, closed as "not planned").
> Exit code 2 + stderr로 피드백하면 Claude가 접근 방식을 조정하지만, 직접 컨텍스트 주입은 불가.
> 또한 Claude가 한 도구를 차단당하면 다른 도구로 우회 시도 (Edit 차단 → Bash sed 사용).
> → 다중 도구 매처에 걸쳐 defense-in-depth 필요.

### 7.3 즉시 구현 가능한 것

**PreToolUse Hook** (스킬 활성화 로깅):

- 모든 스킬 호출을 TSV로 로깅 (Thariq gist 기반)
- matcher: "Skill" → ~/.claude/skill-usage.log
- 주기적으로 집계하여 활성화 빈도 + 에러율 산출

**기존 도구 활용**:

- **Arize Phoenix**: Claude Code 전용 prompt-learning 구현체 존재
  (SWE-bench에서 실행 → 실패 수집 → 자동 규칙 생성)
- **Promptfoo**: YAML로 테스트 케이스 정의 → CI에서 스킬 품질 게이트
- **DeepEval**: ToolCorrectnessMetric으로 스킬 선택 정확도 측정

### 7.3 완전 자동화의 한계

**자동화 가능**: 로깅, 에러 군집화, 후보 규칙 생성, 규칙 평가
**사람 필요**: 실패의 정의 (메트릭/손실 함수), 규칙의 안전성/정확성 검증, 일반화 여부 판단

> "모든 자동 최적화 알고리즘은 사람이 초기 프롬프트와 가이던스를 제공해야 한다."
> — Cameron Wolfe, Automatic Prompt Optimization

---

## 8. 안티패턴 카탈로그

### 8.1 Description 안티패턴

| #   | 안티패턴                                    | 왜 해로운가                    | 대안                            |
| --- | ------------------------------------------- | ------------------------------ | ------------------------------- |
| D1  | 모호한 description ("Helps with documents") | 라우팅 불가. ~20% 활성화       | 구체적 트리거 문구 나열         |
| D2  | 워크플로 요약 description                   | Claude가 body를 읽지 않음      | 트리거 조건만 기술              |
| D3  | 수동형 문체 ("handles X tasks")             | 77% 활성화. undertrigger       | 지시형 ("Use when...") = 100%   |
| D4  | 부정 라우팅 누락                            | 유사 스킬 간 혼동              | "NOT for X, use Y instead" 추가 |
| D5  | Prettier가 description을 다중 행으로 감쌈   | **조용히 스킬 무시됨** (#9817) | description을 단일 행 유지      |

### 8.2 Body 안티패턴

| #   | 안티패턴                   | 왜 해로운가                           | 대안                       |
| --- | -------------------------- | ------------------------------------- | -------------------------- |
| B1  | 500줄 초과                 | instruction 준수율 전반 저하          | 분할 또는 references/ 활용 |
| B2  | "하지 마라" 지시 남용      | Pink Elephant — 오히려 유발           | 긍정형 전환                |
| B3  | CRITICAL/MUST/NEVER 강조   | Opus 4.5+에서 overtrigger             | 직접적이고 차분한 문체     |
| B4  | 중간부에 핵심 정보 매몰    | "Lost in the Middle" — 30%+ 리콜 저하 | 처음/끝에 핵심 배치        |
| B5  | Claude가 이미 아는 것 설명 | 토큰 낭비 + attention 희석            | 삭제                       |
| B6  | 깊은 참조 중첩 (A → B → C) | 로딩 체인 불안정                      | 1단계만                    |
| B7  | 여러 옵션 나열             | 선택 마비                             | 기본값 1개 + 탈출구        |
| B8  | 시간에 민감한 정보         | 구식화됨                              | 링크로 대체                |
| B9  | 불일치한 용어              | 혼동 유발                             | 하나로 통일                |

### 8.3 구조 안티패턴

| #   | 안티패턴                   | 왜 해로운가                           | 대안             |
| --- | -------------------------- | ------------------------------------- | ---------------- |
| S1  | 하나의 스킬에 3+ 관심사    | 과밀. instruction 간 간섭             | 분할             |
| S2  | Reference + Task 혼합      | 참조 로딩 시 불필요한 워크플로도 로딩 | 분리             |
| S3  | managing-\* 접두사 남용    | 8/22 스킬이 managing-. 구분력 저하    | 의미 기반 네이밍 |
| S4  | 중복 콘텐츠 (nrs 명령 3곳) | 불일치 위험 + 토큰 낭비               | 단일 소스 + 참조 |

### 8.4 프로세스 안티패턴

| #   | 안티패턴                    | 왜 해로운가                         | 대안               |
| --- | --------------------------- | ----------------------------------- | ------------------ |
| P1  | LLM으로 자동 생성한 스킬    | -3% 성능 (실증 연구)                | 사람이 작성        |
| P2  | 한 번 작성 후 방치          | Prompt rot                          | 2-4주 리뷰 주기    |
| P3  | 스킬 추가만 하고 삭제 안 함 | description 예산 초과 → 조용히 제외 | 폐기 신호 모니터링 |
| P4  | 10번 수정해도 안 고침       | 프롬프트가 아닌 아키텍처 문제       | 근본 원인 분석     |
| P5  | Eval 없이 배포              | 회귀 감지 불가                      | eval BEFORE 문서   |
| P6  | skill-creator eval을 서브에이전트에서 실행 | 중복 스킬 대량 생성 (세션 내 plugin 메모리 오염, v2.1.78) | 메인 대화에서만 실행 |

---

## 9. 레퍼런스

### 9.1 Anthropic 공식

| 레퍼런스                       | URL                                                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Skill authoring best practices | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices                              |
| Claude Code skills docs        | https://code.claude.com/docs/en/skills                                                                        |
| Claude Code best practices     | https://code.claude.com/docs/en/best-practices                                                                |
| Claude Code memory (CLAUDE.md) | https://code.claude.com/docs/en/memory                                                                        |
| Prompting best practices       | https://platform.claude.com/docs/en/docs/build-with-claude/prompt-engineering/claude-prompting-best-practices |
| Claude 4 best practices        | https://platform.claude.com/docs/en/docs/build-with-claude/prompt-engineering/claude-4-best-practices         |
| Effective context engineering  | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents                             |
| Writing effective tools        | https://www.anthropic.com/engineering/writing-tools-for-agents                                                |
| Building effective agents      | https://www.anthropic.com/research/building-effective-agents                                                  |
| Advanced tool use              | https://www.anthropic.com/engineering/advanced-tool-use                                                       |
| Agent Skills blog              | https://claude.com/blog/equipping-agents-for-the-real-world-with-agent-skills                                 |
| Complete guide to skills (PDF) | https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf                     |
| Skill-creator repo             | https://github.com/anthropics/skills                                                                          |
| Prompt engineering tutorial    | https://github.com/anthropics/prompt-eng-interactive-tutorial                                                 |
| Anthropic cookbook             | https://github.com/anthropics/anthropic-cookbook                                                              |

### 9.2 학술 논문 (핵심)

| 논문                             | 핵심 발견                            | URL              |
| -------------------------------- | ------------------------------------ | ---------------- |
| Underspecification in LLMs (CMU) | 41.1% 해소율, 버전간 20%+ 변동       | arXiv:2505.13360 |
| Lost in the Middle (Stanford)    | U자형 주의. 중간부 30%+ 저하         | arXiv:2307.03172 |
| How Many Instructions?           | 500개 시 68% 정확도. Primacy bias    | arXiv:2507.11538 |
| Tool Preferences Unreliable      | Assertive cues → 10x+ 사용 증가      | arXiv:2505.18135 |
| Same Task More Tokens            | 3,000 토큰부터 추론 성능 저하        | arXiv:2402.14848 |
| Prompt Sensitivity               | 45% accuracy 변동. Few-shot이 안정화 | arXiv:2406.12334 |
| Instruction Hierarchy (OpenAI)   | System > User > Third-party          | arXiv:2404.13208 |
| SCOPE (auto-evolve context)      | 14.23% → 38.64% 자동 개선            | arXiv:2512.15374 |
| Prompt Report (58 techniques)    | 프롬프트 기법 분류 체계              | arXiv:2406.06608 |
| PromptDebt                       | Instruction prompt가 기술부채 최다   | arXiv:2509.20497 |

### 9.3 커뮤니티 & 실전 가이드

| 레퍼런스                              | URL                                                                                                    |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Writing a good CLAUDE.md (HumanLayer) | https://www.humanlayer.dev/blog/writing-a-good-claude-md                                               |
| CLAUDE.md guide (Builder.io)          | https://www.builder.io/blog/claude-md-guide                                                            |
| obra/superpowers (skill framework)    | https://github.com/obra/superpowers                                                                    |
| 650-trial skill activation study      | https://medium.com/@ivan.seleznov1/why-claude-code-skills-dont-activate-and-how-to-fix-it-86f679409af1 |
| Skill activation fixes (Scott Spence) | https://scottspence.com/posts/how-to-make-claude-code-skills-activate-reliably                         |
| awesome-claude-skills                 | https://github.com/travisvn/awesome-claude-skills                                                      |
| agentlinter (CLAUDE.md scoring)       | https://github.com/seojoonkim/agentlinter                                                              |
| Arize Claude Code prompt-learning     | https://github.com/Arize-ai/prompt-learning/tree/main/coding_agent_rules_optimization/claude_code      |
| Prompt tuning playbook (Google)       | https://github.com/varungodbole/prompt-tuning-playbook                                                 |
| Google prompt engineering whitepaper  | https://archive.org/stream/whitepaper-prompt-engineering-v-4/                                          |

### 9.4 타사 프롬프트 가이드

| 레퍼런스                           | URL                                                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------------------------- |
| OpenAI prompt engineering          | https://platform.openai.com/docs/guides/prompt-engineering                                        |
| OpenAI optimize metadata           | https://developers.openai.com/apps-sdk/guides/optimize-metadata/                                  |
| OpenAI GPT-4.1 prompting guide     | https://cookbook.openai.com/examples/gpt4-1_prompting_guide                                       |
| Google Gemini prompting strategies | https://ai.google.dev/gemini-api/docs/prompting-strategies                                        |
| Google Vertex AI prompt design     | https://docs.cloud.google.com/vertex-ai/generative-ai/docs/learn/prompts/prompt-design-strategies |
| MCP tool best practices            | https://mcp-best-practice.github.io/mcp-best-practice/best-practice/                              |

### 9.5 자동화 & 관측성 도구

| 도구          | 용도                      | URL                                    |
| ------------- | ------------------------- | -------------------------------------- |
| Promptfoo     | Eval + CI/CD 게이트       | https://github.com/promptfoo/promptfoo |
| DeepEval      | ToolCorrectnessMetric     | https://deepeval.com                   |
| Arize Phoenix | 트레이싱 + eval           | https://github.com/Arize-ai/phoenix    |
| Langfuse      | 프롬프트 버전 관리        | https://langfuse.com                   |
| DSPy          | 자동 프롬프트 최적화      | https://dspy.ai                        |
| SCOPE         | 실행 트레이스 → 자동 규칙 | arXiv:2512.15374                       |
