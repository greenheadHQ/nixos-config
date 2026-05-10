# anki-study

LLM에게 매 학습 세션마다 인터랙티브 HTML을 만들게 해 Anki 학습을 보조한다.
**학습과 시스템 개선이 동시에 일어나는 closed-loop dogfooding** 으로 점진 진화시킨다.

## 왜 이게 v2 인가

선행 프로젝트 [awesome-anki 1.0](https://github.com/greenheadHQ/awesome-anki)은 "비대한 노트 쪼개기 / 연관 노트 찾기 / 팩트체크 / YAGNI 체크 / 학습 프롬프트" 등 야심찬 올인원 사이트로 시작했다. 결과:

- **사이트 기능 개발만 하고 실제 학습은 0회** → YAGNI 함정 자체 자각
- 손 놓음과 동시에 Anki 학습도 all stop → 슬럼프

이 회고에서 두 교훈을 박제했다:

1. **학습 ↔ 시스템 개선이 반드시 동시에** — awesome-anki 1.0의 결정적 실패 원인
2. **처음부터 너무 많이 결정하지 않기** — 작게 시작 + trial and error로 점진 진화

## 영감

- <https://x.com/trq212/article/2052809885763747935>
- <https://thariqs.github.io/html-effectiveness/>

핵심: "LLM에게 HTML을 만들라고 시키면 효율적". 이걸 Anki 학습에 적용해보니 **준비 부담 0 = LLM에게 부탁만 하면 됨** 이라는 가치가 통했다 (첫 세션 평균 점수 63.6 / 100).

## 디렉토리 구조

```
anki-study/
├── README.md          ← 이 파일
├── GUIDE.md           ← ★ 학습 세션 시작 전 LLM에게 입력으로 제공
└── sessions/
    └── 2026-05-10/    ← 첫 세션 (초기 baseline)
        ├── SESSION.md ← 세션 메타데이터 (좋았던 점·안 좋았던 점·점수 등)
        ├── *.html     ← 카드별 학습 페이지 (5장)
        ├── *.png      ← Anki 노트 원본 이미지 (학습 컨텍스트)
        └── answers/   ← 사용자 답안 JSON (5장)
```

## dogfooding 루프 트리거

세션을 시작할 때:

1. [`GUIDE.md`](GUIDE.md) 를 LLM에게 입력으로 제공
2. lapses 상위 카드 1-5장을 골라 "이 카드들로 학습 페이지 만들어줘" 라고 부탁
3. minipc Tailscale 내부에서 호스팅된 페이지로 학습 + AI 채점

세션 종료 후:

1. 새 디렉토리 `sessions/<YYYY-MM-DD>/` 생성
2. HTML + 답안 JSON + 사용 이미지 보존
3. SESSION.md 작성 — `좋았던 점` / `안 좋았던 점` / `AI 자체 평가` 누락 없이
4. **GUIDE.md 갱신** — 새 학습 원칙을 *추가* (덮어쓰기 금지)
5. N회 세션 후 패턴이 보이면 Future Ideas 1개씩 검토

## 1순위 가치 (반복)

> **closed-loop dogfooding** — 매 학습 세션이 곧 시스템 입력이 되는 피드백 루프.

이걸 깨는 어떤 결정도 1순위 위반.

## 관련 자료

- [issue #711](https://github.com/greenheadHQ/nixos-config/issues/711) — 프로젝트 etcd (1.0 회고 + 2.0 정의 + Future Ideas 박제)
- [hosting-anki 스킬](../.claude/skills/hosting-anki/SKILL.md) — Anki Sync Server + AnkiConnect (minipc) 운영
- 첫 세션 결과: [sessions/2026-05-10/SESSION.md](sessions/2026-05-10/SESSION.md)

## Future Ideas (현재 결정 X — issue #711 § 8 참조)

dogfooding 결과 *불편/욕구*가 명확해지면 그때 검토:

- 공통 HTML 셸 + 카드별 JSON 스키마 (템플릿화)
- 호스팅 영구화 (`homeserver.ankiStudy.*` 모듈)
- AnkiConnect 양방향 sync (`answerCards(cardId, ease 1-4)`)
- A/B 테스트 / user journey 기록 / 자동 채점 백엔드 / 시계열 대시보드
