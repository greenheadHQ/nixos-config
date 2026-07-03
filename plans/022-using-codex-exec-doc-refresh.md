# Plan 022: using-codex-exec 스킬 문서를 codex-cli 0.142.5 실측 기준으로 현행화한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 79530cec..HEAD -- modules/shared/programs/claude/files/skills/using-codex-exec/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Also run `codex --version` — if it
> is not `0.142.x`, re-measure every CLI fact below before applying it.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (문서만 수정 — 단, 잘못된 문서는 모든 fan-out 세션에 전파되므로 실측 원칙 엄수)
- **Depends on**: none
- **Category**: docs (runtime drift)
- **Planned at**: commit `79530cec`, 2026-07-03
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/861

## Why this matters

`using-codex-exec` 스킬은 이 저장소의 codex exec fan-out(`run-da`,
`parallel-audit`, `codex-fan-out`)이 매번 참조하는 실행 계약 문서다. 문서의
"작성 기준"은 codex-cli 0.122.0 (2026-04-21)인데 활성 CLI는 0.142.5로,
문서가 지시하는 `--full-auto` 플래그는 **현행 `codex exec --help`와
`codex exec review --help` 어디에도 존재하지 않는다** (문서에는 15회 등장).
LLM이 문서를 신뢰하고 실행하면 미지원 플래그 에러 또는 조용한 의미 변화를
만나고, 매 fan-out마다 재발한다.

## Current state

- `modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md`
  (262행) — 본체. 19–20행이 "확인 날짜: 2026-04-21 / 확인 버전: codex-cli
  0.122.0". `--full-auto`가 15회 등장 (`grep -c "full-auto"` = 15).
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/patterns.md` —
  상황별 실행 패턴 예제.
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md` —
  제한사항/트러블슈팅 (upstream bug 번호 포함).

2026-07-03 실측 (codex-cli 0.142.5):

- `codex exec --help`: `--full-auto` 없음. `-s, --sandbox <SANDBOX_MODE>`
  (read-only | workspace-write | danger-full-access),
  `--dangerously-bypass-approvals-and-sandbox`, `-p, --profile <CONFIG_PROFILE_V2>`
  ("Layer $CODEX_HOME/<name>.config.toml on top of the base user config" —
  문서의 구형 profile 설명과 다름), `--strict-config`, `--enable/--disable
  <FEATURE>` 존재. stdin 동작 변화: "If stdin is piped and a prompt is also
  provided, stdin is appended as a `<stdin>` block".
- `codex exec review --help`: `--full-auto` 없음. `[PROMPT]` 인자 설명이
  "Custom review instructions. If `-` is used, read from stdin"으로 바뀌어
  있다 — 문서가 단정하는 "PROMPT ↔ scope flag 상호 배타"(#7825 기반)가
  현행에서도 유효한지 실측이 필요하다.
- 참고: 이 저장소의 fan-out 표준 경로인 `codex-exec-supervised` wrapper는
  `--full-auto`를 사용하지 않는다 (`grep -rn "full-auto" modules/shared/scripts/
  modules/shared/programs/codex/` → skills 문서 밖 매치 0).

이슈 #861 본문에 5월 시점의 drift 후보 14건 목록이 있다 — 출발점으로 쓰되,
**각 항목을 현행 0.142.5에서 재실측한 결과만** 문서에 반영한다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 버전 확인 | `codex --version` | `codex-cli 0.142.x` |
| exec surface | `codex exec --help` | 전문 확보 |
| review surface | `codex exec review --help` | 전문 확보 |
| resume surface | `codex exec resume --help` | 전문 확보 |
| 잔존 drift 검사 | `grep -rn "full-auto" modules/shared/programs/claude/files/skills/using-codex-exec/` | 0건 (완료 후) |
| 스킬 노이즈 게이트 | `bash tests/run-shell-script-tests.sh` | exit 0 |

## Scope

**In scope**:

- `modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md`
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/patterns.md`
- `modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md`

**Out of scope**:

- `codex-fan-out`, `run-da`, `parallel-audit` 스킬 본문 — using-codex-exec를
  참조하지만 자체 계약은 별도다. 이들 문서가 `--full-auto`를 직접 지시하는
  부분이 발견되면 수정하지 말고 STOP 조건이 아닌 **보고 항목**으로 목록만
  남긴다 (별도 이슈감).
- `codex-exec-supervised` wrapper 스크립트 — 코드 변경 없음.
- `~/.codex/config.toml` 템플릿 (`modules/shared/programs/codex/files/config.toml`).

## Git workflow

- Branch: `docs/861-using-codex-exec-0142`
- Conventional commits (예: `docs(skills): using-codex-exec를 codex-cli 0.142.5 실측으로 현행화 (#861)`)
- push/PR 생성은 운영자 지시 없이는 하지 않는다.

## Steps

### Step 1: 현행 surface 전수 실측

`codex exec --help`, `codex exec review --help`, `codex exec resume --help`
전문을 파일로 떠서 (`/tmp/codex-help-{exec,review,resume}.txt`) 문서의 모든
플래그 표(exec 전용/review 전용/공통)와 대조표를 만든다. 각 행: 문서 주장 →
실측 결과 → 조치(유지/수정/삭제).

**Verify**: 대조표에 문서의 표 항목 전체가 포함됨 (누락 0)

### Step 2: 상호 배타/버그 주장 재검증

문서의 단정적 주장 중 실행으로 확인 가능한 것을 재검증한다 (모두 read-only
또는 `--ephemeral`로, 실제 저장소를 건드리지 않는 임시 디렉토리에서):

1. review에서 `[PROMPT]` + `--base` 동시 사용 → 에러가 여전한가? (0.142.5는
   PROMPT를 "Custom review instructions"로 문서화하므로 배타 규칙이 풀렸을
   가능성이 있다)
2. review에서 `-o` 빈 파일 버그(#12502)가 여전한가?
3. `--search` 미동작 gotcha가 여전한가?

각 결과를 known-issues.md의 해당 절에 "재확인: 2026-07-03, 0.142.5" 형태로
반영하고, 해소된 항목은 "0.142.5에서 해소됨"으로 남긴다 (삭제하지 않는다 —
버전 하한 판단 근거).

**Verify**: 재검증 명령과 출력 요약이 커밋 메시지 본문 또는 known-issues.md에 기록됨

### Step 3: SKILL.md 본문 갱신

- "작성 기준"을 0.142.5 / 2026-07-03으로.
- `--full-auto` 15곳: 각 위치의 의도(자동 실행 + workspace-write)를 현행
  플래그 조합으로 치환한다. Step 1 실측에서 approval 관련 현행 기본값을
  확인해 치환 형태를 결정하고, 결정 근거를 커밋 본문에 남긴다.
- profile 설명을 `CONFIG_PROFILE_V2` 의미로 갱신.
- stdin 병용 동작(`<stdin>` block append) 갱신.
- 의사결정 트리/하지 말아야 할 패턴 표를 Step 1–2 결과와 모순 없게 정렬.

**Verify**: `grep -rn "full-auto" modules/shared/programs/claude/files/skills/using-codex-exec/` → 0건, `grep -n "0.122.0" …/SKILL.md` → 0건

### Step 4: patterns.md / known-issues.md 예제 정렬

예제 명령들이 Step 3의 치환 결정과 동일한 플래그를 쓰도록 갱신한다.

**Verify**: `grep -rn "full-auto\|0\.122\.0" modules/shared/programs/claude/files/skills/using-codex-exec/references/` → 0건

### Step 5: 게이트

**Verify**: `bash tests/run-shell-script-tests.sh` → exit 0 (skill-noise 게이트 포함 통과)

## Test plan

- 이 plan은 문서 갱신이므로 자동 테스트 신설 없음. 검증은 위 grep 게이트와
  Step 2의 실측 기록으로 대신한다.
- 실측 명령이 세션 파일을 남기지 않도록 `--ephemeral`을 쓴다.

## Done criteria

- [ ] `grep -rn "full-auto" modules/shared/programs/claude/files/skills/using-codex-exec/` 0건
- [ ] SKILL.md 작성 기준이 `0.142.5 / 2026-07-03`
- [ ] known-issues.md의 단정 주장마다 재확인 날짜/버전 스탬프 존재
- [ ] out-of-scope 스킬에서 발견된 `--full-auto` 직접 지시 목록이 최종 보고에 포함 (수정은 안 함)
- [ ] `bash tests/run-shell-script-tests.sh` exit 0
- [ ] `plans/README.md` status row 갱신

## STOP conditions

- `codex --version`이 0.142.x가 아님 (더 최신이면 그 버전 기준으로 전면 재실측이
  필요하다고 보고).
- Step 2에서 review 상호 배타가 **부분적으로만** 풀린 것으로 관측됨 (조합별로
  다르게 동작) — 표로 정리해 보고 후 지시 대기.
- `--full-auto`의 의도를 대체할 현행 조합을 실측으로 확정할 수 없는 경우.

## Maintenance notes

- CLI 버전이 오를 때마다 같은 drift가 재발한다. 문서 서두의 "재검증:
  `codex --version && codex exec --help`" 원칙이 이미 있으므로, 리뷰어는
  향후 codex pin 갱신 커밋(예: homebrew/npm pin)에 이 문서 재검증이
  동반됐는지 확인할 것.
- upstream sync 자동화는 백로그 다이어트에서 close된 #504/#447의 재개 조건
  ("drift로 인한 실사용 오류 재발")과 연결된다 — 이 plan이 그 사례다.
