# Statusline 환경 변수 가이드

statusline.sh 의 동작을 외부에서 조정할 수 있는 환경 변수 모음.

## `CLAUDE_STATUSLINE_COLUMNS` — 터미널 폭 명시 override

Claude Code v2.1.139 부터 hook/statusline 자식 프로세스에서 controlling tty 가
제거되어 statusline.sh 가 터미널 폭을 자동 감지하지 못한다 (`stty size </dev/tty`
실패). 그 결과 rate_limits 의 progressive disclosure 가 가장 좁은 단계로 고정되고
session-id 도 단축 표시로 떨어진다.

```bash
# 사용자 shell rc 또는 home-manager sessionVariables 에 추가
export CLAUDE_STATUSLINE_COLUMNS=200
```

위 변수가 설정되면 다른 어떤 감지 경로보다도 우선 적용된다. 값은 **raw 터미널 cols**
이며, statusline.sh 가 내부적으로 `EFF_COLS = COLS - 40` 보정을 자동 처리한다.

### 폭 감지 우선순위 (5단계 chain)

statusline.sh 는 아래 순서로 폭을 결정한다. 한 단계가 양수 값을 반환하면 즉시 그
값을 사용한다.

| 단계 | 출처 | 비고 |
|------|------|------|
| 1 | `CLAUDE_STATUSLINE_COLUMNS` env | 사용자 명시 override, 항상 우선 |
| 2 | stdin `terminal.columns` | upstream 폭 전달 요청 이슈가 채택되면 자동 활용 |
| 3 | `COLUMNS` env | interactive parent shell 이 export 한 경우 hit |
| 4 | `stty size </dev/tty` | pre-2.1.139 compatibility branch. v2.1.139+ 에서는 항상 실패 |
| 5 | 정적 기본값 `140` | 모든 동적 감지 실패 시 fallback. EFF_COLS=100 → detail=4 + full UUID |

### 임계값 매트릭스

rate_limits detail 단계와 session-id 표시는 서로 다른 임계값에 의존한다.

rate_limits progressive disclosure (`statusline.sh` 의 `RATE_DETAIL` 임계값):

| EFF_COLS 범위 | rate_limits 표시 |
|---------------|------------------|
| ≥88 | bar + pct + window + → remaining + reset_date (detail=4) |
| 58-87 | bar + pct + window + → remaining (detail=3) |
| 40-57 | bar + pct + window (detail=2) |
| <40 | pct + window (detail=1) |

session-id 표시 (별도 임계값):

| EFF_COLS 범위 | session-id 표시 |
|---------------|-----------------|
| ≥100 | full UUID |
| <100 | short prefix (8자) |

raw COLS 입력값과 EFF_COLS 사이는 piecewise 보정이다:

| raw COLS | EFF_COLS |
|----------|----------|
| < 80 | EFF_COLS = COLS (보정 없음) |
| ≥ 80 | EFF_COLS = COLS - 40 |

자주 쓰는 raw 값과 변환 결과:

| raw COLS | EFF_COLS | rate_limits detail | session-id |
|----------|----------|-------------------|------------|
| 50 | 50 | detail=2 | short |
| 80 | 40 | detail=2 | short |
| 100 | 60 | detail=3 | short |
| 128 | 88 | detail=4 | short |
| 140 (default) | 100 | detail=4 | full UUID |
| 200 | 160 | detail=4 | full UUID |

### 권장 설정

| 환경 | 권장값 |
|------|--------|
| Ghostty / iTerm2 fullscreen (~200 cols) | 200 |
| 일반 desktop terminal (~120-150 cols) | 그 값 그대로 |
| split pane / 좁은 ssh 세션 (~80 cols) | 80 (또는 unset → default 140 — wrap 위험 감수) |

### 잘못된 값 처리

비숫자, 음수, 0, **leading-zero 값 (`070`, `0140` 등)**, 5자리 이상 (10000+) 입력은
모두 invalid 로 간주하고 다음 fallback 단계로 fallthrough 한다.

leading-zero 차단 사유: bash 산술 (`$((COLS - 40))`) 이 `0NNN` 형식을 octal 로
해석한다 (`0140` → 96). canonical decimal 만 허용해 호출부 정수 연산 오염을
방지한다. 폭으로 `70` 을 명시하려면 leading-zero 없이 `70` 으로 입력하라.

(`CLAUDE_CACHE_TTL` 의 가드는 `[ -gt 0 ]` 만 적용되어 본 폭 가드보다 느슨하다.
폭과 TTL 의 입력 신뢰 모델이 다르기 때문이다.)

## 관련 환경 변수

- `CLAUDE_CACHE_TTL` — cache TTL 강제. 자세한 내용은 [`cache-guide.md`](./cache-guide.md) 참조.

## 레퍼런스

- nixos-config issue #734 — v2.1.139 폭 측정 회귀 분석 및 fix.
- [anthropics/claude-code#22115](https://github.com/anthropics/claude-code/issues/22115) — statusLine columns 요청 OPEN.
- [Claude Code statusLine docs](https://code.claude.com/docs/en/statusline) — Available data 표 (현재 columns 부재).
