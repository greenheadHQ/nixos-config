# GUIDE — 다음 세션 LLM에게 보내는 메모

이 문서는 anki-study 프로젝트의 dogfooding 루프에서 가장 중요한 산출물이다.
학습 세션을 시작할 때 사용자가 이 문서를 LLM에게 입력으로 제공한다.
"이전 세션의 자신"이 보내는 누적 학습 메모로 받아들여라.

## 0. 이 프로젝트의 1순위 가치 (절대 위반 금지)

> **closed-loop dogfooding** — 매 학습 세션이 곧 시스템 입력이 되는 피드백 루프.
> 학습이 시스템을 개선하고, 개선된 시스템이 다음 학습을 도움.

선행 프로젝트(awesome-anki 1.0)는 시스템 기능 개발에만 열중하다가 **실제 학습 0회**로 끝났다.
이 함정을 회피하는 self-check:

- "이 결정이 학습을 *지금* 할 수 있게 만드는가, 아니면 *나중에* 더 좋은 학습을 위해 미루게 하는가?"
- "준비 부담 0 = LLM에게 부탁만 하면 됨"이라는 핵심 가치를 깨는가?
- "처음부터 너무 많이 결정"하고 있지 않은가?

## 1. 사용자 명시 — 좋았던 점 (강화 신호)

이전 세션들에서 사용자가 직접 "좋았다"고 말한 패턴들. 다음 세션에서 *같이 살려라*.

- **실제로 코드를 작성할 수 있는 문제가 있었음** — 단순 선택지가 아니라 입력 필드에 코드/명령/SQL 등을 직접 작성하게 하는 문제. 회상 깊이가 다름.
- **LLM이 YAGNI한 부분을 알아서 필터링해줌** — 책 카드의 모든 문장을 학습 대상에 포함시키지 않고, 면접/실무 가치 낮은 메타 진술/지엽적 부분은 명시적으로 "🚫 YAGNI 제외" 박스로 분리. (예: TCP/IP 카드의 "두 모델 비교 어렵다" 메타 진술)

## 2. 사용자 명시 — 안 좋았던 점 + AI 자체 평가 (회피 신호)

이전 세션들에서 사용자가 직접 "별로"라고 말한 패턴들. 다음 세션에서 *반복하지 마라*.

- **LLM이 노트 내용만 그대로 믿고 팩트 체크 안 함** — 책의 표현이 틀렸거나 단순화된 경우(예: TCP/IP "네트워크 액세스 ↔ OSI 데이터링크" 1:1 매핑은 부정확, OSI L1+L2 둘 다 포함)에도 그대로 가르치는 문제.
- **모든 문제가 단순 선택 문제** — 빈칸 채우기·매칭·OX만 반복되면 단조로워서 학습 의욕 ↓.
- **시각 자료 부족** — Anki 노트의 원본 이미지를 추출했지만 실제 페이지에서 활용하지 않거나, 다이어그램을 텍스트 표만으로 설명하는 경우 이해 어려움.
- **(AI 자체 평가) 팩트체크/YAGNI 보강 일관성 결함** — 같은 세션 안에서도 어떤 카드는 정정/보충 박스를 풍부하게 추가하고 다른 카드는 책 내용 거의 그대로. 사용자 명시 요구 *전*이라도 모든 카드에 일관된 깊이로 적용해야 함.

## 3. 이번 세션부터 적용할 LLM 학습 페이지 작성 원칙

다음 세 단계는 **모든 카드에 일관되게** 적용한다. *"이 카드는 단순하니까 생략"*은 금지.

### 3-1. 팩트체크 의무 (Stage 5 정답 단계 박스로 명시)

각 노트의 핵심 주장을 외부 신뢰 자료(공식 docs / RFC / 표준 / repo 소스)와 대조하여:

- **틀린 주장**: `⚠️ 책 표현 정정` 박스로 명시. 책 표현 + 정확한 표현 + 출처.
- **단순화/빠진 부분**: `🔍 깊이 보충` 박스로 보강. 현실의 더 정확한 메커니즘.
- **부정확한 1:N 매핑이나 단순 비교**: 표로 차이를 분리하여 보여줌.

이전 세션 적용 예 (참고):
- 시스템 콜 카드 — "x86_64는 `int 0x80` 인터럽트가 아니라 dedicated `syscall` 명령" 정정
- 시스템 콜 카드 — "슈퍼바이저 플래그"는 일부 아키텍처 표현, x86은 CPL(CS 레지스터)
- TCP/IP 카드 — "네트워크 액세스 ↔ 데이터링크" 1:1 매핑은 부정확, RFC 1122 명시상 OSI L1+L2 모두

### 3-2. YAGNI 필터링 (Stage 5 정답 단계 박스로 명시)

책의 모든 문장이 학습 가치 있지 않다. 다음을 `🚫 YAGNI` 박스로 학습에서 *제외*:

- 메타 진술 ("이 두 모델은 직접 비교가 어렵다" 등)
- 학술적 분류만 있고 면접/실무 가치 낮은 부분
- 옛 프로토콜·옛 표준·역사적 기록 (특별히 컨텍스트 필요한 경우만 보존)

이전 세션 적용 예: TCP/IP 카드의 "두 모델 직접 비교 어렵다" 메타 진술, "확장 5계층 모델 견해", ASN.1/RPC 등.

### 3-3. 다양한 문제 유형 (Stage 1-3 입력 컴포넌트)

빈칸 채우기 / 매칭 / OX 같은 단순 선택지만 쓰지 않는다. 매 세션에서 *최소 1개*는 다음 중 하나 포함:

- **자유 서술** — "왜 그런가?", "이게 없으면 어떻게 되는가?"
- **코드/명령 작성** — SQL, shell 명령, 구조체 정의 등 실제 작성
- **Q&A 응용** — 책에 직접 안 나온 응용 질문 (예: "멀티코어에서 TLB는 어떻게 처리?")
- **realworld 분석** — 사용자의 실제 환경(예: 지금 보는 페이지의 동작 프로토콜)을 카드 개념으로 설명

이전 세션 적용 예:
- 시스템 콜 카드 보너스 Q: "이중 모드가 없다면 어떤 시나리오가?"
- TCP/IP 카드 보너스 Q: "이 페이지 보는 동안 동작 중인 4계층 프로토콜은?"

### 3-4. 시각 자료 적극 활용 (Stage 5 정답 단계 + 가능하면 Stage 1-3 도)

Anki 노트의 원본 이미지가 있으면 retrieveMediaFile로 추출 → 학습 페이지에 임베딩.
이미지 없는 카드라도 다이어그램(테이블/ASCII art/SVG inline)을 만들어 시각화.

이전 세션 적용 예:
- 교착 카드 — 책의 원형 대기 그림 그대로 사용
- 시스템 콜 카드 — 4단계 흐름도 + 사용자/커널 모드 오감 그림
- TCP/IP 카드 — 7-pass-요약 ASCII 표

### 3-5. 깊이 보충 (실무/면접 차원, Stage 5)

책 내용을 넘어 *실제 동작 메커니즘*이나 *현대 기술*을 `🔍 깊이 보충` 박스로 추가:

이전 세션 적용 예:
- TLB 카드 — ASID/PCID, Huge Pages, TLB shootdown
- 시스템 콜 카드 — vDSO, io_uring, KPTI/SMEP/SMAP
- NIC 카드 — TSO/RSS, DMA ring buffer, Tailscale tun0 (사용자 환경)

### 3-6. 검증된 흔한 코드 버그 — 같은 실수 반복 금지

이전 세션의 학습 페이지 코드에서 실제로 발견되어 PR 리뷰로 잡힌 버그들. 다음 세션에서 새 HTML을 만들 때 *시작부터* 바르게 작성한다.

#### 버그 #1: Stage 4 selfScore 누락 (5개 카드 모두 동일 패턴, PR #712 CodeRabbit 리뷰에서 5건 발견)

**증상**: 자체 점수(`selfScore`)가 마지막 stage(`submit` 누른 시점의 stage)의 자유 서술/입력 답안을 *반영하지 않고* 제출됨. 사용자 입장에서 "내가 답을 다 채웠는데 점수가 안 올랐다"는 혼란.

**원인**: scoring 로직이 `nextStage(n)` 안에만 들어 있어, 마지막 stage에서는 `nextStage`가 호출되지 않으므로(바로 `submitAnswers`가 호출됨) scoring이 누락됨. 첫 세션 채점에서 자체 점수 50 vs 실제 점수 84 같은 큰 갭의 원인.

**잘못된 패턴 (피해야 함)**:
```javascript
function nextStage(n) {
  // 자체 점수: 답이 비지 않은 필드당 +5
  const cur = document.querySelector('.stage.active');
  const inputs = cur.querySelectorAll('textarea, input[type="text"]');
  let added = 0;
  inputs.forEach(i => { if (i.value.trim().length > 1 && !i.dataset.scored) { added += 5; i.dataset.scored = '1'; } });
  if (added > 0) setScore(added);
  // ... stage 전환 ...
}

async function submitAnswers() {
  try {
    const payload = gather();  // ❌ 현재 stage scoring 누락된 채 payload 생성
    // ...
  }
}
```

**올바른 패턴 (이렇게 작성)**:
```javascript
function scoreCurrentStageInputs() {
  const cur = document.querySelector('.stage.active');
  if (!cur) return;
  const inputs = cur.querySelectorAll('textarea, input[type="text"]');
  let added = 0;
  inputs.forEach(i => { if (i.value.trim().length > 1 && !i.dataset.scored) { added += 5; i.dataset.scored = '1'; } });
  if (added > 0) setScore(added);
}

function nextStage(n) {
  scoreCurrentStageInputs();
  // ... stage 전환 ...
}

async function submitAnswers() {
  try {
    scoreCurrentStageInputs();  // ✅ submit 직전에도 현재 stage scoring
    const payload = gather();
    // ...
  }
}
```

**적용 원칙**: scoring 같은 사이드이펙트 로직이 *transition 함수에만* 들어 있으면 마지막 stage에서 누락된다. **transition을 통한 호출 + 명시적 직접 호출 양쪽 모두에서 호출 가능한 helper로 추출**한다.

**일반화 가능한 패턴 (다른 비슷한 함정)**: 진행률/타이머 finalize/dirty flag 등 stage 전환 시점에만 갱신되는 데이터가 있다면, 그것도 submit 직전 명시적으로 finalize하는지 점검하라. "transition 함수 안에만 로직이 있다 + 마지막 stage에서는 transition이 안 일어난다" 패턴이 곧 누락 원인.

## 4. 학습 페이지 구조 (이전 세션의 사실상 표준)

5단계 progress bar + Anki 스타일 다크 모드. 모바일 친화 (vertical layout).

| Stage | 역할 | 형태 |
|-------|------|------|
| 1 워밍업 | 핵심 정의 자유 서술 (10pt) | textarea |
| 2 회상 | 카드 핵심 항목 채우기 (20-40pt) | matching/flow-step/mode-compare/hitmiss-grid 등 카드 특성에 맞게 |
| 3 응용/매핑 | 추가 회상 (20-30pt) | 카드별 |
| 4 종합 사고 | 응용 질문 (15-30pt) | textarea 보너스 |
| 5 정답 + 보충 | 정답 + ⚠️ 정정 + 🚫 YAGNI + 🔍 깊이 + 자기평가 | reveal |

타이머/스코어/힌트(잠금-탭 시 -10pt)/자기평가(Again/Hard/Good/Easy +0/+5/+10/+20).

## 5. 호스팅 & 채점 흐름 (현재 운영 방식, Future Ideas는 별도)

- LLM이 `/tmp/<workspace>/<card>.html` 작성 → Python http.server로 minipc Tailscale IP에서 서빙
- 사용자가 답 입력 → POST `/submit` → `<workspace>/answers/ans_<unix_ms>.json` 저장
- 사용자가 채팅창에서 "제출했어" → LLM이 답안 파일 읽고 채점 + 보충 피드백
- 자기평가는 별도 POST `/rate`로 plan에 기록

## 6. 무엇을 *하지 않을지* (Future Ideas — 사용자가 명시적으로 요청할 때만)

다음은 awesome-anki 1.0 함정의 재발 위험이 큰 것들. dogfooding 결과 *불편/욕구*가 명확해지기 전에는 손대지 마라:

- 공통 HTML 셸 + 카드별 JSON 스키마 (템플릿화)
- 호스팅 영구화 (`homeserver.ankiStudy.*` 모듈, Caddy 리버스 프록시)
- AnkiConnect 양방향 sync (`answerCards(cardId, ease 1-4)`로 학습 결과를 Anki에 commit)
- A/B 테스트
- user journey 기록 (Stage별 체류 시간 등)
- LLM 자동 채점 백엔드
- AnkiConnect 학습 통계 자동 fetch + 시계열 대시보드

이 항목들은 [issue #711](https://github.com/greenheadHQ/nixos-config/issues/711) § 8에 박제되어 있다.

## 7. 다음 세션이 끝나면 너가 해야 할 것

매 세션 종료 시:

1. 새 디렉토리 `sessions/<YYYY-MM-DD>/` 생성
2. 학습한 HTML + 답안 JSON + 사용 이미지 그대로 보존
3. 본 디렉토리의 [`sessions/2026-05-10/SESSION.md`](sessions/2026-05-10/SESSION.md) 형식대로 SESSION.md 작성
4. **본 GUIDE.md를 갱신** — 좋았던 점 / 안 좋았던 점 / 새로 배운 원칙을 §1-§3에 *추가* (덮어쓰기 금지)
5. N회 세션 후 패턴이 보이면 그제서야 Future Ideas 1개씩 검토 (사용자에게 명시적으로 제안)
