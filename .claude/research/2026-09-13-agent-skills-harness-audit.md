# Agent Skills·하네스 전수 감사 — 2026-09-13

상태: 조사·설계 인터뷰와 합의한 첫 구현 묶음을 완료했다. 1–12절은 조사와 인터뷰 당시의 판단 기록이며, 13절은 승인된 범위, 14절은 실제 구현·검증·호스트 반영 결과다. 조사 당시 제안과 초기 수치를 현재 상태로 해석하지 않는다.

추가 조사: 사용자의 후속 요청으로 [Mac 세션 로그의 용어·암묵지 조사](2026-09-13-session-vocabulary-and-tacit-knowledge.md)를 수행했다. 질문·학습·자율성의 실제 선호와 퀴즈 실행 증거를 함께 읽어야 한다.

기준: `main`의 `f65d428550c495cd07101aca3d197ec338c06ec9`. 사용자가 요청한 GPT-6 Astra·Claude Fable 5.1 공식 문헌, 커뮤니티 1차 자료, 이 저장소의 스킬 본문과 CIR/ADR 이력, 관측 가능한 호출 기록을 대조했다. 이 보고서는 새 실행 지침이 아니다.

## 1. 결론

가장 먼저 재검토할 대상은 `finding-unknowns`와 그 방법론을 PR 생성·리뷰·머지에 연결하는 의무 절차다. 다음은 `run-da`의 일괄 검토 정책, 공유 PR 스킬의 고정 형식, 공급자 CLI 지식의 장기 복제다. 정리의 단위는 파일 수보다 불필요하게 유발되는 행동과 여러 파일에 걸친 계약이어야 한다.

다만 35개 스킬을 모두 읽은 결과, 대부분의 운영 스킬을 통째로 쓸모없다고 판정할 근거는 없었다. 호스트·경로·복구·배포·인증의 고유 지식은 최신 모델도 저절로 알 수 없다. 호출이 없는 복구 스킬과, 매번 호출되지만 절차만 늘리는 스킬은 다르게 평가해야 한다.

사용자가 지정한 [OpenAI의 9월 11일 Astra 글](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)이 이번 감사의 최우선 기준이다. 모델이 이미 수행하는 사고법을 재교육하기보다 짧은 설명, 좁은 적용 조건, 필요한 참조만 읽는 구조, 구체적인 완료 조건을 남기라는 방향이다. [Anthropic의 7월 24일 글](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models)도 최신 모델용 시스템 프롬프트를 80% 이상 줄인 사례를 보고한다. 이 수치는 이 저장소의 삭제 목표가 아니다.

아직 측정하지 않은 것은 **이 레포에서 스킬 제거 전후의 최신 모델 작업 성과**다. 아래 판정은 내용·의존성·과거 실패·사용 기록을 종합한 정리 우선순위이며, 성능 향상이 입증됐다는 뜻은 아니다.

## 2. 범위와 측정의 한계

### 저장소에서 관리하는 정본

| 범위 | 확인 결과 |
|---|---|
| 프로젝트 스킬 | `.claude/skills/`의 21개. `.agents/skills/`의 심링크는 중복 집계하지 않음 |
| 공유 스킬 | `modules/shared/programs/claude/files/skills/`의 14개 |
| Codex 공유 노출 | 14개 중 10개. [Nix 정책](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/codex/default.nix)이 정본 |
| Claude 공유 노출 | 14개. [Claude Nix 설정](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/default.nix)으로 관리 |
| 스킬 진입점 합계 | 35개, 4,162줄, 189,387자 |
| 참조 포함 Markdown | 126개, 945,863자. 디스크 총량이며 상시 프롬프트 크기가 아님 |
| 상시 지침 정본 | `CLAUDE.md`, `AGENTS.override.md`, 공유 `CLAUDE.md`: 합계 10,426자. 심링크 중복 제외 |

문자 수는 Unicode 문자 수다. 토큰 수나 UTF-8 바이트 수가 아니다. `run-da`는 참조 포함 16개 Markdown·204,792자이며, `using-codex-exec`·`using-claude-p`까지 합치면 스킬 Markdown 전체의 약 41%다. 모든 참조가 매번 읽힌다는 의미는 아니다.

사용자 홈의 외부 스킬, Codex 내장 스킬, 설치 플러그인까지 전부 이 레포의 관리 대상으로 포함하지 않았다. `grill-with-docs`와 그 구성 스킬은 외부 관리이며 이번 진행 방식의 참고 대상이다.

### 호출과 효과는 다르다

[기존 집계기](../../scripts/ai/skill-usage-report.sh)로 2026-07-11부터 조사일까지 Mac의 Claude 로그를 집계했다. [기록 훅](../../modules/shared/programs/claude/files/hooks/log-skill.sh)은 `Skill` 호출 전 이벤트를 기록하고 하위 에이전트 호출을 제외한다. 따라서 다음을 뜻하지 않는다.

- 이 레포만의 호출 수: 공유 스킬 수치에는 다른 프로젝트도 포함된다.
- 전체 런타임의 사용량: Codex, MiniPC, 본문을 직접 읽은 실행은 이 로그로 포괄하지 못한다.
- 성공 횟수: 호출 시도와 작업 완료·효용은 별개다.

`finding-unknowns`는 6회로, 전혀 쓰이지 않았다는 판정은 틀리다. 대화 기록에서는 분기된 세션의 중복을 제외한 6개 실제 호출 ID도 확인했다. 이 레포 외의 다른 프로젝트 작업도 포함한다. `run-da` 55회, `create-pr` 48회, `create-issue` 25회, `write-handoff` 18회, `finish-pr` 17회, `review-pr-feedback` 13회였다.

같은 기간 생성된 이 레포 PR 143개를 조회했을 때 방법론 marker를 포함한 본문은 8개였다. #1129, #1192, #1268, #1271, #1272, #1274, #1315는 머지됐고 #1305는 미머지 종료였다. 이것은 기록된 적용의 흔적이며, 퀴즈 통과나 결함 감소를 입증하지 않는다. 호출 로그와 PR은 측정 범위·단위가 달라 직접 전환율을 계산할 수 없다.

후속 세션 전수 스캔에서는 Claude와 Codex의 실제 퀴즈 출제·응답을 별도로 확인했다. 따라서 퀴즈의 실행 증거도 존재한다. 이 사실은 학습 효용이나 작업 품질 향상의 입증과 구별한다.

## 3. 최신 공식 문헌에서 실제로 말하는 것

### 최우선 문헌

| 자료 | 핵심 내용 | 이번 레포에서의 의미와 한계 |
|---|---|---|
| [OpenAI, Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra), 2026-09-11, Eric Provencher | 긴 description과 넓은 trigger, 상세 recipe, 매번 문서 전부 읽기, 과잉 테스트, 첫 구현 직후 승인 대기를 감사하라고 명시 | 스킬·AGENTS·작업 프롬프트를 함께 검토할 직접 근거. 필요한 제약이나 모든 스킬을 폐기하라는 뜻은 아님 |
| [Anthropic, The new rules of context engineering for Claude 5 generation models](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models), 2026-07-24, Thariq Shihipar | Opus 5·Fable 5용 시스템 프롬프트를 80% 넘게 줄이고 자체 coding eval에서 측정 가능한 손실이 없었다고 보고 | 일반 규칙을 판단으로, 상시 상세 설명을 선택적 참조로 전환. 검증·리뷰는 선택적 스킬로 남겼음. Fable 5.1의 모든 작업에 대한 80% 절감 실험은 아님 |
| [OpenAI, Using GPT-6 Astra](https://developers.openai.com/api/docs/guides/latest-model), 2026-09-13 열람 | 강한 지침 준수 때문에 충돌·모호한 스킬이 조기 중단을 유발할 수 있음. 허용된 준비를 끝낸 뒤 구체적 결과를 두고 승인받게 조정 | 오래된 과잉 행동 억제 규칙이 지금은 자율성을 해칠 수 있음. 과잉 테스트도 별도 감사 대상 |
| [Anthropic, Prompting Claude Fable 5.1](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1), 2026-09-13 열람 | 목표가 명확하면 상세 방법론 없이 긴 작업 수행 가능. 과거의 억제 지침·불필요한 설명·추가 작업을 재검토 | 중단을 막는 새 규칙을 계속 더하기 전에 기존 규칙을 제거할 후보를 찾을 근거 |
| [Anthropic, Prompting Claude Fable 5](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5), 2026-09-13 열람 | 이전 모델용 스킬이 과도하게 절차를 규정해 기본 전략보다 나빠질 수 있음 | 구체적 실패 경계와 고유 맥락을 남기고, 일반 사고 순서를 일괄 강제하는 부분을 비교할 근거 |

사용자가 첨부한 OpenAI 본문은 공식 문서 조회 결과와 함께 읽었다. [X 링크](https://x.com/OpenAIDevs/status/2098480213244117065?s=20)는 직접 열람에 실패했으므로 게시물 자체의 내용·날짜를 독립 확인했다고 주장하지 않는다. 기술적 근거는 연결된 공식 블로그다.

공식 명칭은 [GPT-6 Astra](https://openai.com/index/gpt-6-astra/)와 [Claude Fable 5.1](https://www.anthropic.com/claude-fable-and-mythos-5-1)이다. Astra의 [안전 개요](https://openai.com/index/safety-overview-gpt-6-astra/)는 2026-09-03 출시를 명시한다. Fable 5.1 발표는 September 2026 표기를 확인했으며 정확한 발표일은 이 조사에서 확정하지 않았다. 모델명 확인과 이 로컬 환경의 기능 활성화 여부는 별개다.

### 하네스를 전부 줄이면 되는가

[Anthropic의 장기 앱 하네스 사례](https://www.anthropic.com/engineering/harness-design-long-running-apps)(2026-03-24)는 전면 축소가 실패한 뒤 구성요소를 하나씩 제거하는 비교로 전환했다. 모델 개선으로 sprint 구획은 불필요해졌지만 계획·평가의 역할은 남았다. [OpenAI의 harness engineering 사례](https://openai.com/index/harness-engineering/)(2026-02-11)는 거대한 AGENTS.md를 약 100줄 안내와 버전 관리되는 상세 문서로 바꾸면서 도구·관측·불변식 검사를 유지했다. 100줄은 보편적 임계값이 아니다.

따라서 이 조사에서 채택할 원칙은 “짧을수록 무조건 좋다”가 아니라 **모델의 기본 능력과 겹치는 요구는 줄이고, 재발견하기 어려운 지식과 실제 결과 피드백은 유지한다**는 것이다.

### `finding-unknowns`의 원문을 공정하게 읽기

[A field guide to Claude Fable 5: Finding your unknowns](https://claude.com/blog/a-field-guide-to-claude-fable-finding-your-unknowns)(2026-07-06, Thariq Shihipar)는 blind spot 탐색, 인터뷰, 프로토타입, 임시 구현 노트, 설명과 퀴즈를 소개한다. 저자가 퀴즈를 완벽히 통과한 후 머지한다는 개인 습관도 실제로 있다. 퀴즈 게이트 개념 자체를 로컬에서 근거 없이 발명한 것은 아니다.

그러나 원문은 모든 PR 자동 적용, 매 단계 생략 사유 원장, 고정 owner header, PR marker, CIR 흡수·삭제 제약, 다른 스킬과의 전역 연결까지 요구하지 않는다. 개인 학습 방법을 이 레포의 실행 계약으로 확장한 것은 #1082의 별도 결정이다. 개인이 원하는 학습과 모델에게 자동으로 부과하는 절차의 가치를 구분해야 한다.

### 함께 검토한 공식 설계·평가 문헌

- [OpenAI Build skills](https://learn.chatgpt.com/docs/build-skills), 갱신형: 이름·설명은 발견 단계, 본문·참조는 선택 후 로딩. 현재 문서는 목록 예산과 description 축약·생략을 설명한다. `agents/openai.yaml`의 `policy.allow_implicit_invocation: false`도 문서화한다. 로컬 버전 지원은 구현 전에 별도 확인해야 한다.
- [OpenAI skills best practices](https://learn.chatgpt.com/guides/best-practices), 갱신형: 실제 반복 작업, 명확한 입출력, 작은 대표 사례에서 시작한다. 모든 예외를 선제적으로 넣지 않는다.
- [Anthropic Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices), 갱신형: 모델이 이미 똑똑하다고 가정하고 모르는 내용을 제공하며 작업 특성에 따라 자유도를 조절한다.
- [Anthropic Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), 2025-09-29: 필요한 최소의 충분한 맥락. 최신 세대에 관한 판단은 위 2026-07 글을 우선 참고한다.
- [Anthropic Equipping agents with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), 2025-10-16·2025-12-18 갱신: 조직 맥락·절차·실행 자산을 필요할 때 제공하고 실제 부족을 관찰해 개선한다.
- [Anthropic Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents), 2026-01-09: 실제 실패에서 작은 평가 세트를 만들고, 스킬 호출 순서보다 결과를 평가한다. 과잉 호출을 잡는 음성 사례도 필요하다.
- [Anthropic Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), 2025-11-26: 과거 Opus 4.5의 문맥 소실·성급한 완료를 보완한 배경. 당시 initializer·feature list를 최신 모델의 영구 의무로 옮길 근거는 아니다.

## 4. 커뮤니티·논문: 서로 다른 실험을 섞지 않기

| 1차 자료 | 관찰 | 적용 한계 |
|---|---|---|
| [ETH/LogicStar, Evaluating AGENTS.md v2](https://arxiv.org/html/2602.11988v2), 2026-06-23 | SWE-bench Lite 300문제·CTXbench 138문제. 무문서와 LLM/개발자 문서의 성공률 차이는 유의하지 않았고(p=.87/.37/.21), LLM 문서의 비용 증가는 유의. 개발자 문서는 생성 문서보다 유의하게 나았음(p=.038) | v1의 부정적 평균만 인용하면 과장. 길이 자체와 성능의 강한 관계도 찾지 못함. Python·이전 모델 중심 |
| [SkillsBench v4](https://arxiv.org/html/2602.12670v4), 2026-06-14 | 87과제·8영역·18 model–harness 구성에서 curated 스킬 33.9→50.5%, +16.6pp. 13과제는 악화 | 스킬 없이 풀리는 과제를 의도적으로 배제한 선택 편향. 개수·길이 비교도 서로 다른 과제군을 포함하므로 전역 “3개 제한”의 근거가 아님 |
| [How Well Do Agentic Skills Work in the Wild](https://arxiv.org/html/2604.04323v1), 2026-04-06 | 34,198개 라이브러리에서 검색과 적합성 판단을 요구하면 curated 스킬의 이득이 크게 감소 | 미사용은 불필요함뿐 아니라 발견 실패일 수 있음. 무관한 스킬과 넓은 trigger를 평가할 근거 |
| [Vercel, AGENTS.md outperforms skills](https://vercel.com/blog/agents-md-outperforms-skills-in-our-agent-evals), 2026-01-27 | Next.js 16 지식 평가: 기본 스킬 53%, 호출 지시 추가 79%, 상시 8KB 문서 색인 100% | 특정 신규 API의 검색 실험. 본문 전체 상시 삽입이나 범용 방법론의 무효를 증명하지 않음. 전체 재현 조건 공개에 한계 |
| [Lulla 외, repository instructions 연구 v2](https://arxiv.org/html/2601.20404v2), 2026-03-30 | GPT-5.2-Codex·124개 작은 PR에서 실행시간 중앙값 -28.64%, 출력 토큰 -16.58% | 기능적 동등성을 종합 검증하지 않아 비용 감소를 정답률 개선으로 읽으면 안 됨 |
| [LangChain, Improving Deep Agents](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering), 2026-02-17 | 같은 GPT-5.2-Codex에서 실제 실패 trace로 하네스를 고쳐 Terminal-Bench 52.8→66.5%. 무조건 높은 effort는 timeout 악화 | 같은 벤치마크 반복 최적화 사례. 각 구성요소의 독립 효과나 최신 모델에 대한 일반화는 아님 |
| [Mario Zechner, pi coding agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/), 2025-11-30 | 적은 기본 도구와 짧은 prompt, 필요한 문서만 읽기, 상태 관측을 지향. 과거 Opus 4.5 benchmark와 runner 공개 | 비교 제품의 모델도 달라 짧은 prompt 자체의 인과 실험은 아님. 프로젝트 지침·도구까지 없앤 설계도 아님 |
| [HumanLayer, Writing a good CLAUDE.md](https://www.humanlayer.dev/blog/writing-a-good-claude-md), 2025-11-25; [Advanced Context Engineering](https://www.humanlayer.dev/blog/advanced-context-engineering), 2025-08-29 | 상시 안내는 간결하게, 조사·계획은 필요한 작업에서 선택. 기계적 스타일 검사는 도구로 | 150–200개 지침·300줄 같은 수치는 최신 모델의 공식 한계가 아님. 실무 성공·실패 사례이지 보편적 고정 workflow 증거가 아님 |
| [Matt Pocock의 작은 스킬 조합](https://github.com/mattpocock/skills), [grill-with-docs 고정 revision](https://github.com/mattpocock/skills/blob/447ca70872026d5b79d6073a546dac082117fed7/skills/engineering/grill-with-docs/SKILL.md), 2026-08-15 | 7줄 조합 스킬도 사용자가 원하는 협업 방식을 고르는 단축 명령으로 가치가 있음 | 추론 능력 보충만이 스킬의 목적은 아님. 독립 benchmark는 없고, upstream Skill tool 호출 표현을 Codex API로 그대로 복사하면 안 됨 |
| [Agent Skills 사양](https://agentskills.io/specification), 2026-09-13 열람 | 메타데이터→본문→참조·자산의 단계별 로딩 | 권장 줄 수는 성능 최적점의 증명이 아님. 목록·본문·참조·실행 행동 비용을 나눠야 함 |

이 자료들은 “하네스 최소화”와 “좋은 하네스가 성능을 높임”이 함께 성립할 수 있음을 보여준다. 서로 다른 작업·모델·선택 조건의 숫자를 한 순위표로 합치지 않았다. 커뮤니티 자료는 널리 인용되는 원저자 자료를 선정했으며 인기도 자체를 계량 검증하지 않았다.

## 5. 이 레포의 CIR·ADR 이력

관련 PR 24개와 이슈 2개의 본문·결정 기록, 관련 Git 이력과 현행 소비처를 확인했다. 아래는 채택·철회·재도입 이유가 중요한 사건들이다. 모든 과거 PR·댓글·대화 전체를 감사했다는 뜻은 아니다.

| 시기 | 기록 | 결정과 이번 감사의 함의 |
|---|---|---|
| 2월 | [#44](https://github.com/greenheadHQ/nixos-config/pull/44) | `karpathy-guidelines`를 체감 품질 이득 없이 컨텍스트 잡음을 만든다고 판단해 제거. 최신 모델 이전에도 일반론 스킬을 정리한 선례 |
| 3월 | [#156](https://github.com/greenheadHQ/nixos-config/pull/156) | `documenting-intent` 도입. 코드·커밋·PR에 변경 이유를 남겨 의도 소실을 막는 것이 목적 |
| 3월 | [#267](https://github.com/greenheadHQ/nixos-config/pull/267) | 반복 수동 요청을 작은 prompt building block으로 스킬화. DA·질문·PR 재작성에 실제 반복 수요가 있었음 |
| 3월 | [#275](https://github.com/greenheadHQ/nixos-config/pull/275) | 긴 description·중복 라우팅을 줄이고 사용 기록 훅 도입. 발견 비용을 이미 문제로 인식 |
| 3월 | [#287](https://github.com/greenheadHQ/nixos-config/pull/287) | `configuring-claude-code` 제거. 자동 호출·평가 이득이 약했지만 비자명한 지식 3개는 CIR로 보존 |
| 3월 | [#309](https://github.com/greenheadHQ/nixos-config/pull/309) | Superpowers 설계 원칙을 참고해 라우팅·반합리화·절차 준수 규칙을 추가. 이후 제거 후보가 생긴 역사적 배경 |
| 3월 | [#359](https://github.com/greenheadHQ/nixos-config/pull/359) | 사용자가 호출하지 않고 기존 creator와 중복된 `maintaining-skills` 제거. 이번에도 새 거대 “스킬 관리 스킬”을 만들 이유가 약함 |
| 4월 | [#578](https://github.com/greenheadHQ/nixos-config/pull/578) | 3,717세션 중 1회 사용한 `documenting-intent` 제거. 한 줄 CIR와 PR 흐름은 유지. 기록의 목적과 전용 오케스트레이터를 분리한 선례 |
| 5월 | [#739](https://github.com/greenheadHQ/nixos-config/pull/739), [#732](https://github.com/greenheadHQ/nixos-config/issues/732) | bold 881개와 공백을 제거하고 noise 검사 도입. 토큰 경계와 한국어 오류의 관계는 가설이었고 구조 지표만 확인. 출력 품질 인과 검증은 없었음 |
| 5월 | [#812](https://github.com/greenheadHQ/nixos-config/pull/812), [#810](https://github.com/greenheadHQ/nixos-config/issues/810) | `plan-with-questions` 22파일·약 2,100줄 제거. 10회 넘는 루프, 재개/기준점 실패, 자체 규칙 충돌 뒤 작은 수동 조합·자동 연결 금지를 선택 |
| 6월 | [#921](https://github.com/greenheadHQ/nixos-config/pull/921) | `grill-me`의 Nix 내 복제 제거, 외부 원본으로 관리 전환. 공급자·외부 스킬을 로컬 포크해 계속 동기화하는 비용을 줄임 |
| 6월 | [#927](https://github.com/greenheadHQ/nixos-config/pull/927) | 의도적으로 삭제했던 것을 재도입하거나 가드를 근거 없이 없애는 decision regression을 감사. 과거 결정을 영원히 고정하는 뜻은 아니며, 바꿀 때 이유를 알아야 한다는 요구 |
| 7월 | [#1082](https://github.com/greenheadHQ/nixos-config/pull/1082) | `finding-unknowns` 도입. 구현 노트 소실·퀴즈 누락·방법론 미호출을 계기로 사용자가 풀코스 스킬, 노트의 PR CIR 흡수, 머지 전 퀴즈를 명시 선택 |
| 7월 | [#1087](https://github.com/greenheadHQ/nixos-config/pull/1087) | Codex도 동등한 지휘자로 노출. grilling/prototype이 없다는 초기 가정이 틀렸음을 확인. 당시 Codex의 질문 회피를 막기 위한 blocking 계약도 반영 |
| 7월 | [#1146](https://github.com/greenheadHQ/nixos-config/pull/1146) | 직접 호출 1회의 `codex-fan-out` 진입점과 낡은 Playwright 문서 복제를 제거하되 실행 도구는 유지. 사용자 선택은 장기간 canary보다 즉시 제거·Git 복구 가능성이었음 |
| 7월 | [#1183](https://github.com/greenheadHQ/nixos-config/pull/1183) → [#1193](https://github.com/greenheadHQ/nixos-config/pull/1193) | 강제 Claude–Codex 위임·scout 하네스를 다음 날 롤백. 낮은 조사 품질, 숨겨진 진행, 고정된 위임 구조가 문제. 구조 테스트 통과가 품질·지연·가시성을 보장하지 못함 |
| 8월 | [#1268](https://github.com/greenheadHQ/nixos-config/pull/1268) | `run-da`의 사용 0건 기능과 겹치는 표면 제거. 사용자 의도는 무작정 글자 수 맞추기가 아니었음 |
| 8월 | [#1271](https://github.com/greenheadHQ/nixos-config/pull/1271) | 실제 6–22라운드와 연쇄 수정 문제에 종료 계약·재계획 탈출을 수리. 독립 검토의 가치와 루프 비용을 함께 평가해야 함 |
| 8월 | [#1272](https://github.com/greenheadHQ/nixos-config/pull/1272), [#1274](https://github.com/greenheadHQ/nixos-config/pull/1274) | 기계 검증 계약, 실행 backend·effort 정책 정비. 텍스트가 크다는 이유로 실행 경계와 검증기까지 한꺼번에 지우면 다른 기능을 잃음 |
| 9월 | [#1281](https://github.com/greenheadHQ/nixos-config/pull/1281) | 폐기한 `syncing-codex-harness`를 외부 링크 404 방지용 짧은 stub으로 복구. 호출 0회가 의도된 호환성 문서 |
| 9월 | [#1311](https://github.com/greenheadHQ/nixos-config/pull/1311) → [#1312](https://github.com/greenheadHQ/nixos-config/pull/1312) | 이미 Astra 기준으로 description·진입점·반복 검증·확인 형식을 줄였음. 후속 리뷰에서 이동한 참조의 링크·실행 예제·보안 경계를 수리. 줄 수 감소만으로 성능 향상을 입증한 것은 아님 |

[plan-with-questions 폐기 메모](../../docs/archive/plan-with-questions-design-notes.md)는 통합 욕구, 단일 정본 강박, 회귀 방지 규칙의 누적이 절차 팽창을 만든 과정을 남긴다. [이전 통합 PRD](../../docs/archive/prds/prd-skill-router-consolidation.md)는 서로 대체된 결정까지 보존하고 있으므로 현재 규칙으로 읽으면 안 된다. [하네스 추출 검토](../../plans/018-findings-harness-extraction.md)도 전체 프레임워크 분리의 이득보다 결합 비용이 크다고 판단했다.

특히 #812의 작은 조합 선호와 #1082의 풀코스·퀴즈 선택 사이에는 긴장이 있다. 후자를 우발적 회귀라고 단정하면 당시의 명시 결정을 지워버린다. 지금 필요한 일은 **현재 사용자가 어떤 협업 방식을 원하는지 다시 결정하고, 달라진 이유를 짧게 남기는 것**이다.

## 6. 전체 35개 스킬 판정 초안

호출은 위 Mac Claude 표본이다. “0”은 삭제 근거가 아니라 조사 단서다. 줄 수는 `SKILL.md`만 센다. “유지”는 영구 존속 판정이 아니라 이번 감사에서 통째로 없앨 충분한 근거가 없다는 뜻이다.

### 공유 스킬 14개

| 스킬 | 줄 / 호출 | 제안 | 근거·보존할 가치 |
|---|---:|---|---|
| [finding-unknowns](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/finding-unknowns/SKILL.md) | 70 / 6 | 완전 퇴역으로 합의 | 넓은 trigger, 비적용 선언·스킵 사유, 원장, 자동 리뷰, 노트 수명, 퀴즈까지 연결. 질문·설명·변경 이유 기록의 목적은 따로 유지 |
| [run-da](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/run-da/SKILL.md) | 179 / 55 | 퇴역·내장 리뷰 전환, 조건부 이력 조회 지침 유지로 합의 | 독립 검토 수요가 자체 오케스트레이터의 필요성을 증명하지는 않음. 양쪽 제품의 내장 리뷰와 비교한 결과 및 남는 차이는 §12 |
| [create-pr](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/create-pr/SKILL.md) | 93 / 48 | 고정 형식·방법론 계약 축소로 합의 | PR 작성 단축 명령은 유지. 필요한 항목만 작성하고 7섹션·N/A 채우기 의무 해제. 정확한 대상·본문 전달·검증 근거는 유지 |
| [finish-pr](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/finish-pr/SKILL.md) | 110 / 17 | 머지 작업 유지, 방법론 퀴즈 게이트 제거로 합의 | 현재 head·CI·미해결 리뷰 확인과 작업 트리 보호는 실제 동작 경계. 학습 퀴즈는 사용자가 요청하는 별도 작업 |
| [review-pr-feedback](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/review-pr-feedback/SKILL.md) | 186 / 13 | 피드백 처리 유지, 반복 형식·CIR 연결 축소 | 타당성 판단·현재 변경 확인·답글·resolve는 반복 수요. 고정 기각 형식과 방법론 PR 동기화의 강제 범위 재검토 |
| [create-issue](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/create-issue/SKILL.md) | 116 / 25 | 짧은 진입점과 필요한 참조 유지 | 반복 발행·라벨·실패 후 재시도 지식에 가치. 보편적 이슈 작성법·모든 경우의 고정 양식은 줄일 후보 |
| [write-handoff](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/write-handoff/SKILL.md) | 54 / 18 | 유지, 필수 문서 형식만 비례 조정 | 재개 가능한 전달과 게시 전 정리에 수요. 모든 작업에 동일한 장문의 체크리스트를 적용할 필요는 별도 판단 |
| [using-codex-exec](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md) | 108 / 4 | 공급자 설명 복제 축소 | 로컬 supervised wrapper·종료·산출물·격리 계약은 유지. 일반 CLI 설명과 버전별 문서 사본은 공식 문서 연결로 대체 후보 |
| [using-claude-p](../../modules/shared/programs/claude/files/skills/using-claude-p/SKILL.md) | 237 / 4 | 공급자 설명 복제 축소 | 실제 headless 실패와 로컬 실행 경계는 가치. 큰 옵션·모델·제약 사본은 노후화 비용이 큼. adapter 소비처를 확인하며 분리 |
| [analyzing-da-sessions](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/analyzing-da-sessions/SKILL.md) | 106 / 0 | 분석기·DA 주간 보고와 함께 퇴역으로 합의 | 자동 분석 소비처를 확인한 후 사용자 선택. run-da 전용 지표의 정기 발행은 종료하되 기존 세션 로그·보고서는 보존 |
| [set-icons](../../modules/shared/programs/claude/files/skills/set-icons/SKILL.md) | 158 / 0 | 명시 명령·짧은 안내 또는 일반 문서로 격하 후보 | 수동 편의 기능 수요를 확인할 대상. 상태 표시·아이콘 실행 기능의 사용 여부는 Skill 호출만으로 판단 불가 |
| [syncing-codex-harness](../../modules/shared/programs/claude/files/skills/syncing-codex-harness/SKILL.md) | 16 / 0 | 외부 참조 해소 후 퇴역 후보 | 이미 폐기된 기능의 링크 호환 stub. Codex 미노출·Claude 자동 호출 차단. 0회는 정상이고 컨텍스트 절감도 작음 |
| [issuing-codex-pairing-code](../../modules/shared/programs/claude/files/skills/issuing-codex-pairing-code/SKILL.md) | 54 / 1 | 유지 | 명시적인 코드 발급 작업과 민감 정보 처리·실행 script를 묶음. 최신 내장 도구가 완전히 대체하는지 검증 전 제거 근거 부족 |
| [attaching-github-media](../../modules/shared/programs/claude/files/skills/attaching-github-media/SKILL.md) | 32 / 0 | 유지 | 짧고 구체적인 미디어 첨부 능력. 일반 추론으로 대체하는 스킬이 아니며 최근 추가된 진입점의 0회는 약한 증거 |

### 프로젝트 스킬 21개

| 스킬 | 줄 / 호출 | 제안 | 근거·보존할 가치 |
|---|---:|---|---|
| [configuring-codex](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/.claude/skills/configuring-codex/SKILL.md) | 237 / 1 | 축소 우선 | Nix 소유 경로·공유 노출·심링크 진단은 고유 지식. 일반 CLI 안내와 일괄 진단·버전 전제를 최신 문서와 분리 |
| [managing-secrets](../skills/managing-secrets/SKILL.md) | 172 / 3 | 진입점 축소 | 긴 인벤토리·절차를 필요한 참조로 분리. agenix·1Password·호스트별 소유와 권한 경계는 유지 |
| [managing-mise](../skills/managing-mise/SKILL.md) | 131 / 0 | 일반 설명·중복 규칙 축소 | shim·trust·프로젝트 설정의 실행성은 실제 로컬 제약. 기본 사용법을 장황하게 복제할 필요는 낮음 |
| [hosting-copyparty](../skills/hosting-copyparty/SKILL.md) | 236 / 1 | 긴 운영 설명의 조건부 로딩 | 서비스 경로·복구·인증은 유지하고 문제별 runbook으로 탐색 범위 축소 |
| [understanding-nix](../skills/understanding-nix/SKILL.md) | 113 / 0 | 일반 교재 부분을 문서로 이동 후보 | Nix 기초 개념은 모델·공식 문서와 중복. 이 레포의 cache·평가·빌드 제약은 남길 필요 |
| [automating-hammerspoon](../skills/automating-hammerspoon/SKILL.md) | 94 / 0 | 유지, 일반 recipe 축소 후보 | hotkey·Ghostty·launchd 연결은 로컬 지식. 일반 Lua 설명과 복제 예제만 별도 평가 |
| [configuring-git](../skills/configuring-git/SKILL.md) | 89 / 0 | 유지, 좁은 라우터 | Home Manager·delta·lazygit·rerere 소유 경로가 목적. 보편 Git 설명은 참조로 충분 |
| [managing-tmux](../skills/managing-tmux/SKILL.md) | 100 / 0 | 유지, 일반 recipe 축소 후보 | pane·알림·세션 복구의 로컬 연결을 보존. 일반 tmux 설명은 중복 후보 |
| [viewing-immich-photo](../skills/viewing-immich-photo/SKILL.md) | 146 / 0 | 짧은 명령·절차로 축소 후보 | 컨테이너→호스트 경로와 이미지 전달 방법은 고유 기능. 범용 설명을 덜어도 실질 능력은 남길 수 있음 |
| [hosting-anki](../skills/hosting-anki/SKILL.md) | 42 / 0 | 유지 | 짧은 진입점으로 실제 호스트·동기화·백업 문서에 연결. 희귀 호출만으로 제거할 근거 부족 |
| [hosting-karakeep](../skills/hosting-karakeep/SKILL.md) | 150 / 0 | 유지 | 실제 서비스 운영·복구·구성 연결. 설명 갱신은 필요하지만 모델 일반 지식과 동등하지 않음 |
| [managing-claude-rc](../skills/managing-claude-rc/SKILL.md) | 91 / 2 | 유지 | 원격 제어 프로세스·로그·재시작·실제 장애 경계. 최근 실제 수리 이력도 있음 |
| [managing-macos](../skills/managing-macos/SKILL.md) | 140 / 0 | 유지 | nix-darwin·Homebrew·macOS 설정 소유 경계. 필요한 작업별 참조를 선택하도록 유지 |
| [managing-minipc](../skills/managing-minipc/SKILL.md) | 156 / 0 | 유지 | 머신 배치·디스크·복구·롤백은 낮은 빈도여도 중요한 로컬 지식 |
| [managing-ssh](../skills/managing-ssh/SKILL.md) | 146 / 1 | 유지 | 실제 연결·인증·Tailscale·sudo 제약. 일반 SSH 사용법과 분리할 여지는 있음 |
| [configuring-neovim](../skills/configuring-neovim/SKILL.md) | 88 / 1 | 유지 | LazyVim·LSP·설정 소유와 필요한 문서로 가는 라우터. 최근 경량화가 반영됨 |
| [managing-vscode](../skills/managing-vscode/SKILL.md) | 67 / 0 | 유지 | 확장·설정·키바인딩의 레포 소유 경로와 참조. 이미 짧은 진입점 |
| [running-containers](../skills/running-containers/SKILL.md) | 161 / 0 | 유지 | Podman·홈서버 공통 인프라와 실제 서비스 제약. 모든 참조를 매번 읽게 할 필요는 없음 |
| [syncing-atuin](../skills/syncing-atuin/SKILL.md) | 88 / 0 | 유지 | 동기화 키 복구·한국어 정리 도구의 고유 절차 |
| [sharing-text](../skills/sharing-text/SKILL.md) | 112 / 1 | 유지 | Pushover 전달과 셸 인용·실행 환경의 구체 경계. 짧은 실행 인터페이스로 개선 가능 |
| [triage-issues](../skills/triage-issues/SKILL.md) | 84 / 3 | 유지 | 이 레포 백로그 우선순위·종료 판단이라는 명시 작업. 범용 추론 보정보다 사용자가 고르는 작업 단위 |

## 7. 우선순위별 구체적인 정리 후보

### P1. `finding-unknowns`는 연결된 계약까지 한 단위로 판단

현행 연결은 다음과 같다.

```text
finding-unknowns
  → 원장·계획·검토·implementation-notes.md
  → create-pr: owner 확인, CIR 흡수, methodology marker
  → review-pr-feedback: 방법론 PR의 CIR 동기화
  → finish-pr: 퀴즈, 오답 재출제, head·본문 변경 시 재시작
```

[진입점](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/finding-unknowns/SKILL.md), [전술·형식](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/finding-unknowns/references/tactics.md), [PR 흡수](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/create-pr/SKILL.md), [리뷰 동기화](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/review-pr-feedback/SKILL.md), [머지 게이트](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/finish-pr/SKILL.md)가 각각 내용을 소유한다.

제안은 질문·조사·설명의 목적을 남기면서 자동 풀코스와 기본 학습 게이트를 분리하는 것이다. 필요하면 사용자가 `grill-with-docs`, 연구, 설명·퀴즈를 직접 선택할 수 있다. 제거를 결정해도 진행 중인 노트·기존 marker PR을 어떻게 처리할지 먼저 정해야 한다. 파일 하나만 지우면 다른 스킬은 이전 규칙을 계속 실행한다.

### P2. `run-da`는 제품 내장 리뷰로 대체할 수 있는지 먼저 판단

후속 인터뷰에서 사용자는 강도 조정보다 `run-da` 자체를 유지할 필요가 있는지 문제를 제기했다. §12의 최신 제품 기능·로컬 설치 대조를 반영하여, 초기의 “유지하되 재설계” 제안을 **퇴역·내장 리뷰 전환**으로 갱신했다. 사용자는 퇴역과 §12.4의 조건부 이력 조회 지침 유지에 동의했다. 아직 구현하지 않는다.

독립 검토를 없애자는 결론은 아니다. 재검토할 것은 [하드닝 계약](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/run-da/references/hardening-contract.md)의 기본 강도 확정, 여러 검토자·Arbiter가 필요한 범위, 인용된 diff의 문구가 검토 강도에 미치는 영향, 반복 루프와 사용자 재질문의 비용이다. 사용자 명시 요청의 우선순위가 내부 정책보다 약해지는 결과도 피해야 한다.

반면 작성자와 독립된 검토, 하위 에이전트의 쓰기 금지, 변경된 head 재확인, 산출물 검증 등은 실제 오류 경계다. #1268–#1274의 구체적 실패를 읽고 부분별로 평가해야 한다. 단순히 “FULL 대신 LITE” 한 줄을 추가하면 기존 강제 규칙과 충돌하는 새 지침만 늘 수 있다.

### P3. PR·이슈·핸드오프의 결과와 양식을 분리

변경 이유, 검증 근거, 남은 제약은 필요하다. 모든 작은 변경에 같은 7개 섹션, ADR·CIR의 N/A, 고정 기각 양식, 별도 원장까지 필요하다는 것은 다른 주장이다. 외부 프로젝트에도 노출되는 공유 스킬에 이 레포의 문서 양식이 섞인 부분도 소유 위치를 재검토할 대상이다.

다만 공개 대상 확인, 민감 정보 정리, `--body-file` 전달, 실패 시 본문 보존, 현재 PR 상태 확인은 형식상의 군더더기가 아니라 동작·정보 경계다. 양식을 줄이며 이 경계까지 지우지 않는다.

### P4. 공급자 설명 사본과 관리용 검사 자체도 감사

- `using-codex-exec`·`using-claude-p`: 공급자 기본 사용법은 공식 문서 연결, 로컬 wrapper·실제 실패 조건은 로컬 참조로 나누는 후보다. 관련 실행 script를 없애는 결정과 구별한다.
- `analyzing-da-sessions`: 현재 본문은 Codex에 자동 호출 차단의 동등 기능이 없다고 설명한다. 최신 [공식 Build skills](https://learn.chatgpt.com/docs/build-skills)는 `allow_implicit_invocation: false`를 문서화한다. **문서의 전제가 낡았을 가능성은 확인했지만 로컬 지원·노출은 아직 검증하지 않았다.**
- [check-skill-noise.sh](../../scripts/ai/check-skill-noise.sh): bold·공백의 hard fail은 모델 품질 근거보다 스타일 정책에 가깝다. #739의 정량 근거는 구조 변화였으므로 이 검사가 현재 원하는 비용 대비 가치가 있는지도 정리 범위다.
- [verify-ai-compat.sh](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/scripts/ai/verify-ai-compat.sh): 양쪽 런타임의 실제 노출·경로를 확인하는 검사는 보존 가치가 있다. 삭제·격하를 결정하면 Nix 정책과 감사 목록을 함께 갱신한다.

### P5. 상시 지침은 줄 수보다 매 작업에 필요한 정보인지 보기

[CLAUDE.md](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/CLAUDE.md)는 82줄이지만 `wt ls`의 모든 필드 의미, cleanup 옵션의 세부 동작, 셸 변환 표, GNU/BSD의 특정 경계 사례까지 긴 문단으로 담고 있다. 고유한 사실이므로 없애기보다 작업별 참조로 옮길 후보다. 상시 진입점에는 현재 호스트·셸, `nrs` 사용, 위험한 정리 옵션, hook 경로 충돌 같은 핵심 주의와 관련 문서 링크를 남길 수 있다. GNU/BSD 충돌 사례를 같은 상시 문단에 계속 추가하라는 규칙도 문서가 자라는 경로다.

[AGENTS.override.md](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/AGENTS.override.md)의 상세 위임 분류·프로파일 설명 역시 실제 fan-out을 수행할 때 읽을 내용과 항상 필요한 메인 에이전트의 쓰기 경계를 구분할 여지가 있다. 반면 `CLAUDE.md`의 사용자 명시 지시 우선·동일 승인 재질문 방지, 공유 지침의 mise·trust 조건은 구체적인 운영 경계를 제공한다. 모든 작업 전에 저장소 전체를 읽으라는 포괄 규칙은 현행 정본에서 확인하지 못했다.

## 8. 문서로 무엇을 남길 것인가

이번에 요청한 `grill-with-docs`의 [domain-modeling 원본](https://github.com/mattpocock/skills/blob/321658273cb1d20b76026717d027d505790106d4/skills/engineering/domain-modeling/SKILL.md)은 `CONTEXT.md`를 **구현 지침 없는 순수 용어집**으로 정의한다. 조사 착수 당시 이 레포에는 root `CONTEXT.md`와 `docs/adr/`가 없었다. 첫 인터뷰 후 작성한 용어는 §11에 기록한다.

따라서 제안은 다음과 같다.

- 이 보고서: 조사 사실·출처·한계·제안. 운영 규칙으로 자동 승격하지 않는다.
- `CONTEXT.md`: 인터뷰에서 합의된 이 레포 고유 개념의 이름과 짧은 정의만 기록한다. 일반 용어 사전이나 하네스 설명서로 만들지 않는다. 후보는 공유/프로젝트 스킬의 경계, 정본과 노출, 이 레포가 구분하는 CIR·ADR 등이다.
- 기존 CIR: 변경 당시 왜 그렇게 했는지와 중요한 이탈 이유. 모든 중간 활동을 원장에 남기는 의무와 구별한다.
- 별도 ADR: 되돌리기 어렵고, 맥락 없이는 의아하며, 실제 대안 사이 trade-off가 있는 결정에만 고려한다. 가역적인 스킬 한 개 삭제마다 ADR을 만들 필요는 없다.
- 운영 runbook·참조: 호스트, 명령, 소유 경로, 복구와 검증 방법. `CONTEXT.md`로 옮기지 않는다.

새 CONTEXT가 기존 AGENTS와 스킬 규칙을 모두 복제하면 이번 목표를 거스른다. #578에서 없앤 `documenting-intent`를 다른 이름으로 다시 만드는 것도 피해야 한다. 인터뷰에서 용어가 확정될 때 기록하고, 정리 방향 합의 전에는 스킬 구현을 바꾸지 않는다.

## 9. 인터뷰 이후의 작업 초안과 검증

먼저 결정할 것은 “모델이 이미 잘하는 방법론”과 “사용자가 계속 원하는 협업 방식”의 경계다. 특히 학습 퀴즈를 기본 흐름으로 유지할지, 요청할 때 분리할지는 최신 모델의 지능만으로 답할 수 없다. 그 다음 자동 호출 범위, `run-da` 존폐와 대체 경로, 문서 형식, 잔여 호환성을 한 질문씩 결정한다.

합의 후에는 목적이 같은 작은 변경 묶음으로 진행하는 편이 적절하다.

1. `finding-unknowns` 및 PR/리뷰/머지 소비처를 함께 정리하고, 필요한 변경 이유 기록·사용자 요청형 인터뷰는 남긴다.
2. PR 형식과 공유 스킬의 레포별 관례를 정리한다. `run-da`의 정책 변경은 고유한 검토 수요가 있으므로 별도로 다룬다.
3. 공급자 문서 복제·수동 관리 진입점·스타일 검사를 정리한다.
4. 운영 스킬은 로컬 지식과 실제 실행 경계를 남기면서 반복 설명만 축소한다.

이를 위해 새 평가 플랫폼이나 장기간 canary를 기본 의무로 도입할 필요는 없다. 성능 개선을 주장할 부분만 대표 실제 과제의 제거 비교로 확인할 수 있다. 동일 모델·effort·도구·권한·시작 커밋에서 현재/제거/짧은 버전을 비교하고, 완료 결과·결함·불필요한 질문·사람의 개입·실행 비용을 본다. “스킬을 호출했음”이나 “문서를 만들었음”은 성공 기준으로 쓰지 않는다.

작은 PR, 큰 설계 변경, 낯선 API, 로컬 서비스 복구처럼 성격이 다른 사례가 적합하다. 효과를 수치로 주장하려면 반복성과 표본 한계를 공개해야 한다. 이 비교 실행은 아직 하지 않았다. 기존 `tests/run-eval-tests.sh`는 Nix 평가 검사이며 LLM 작업 성과 평가가 아니다.

노출 정책을 바꿀 때는 정본 디렉토리·양쪽 Nix 설정·검증 목록·소비처·잔여 링크를 함께 확인하고, 저장소 규칙에 따라 `nrs` 후 `verify-ai-compat.sh`로 실제 런타임을 확인해야 한다. 이번 조사에서는 이 배포 단계나 기능 변경을 수행하지 않았다.

## 10. 조사 산출물 검증

- 35개 진입점의 정본 목록과 본문을 확인했고, 위 판정 표에 35개 모두 포함했다.
- 관련 참조는 방법론 연결, 하드닝, 실행 계약, 운영 진입점과 이전 정리의 소비처를 중심으로 추적했다. 126개 Markdown의 모든 문장을 동일 깊이로 재감사한 것은 아니다.
- 사용량은 기존 읽기 전용 집계와 일부 실제 호출 대조이며 성공률 분석이 아니다. 최신 모델에서 비교 실험을 하지 않았다.
- 관련 Git·PR·CIR/ADR을 조회했고 새 브랜치, 커밋, push, PR, 외부 메시지, 호스트 설정 변경은 하지 않았다.
- 이 문서의 로컬 링크·35개 표 누락 여부·공백 diff를 검사했고 누락·깨진 로컬 링크·공백 오류는 없었다. 스킬 동작이 바뀌지 않은 조사 문서이므로 기능 테스트·`nrs`는 수행하지 않았다.

## 11. 인터뷰에서 확정된 원칙

2026-09-13, 첫 설계 질문에서 사용자는 **지식·명시 명령 중심**을 선택했다. 운영 지식과 사용자가 직접 선택하는 인터뷰·DA·PR 명령의 편의는 보존하고, 범용 방법론의 자동 연쇄와 기본 의무 절차를 정리한다. 고유 지식만 남기는 전면 축소나 현행 자동 연계를 유지하는 방향은 선택하지 않았다.

[CONTEXT.md](../../CONTEXT.md)에 운영 지식과 작업 명령의 정의를 기록했다. 개별 스킬의 퇴역·재설계 방식과 구현 범위는 후속 질문에서 결정한다. 스킬 구현과 노출 정책은 아직 변경하지 않았다.

두 번째 설계 질문에서 사용자는 **`finding-unknowns` 완전 퇴역**을 선택했다. 스킬과 전용 원장, create-pr의 방법론 흡수 계약, review-pr-feedback의 방법론 CIR 동기화, finish-pr의 머지 퀴즈 게이트를 함께 제거하는 방향이다. 짧은 명시 명령 형태로 이 스킬을 남기지는 않는다.

변경 이유 기록 자체와 사용자가 요청하는 인터뷰·설명·퀴즈는 유지한다. 기존 노트와 과거 PR의 기록을 일괄 삭제하거나 소급 수정하는 결정은 아니다. 실제 퇴역 시 정본·노출 목록·검증기·현재 소비처를 함께 처리하고 진행 중인 기록의 보존을 확인한다.

이어서 제시한 `run-da` 검토 강도 질문에는 선택이 제출되지 않았다. 사용자는 `code-review`와의 중복, Claude Code의 내장 리뷰 존재 여부를 먼저 조사하도록 방향을 바꿨다. 따라서 다음 결정은 **`run-da` 존폐와 대체 경로**다. 첫 원칙에서 DA 작업 명령의 편의를 보존한다는 답변을 특정 구현인 `run-da`의 존속 합의로 해석하지 않는다.

내장 리뷰 비교 후 사용자는 `run-da` 퇴역에 동의하면서 내장 리뷰가 회귀와 이전 의사결정을 고려하는지 확인을 요청했다. 추가 확인 후 **조건부 지침만 유지**를 선택했다. `run-da`를 퇴역하고 제품 내장 리뷰와 기존 회귀 테스트를 사용하며, 동작·정책·방어 로직을 제거하거나 약화할 때 관련 CIR·ADR·PR의 근거를 조회하는 두 문장을 공통 지침에 남긴다. 별도 이력 검토 단계·고정 reviewer·Arbiter는 유지하지 않는다. 과거 결정의 현재 유효성을 판단하고 의도적인 변경은 허용한다. [CONTEXT.md](../../CONTEXT.md)에는 의사결정 회귀의 정의를 추가했고, 작업 명령의 정의는 내장 명령도 포함하도록 명확히 했다.

사용자는 이어서 **외부 Matt Pocock `code-review`도 제거**를 선택했다. 이번 구현 범위에 해당 사용자 전역 스킬 설치와 Claude 연결의 정리를 포함한다. 다른 Matt Pocock 스킬·플러그인 전체를 제거하는 결정은 아니다. 내장 리뷰는 유지하며, 나머지 스킬·문서 정리는 후속 설계 항목이다.

문서 작성 방식은 **필요한 항목만 작성**으로 합의했다. `create-pr`·`create-issue`·`write-handoff`에서 고정된 섹션 수, 빈 항목의 N/A 채우기와 중복 설명을 기본 의무로 두지 않는다. 작은 변경은 문제·변경·검증을 간결하게 설명하고, 중요한 결정은 CIR·ADR과 대안·선택 이유를 충분히 남긴다. 핸드오프의 현재 상태·남은 일·제약·결정 근거 등 다음 작업을 재개하는 데 필요한 정보는 보존한다. 공개 대상·민감정보·실제 검증 근거·본문 전달과 실패 시 보존 같은 동작 경계는 문서 형식 축소와 구분한다. 외부 저장소에서는 해당 저장소의 문서 관례를 우선한다. 아직 스킬 구현은 바꾸지 않았다.

`run-da` 전용 분석·정기 보고는 **함께 퇴역**으로 합의했다. `analyzing-da-sessions`와 분석기, DA 주간 보고·리마인더의 예약 실행·자동 게시·알림을 정리한다. 기존 세션 로그·이미 작성한 보고서·발행 기록은 보존한다. 새로운 범용 통계 시스템으로 대체하지 않는다. `modules/nixos/configuration.nix`에서 `homeserver.daWeeklyReport.enable = true`, 추적 이슈 `1067`을 확인했고, 자동 작업이 스킬 내부 `scripts/analyze.py`를 직접 참조하는 것도 확인했다. 이 확인은 저장소 선언 기준이며, 실제 MiniPC 실행 상태와 예약 해제는 구현·배포 때 확인한다. 다른 작업도 사용하는 Pushover·GitHub 인증·SSH·subprocess 실행 도구는 독립 소비처를 확인해 보존한다.

## 12. `run-da`와 제품 내장 리뷰 비교

2026-09-13, 로컬 CLI·스킬 설치 출처·공식 문서·Anthropic 공식 플러그인 원문을 대조했다. 리뷰 실행, 플러그인 설치, 설정 변경은 하지 않았다.

### 12.1 같은 이름의 서로 다른 구현

| 대상 | 출처와 확인한 동작 | 이 환경의 상태 |
|------|--------------------|----------------|
| 사용자가 지정한 `code-review` | Matt Pocock 외부 스킬. Standards와 Spec 두 축을 독립 검토하고 병렬 보고 | 사용자 전역 skill lock의 `source=mattpocock/skills`, `skillPath=skills/engineering/code-review/SKILL.md`로 확인. Claude의 사용자 스킬 경로도 같은 디렉토리로 연결 |
| Codex `/review`, `codex review` | OpenAI 내장 리뷰. 미커밋 변경·기준 브랜치·특정 커밋·사용자 지정 지시를 지원 | 로컬 `codex-cli 0.154.0`의 `codex review --help` 확인. `--uncommitted`는 staged·unstaged·untracked를 포함 |
| Claude Code `/code-review`, `/review` | Anthropic 번들 스킬. 현재 diff나 지정 대상을 검토하고 `--fix`로 선택적 수정 | 로컬 Claude Code `2.1.270`. `/review`가 별칭이 된 버전은 `2.1.223`이며 공식 changelog와 일치 |
| Anthropic `code-review` 플러그인 | PR 검토용 별도 플러그인. 현재 명령 원문은 5개 Sonnet 검토자, finding별 Haiku 신뢰도 평가, PR 댓글 게시 절차 | marketplace 소스는 있으나 `claude plugin list`에 설치된 리뷰 플러그인은 없음. README의 4명 설명과 명령 원문의 5명이 다르므로 실행 원문을 기준으로 판독 |
| Anthropic managed Code Review / ultrareview | 원격 실행·계정 설정·과금 조건이 있는 별도 제품 경로 | 기본 로컬 리뷰를 대체하기 위해 활성화할 필요 없음. 이번 작업에서 사용하지 않음 |

Codex 근거: [공식 CLI 명령](https://learn.chatgpt.com/docs/developer-commands#codex-review), [리뷰 API의 대상·독립 실행 지원](https://learn.chatgpt.com/docs/app-server#review). CLI에서 `--uncommitted`·`--base`·`--commit`·custom prompt는 서로 배타적이므로 함께 붙인 명령을 제안하면 안 된다.

Claude 근거: [공식 명령 목록](https://code.claude.com/docs/en/commands), [로컬 리뷰](https://code.claude.com/docs/en/code-review#review-a-diff-locally), [공식 changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md). 로컬 리뷰는 별도 컨텍스트의 background subagent로 실행되고 결과가 대화로 돌아온다. `--comment`는 외부 게시를 선택하는 플래그다. `--fix`를 지정하지 않는 기본 리뷰와 수정 실행을 구분해야 한다. 관리형 PR 리뷰는 Team/Enterprise research preview이고 로컬 리뷰는 그 설정을 요구하지 않는다.

플러그인 근거: [Anthropic의 실제 명령 원문](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/code-review/commands/code-review.md). “공식 플러그인”을 “CLI에 번들된 리뷰”와 혼동하면 불필요하게 다른 다중 검토 절차를 추가하게 된다.

### 12.2 현재 동명 스킬이 Claude 내장 명령을 가리는 구성

로컬 `~/.claude/skills/code-review`는 `~/.agents/skills/code-review`로 연결된다. 공식 [동명 스킬 우선순위](https://code.claude.com/docs/en/skills#resolve-skills-that-share-a-name)에 따르면 사용자·프로젝트 스킬은 동명의 번들 명령을 대체하지만 번들 별칭은 대체하지 않는다. 따라서 확인한 설치 상태와 이 규칙을 적용하면 **`/code-review`는 Matt Pocock 스킬, `/review`는 Claude 내장 리뷰**로 해석된다.

사용자·프로젝트·로컬 설정에서 `disableBundledSkills`와 `skillOverrides`의 해당 설정은 발견하지 못했다. 실제 대화에서 두 명령을 실행해 분기 결과를 확인한 것은 아니므로, 위 판정은 파일 배치와 공식 로딩 규칙의 대조 결과다. 동명 충돌은 퇴역 작업의 런타임 검증 대상으로 기록한다.

Matt Pocock 스킬은 범용 리뷰의 자동 대체재로 삼기에도 확인할 차이가 있다. 이 레포에는 선행 조건인 `docs/agents/issue-tracker.md`가 없고, 절차의 `git diff <fixed-point>...HEAD`는 미커밋 변경을 포함하지 않는다. 기준점·spec가 없으면 사용자 질문을 요구하며, 고정된 Fowler smell 목록과 두 축 보고 형식을 갖는다. 두 축을 분리해 보고 싶은 명시적 수요에는 의미가 있지만, 자체 방법론 유지 비용을 줄이려는 이번 목적에서는 우선 기본값으로 삼을 이유가 약하다.

### 12.3 `run-da`에서 남는 차이와 처리 제안

| 현재 `run-da` 기능 | 퇴역 시 제안 | 동일성을 주장하지 않는 부분 |
|--------------------|--------------|-----------------------------|
| 코드 변경의 독립 검토 | 각 제품의 내장 리뷰를 기본 진입점으로 사용 | 같은 변경에 대한 결함 탐지율·오탐·비용 비교는 아직 하지 않음 |
| 계획·PRD 검토, 넓은 회귀 감사 | 필요할 때 목표·대상을 명시해 독립 검토 요청. 사용자 의사결정 인터뷰는 `grill-with-docs` | 코드 리뷰 명령 하나가 기존 계획·감사 모드를 전부 대체한다고 보지 않음 |
| 4개 기본 bundle, 별도 Arbiter, 반복 수렴 루프 | 기본 의무에서 제거하고 결과에 따라 필요한 후속 검증·수정을 요청 | 제품의 리뷰 결과는 기존 수렴 predicate 충족이나 Arbiter 판정을 의미하지 않음 |
| CIR·ADR·git history 조사 | 삭제·정책 변경의 이유를 확인할 때 관련 기록을 명시적으로 제공 | 제품이 이 레포의 의사결정 원장 체계를 자동 복원한다고 가정하지 않음 |
| 읽기 전용 검토자, 메인 에이전트 쓰기, `wt`·`nrs` 실행 경계 | 필요한 환경 고유 제약을 프로젝트 규칙·운영 참조로 옮김 | 기존 하드닝 문서 전체와 역할 상태 머신을 통째로 보존하는 제안은 아님 |
| PR 피드백 판정·수정·게시 | 기존 `review-pr-feedback`의 목적과 함께 별도 정리 | 새 리뷰 생성과 이미 받은 GitHub 피드백 처리는 다른 작업 |

현재 [for_pr](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/run-da/modes/for_pr.md)는 리뷰 전에 미추적 파일까지 없는 clean workspace를 요구하고, 수정 단계에서 커밋·최종 push 절차로 이어진다. 이는 기본적인 “작성 중 변경 검토”보다 큰 작업 계약이다. 내장 리뷰로 전환하면 이 계약을 기본 코드 리뷰마다 다시 구현할 필요가 없다.

퇴역 영향은 본체 디렉토리보다 넓다. [AGENTS.override.md](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/AGENTS.override.md), [configuring-codex](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/.claude/skills/configuring-codex/SKILL.md), [review-pr-feedback](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/review-pr-feedback/SKILL.md), [create-pr](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/create-pr/SKILL.md), [write-handoff](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/write-handoff/references/guide-template.md), [using-codex-exec](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md), [analyzing-da-sessions](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/analyzing-da-sessions/references/algorithm.md), 양쪽 Nix 노출과 [검증기](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/scripts/ai/verify-ai-compat.sh)가 참조한다. `analyzing-da-sessions`와 DA 전용 검사·fixture도 후속 퇴역 범위에 넣고, 범용 subprocess wrapper는 별도 소비처를 확인한다. 과거 CIR·PR·세션 로그는 역사 자료로 보존한다.

사용자는 **`run-da`와 외부 Matt Pocock `code-review`를 퇴역하고 제품 내장 리뷰를 우선**하는 방향에 동의했다. 같은 diff를 여러 리뷰 스킬에 기본적으로 연쇄 전달하지 않고, Standards/Spec 분리나 다른 모델의 교차 검토가 필요할 때만 별도로 요청한다. 제거할 외부 스킬은 `code-review` 하나이며 사용자 전역 설치와 Claude 연결도 정리 범위에 포함한다.

이는 리뷰 품질이 반드시 향상된다는 실험 결과가 아니라, 이미 공급되는 기능과 현재 유지 비용을 비교한 설계 제안이다. [Astra 가이드](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)의 과도한 레시피 재검토 원칙과 부합하지만, 그 글이 다중 검토나 모든 스킬의 무용함을 증명하는 것은 아니다. 검토 수요를 유지하면서 자체 오케스트레이터를 없애는 선택이 가능하다는 것이 이번 비교의 결론이다.

### 12.4 회귀와 과거 의사결정 보호

사용자의 우려를 확인하기 위해 로컬 Codex 0.154.0 실행 파일에 포함된 리뷰 지침도 직접 읽었다. 기본 지침은 변경으로 도입된 결함, 실제 영향을 받는 다른 코드, 정확성·성능·보안·유지보수 영향을 검토한다. 명시되지 않은 의도를 추정하지 말고 의도적 변경을 결함으로 오인하지 않도록 하며, 적용되는 `AGENTS.override.md`·`AGENTS.md`와 프로젝트 규칙을 읽고 관련 근거를 인용하도록 한다. 즉 일반적인 회귀가 내장 리뷰의 범위 밖인 것은 아니다. [OpenAI 공식 가이드](https://learn.chatgpt.com/guides/best-practices#improve-reliability-with-testing-and-review)도 회귀 검토와 `AGENTS.md`를 통한 프로젝트 리뷰 지침 연결을 안내한다.

그러나 이 사실은 과거 PR·CIR·ADR과 사용자 대화를 자동으로 빠짐없이 복원한다는 보장이 아니다. 특히 “동작은 바뀌지만 왜 그 동작을 유지해야 하는가”가 코드 밖에만 있는 경우, 맥락이 전달되지 않으면 누락할 수 있다. Claude의 로컬 리뷰 역시 `CLAUDE.md`는 따르지만 관리형 리뷰용 `REVIEW.md`는 읽지 않는다고 [명시](https://code.claude.com/docs/en/code-review#what-the-review-reads-and-edits)한다. 두 제품에 공통으로 전달할 내용은 현재 공통 프로젝트 지침과 코드 가까운 근거에 둬야 한다.

이번 레포의 실제 예는 [실행 파일 동일성 판정](../../modules/nixos/scripts/claude-rc-lib.sh)이다. 경로 문자열이 달라도 같은 inode일 수 있다는 주석과 [hardlink alias 회귀 테스트](../../tests/suites/claude-remote-control-maint.sh)가 이미 존재한다. 이런 근거는 리뷰어가 현재 코드에서 발견하기 쉽다. 반대로 도입 PR에만 있는 사유는 관련 PR을 연결해야 한다. 반복 방지 가능한 동작은 기존 회귀 테스트가 담당하고, 결정 당시의 제약과 기각 이유는 CIR·ADR·가까운 주석이 담당하는 구성이 적절하다.

사용자가 유지하기로 선택한 공통 지침은 다음 두 문장이다. 아직 실제 지침에는 반영하지 않았다.

> 기존 동작·정책·방어 로직을 제거하거나 약화하는 변경은 관련 코드·회귀 테스트·도입 및 후속 변경의 CIR/ADR·PR을 확인해 현재도 유효한 제약을 보존한다. 의도적으로 결정을 바꾸면 그 근거를 남기고, 과거 결정과 다르다는 이유만으로 회귀로 판정하지 않는다.

이 규칙은 관련 변경에서 필요한 근거를 찾는 조건부 지침이다. 고정 검토자·Arbiter·전체 세션 로그 조사·별도 원장·반복 수렴 절차는 요구하지 않는다. 기존 [의사결정 회귀 조사 문서](https://github.com/greenheadHQ/nixos-config/blob/f65d428550c495cd07101aca3d197ec338c06ec9/modules/shared/programs/claude/files/skills/run-da/references/decision-regression-audit.md)의 가치 있는 목적을 남기면서 그 구현 절차를 퇴역하는 제안이다. 실제 전환을 검증할 때는 해당 지침과 근거가 내장 리뷰에 전달되는지를 확인해야 하며, 지침 두 문장만으로 모든 누락이 사라진다고 주장하지 않는다.

## 13. 합의된 핵심 정리의 구현 계획

이 절은 사용자가 구현을 승인한 첫 변경 묶음이다. §11의 선택을 적용한다. 조사 단계의 기록은 당시 상태를 설명하며, 실제 반영 결과는 §14에 구분해 기록한다.

### 변경 범위

1. `finding-unknowns`·`run-da`·`analyzing-da-sessions`의 정본과 양쪽 Nix 노출을 제거한다. PR 생성·피드백 처리·머지·핸드오프에 남은 자동 연계와 퇴역 전용 검증도 함께 정리한다. 실제 동작과 무관한 과거 보고서는 소급 수정하거나 삭제하지 않는다.
2. 사용자 전역 Matt Pocock `code-review`의 설치 등록과 해당 스킬, Claude 연결을 정리한다. 같은 패키지의 다른 스킬과 제품 내장 리뷰는 유지한다. 로컬 수정이 있는지 제거 전에 확인해 필요한 내용은 보존한다.
3. DA 주간 보고·리마인더의 Nix 옵션·모듈·설정·전용 실행 파일과 검사를 정리한다. MiniPC의 신규 예약 실행·자동 게시·알림이 해제되는지 확인하며, 기존 로그·보고서·발행 기록을 보존한다. 다른 서비스의 공용 전송·인증·SSH·실행 도구는 유지한다.
4. `create-pr`·`create-issue`·`write-handoff`의 고정 양식을 조건부 작성 가이드로 바꾼다. `review-pr-feedback`·`finish-pr`의 연결 규칙도 새 방식에 맞춘다. 변경 이유·관련 결정·실제 검증 근거·재개에 필요한 맥락·게시 대상 확인은 보존한다.
5. 두 제품이 읽는 공통 프로젝트 지침에 §12.4의 조건부 이력 조회 두 문장을 둔다. `run-da` 안에 묶여 있던 유효한 환경 고유 실행 경계는 적절한 프로젝트 문서에 남긴다. `CONTEXT.md`에는 합의한 용어의 정의만 둔다.

### 검증과 완료 조건

- 퇴역 체크리스트에 따라 정본·Nix 선언·노출 목록·모든 활성 소비처·테스트·hook을 대조한다. 과거 조사 자료의 링크는 필요하면 기준 커밋의 불변 링크로 바꿔 역사 근거를 보존한다.
- 삭제한 기능만 검사하던 테스트는 함께 퇴역하고, `tests/test-skill-doc-sync.sh`도 확인 결과 범용 문서 검사가 아니라 DA 전용 계약 검사이므로 함께 퇴역한다. 남는 기능은 통합 회귀 테스트와 변경 문서의 링크 검사로 확인한다. Nix 모듈 변경에 맞는 평가와 관련 shell/Python 검사를 실행한다. 이번에 조사만 했던 단계의 통과 결과로 기능 검증을 대신하지 않는다.
- 노출 정책 변경 후 `nrs`와 `scripts/ai/verify-ai-compat.sh`로 실제 설치 경로·잔재·내장 명령 충돌 해소를 확인한다. MiniPC 서비스 변경도 실제 호스트의 적용 상태와 타이머 해제를 확인한다. 저장소 변경과 운영 반영을 구분해 보고한다.
- 최종 변경을 제품 내장 리뷰로 검토한다. 프로젝트 지침과 관련 회귀 근거가 전달되는지 확인하고, 발견된 실제 결함을 수정한 뒤 영향을 받는 검사를 재실행한다. 내장 리뷰에 지적이 없었다는 사실을 완전한 품질 보장으로 해석하지 않는다.
- 기존 사용자 변경·세션 로그·기존 보고서를 보존하고, 변경 내용·검증 결과·미확인 범위를 검토 가능한 diff와 함께 제시한다. 커밋·push·PR 게시 상태는 실제 수행 여부를 구분한다.

운영 스킬의 긴 진입점, 공급자 CLI 문서 사본, 문서 스타일 검사와 호환 stub은 전체 감사의 후속 정리 대상이다. 핵심 퇴역과 섞어 무조건 삭제하지 않고, 실제 남은 소비처와 고유 지식을 확인한 결과로 다음 변경 묶음을 정한다.

## 14. 구현과 운영 반영

사용자의 구현 승인에 따라 `feat/retire-agent-methodologies`에서 첫 변경 묶음을 구현했다. 아래 상태는 조사 당시 서술과 구분한다.

### 구현한 범위

- 세 shared skill 정본과 DA 주간 보고·리마인더를 퇴역했다. 양쪽 Nix 노출, 독립 검증 목록, 활성 소비처, 전용 검사와 hook을 함께 정리했다. 퇴역 전용 파일 60개를 제거했으며, Git 이력과 과거 조사 자료는 보존한다.
- `skill-doc-sync`는 범용 링크 검사가 아니라 DA 문서·프로토콜 계약 검사였고, `fleiss-kappa.py`는 집계 도구가 아니라 DA verdict 검증기였다. 독립 소비처가 없어 전용 테스트와 함께 제거했다. 공용 실행 wrapper, GitHub 인증, Pushover·SSH, 스킬 사용 로그와 집계기는 유지한다.
- PR·이슈·핸드오프는 필요한 항목만 작성한다. 별도 원장 흡수·marker·머지 퀴즈와 고정 기각 양식을 제거했다. 다섯 작성·피드백·머지 문서군은 2,331줄에서 1,374줄로 줄었다. 정확한 게시 대상, 민감정보 처리, 파일을 통한 본문 전송과 실패 시 보존, 현재 head 확인은 유지한다.
- 공통 프로젝트 `CLAUDE.md`에 조건부 이력 조회 두 문장을 기록했다. Codex의 위임 권한·동시 실행 상한·단일 작성자 경계는 프로젝트 지침에 남겼다. `CONTEXT.md`는 용어집으로만 유지하고 README에 연결했다.
- 외부 Matt Pocock `code-review`는 Mac과 MiniPC 모두에서 해당 디렉터리·Claude symlink·lock entry만 제거했다. 각각 `~/.local/state/nixos-config/harness-retirement/` 아래에 원본과 설치 기록을 보존했다. 다른 외부 스킬의 lock entry는 Mac 25개, MiniPC 22개를 유지한다.

### 검증 기록

- 변경 문서 상대 링크 검사, shared/project 스킬 noise 검사, 저장소 기준 `shellcheck -S warning`, `git diff --check`, 임시 인덱스를 사용한 Lefthook 설정 계약 검사를 통과했다.
- Codex 0.154.0 내장 `codex review --uncommitted`를 읽기 전용으로 실행했다. 프로젝트 두 지침 파일과 합의 문서를 읽었으며, 수정이 필요한 결함을 보고하지 않았다. 이 결과는 전체 검증이나 배포 성공을 대신하지 않는다.
- 첫 Mac 통합 실행의 개별 검사들은 통과했지만, 실행 도중 러너 주석을 편집해 셸의 파일 읽기 위치가 어긋나는 오류가 발생했다. 그 실행을 최종 통과 근거로 사용하지 않고, 파일을 고정한 상태에서 다시 실행했다.
- 고정된 파일로 실행한 최종 통합 검사는 Mac·MiniPC 모두 11개 driver 통과, SKIP 0, 실패 0이었다. 셸 회귀는 Mac 362개, MiniPC 391개가 통과했다. Mac의 Linux 전용 fixture는 N/A이며 MiniPC 실행으로 해당 플랫폼을 검증했다. 모델을 실제 호출하는 선택적 live hook probe는 이 통합 검사의 범위 밖이다.
- Mac·MiniPC 모두 `nrs` 후 즉시 `verify-ai-compat.sh`를 실행해 exit 0을 확인했다. 양쪽의 경고 한 개는 이번 `.claude/skills` 변경이 아직 미커밋이라는 안내다. 퇴역 스킬·helper의 런타임 잔재는 없다. 외부 `code-review`의 설치 경로와 lock entry도 제거된 상태다. 내장 리뷰 명령 자체의 설치는 유지한다.

### 운영 상태와 보존

MiniPC 원래 checkout은 `5dcc5443`, Mac은 `f65d4285`였다. 각 호스트의 기존 기준 커밋 위에 이번 변경만 적용했으며 원격의 다른 변경을 덮거나 기본 브랜치를 최신화하지 않았다. 이 구현·배포 검증 시점에는 커밋·push·PR 게시를 수행하지 않았다. 두 기준 커밋 간 `modules/nixos/configuration.nix`의 Anki lab 주석 차이는 이번 변경과 무관하므로 그대로 남아 있다.

MiniPC의 기존 DA state 55개 파일(120,277,930 bytes)은 적용 전 SHA-256 목록을 로컬 state에 기록했다. 활성화 후 55개 모두 해시가 같고 누락·변경·추가가 없음을 확인했다. `da-weekly-report`·`da-weekly-reminder`의 timer/service 네 unit은 모두 `LoadState=not-found`, `ActiveState=inactive`다. Mac의 예약 작업·launchd·전역 설정 21개를 점검해 추가 예약 호출은 발견하지 못했다. 전역 Codex config에 남은 세 문자열은 과거 worktree의 trust 기록이므로 보존한다.

최종 결과: 합의한 첫 구현 묶음의 소스 변경, 양쪽 호스트 적용, 내장 리뷰와 관련 검증을 완료했다. 운영 스킬 21개 일반 경량화, 공급자 CLI 문서 사본 축소, 스타일 검사 개편과 호환 stub 전체 퇴역은 §13의 후속 범위로 남긴다.
