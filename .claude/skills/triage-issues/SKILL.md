---
name: triage-issues
description: |
  이 레포의 GitHub 이슈 백로그를 전수 평가하고 다음 착수 후보와 close 후보를 선별한다. priority 라벨, YAGNI/NGMI 문화, 관련 코드 실측 근거를 기준으로 stale/false-positive/over-engineering 여부를 판정한다.
  Trigger: '이슈 정리', '이슈 추천', '다음 작업 추천', 'triage', '백로그 평가', '이슈 전수 평가', 'stale 이슈', 'YAGNI 판정', 'close 후보', '착수 후보 추천'.
  NOT for 이슈 등록 (use create-issue). NOT for 머지 직후 관련 이슈 동기화 (use finish-pr).
---

# 이슈 백로그 Triage

이 레포의 열린 GitHub 이슈를 전수 평가하고, 착수 추천과 close 후보를 근거와 함께 제안한다. close 실행은 항상 사용자 확인 뒤 승인된 이슈에만 수행한다.

## 입력

- 사용자 자연어에서 범위 힌트(라벨, 주제, 키워드, "priority high만", "AI 스킬만" 등)를 선택적으로 수신한다.
- 인라인 치환 토큰을 사용하지 않는다. 요청 문장과 대화 컨텍스트에서 범위를 해석한다.
- 사용자가 top N을 지정하지 않으면 착수 추천은 기본 3개로 제한한다.

## 불변 조건

- 사용자 승인 없이 이슈를 close하지 않는다.
- close 후보 제안과 close 실행은 별도 단계다.
- 비자명 판정에는 코드, 커밋, 기존 이슈, 또는 PR 근거를 병기한다.
- 근거가 부족하면 단정하지 말고 "미확인"으로 표시한다.

## 절차

### 1. 대상 수집

1. 현재 repo를 확인한다: `gh repo view --json nameWithOwner -q .nameWithOwner`.
2. 기본 대상은 열린 이슈 전체다: `gh issue list --state open --limit 200 --json number,title,labels,createdAt,updatedAt,url,body`.
3. 사용자가 범위를 좁히면 `--label`, `--search`, 제목/본문 키워드 검색을 조합하되 `--state open`을 유지한다.
4. 결과가 limit에 걸릴 가능성이 있으면 limit를 늘리거나 검색 조건을 나누어 누락 가능성을 보고한다.
5. 관련 PR은 필요할 때만 `gh pr list --state all --search "<키워드>"`로 보조 확인한다.

### 2. 이슈별 평가

각 이슈마다 본문 주장을 먼저 요약한 뒤, 현재 코드와 변경 이력을 실측한다.

- Freshness: 전제가 여전히 유효한지 확인한다. 관련 파일 `rg -n`, `git log --oneline -- <path>`, 관련 PR/이슈 상태로 이미 해결됐는지 본다.
- False-positive: 주장한 문제가 실제로 재현되거나 코드상 존재하는지 확인한다. 없으면 왜 false-positive로 보는지 파일/라인 근거를 남긴다.
- YAGNI/NGMI/over-engineering: 이 레포의 실제 사용 흐름, 기존 단순화 관습, 유지보수 비용 대비 필요한 복잡도인지 판단한다.
- 공수 대비 효용: 공수는 S/M/L로, 기대 효용은 high/medium/low로 표시한다. 공수 추정 근거를 한 줄로 남긴다.
- 선행관계: 다른 이슈, PR, 설정 반영, 외부 확인이 먼저 필요한지 확인한다.
- 병렬 가능성: 서로 다른 파일/서비스/스킬 영역이면 병렬 가능, 같은 모듈이나 같은 정책 문서면 충돌 가능으로 표시한다.

근거 파일은 가능하면 `path:line` 형식으로 적는다. 라인 번호가 불안정하면 파일 경로와 검색어, 관련 커밋 해시를 함께 적는다.

### 3. 산출물 작성

사용자에게 다음 세 가지를 한 번에 제시한다.

1. 평가 표
   - 열: 이슈, 판정, 근거, freshness, false-positive/YAGNI 여부, 공수, 효용, 병렬 가능성.
   - 판정 값은 "착수 추천", "보류", "추가 확인", "close 후보" 중 하나를 우선 사용한다.
2. 착수 추천 top N
   - 효용/공수 비율, unblock 효과, 회귀 위험을 기준으로 정렬한다.
   - 각 추천에는 첫 작업 파일이나 첫 확인 명령을 포함한다.
3. close 후보 목록
   - 각 후보마다 close reason을 `completed` 또는 `not planned`로 제안한다.
   - `gh issue close`에 넣을 사유 초안을 함께 작성한다.
   - 사용자 이견 가능성이 있는 항목은 close 후보 대신 "추가 확인"으로 둔다.

### 4. Close 실행 게이트

close 후보가 있으면 질문 도구로 사용자에게 승인 범위를 묻는다. 질문에는 이슈 번호, 제목, reason, 사유 초안을 포함한다.

선택지는 기본적으로 다음 형태를 사용한다.

- "추천 후보 모두 승인"은 제안한 close 후보 전체를 close한다.
- "일부만 승인"은 사용자가 번호를 지정한 항목만 close한다.
- "close 안 함"은 어떠한 close 명령도 실행하지 않는다.

승인된 항목에 대해서만 다음 형식으로 실행한다.

`gh issue close <n> --comment "<사유>" --reason <completed|not planned>`

사유에 shell 특수 문자가 많으면 안전하게 한 줄 문자열로 정리한 뒤 전달한다. close 실행 후 성공/실패를 이슈별로 보고한다.

## 경계

- 새 이슈 등록은 `create-issue` 범위다.
- PR 머지 직후 관련 이슈 동기화와 완료 close는 `finish-pr` 범위다.
- PR 리뷰 코멘트 처리, review thread resolve, stale review 판정은 `review-pr-feedback` 범위다.
