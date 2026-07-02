# Plan 013: Karakeep 아카이빙 파이프라인 헬퍼(fallback-sync·singlefile-bridge)에 테스트를 추가한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/karakeep-fallback-sync/ modules/nixos/programs/docker/karakeep-singlefile-bridge/ tests/`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (테스트 추가 — 대상 동작 변경 없음)
- **Depends on**: none (plan 003과 파일 안 겹침 — log-monitor는 003이 수정,
  여기서는 테스트 대상에서 제외)
- **Category**: tests
- **Planned at**: commit `fb2a8aa6`, 2026-07-02

## Why this matters

Karakeep 아카이빙 파이프라인의 두 핵심 헬퍼가 테스트 0건이다 (grep 실측):
`fallback-sync.sh`(385줄 — 실패 URL 큐를 소비해 Copyparty로 폴백 동기화,
상태 GC 포함)와 `singlefile-bridge.py`(688줄 — 이 저장소 최대 Python,
SingleFile 업로드를 Karakeep API로 중계, multipart 파싱·재시도·알림 분기
포함). 재시도/에러 경로의 회귀는 아카이브 누락을 **무음으로** 유발한다 —
사용자는 저장됐다고 믿는데 실제로는 유실되는 종류의 실패다. 순수 함수부터
특성화 테스트를 씌운다.

## Current state

- `modules/nixos/programs/docker/karakeep-fallback-sync/files/fallback-sync.sh`
  — 함수 구조 (grep 실측):

```
 45: timestamp_to_epoch()      55: gc_unmatched_notified_state()
 77: gc_processed_state()      99: gc_notify_state()
112: gc_state_files()         118: normalize_url()
127: normalize_url_loose()    134: shorten_url()
147: should_notify_key()      165: is_unmatched_notified()
170: record_unmatched_notified()  176: remove_queue_url()
```

  상태 파일은 `mktemp -p "$STATE_DIR"` + `mv` 패턴으로 재작성한다 (:59,:81,:103).

- `modules/nixos/programs/docker/karakeep-singlefile-bridge/files/singlefile-bridge.py`
  — 함수 구조 (grep 실측):

```
 32: log()                     36: shorten_url()
 42: sanitize_filename()       52: extract_boundary()
 59: parse_content_disposition()  72: parse_multipart_body()
120: parse_response_headers()  133: run_curl()
172: parse_json_body()         182: send_pushover()
207: format_created_at()       219: parse_ifexists_mode()
```

- 이 저장소의 pytest 선례: EPIC #912의 #915가 "Python characterization
  레이어"를 도입했다 — `tests/` 아래에서 pytest가 어떻게 배선돼 있는지
  (`grep -rn "pytest" tests/ lefthook.yml`) 확인하고 같은 방식을 따른다.
  루트에 `.pytest_cache/`가 존재하므로 pytest 실행 선례가 있다.
- 셸 suite 컨벤션: `tests/suites/*.sh` (정의 전용) + `tests/lib/test-common.sh`.
- **테스트 대상에서 제외**: `log-monitor.sh` (plan 003이 수정 중 — 그 plan이
  테스트를 YAGNI로 스코프 아웃한 판단을 존중), `webhook-bridge.sh`
  (plan 002의 test plan이 다룬다).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| pytest 배선 확인 | `grep -rn "pytest" tests/ lefthook.yml .github/workflows/ 2>/dev/null` | 기존 방식 파악 |
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `tests/suites/karakeep-fallback-sync.sh` (신규 — 셸 함수 특성화)
- singlefile-bridge용 pytest 파일 (신규 — 위치는 기존 pytest 배선을 따름)

**Out of scope** (do NOT touch):
- `fallback-sync.sh`·`singlefile-bridge.py` **동작 변경 일절**. 테스트를 위해
  대상 수정이 필요하면 STOP.
- `log-monitor.sh`, `webhook-bridge.sh` (위 명시된 대로 다른 plan 소관).
- 실 네트워크/실 Karakeep API 호출 — 전부 스텁/mock.

## Git workflow

- Branch: `advisor/013-karakeep-pipeline-tests`
- Commit 예: `test(karakeep): fallback-sync·singlefile-bridge 특성화 테스트`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: fallback-sync 셸 함수 특성화

`fallback-sync.sh`가 source-safe한지 확인한다 (파일 하단에 즉시 실행부가
있는지 — 있으면 어떤 가드가 있는지). source 가능하면
`tests/suites/karakeep-fallback-sync.sh`에서 함수 단위로:

1. `normalize_url`/`normalize_url_loose`/`shorten_url` — 대표 입력 3~4개의
   현행 출력 박제 (쿼리스트링/트레일링 슬래시/프로토콜 변형).
2. `remove_queue_url` — sandbox 큐 파일에서 대상 URL만 제거되고 나머지 보존,
   결과 파일이 `STATE_DIR` 안 임시 파일 경유로 교체됨.
3. `gc_*_state` — 오래된 항목(타임스탬프 조작)만 제거되고 최신 항목 보존.
4. `should_notify_key`/`record_unmatched_notified` — dedup 왕복.

source-unsafe하면 함수 구동이 가능한 다른 방법을 발명하지 말고 STOP 조건을
따른다.

**Verify**: suite 실행에서 신규 테스트 통과.

### Step 2: singlefile-bridge pytest 특성화

기존 pytest 배선 방식(Step 0 확인 결과)에 맞춰 순수 함수부터:

1. `sanitize_filename` — 경로 구분자/특수문자 입력의 현행 출력 박제.
2. `extract_boundary`/`parse_content_disposition`/`parse_multipart_body` —
   정상 multipart, boundary 누락, 필드 누락 케이스.
3. `parse_json_body` — 정상/비-JSON/빈 바디.
4. `parse_ifexists_mode` — 쿼리 변형들.
5. `run_curl`/`send_pushover`는 subprocess/network 경계라 mock 비용이 크면
   이번 범위에서 제외하고 그 사실을 suite 주석에 명시 (silent cap 금지).

**Verify**: pytest 실행 (기존 배선 명령) → 신규 테스트 전부 통과.

### Step 3: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP (pytest가
run-all-tests에 배선돼 있지 않다면, 신규 pytest를 어떻게 게이트에 태울지 —
기존 #915 테스트가 태워진 방식 그대로 — 확인하고 동일하게).

## Test plan

Steps 1-2가 test plan이다.

## Done criteria

- [ ] `grep -rl "fallback-sync" tests/` → 1건 이상 (참조 0건 해소)
- [ ] `grep -rl "singlefile" tests/` → 1건 이상
- [ ] 신규 테스트 전부 통과 (suite + pytest)
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] 대상 스크립트 2개의 diff 없음 (`git diff --stat`에 tests/만)
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- `fallback-sync.sh`가 source-unsafe하고(로드 즉시 메인 로직 실행) 기존
  suite에 우회 선례가 없다 — 대상을 고치지 말고 보고.
- 기존 pytest 배선이 없거나(grep 0건) #915의 방식이 식별되지 않는다 —
  새 테스트 러너를 발명하지 말고 발견 내용을 보고.
- 특성화 중 현행 동작이 명백한 버그로 보인다 — 기대값 박제를 멈추고 보고.

## Maintenance notes

- 이 특성화는 현행 동작의 박제다 — URL 정규화 규칙이나 multipart 파싱을
  의도적으로 바꾸는 PR은 기대값도 함께 갱신해야 정상.
- plan 003이 머지되면 log-monitor의 mktemp 패턴이 fallback-sync와 동일해진다
  — 그 시점에 log-monitor 함수 테스트를 이 suite에 추가하는 것은 자연스러운
  후속이지만, source-safety 문제(메인 루프 즉시 실행)가 먼저 해결돼야 한다.
