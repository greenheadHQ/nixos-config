# Plan 004: 백업 스크립트(immich/karakeep)를 파일로 추출하고 특성화 테스트를 씌운다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/immich-backup.nix modules/nixos/programs/docker/karakeep-backup.nix tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (동작 불변 리팩토링 + 테스트 — 배포 검증은 운영자 `nrs`)
- **Depends on**: none (Plan 001과 파일 겹침 없음 — 001은 문서만)
- **Category**: tests
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/941

## Why this matters

이 홈서버의 존재 이유는 개인 사진(Immich)·북마크(Karakeep) 데이터 보존이고, 그
최후 방어선이 두 백업 스크립트다. 두 스크립트 모두 `find ... -mtime +N -delete`
/ `-exec rm -rf {} +`로 오래된 백업을 **삭제**하고, 무결성 검증 실패 시 non-zero
exit로 알림을 내야 한다. 그런데 `tests/`에서 이들을 참조하는 테스트가 0건이다
(grep 실측). 보관정리 경로 조립이나 무결성 분기에 회귀가 생기면 잘못된 파일을
지우거나 손상 백업을 정상으로 오판하는데, 그걸 알아챌 수단이 없다. 스크립트가
`.nix` 파일 안 인라인 문자열이라 테스트 하네스에서 직접 구동할 수 없는 것이
근본 장애물이므로, 이 저장소의 기존 컨벤션(`karakeep-notify.nix`가
`webhook-bridge.sh`를 `builtins.readFile`로 임베드)대로 스크립트를 `files/`로
추출한 뒤 특성화 테스트를 씌운다. 이 테스트는 향후 백업 자세 개선(오프사이트
사본 등)과 #917류 리팩토링의 안전망이 된다.

## Current state

관련 파일과 역할:

- `modules/nixos/programs/docker/immich-backup.nix` — 수정 대상.
  `pkgs.writeShellApplication` `text = ''...''` 인라인으로 pg_dump 백업 스크립트
  포함. 스크립트 파라미터는 이미 **모두 env로 주입**된다
  (`BACKUP_DIR`, `RETENTION_DAYS`, `PUSHOVER_CRED_FILE`, `SERVICE_LIB`).
- `modules/nixos/programs/docker/karakeep-backup.nix` — 수정 대상. 같은 구조지만
  **Nix 보간이 스크립트 본문에 박혀 있다**: `DB_FILE="${srcDir}/db.db"` —
  추출하려면 env 변수화가 필요하다.
- `modules/nixos/programs/docker/karakeep-notify.nix:19-28` — **추출 패턴 exemplar**:

```nix
webhookBridgeScript = pkgs.writeShellApplication {
  name = "karakeep-webhook-bridge";
  runtimeInputs = with pkgs; [ coreutils jq curl gnused ];
  text = builtins.readFile ./karakeep-notify/files/webhook-bridge.sh;
};
```

- `tests/lib/test-common.sh` — 테스트 공통 헬퍼 (`new_sandbox`, `fail`,
  `assert_contains`, `cleanup` trap). suite는 **정의 전용(sourced)** 파일로
  `tests/suites/`에 두면 aggregator가 find 디스커버리로 집어간다.
- `tests/suites/fragile-hardcoding-guard.sh` — **suite 구조 exemplar** (소형,
  스크립트에 입력을 흘려 출력을 assert).

**immich-backup 스크립트의 핵심 로직** (immich-backup.nix `text` 내부):

```bash
# 에러 핸들러: 실패 시 Pushover 알림 + 임시 파일 정리
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    rm -f "$TMP_FILE"
    send_notification "Immich DB Backup" \
      "백업 실패 (exit $exit_code). journalctl -u immich-db-backup 확인 필요." 1
  fi
}
trap cleanup_on_error EXIT
# 1. 디스크 공간 검사 (5GB 미만이면 중단)
AVAIL_KB=$(df --output=avail "$BACKUP_DIR" | tail -1)
# 2. PostgreSQL 컨테이너 실행 확인
PG_STATE=$(podman inspect --format '{{.State.Status}}' immich-postgres 2>/dev/null || echo "not_found")
# 3. pg_dump -Fc → "$TMP_FILE"
podman exec immich-postgres pg_dump -Fc -U immich immich > "$TMP_FILE"
# 4. 무결성 검증
podman exec -i immich-postgres pg_restore --list < "$TMP_FILE" > /dev/null
# 5. 최소 크기 검증 (10KB 이상)
# 6. 원자적 이동: mv "$TMP_FILE" "$BACKUP_FILE"
# 7. 보관 정리:
DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "immich-db-*.dump" -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
```

주의: `text = ''...''` 안에서 `''${AVAIL_GB}`처럼 보이는 것은 Nix indented-string
escape로, **셸에는 `${AVAIL_GB}`로 전달된다**. 추출 시 `''${` → `${`로 풀어야
한다 (이걸 틀리면 동작이 바뀐다 — Step 1의 diff 검증이 이를 잡는다).

**karakeep-backup 스크립트의 핵심 로직** (karakeep-backup.nix `text` 내부):

```bash
DB_FILE="${srcDir}/db.db"          # ← Nix 보간! srcDir = "${mediaData}/karakeep"
QUEUE_DB_FILE="${srcDir}/queue.db" # ← Nix 보간!
DATED_DIR="$BACKUP_DIR/$(date +%Y-%m-%d)"
sqlite3 "$DB_FILE" ".backup '$DATED_DIR/db.db.tmp'"
mv "$DATED_DIR/db.db.tmp" "$DATED_DIR/db.db"
gzip -f "$DATED_DIR/db.db"
if ! gunzip -t "$DATED_DIR/db.db.gz"; then ... exit 1; fi
# queue.db는 존재하는 경우에만 동일 처리
# 보관 정리:
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
```

`BACKUP_DIR`/`RETENTION_DAYS`/`PUSHOVER_CRED_FILE`/`SERVICE_LIB`는 karakeep 쪽도
`environment`로 이미 주입된다 (`.nix`의 `systemd.services.karakeep-backup` 참조).
`srcDir`만 env가 아니다.

**테스트 러너**: suite는
`nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh`
로 구동된다. suite 파일은 `test_`로 시작하는 함수 정의만 담는다(등록은 find
디스커버리 + 함수명 규약 — 기존 suite들이 어떻게 등록되는지는
`tests/shell-script-tests.sh`의 디스커버리 주석 참조).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| Flake 검증 | `nix flake check --no-build --all-systems` | exit 0 |
| Nix 포맷 | `nixfmt --check modules/nixos/programs/docker/immich-backup.nix modules/nixos/programs/docker/karakeep-backup.nix` | exit 0 |
| 셸 린트 | `shellcheck -S warning <추출된 .sh 2개>` | exit 0 |
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 신규 포함 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

`nrs`(실 배포)는 executor가 실행하지 않는다 — 운영자 후속.

## Scope

**In scope**:
- `modules/nixos/programs/docker/immich-backup.nix`
- `modules/nixos/programs/docker/immich-backup/files/immich-db-backup.sh` (신규)
- `modules/nixos/programs/docker/karakeep-backup.nix`
- `modules/nixos/programs/docker/karakeep-backup/files/karakeep-backup.sh` (신규)
- `tests/suites/backup-scripts.sh` (신규)

**Out of scope** (do NOT touch):
- 백업 **동작 변경** 일절 — 이것은 동작 불변(characterization) 작업이다.
  보관정리 정책, 알림 문구, 백업 포맷 모두 그대로.
- `modules/nixos/programs/immich-update/` — 업데이트 직전 백업은 이슈 #917
  범위(BLOCKED, 별도 계획 존재)라 건드리지 않는다.
- `modules/nixos/lib/service-lib.sh` — 테스트에서는 스텁으로 대체할 뿐 수정 금지.
- systemd 서비스/타이머 선언의 구조 (ExecStart가 가리키는 스크립트만 추출본으로).

## Git workflow

- Branch: `advisor/004-backup-scripts-characterization`
- Commit 예: `test(backup): immich/karakeep 백업 스크립트 추출 + 특성화 테스트`
  (추출과 테스트를 나눠 2커밋도 가능: `refactor(backup): ...` → `test(backup): ...`)
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: immich 백업 스크립트를 files/로 추출 (동작 불변)

1. 추출 전, 현행 렌더링 본문을 보존한다:
   `nix eval --raw` 대신 간단히 — `.nix`의 `text = ''...''` 블록을 복사해
   스크래치 파일에 두고, Nix escape를 수동 변환한다: `''${` → `${`
   (그 외 `''`-escape가 본문에 있는지 눈으로 확인 — `'''`나 `''\` 패턴).
2. `modules/nixos/programs/docker/immich-backup/files/immich-db-backup.sh`를
   생성하고 변환된 본문을 넣는다. 셔뱅은 붙이지 않는다
   (`writeShellApplication`이 관리 — exemplar인 `webhook-bridge.sh`는 자체
   셔뱅이 있으나 `text = builtins.readFile`로 읽히므로 첫 줄 셔뱅은 무해하다;
   exemplar와 동일하게 `#!/usr/bin/env bash` + `# shellcheck shell=bash` 헤더로
   시작해도 된다).
3. `immich-backup.nix`의 `text = ''...''`를
   `text = builtins.readFile ./immich-backup/files/immich-db-backup.sh;`로 교체.
4. 변환 검증: 스크래치의 수동 변환본과 커밋할 `.sh`가 동일한지 `diff`로 확인.

**Verify**: `bash tests/run-eval-tests.sh` → 통과,
`nixfmt --check modules/nixos/programs/docker/immich-backup.nix` → exit 0,
`shellcheck -S warning modules/nixos/programs/docker/immich-backup/files/immich-db-backup.sh` → exit 0

### Step 2: karakeep 백업 스크립트를 추출하며 srcDir을 env로 승격

1. `karakeep-backup.nix`의 `systemd.services.karakeep-backup.environment`에
   `SRC_DIR = srcDir;`를 추가한다.
2. 본문을 `modules/nixos/programs/docker/karakeep-backup/files/karakeep-backup.sh`
   로 추출하되, `DB_FILE="${srcDir}/db.db"` → `DB_FILE="$SRC_DIR/db.db"`,
   `QUEUE_DB_FILE="${srcDir}/queue.db"` → `QUEUE_DB_FILE="$SRC_DIR/queue.db"`로
   바꾼다. `writeShellApplication`은 `set -u`를 켜므로 미주입 시 즉시 실패한다
  (조용한 빈 문자열 없음 — 의도된 안전성).
3. `text = builtins.readFile ./karakeep-backup/files/karakeep-backup.sh;`로 교체.

**Verify**: Step 1과 동일한 3종 (karakeep 파일 대상)

### Step 3: tests/suites/backup-scripts.sh 특성화 테스트 작성

`tests/suites/fragile-hardcoding-guard.sh`의 구조(정의 전용, 공통 헬퍼 사용)를
모델로 작성한다. 공통 준비 헬퍼를 suite 안에 만든다:

- sandbox(`new_sandbox`) 안에 `stub-bin/` 디렉토리를 만들어 PATH 선두에 추가.
- `podman` 스텁: `inspect --format ...` → `running` 출력; `exec ... pg_dump ...`
  → 20KB 이상의 더미 바이트를 stdout으로; `exec -i ... pg_restore --list` →
  환경 변수(`STUB_PG_RESTORE_EXIT`)에 따라 exit 0/1.
- `sqlite3` 스텁: `".backup '<path>'"` 인자에서 경로를 파싱해 더미 파일 생성
  (실제 sqlite3에 의존하지 않아 hermetic).
- `SERVICE_LIB` 스텁 파일: `send_notification() { printf '%s\n' "$*" >> "$SANDBOX/notifications.log"; }`
- `PUSHOVER_CRED_FILE` 스텁 파일: 빈 주석 한 줄.
- 스크립트 구동:
  `env PATH="$stub:$PATH" BACKUP_DIR=... RETENTION_DAYS=30 SRC_DIR=... PUSHOVER_CRED_FILE=... SERVICE_LIB=... bash modules/.../files/<script>.sh`
  — 추출본은 `bash`로 직접 구동 가능해야 한다(`writeShellApplication` 래퍼의
  `set -euo pipefail`은 스크립트 본문이 이미 전제하므로, 구동 시
  `bash -euo pipefail -c '. <script>'`가 아니라 `bash <script>`로 돌리되 테스트
  시작에 `set -euo pipefail` 부재가 결과를 바꾸는 케이스가 있으면
  `bash -o pipefail -eu <script>`로 구동한다 — 래퍼와 동일 조건).

테스트 케이스 (각각 독립 sandbox):

1. `test_immich_backup_happy_path_creates_dump_atomically` — 정상 실행 →
   `immich-db-*.dump` 1개 생성, `*.tmp` 잔존 0개, exit 0,
   notifications.log 비어 있음(성공 시 무알림).
2. `test_immich_backup_integrity_failure_exits_nonzero` —
   `STUB_PG_RESTORE_EXIT=1` → exit non-zero, `.dump` 미생성(`.tmp`도 정리됨),
   notifications.log에 "백업 실패" 포함.
3. `test_immich_backup_retention_deletes_only_old_dumps_in_dir` — BACKUP_DIR에
   미리 3개 파일 배치: `immich-db-old.dump`(`touch -d '40 days ago'`),
   `immich-db-new.dump`(현재), 그리고 **하위 디렉토리** `sub/immich-db-old2.dump`
   (`-maxdepth 1` 보호 확인용, 40일 전). 실행 후: old 삭제됨, new 유지,
   `sub/` 파일 유지.
4. `test_karakeep_backup_happy_path_dated_dir` — SRC_DIR에 더미 `db.db` 배치 →
   `BACKUP_DIR/<오늘날짜>/db.db.gz` 생성, exit 0.
5. `test_karakeep_backup_missing_db_exits_nonzero` — SRC_DIR에 `db.db` 없음 →
   exit non-zero, notifications.log에 "백업 실패" 포함.
6. `test_karakeep_backup_retention_scopes_to_backup_dir` — BACKUP_DIR에
   `20200101/`(40일 전 mtime) + `<오늘>/` 디렉토리 → old만 삭제.

주의: `date`/`find -mtime`은 실제 명령을 쓴다(스텁 불필요). `df` 검사(5GB)는
tmpfs sandbox에서 대부분 통과하지만, 통과가 환경 의존이면 그 테스트만
`STUB` df로 대체하지 말고 **케이스에서 검증 대상에서 제외**한다(디스크 검사
분기는 특성화 대상 아님 — suite 주석에 명시).

**Verify**:
`nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh`
→ 신규 테스트 전부 포함 통과 (실행 로그에서 함수명 확인)

### Step 4: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP,
`nix flake check --no-build --all-systems` → exit 0

## Test plan

Step 3 자체가 test plan이다. 구조 패턴: `tests/suites/fragile-hardcoding-guard.sh`
(정의 전용 suite) + `tests/lib/test-common.sh` 헬퍼(`new_sandbox`/`fail`/
`assert_contains`). 위 케이스 목록의 각 항목이 곧 커버리지 목표다.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "builtins.readFile" modules/nixos/programs/docker/immich-backup.nix modules/nixos/programs/docker/karakeep-backup.nix` → 각 1건
- [ ] `test -f modules/nixos/programs/docker/immich-backup/files/immich-db-backup.sh && test -f modules/nixos/programs/docker/karakeep-backup/files/karakeep-backup.sh` → exit 0
- [ ] `grep -n 'SRC_DIR' modules/nixos/programs/docker/karakeep-backup.nix` → environment 주입 1건 이상
- [ ] `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` → exit 0, 신규 backup-scripts 테스트 함수들이 로그에 나타남
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] 최종 보고에 "운영자 후속: `nrs` 적용 후 `sudo systemctl start immich-db-backup.service && journalctl -u immich-db-backup -n 20`으로 실경로 1회 확인" 명시
- [ ] `git status --porcelain`에 in-scope 외 파일 없음
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

Stop and report back (do not improvise) if:

- "Current state" 발췌와 실제 코드가 다르다.
- `text = ''...''` 본문에 `''${` 외의 Nix escape(`'''` 등)가 있어 기계적 변환의
  정확성을 확신할 수 없다 — 변환 규칙을 임의로 정하지 말고 보고.
- suite 디스커버리 방식이 예상과 달라(함수 자동 등록이 아니라 명시 등록부가
  필요) 기존 suite들과 다른 등록 코드를 써야 한다 — 기존 suite 하나가 어떻게
  등록되는지 확인해 그대로 따르되, 그래도 불명확하면 보고.
- 추출 후 eval-tests가 배포 레이아웃 검증(assert_nix_has_attr류)에서 실패한다 —
  테스트 기대값이 인라인 text를 전제할 수 있으니, 기대값 갱신이 필요한지
  판단하지 말고 실패 내용을 보고.

## Maintenance notes

- 추출 이후 백업 스크립트 수정은 `.sh` 파일에서 한다 — `.nix`의 `text`로
  되돌리면 이 suite가 스크립트를 잃는다(리뷰어 확인 포인트).
- 이 suite는 향후 백업 자세 개선(오프사이트 사본, Copyparty 백업 신설)과
  이슈 #917(update-script 골격 통합)의 안전망이다 — 그 작업들 전에 이 plan이
  먼저 머지되는 것이 순서상 이득이다.
- 스텁 podman의 시그니처가 실제 podman과 달라지는 방향의 스크립트 변경
  (예: `podman exec` 인자 순서 변경)이 생기면 스텁도 함께 갱신해야 한다.
