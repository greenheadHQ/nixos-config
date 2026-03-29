# Pain Point Collection Harness

Claude Code 전체 세션에서 사용자의 pain point를 자동/수동으로 수집하고,
Claude가 세션 시작 시 자동으로 읽어 행동을 조정하는 harness.

## 접근법: JSONL 로그 + Hook 체인

- 저장: `~/.claude/pain-points.jsonl` (append-only JSONL)
- 수집: Stop hook (자동 transcript 분석) + `/pain` 스킬 (수동 태깅)
- 읽기: SessionStart hook (최근 7일 원본을 additionalContext로 주입)
- 정제: 하이브리드 (최근 7일 원본 유지 + 7일 이전은 claude -p로 요약 → memory 승격)

## 1. 데이터 모델

저장소: `~/.claude/pain-points.jsonl` — 한 줄에 하나의 레코드.

```jsonl
{
  "ts": "2026-03-28T15:30:00+09:00",
  "session_id": "abc-123",
  "repo": "nixos-config",
  "branch": "feat/something",
  "source": "auto|manual",
  "severity": "high|medium",
  "signals": {
    "corrections": ["아니 그거 말고", "다시 해봐"],
    "rejects": 2,
    "turns": 45,
    "duration_min": 38
  },
  "description": "Edit tool을 2회 거부, 교정 표현 2회 사용",
  "user_note": null
}
```

| 필드 | 설명 |
|------|------|
| `ts` | 기록 시각 (ISO 8601) |
| `session_id` | Claude Code 세션 ID |
| `repo` / `branch` | 발생한 프로젝트와 브랜치 |
| `source` | `auto` (Stop hook 자동 분석) 또는 `manual` (/pain 수동 태깅) |
| `severity` | `high` (;; 감지) 또는 `medium` (기타 교정 키워드) |
| `signals` | 감지된 신호: 교정 표현 목록, reject 횟수, 턴 수, 세션 시간 |
| `description` | 자동 생성된 요약 |
| `user_note` | `/pain`으로 수동 태깅 시 사용자 입력 메모 |

## 2. 수집 계층

3가지 수집 메커니즘이 하나의 JSONL 파일에 append.

### 2-A. Stop Hook: 자동 transcript 분석

**스크립트**: `~/.claude/hooks/collect-pain-points.sh`
**트리거**: 매 세션 종료 시 자동 실행
**구현**: 순수 bash + jq (AI 호출 없음, 저렴하고 빠름)

동작:
1. stdin JSON에서 `transcript_path` 추출
2. transcript JSONL 파싱 → user 메시지 추출
3. 교정 키워드 매칭
4. tool rejection 패턴 카운팅
5. 턴 수, 세션 시간 계산
6. 어느 하나라도 임계값 초과 → JSONL 레코드 append
7. 임계값 미달 → 아무것도 안 함 (깨끗한 세션)

**교정 키워드 및 severity**:

| 키워드 | 매칭 방식 | Severity | 설명 |
|--------|-----------|----------|------|
| `;;` | 정확 매칭 | **high** | 사용자의 강한 불만 표현 |
| `아니` | 메시지 앞부분 매칭 (`^아니[^면]` 또는 `^아니 `) | medium | 부정/교정. "아니면"(접속사) 오탐 방지 |
| `해야지` | suffix 포함 매칭 | medium | "~해야지" 패턴 |
| `그거 말고` | 포함 매칭 | medium | 방향 교정 |

**임계값**:

| 신호 | 임계값 |
|------|--------|
| 교정 키워드 | 1회 이상 매칭 |
| Tool reject | 1회 이상 (구현 시 transcript에서 rejection 표현 형식 확인 필요) |
| 긴 세션 | 30턴 초과 |

### 2-B. /pain 스킬: 수동 태깅

**스킬 경로**: `~/.claude/skills/pain/SKILL.md`
**사용법**: `/pain Edit할 때 자꾸 잘못된 파일 수정함`

동작:
1. 사용자 입력을 `user_note`로 캡처
2. 현재 session_id, repo, branch 수집
3. `source: "manual"` 레코드를 pain-points.jsonl에 append

수동 태깅은 `signals` 필드가 비어있고, `user_note`에 사용자 메모가 들어감.
수동 항목의 severity는 기본 `medium`. 사용자가 같은 세션에서 ";;"도 사용했다면
auto 항목이 별도로 high로 잡히므로 수동 항목은 항상 medium으로 충분.

### 2-C. 세션 메트릭 (Stop hook의 일부)

Stop hook이 자동으로 수집하는 메트릭:

| 메트릭 | 계산 방법 |
|--------|-----------|
| `turns` | transcript의 user/assistant 메시지 쌍 수 |
| `duration_min` | 첫 메시지 ~ 마지막 메시지 시간 차이 |
| `rejects` | tool denial 패턴 수 |
| `corrections` | 교정 키워드 매칭된 user 메시지 목록 |

## 3. 읽기 계층 (SessionStart Hook)

**스크립트**: `~/.claude/hooks/read-pain-points.sh`
**트리거**: 매 세션 시작 시 자동 실행

동작:
1. `~/.claude/pain-points.jsonl` 존재 확인 (없으면 exit 0)
2. jq로 최근 7일 레코드 필터링
3. severity 정렬 (high → medium → manual)
4. 최대 10건 제한 (초과 시 high severity + 최신 우선)
5. 요약 텍스트 생성 → additionalContext로 반환

출력 형식:

```json
{
  "hookSpecificOutput": {
    "additionalContext": "## 최근 Pain Points (7일)\n\n### HIGH\n- [03/27] ;; 감지 — ...\n\n### MEDIUM\n- [03/25] 교정 2회 — ..."
  }
}
```

Claude가 보는 화면 예시:

```markdown
## 최근 Pain Points (7일) -- 3건

### HIGH (1건)
- [03/27 세션 abc-123] ;; 감지, reject 1회, 45턴
  └ repo: nixos-config/feat/something

### MEDIUM (1건)
- [03/25 세션 def-456] "아니" 2회, "해야지" 1회, 28턴
  └ repo: nixos-config/main

### MANUAL (1건)
- [03/26 세션 ghi-789] "Edit할 때 자꾸 잘못된 파일 수정함"
  └ repo: nixos-config/fix/something
```

설계 원칙:

| 원칙 | 이유 |
|------|------|
| 최대 10건 | 컨텍스트 윈도우 절약 |
| severity 정렬 | high 항목을 Claude가 우선 인지 |
| 한 줄 요약 | 원본 transcript 미포함, 핵심만 |
| 7일 윈도우 | 하이브리드 전략의 "최근" 기준 |

## 4. 정제 계층 (하이브리드 라이프사이클)

7일 이전 pain point를 자동 요약하여 기존 memory 시스템으로 승격.

### 트리거

Stop hook (collect-pain-points.sh)의 후반부에서 실행:
- 7일 이전 항목이 5건 이상일 때만 트리거
- 5건 미만이면 다음 세션으로 이월

### 프로세스

1. jq로 7일 이전 항목 추출 (저렴)
2. 5건 이상이면 `claude -p` 호출:
   - 반복 패턴 분석
   - feedback memory 형식으로 요약 생성
   - 1회성 항목 판별
3. 결과 처리:
   - 반복 패턴 → `memory/` 디렉토리에 feedback memory 파일 생성
   - MEMORY.md에 인덱스 추가
   - 처리된 원본 항목 → `pain-points.archive.jsonl`로 이동

### 자동 생성되는 memory 파일 예시

```markdown
---
name: pain-edit-wrong-file
description: Claude가 Edit 시 잘못된 파일을 수정하는 반복 패턴 (pain point 자동 정제)
type: feedback
---

Claude가 Edit tool 사용 시 대상 파일을 잘못 선택하는 패턴이 3회 반복됨.

**Why:** 사용자가 3개 세션에서 ;; 또는 "그거 말고"로 교정 (03/15, 03/18, 03/22)
**How to apply:** Edit 전에 대상 파일 경로를 사용자에게 확인. 비슷한 이름의 파일이 여럿일 때 특히.
```

### 아카이브 전략

| 항목 | 동작 |
|------|------|
| 반복 패턴 → memory 승격 | 원본을 `pain-points.archive.jsonl`로 이동 |
| 1회성 + 7일 초과 | 동일하게 아카이브로 이동 |
| 아카이브 파일 | 30일 후 자동 삭제 (기존 cleanup 패턴) |

## 5. Nix 통합

### 새로 추가되는 컴포넌트

| 컴포넌트 | 유형 | Nix 관리 | 런타임 경로 |
|----------|------|----------|------------|
| `collect-pain-points.sh` | Stop hook | O (nix store → symlink) | `~/.claude/hooks/` |
| `read-pain-points.sh` | SessionStart hook | O (nix store → symlink) | `~/.claude/hooks/` |
| `/pain` 스킬 (SKILL.md) | 스킬 | O (nix store → symlink) | `~/.claude/skills/pain/` |
| `pain-points.jsonl` | 런타임 데이터 | X | `~/.claude/` |
| `pain-points.archive.jsonl` | 아카이브 | X | `~/.claude/` |

### settings.json 변경

기존 hooks 배열에 2개 항목 추가:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/collect-pain-points.sh" }]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/read-pain-points.sh" }]
      }
    ]
  }
}
```

## 6. 전체 데이터 흐름

```
┌─ 세션 시작 ─────────────────────────────────────────────────┐
│  SessionStart: read-pain-points.sh                          │
│  → pain-points.jsonl에서 최근 7일, 최대 10건 읽기            │
│  → additionalContext로 Claude에 주입                        │
├─ 세션 진행 ─────────────────────────────────────────────────┤
│  /pain "메모" → pain-points.jsonl에 manual 항목 append      │
├─ 세션 종료 ─────────────────────────────────────────────────┤
│  Stop: collect-pain-points.sh                               │
│  1. transcript 분석 → 교정 키워드/reject/메트릭 감지         │
│  2. 신호 있으면 → pain-points.jsonl에 auto 항목 append       │
│  3. 7일 이전 항목 5건+? → claude -p로 패턴 분석              │
│     → feedback memory 생성 + MEMORY.md 인덱싱               │
│     → 처리된 항목 archive로 이동                             │
└─────────────────────────────────────────────────────────────┘
```
