---
name: analyzing-da-sessions
disable-model-invocation: true
description: |
  사용자가 `/analyzing-da-sessions` 슬래시 명령으로 명시 호출했을 때만 DA 세션 로그 정량 통계를 측정한다.
  자연어 trigger 매칭은 사용하지 않는다 — 자연어로 측정을 원하더라도 사용자가 명시 호출해야 한다.
argument-hint: "[--hosts mac,minipc] [--corpus <manifest.json>] [--json out=<path>]"
---

# DA 세션 정량 분석

PR #670에서 사용한 session log 정량 측정 워크플로의 정식 Skill. `run-da` 워크플로 산출물(verdict, severity, stability_status)을 Mac+MiniPC 세션 로그 전체에서 추출하여 markdown 표 + JSON sidecar로 출력한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| Metric Catalog (M-1 ~ M-5 산식) | [`references/algorithm.md`](references/algorithm.md) |
| jsonl 데이터 소스 + manifest.json 스키마 | [`references/data-sources.md`](references/data-sources.md) |
| 출력 형식 (markdown + JSON spec, GitHub Mermaid 안전 subset) | [`references/output-format.md`](references/output-format.md) |
| `--hosts` 인자 + SSH whitelist + partial result 처리 | [`references/host-handling.md`](references/host-handling.md) |
| pytest 회귀 검증 fixture 5종 | [`tests/`](tests/) |

## 호출 예시

```bash
# 기본: Mac + MiniPC 양쪽, live 전체 home log, markdown stdout + JSON sidecar 자동
/analyzing-da-sessions

# 단일 호스트 (디버그)
/analyzing-da-sessions --hosts mac
/analyzing-da-sessions --hosts minipc

# pinned corpus 모드 (PR #670 회귀 게이트 검증용)
/analyzing-da-sessions --corpus references/pr-670-baseline.json

# JSON sidecar 위치 명시 (영구 저장 의도)
/analyzing-da-sessions --json out=$HOME/da-stats-$(date +%Y%m%d).json
```

## 측정 metric (M-1 ~ M-5)

| ID | 이름 | 의미 |
|----|------|------|
| M-1 | 검토 강도 verdict 분포 | Review Intensity 인라인 체크리스트 결과 (FULL / LITE / SKIP) 카운트 |
| M-2 | 판정자 verdict 분포 | Arbiter VERDICT_JSON `verdict` 카운트 (CONFIRMED_ISSUE / NOT_AN_ISSUE / NEEDS_MORE_INFO) |
| M-3 | reviewer 묶음별 confirmed-rate | 4 reviewer 묶음(correctness / design / regression / maintainability) 각각의 CONFIRMED_ISSUE 비율 |
| M-4 | 동일 세션 max severity 전이 | 같은 세션 내 round N → N+1 confirmed finding 집합의 max severity 전이 매트릭스 |
| M-5 | selective consistency stability_status 분포 | `fleiss-kappa.py` aggregate envelope의 `per_finding[].stability_status` 카운트 (stable / split / fragmented / unknown / N/A) |

각 metric의 산식과 source는 [`references/algorithm.md`](references/algorithm.md)가 단일 진실 원천이다.

**측정에서 제외되는 항목** (산식 부재로 별도 follow-up):
- bundle 간 unique finding 비율 — finding 매칭 키 미정 (이슈 #671 follow-up)
- verdict 모순률 (CONFIRMED 후 NOT_AN_ISSUE) — 분모/매칭 키 미정 (이슈 #671 follow-up)

## 절차

1. 인자 파싱 — `--hosts <list>` (default `mac,minipc`, whitelist `{mac,minipc}` reject-fast), `--corpus <path>` (선택), `--json out=<path>` (선택).
2. 각 호스트별 세션 로그 수집:
   - 현재 머신: 직접 glob.
   - 원격 머신: `subprocess.run(["ssh", alias, ...])` 고정 argv. SSH 실패 시 partial result 표시.
3. `analyze.py` 알고리즘 적용 (4-tier fallback + source/confidence 라벨링).
4. M-1 ~ M-5 aggregate.
5. markdown 표 (stdout) + JSON sidecar (auto: `/tmp/analyze-da-sessions-<ISO>.json`, override: `--json out=`) 동시 출력.

## 한계

- 사용자 명시 호출 전용. Claude Code는 frontmatter `disable-model-invocation: true`로 자동 trigger 차단. **Codex 세션은 동등 메커니즘이 없으므로 자동 trigger 차단 보장이 best-effort이다** — 자연어 trigger 키워드를 description에서 빼는 방식으로 자동 매칭 surface를 줄이지만 구조적 차단은 아니다 (이슈 #671 D-2 YAGNI 결정).
- live 전체 home log 분석은 시간이 지남에 따라 분모가 변하므로 PR #670 ±5% 회귀 게이트는 `--corpus pr-670-baseline.json` pinned manifest 모드에서만 사용한다. 단 v1은 manifest 생성 절차(별도 producer 모드)를 포함하지 않는다 — PR #670 baseline manifest는 별도 follow-up에서 capture한다.
- `stability_status` (M-5)는 v1에서 round summary `selective:` 라인 source만 사용한다. `fleiss-kappa.py` aggregate envelope 호출은 selective consistency arbiter result 디렉터리를 session-level에서 직접 추적해야 하므로 corpus 전체 스캔 모델과 자연스럽게 결합되지 않아 v1에서 미연결 — round summary 부재 시 `unavailable` 표기.
- bundle 간 unique finding 비율, verdict 모순률은 산식 부재로 v1에 포함하지 않는다 (이슈 #671 follow-up).

## 회귀 검증

algorithm fixture 5종 (`tests/fixtures/01-skill-doc.txt`, `02-xxxxxx-template.txt`, `03-json-unmarked.txt`, `04-kv-arbiter-window.txt`, `05-nl-summary-dedup.txt`)은 pytest로 자동 검증한다:

```bash
# Repo root 기준 절대 경로 호출 (호환성)
pytest modules/shared/programs/claude/files/skills/analyzing-da-sessions/tests/

# 또는 ad-hoc nix run (devShell pytest 부재 시)
nix run nixpkgs#python3Packages.pytest -- \
  modules/shared/programs/claude/files/skills/analyzing-da-sessions/tests/

# 또는 cd 후 호출
cd modules/shared/programs/claude/files/skills/analyzing-da-sessions
pytest tests/
```

## 주의사항

- 사용자 명시 호출 전용. Claude Code는 자연어 trigger로 자동 호출되지 않는다 (frontmatter `disable-model-invocation: true`). Codex는 동등 메커니즘이 없어 자동 trigger 차단이 best-effort이다.
- `--hosts` 값은 `{mac, minipc}` whitelist 외에는 reject-fast.
- 원격 path는 `HOST_PATH_MAP` base prefix 아래의 `.jsonl` 파일만 허용 (제어문자/shell metacharacter 거부).
- SSH 실패는 silent fallback 금지. partial result + warnings 누적 + 명시적 경고 표시.
- JSON sidecar 자동 경로(`/tmp/...`)는 재시작 시 휘발. 영구 저장은 `--json out=` 명시.
