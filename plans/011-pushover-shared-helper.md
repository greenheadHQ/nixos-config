# Plan 011: Pushover 전송을 플랫폼 공용 헬퍼로 통합한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/smartd.nix modules/darwin/programs/opnix-rotate.nix modules/darwin/programs/folder-actions/files/scripts/_folder-actions-lib.sh modules/darwin/programs/folder-actions/files/scripts/upload-immich.sh modules/shared/programs/shell/default.nix modules/nixos/lib/service-lib.sh`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (알림 경로는 실패해도 조용해서 회귀가 눈에 안 띈다)
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/948

## Why this matters

"cred 로드 → TOKEN/USER 확인 → `curl --form-string ... api.pushover.net`"
블록이 저장소에 여러 사본으로 재구현되어 있다. NixOS 쪽에는 공유 헬퍼
(`modules/nixos/lib/service-lib.sh`의 `send_notification`)가 있고 대부분의
NixOS 호출자는 그걸 쓰지만, ① `smartd.nix`는 NixOS인데도 자체 curl을 쓰고,
② darwin 쪽 3곳(`opnix-rotate.nix`, `_folder-actions-lib.sh`,
`upload-immich.sh`)과 shared 쪽 1곳(`shell/default.nix`의 `push` 함수)은
`modules/nixos/lib`에 구조적으로 닿을 수 없어 각자 재구현했다. 이미 사본 간
동작이 미세하게 발산했다(`|| true` 유무, 리다이렉션 차이). 알림 정책(재시도,
timeout, 실패 로깅)을 바꿀 때 여러 곳을 lockstep 수정해야 하고 하나라도
빠지면 조용히 틀어진다. `modules/shared`에 얇은 전송 함수를 두고 수렴시킨다.

## Current state

재구현 지점 (grep `api.pushover.net` 실측, service-lib 제외):

| 위치 | 플랫폼 | 형태 |
|------|--------|------|
| `modules/nixos/programs/smartd.nix:64` 부근 | NixOS | nix 인라인 셸, 자체 curl |
| `modules/darwin/programs/opnix-rotate.nix:75` 부근 | darwin | nix 인라인 셸, 자체 curl |
| `modules/darwin/programs/folder-actions/files/scripts/_folder-actions-lib.sh:44-49` | darwin | 셸 lib 함수 `notify_failure` 내부 |
| `modules/darwin/programs/folder-actions/files/scripts/upload-immich.sh:68-74` | darwin | 자체 `send_notification` |
| `modules/shared/programs/shell/default.nix:404` 부근 | shared | zsh `push` 함수 |
| `modules/nixos/programs/docker/karakeep-singlefile-bridge/files/singlefile-bridge.py:202` | NixOS | **Python** — 이번 통합 대상 아님 |

공유 헬퍼 (exemplar, 읽기 전용 기준):

- `modules/nixos/lib/service-lib.sh:12,31` — `send_notification` /
  `send_notification_strict`. NixOS 모듈들이
  `serviceLib = import ../../lib/service-lib.nix { inherit pkgs; }` +
  `SERVICE_LIB` env로 주입받아 `source "$SERVICE_LIB"`로 쓴다
  (예: `modules/nixos/programs/docker/karakeep-notify.nix`).

발췌 — `_folder-actions-lib.sh:44-49` (darwin 사본의 형태):

```bash
            --form-string "title=${title}" \
            --form-string "message=${message}" \
            --form-string "priority=${priority}" \
            https://api.pushover.net/1/messages.json > /dev/null 2>&1; then
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 재구현 지점 전수 | `grep -rn "api.pushover.net" --include="*.sh" --include="*.nix" modules/ \| grep -v service-lib` | 위 표와 일치 (Python 제외 5곳) |
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| Flake | `nix flake check --no-build --all-systems` | exit 0 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

`nrs` 실 배포와 실제 알림 왕복 확인은 운영자 후속 (macOS 쪽은 Mac에서의
`nrs`도 필요 — darwin 모듈 포함이므로).

## Scope

**In scope**:
- `modules/shared/lib/pushover.sh` (신규 — 위치는 Step 1에서 기존 shared 구조
  확인 후 확정; `modules/shared/scripts/lib/`가 이미 쓰이면 거기에)
- 위 표의 셸/nix 5곳 (Python 제외)
- 신규 테스트 1개 (suite)

**Out of scope** (do NOT touch):
- `singlefile-bridge.py`의 `send_pushover` — Python이라 셸 헬퍼 공유가 불가.
  통합하려면 언어 경계를 넘는 설계가 필요한데 사본 1개 제거에 과하다 (YAGNI).
- `modules/nixos/lib/service-lib.sh`의 **인터페이스 변경** — NixOS 호출자
  다수가 의존한다. service-lib가 새 shared 헬퍼를 내부적으로 쓰도록 바꾸는
  것도 이번 범위 밖 (Maintenance notes).
- 각 호출부의 알림 **정책**(priority 값, 메시지 문구, 실패 시 계속 진행 여부)
  — 현행 유지. `|| true`가 있던 곳은 그대로 `|| true`.

## Git workflow

- Branch: `advisor/011-pushover-shared-helper`
- Commit 예: `refactor(shared): Pushover 전송 공용 헬퍼 추출 + 5개 사본 수렴`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 헬퍼 배치 위치 확정 및 작성

`modules/shared/` 아래 기존 lib 배치를 확인한다
(`ls modules/shared/scripts/lib/ modules/shared/lib 2>/dev/null`). 기존 관례
위치에 `pushover.sh`를 만든다. 인터페이스 (인자 기반, env 전제 없음):

```bash
# pushover_send <cred_file> <title> <message> <priority> [sound]
# cred_file: PUSHOVER_TOKEN/PUSHOVER_USER를 export하는 셸 파일
# sound: 선택 5번째 인자 — 주어지면 --form-string "sound=<값>"을 추가 전송,
#        생략하면 sound 필드 자체를 보내지 않음 (기존 4필드 사본들과 동일)
# 반환: 전송 성공 0, cred 부재/전송 실패 1 (호출부가 || true로 정책 결정)
pushover_send() { ... }
```

(2026-07-06 executor 실측 반영: `upload-immich.sh`의 `send_notification`은
`sound` 4번째 인자를 항상 전송한다 — 기본 `"none"`, 실패 알림은 `"falling"`.
선택 인자 없이는 이 사본이 수렴되지 않아 인터페이스를 위처럼 확장했다.)

내부는 기존 사본들의 공통형(`curl --form-string token/user/title/message/priority`,
`--max-time` 포함 여부는 사본들을 비교해 가장 방어적인 형태로)을 따른다.

**Verify**: `shellcheck -S warning <신규 파일>` → exit 0

### Step 2: 호출부를 하나씩 전환 (한 곳씩 검증)

각 호출부마다: 헬퍼를 source(셸 파일) 또는 스크립트에 배선(nix 인라인 셸이면
`builtins.readFile`/`source` 가능한 형태로 주입 — 해당 모듈이 이미 스크립트를
어떻게 구성하는지 따름)하고 curl 블록을 `pushover_send` 호출로 교체한다.
전환 순서: ① `_folder-actions-lib.sh` ② `upload-immich.sh` ③ `smartd.nix`
④ `opnix-rotate.nix` ⑤ `shell/default.nix`의 `push`.

②의 주의: `upload-immich.sh`는 호출부들이 `send_notification "제목" "메시지"
"priority" "sound"` 형태로 sound 정책("none"/"falling")을 쓰고 있다 —
`pushover_send`의 5번째 인자로 그대로 전달해 기존 알림 정책(우선순위·소리)을
바이트 단위로 보존하라. 나머지 4곳은 sound 인자 없이 전환한다 (기존에도
sound 필드를 보내지 않았으므로).

각 전환 후 **Verify**: `bash tests/run-eval-tests.sh` → 통과 (nix 파일 전환 시),
`shellcheck` (셸 파일 전환 시).

### Step 3: 헬퍼 단위 테스트

`tests/suites/`에 신규 suite: `curl` 스텁으로 ① cred 파일 부재 → return 1,
curl 미호출 ② 정상 cred → curl 인자에 title/message/priority 반영
③ curl 실패 → return 1을 assert.

**Verify**: suite 통과 + `bash tests/run-all-tests.sh` → exit 0 +
`grep -rn "api.pushover.net" --include="*.sh" --include="*.nix" modules/ | grep -v "service-lib\|pushover.sh"` → 0건

## Test plan

Step 3이 test plan. 구조 모델: `tests/suites/fragile-hardcoding-guard.sh`.

## Done criteria

- [ ] 신규 헬퍼 파일 존재 + shellcheck 통과
- [ ] `grep -rn "api.pushover.net" --include="*.sh" --include="*.nix" modules/ | grep -v "service-lib\|pushover"` → 0건
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] 최종 보고에 "운영자 후속: 양 플랫폼 `nrs` 후 알림 1회 실측
  (예: Mac `push test`, MiniPC smartd 테스트 알림)" 명시
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 어떤 호출부의 curl 블록이 공통형과 달라(추가 필드, 다른 엔드포인트) 헬퍼
  인터페이스로 수렴이 안 된다 — 그 사본은 남기고 사유를 보고.
- darwin 모듈에서 shared 파일을 참조하는 기존 패턴이 없다(경로 참조 선례
  부재) — 임의 배선 방식을 발명하지 말고 후보 방식을 보고.

## Maintenance notes

- 후속 후보(이번 범위 밖): `service-lib.sh`의 `send_notification`이 내부에서
  이 헬퍼를 쓰게 하면 사본이 완전히 1개로 수렴한다 — NixOS 호출자 전체 회귀
  확인이 필요해 별도 작업.
- 새 알림 지점을 만들 때는 이 헬퍼를 쓰는 것이 관례가 된다 — 리뷰어는 새
  `api.pushover.net` 직접 curl이 diff에 등장하면 반려.
