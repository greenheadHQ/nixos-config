# Plan 003: log-monitor의 상태/큐 파일 재작성을 same-filesystem 원자적 교체로 고친다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `fb2a8aa6`, 2026-07-02

## Why this matters

`log-monitor.sh`는 Karakeep 아카이브 실패 URL의 **durable 재시도 큐**
(`failed-urls.queue`)와 알림 dedup 상태 파일을 "임시 파일에 쓰고 `mv`로 교체"하는
패턴으로 재작성한다. 그런데 임시 파일을 bare `mktemp`로 만들기 때문에 임시
파일은 `$TMPDIR`(tmpfs `/tmp` 또는 systemd `PrivateTmp`)에, 목적지는
`/var/lib/karakeep-log-monitor/`에 놓인다. 서로 다른 파일시스템 간 `mv`는
rename(2)이 아니라 **copy+unlink라 원자적이지 않다** — 복사 도중 프로세스가
죽으면 큐가 부분 기록 상태로 손상되어 실패 URL 재연결 대기열이 유실될 수 있다.
큐는 flock으로 동시성이 보호되지만 cross-fs `mv`의 비원자성은 락과 무관하다.
같은 데이터를 다루는 자매 스크립트 `fallback-sync.sh`는 이미 올바른 패턴
(`mktemp -p "$STATE_DIR"`)을 쓰고 있어, 이 파일만 컨벤션에서 벗어나 있다.

## Current state

관련 파일과 역할:

- `modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` —
  수정 대상. journald를 follow하며 Karakeep 크롤 실패를 감지해 Pushover 알림 +
  실패 URL 큐 적재.
- `modules/nixos/programs/docker/karakeep-fallback-sync/files/fallback-sync.sh` —
  **패턴 exemplar** (읽기 전용). 같은 큐 파일을 소비하는 쪽.

**결함 지점 1** — `log-monitor.sh:60-63` (`should_notify_url` 함수 내부,
dedup 상태 파일 재작성):

```bash
  tmp=$(mktemp)
  awk -F '\t' -v key="$url" '$1 != key { print }' "$NOTIFY_STATE_FILE" > "$tmp"
  printf "%s\t%s\n" "$url" "$now" >> "$tmp"
  mv "$tmp" "$NOTIFY_STATE_FILE"
```

**결함 지점 2** — `log-monitor.sh:90-96` 부근 (`enqueue_failed_url` 함수 내부,
durable 큐 트림 후 재작성):

```bash
  tmp=$(mktemp)
  if [ "$rc" -eq 0 ]; then
    if ! tail -n "$FAILED_URL_QUEUE_MAX" "$FAILED_URL_QUEUE_FILE" > "$tmp"; then
      rc=1
    elif ! mv "$tmp" "$FAILED_URL_QUEUE_FILE"; then
      rc=1
    fi
  fi
```

**목적지 경로** — 같은 파일 상단 (9-12행 부근):

```bash
FAILED_URL_QUEUE_FILE="${FAILED_URL_QUEUE_FILE:-/var/lib/karakeep-log-monitor/failed-urls.queue}"
NOTIFY_STATE_FILE="${NOTIFY_STATE_FILE:-/var/lib/karakeep-log-monitor/notified-urls.tsv}"
```

**저장소의 올바른 패턴** — `fallback-sync.sh:59,81,103`:

```bash
  tmp=$(mktemp -p "$STATE_DIR")
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 셸 린트 | `shellcheck -S warning modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` | exit 0 |
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| 통합 테스트 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope** (수정 가능한 파일):
- `modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh`
  (위 두 `mktemp` 호출만)

**Out of scope** (do NOT touch):
- `fallback-sync.sh` — 이미 올바르다.
- `log-monitor.sh`의 다른 로직 (flock 처리, 정규식 매칭, 알림 본문) — 이 plan은
  임시 파일 위치만 고친다.
- karakeep-log-monitor.nix 모듈 — 변경 불필요.
- 신규 테스트 suite — 이 스크립트는 파일 하단에서 `journalctl -f`를 직접
  실행하는 구조라 source 즉시 무한 루프에 들어간다. 테스트 가능하게 만드는
  구조 변경은 2줄 수정 대비 과한 범위다(YAGNI — 이 저장소의 원칙). Done
  criteria의 grep 검증으로 갈음한다.

## Git workflow

- Branch: `advisor/003-log-monitor-atomic-mktemp`
- Commit 예: `fix(karakeep): log-monitor 상태/큐 재작성을 same-fs 원자적 mv로 교정`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 두 mktemp 호출을 목적지 디렉토리 기준으로 교체

`log-monitor.sh`에서:

1. `should_notify_url` 내부(60행 부근):
   `tmp=$(mktemp)` → `tmp=$(mktemp -p "$(dirname "$NOTIFY_STATE_FILE")")`
2. `enqueue_failed_url` 내부(90행 부근):
   `tmp=$(mktemp)` → `tmp=$(mktemp -p "$(dirname "$FAILED_URL_QUEUE_FILE")")`

두 함수 모두 실패 시 `rm -f "$tmp"` 정리가 이미 있거나 `mv`로 소비되므로 추가
정리 로직은 넣지 않는다. 다른 줄은 건드리지 않는다.

**Verify**:
`grep -n 'mktemp' modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh`
→ 출력의 모든 행이 `-p "$(dirname` 를 포함, bare `$(mktemp)` 0건

### Step 2: 린트와 기존 게이트 통과 확인

**Verify**:
- `shellcheck -S warning modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` → exit 0
- `bash tests/run-all-tests.sh` → 전부 통과/SKIP

## Test plan

신규 테스트 없음 (Out of scope 참조 — 스크립트 구조상 source 불가, 2줄 수정에
구조 변경은 과함). 회귀 방어는 Done criteria의 "bare mktemp 0건" grep이 담당한다.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -cE '\$\(mktemp\)' modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` → `0` (exit 1)
- [ ] `grep -c 'mktemp -p' modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` → `2`
- [ ] `shellcheck -S warning modules/nixos/programs/docker/karakeep-log-monitor/files/log-monitor.sh` → exit 0
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `git diff --stat` → 변경 파일이 정확히 1개
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

Stop and report back (do not improvise) if:

- "Current state"의 두 발췌 지점이 실제 코드와 다르다 (이미 고쳐졌거나 로직이
  바뀐 경우).
- `mktemp -p`로 바꾼 뒤 shellcheck이 새 경고를 낸다 (인용 문제 등 — 원인을
  보고).

## Maintenance notes

- 이 수정 후 임시 파일이 `/var/lib/karakeep-log-monitor/`에 생성된다. 스크립트가
  `mv` 전에 죽으면 `mktemp` 파일(`tmp.XXXXXXXXXX`)이 상태 디렉토리에 잔류할 수
  있다 — 무해하지만, 리뷰어는 잔류 파일 정리가 필요해질 수 있음을 인지할 것
  (현행 cross-fs 손상 위험보다 훨씬 나은 트레이드오프).
- 같은 패턴(bare `mktemp` + 다른 fs 목적지로 `mv`)이 새 스크립트에 다시 나타나면
  같은 이유로 교정해야 한다. exemplar는 `fallback-sync.sh`.
