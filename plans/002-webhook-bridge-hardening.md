# Plan 002: karakeep webhook 브리지를 비특권·sandbox·인증으로 하드닝한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/karakeep-notify.nix modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (실 배포 검증은 운영자 `nrs` 필요 — executor는 평가/빌드 검증까지)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/939

## Why this matters

karakeep-webhook-bridge는 이 호스트에서 **유일한 미인증 네트워크 리스너**인데,
최소 권한 원칙과 정반대로 배치되어 있다: socat이 바인드 주소 없이(=모든
인터페이스) 리슨하고, 방화벽이 `podman+` 인터페이스를 허용하며 `tailscale0`은
trusted interface라(`modules/nixos/programs/tailscale.nix:80`) **컨테이너망과
tailnet 전역 양쪽에서** 도달 가능하다. 요청 본문 검증은 없고 서비스는 root로
실행되며 sandbox는 `PrivateTmp`/`NoNewPrivileges`뿐이다. 신뢰 불가 웹 콘텐츠를
렌더링하는 headless Chrome이 같은 컨테이너망에 있으므로, 컨테이너 침해 시 이
엔드포인트로 알림 위조/스팸이 가능하고, root로 도는 bash/jq 파서의 어떤 결함도
root 권한으로 증폭된다. 같은 저장소의 다른 서비스(codex-remote-control)는 이미
강한 systemd hardening을 적용하고 있어, 이 서비스만 예외로 남아 있다.

## Current state

관련 파일과 역할:

- `modules/nixos/programs/docker/karakeep-notify.nix` — 수정 대상. socat 리스너
  systemd 서비스 + 방화벽 규칙 선언.
- `modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh` — 수정
  대상. socat `EXEC:` 핸들러 (stdin=HTTP 요청, stdout=HTTP 응답).
- `modules/nixos/options/homeserver.nix:121-128` — `karakeepNotify.enable`,
  `webhookPort`(기본 9999) 옵션 선언.
- `modules/nixos/programs/codex-remote-control.nix` — **hardening 패턴 exemplar**
  (읽기 전용). systemd sandbox 옵션들을 이 파일에서 확인해 같은 스타일로 적용.
- `tests/eval-tests.nix` — Nix 평가 테스트 (있는 그대로 통과 유지).

**현행 서비스 선언** — `karakeep-notify.nix:54-75` 부근:

```nix
systemd.services.karakeep-webhook-bridge = {
  description = "Karakeep webhook-to-Pushover bridge";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];

  unitConfig = {
    ConditionPathExists = pushoverCredPath;
  };

  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString cfg.webhookPort},reuseaddr,fork EXEC:${webhookBridgeScript}/bin/karakeep-webhook-bridge";
    Restart = "on-failure";
    RestartSec = "5s";
    PrivateTmp = true;
    NoNewPrivileges = true;
  };

  environment = {
    PUSHOVER_CRED_FILE = pushoverCredPath;
    SERVICE_LIB = "${serviceLib}";
  };
```

`pushoverCredPath = config.age.secrets.pushover-karakeep.path`이고 해당 시크릿은
`owner = "root"; mode = "0400";`으로 선언되어 있다(같은 파일 35-39행 부근).

**현행 방화벽** — `karakeep-notify.nix:44-49`:

```nix
networking.firewall.extraCommands = ''
  iptables -I nixos-fw 1 -i podman+ -p tcp --dport ${toString cfg.webhookPort} -j nixos-fw-accept
'';
```

**현행 브리지 스크립트** — `webhook-bridge.sh` 요지 (전문 45줄):

```bash
set -uo pipefail
# HTTP 헤더 읽기 (빈 줄까지 스킵) — content-length만 추출
# HTTP body 읽기: body=$(head -c "$content_length")
operation=$(printf '%s' "$body" | jq -r '.operation // empty' 2>/dev/null)
url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null)
if [ "$operation" = "crawled" ] && [ -n "$url" ]; then
  source "$PUSHOVER_CRED_FILE" || echo "WARN: ..." >&2
  source "$SERVICE_LIB" || echo "WARN: ..." >&2
  send_notification "Karakeep" "아카이브 완료: ${short_url}" 0 || true
fi
# HTTP 200 응답 (항상)
printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
```

**결정된 계약 (변경 금지)**: 이 핸들러는 항상 HTTP 200을 응답하고 `set -e`를
쓰지 않는다 — 이슈 #919에서 확정된 의도적 설계다. 인증 실패 시에도 흐름을 깨지
않는 방식(로그 + 알림 스킵 + 200 응답)을 유지해야 한다.

**Karakeep 쪽 연결**: Karakeep 컨테이너는 UI(Settings → Webhooks)에서
`http://host.containers.internal:<port>`로 등록해 호출한다
(`modules/nixos/programs/docker/karakeep.nix:165-167`의
`CRAWLER_ALLOWED_INTERNAL_HOSTNAMES = "host.containers.internal"` 주석 참조).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Nix 평가 검증 | `bash tests/run-eval-tests.sh` | 전체 통과 |
| Flake 검증 | `nix flake check --no-build --all-systems` | exit 0 |
| Nix 포맷 | `nixfmt --check modules/nixos/programs/docker/karakeep-notify.nix` | exit 0 |
| 셸 린트 | `shellcheck -S warning modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh` | exit 0 |
| 통합 테스트 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

**주의**: `nrs`(실제 시스템 적용)는 이 plan에서 실행하지 않는다 — 운영자 후속
작업이다. executor의 게이트는 평가/빌드/린트까지다.

## Scope

**In scope** (수정 가능한 파일):
- `modules/nixos/programs/docker/karakeep-notify.nix`
- `modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh`
- `modules/nixos/options/homeserver.nix` (옵션 추가가 필요한 경우만, karakeepNotify 블록 한정)
- `secrets/secrets.nix` + 신규 `.age` (Step 3에서 토큰 시크릿이 필요하다고 판정된 경우만 — 단, `.age` 암호화 생성은 운영자 개입 필요라 보통 STOP 대상)

**Out of scope** (do NOT touch):
- `modules/nixos/programs/docker/karakeep.nix` — Karakeep/Chrome 컨테이너 정의.
  네트워크 재구성(서브넷 고정, bind 제한)은 이번 범위가 아니다 (Maintenance notes 참조).
- `modules/nixos/lib/service-lib.sh` — 공유 알림 라이브러리.
- HTTP 200 응답 계약, `set -uo pipefail` 유지 — #919에서 결정된 사항.
- Caddy/방화벽의 다른 규칙.

## Git workflow

- Branch: `advisor/002-webhook-bridge-hardening`
- Commit 예: `fix(karakeep): webhook 브리지 비특권 유저 + systemd sandbox 하드닝`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 서비스를 비특권 유저로 전환하고 credential은 LoadCredential로 전달

`karakeep-notify.nix`의 `serviceConfig`를 수정한다:

1. `DynamicUser = true;` 추가.
2. root 소유 `0400` agenix 시크릿을 비특권 프로세스가 읽을 수 있도록
   `LoadCredential = [ "pushover:${pushoverCredPath}" ];`를 추가하고,
   `environment.PUSHOVER_CRED_FILE`을 `"%d/pushover"`로 교체한다
   (`%d`는 systemd credentials directory specifier — root가 읽어 서비스 유저에게
   전달하므로 `.age` 시크릿의 owner/mode는 그대로 둔다).
3. `unitConfig.ConditionPathExists = pushoverCredPath;`는 유지 (시크릿 부재 시
   기동 억제 — 기존 동작 보존).

**Verify**: `nixfmt --check modules/nixos/programs/docker/karakeep-notify.nix` → exit 0,
`bash tests/run-eval-tests.sh` → 통과

### Step 2: systemd sandbox를 codex-remote-control 수준으로 보강

`modules/nixos/programs/codex-remote-control.nix`를 열어 그 서비스의
`serviceConfig` sandbox 옵션들을 확인하고, 이 서비스 성격에 맞는 부분집합을
`karakeep-webhook-bridge`에 적용한다. 최소한 다음을 포함할 것:

```nix
ProtectSystem = "strict";
ProtectHome = true;
PrivateDevices = true;
ProtectKernelTunables = true;
ProtectKernelModules = true;
ProtectControlGroups = true;
RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
RestrictNamespaces = true;
LockPersonality = true;
```

이 서비스는 쓰기 경로가 전혀 없다(상태 파일 없음, stdout/stderr는 journald) —
`ReadWritePaths`는 추가하지 않는다. socat이 fork로 자식(브리지 스크립트)을
실행하므로 `RestrictAddressFamilies`에 `AF_UNIX`가 필요한지는 eval이 아닌 실
배포에서만 드러난다 — Maintenance notes에 운영자 확인 항목으로 남긴다.

**Verify**: `bash tests/run-eval-tests.sh` → 통과,
`nix flake check --no-build --all-systems` → exit 0

### Step 3: 브리지에 공유 시크릿(Bearer 토큰) 검증을 조사 후 조건부 추가

이 단계는 **조사 우선**이다:

1. Karakeep(현재 배포 버전은 `modules/nixos/programs/docker/karakeep.nix`의
   `image =` 태그로 확인)이 webhook 설정에서 인증 토큰(Authorization 헤더 등)을
   지원하는지 공식 문서(https://docs.karakeep.app)에서 확인한다.
2. **지원하는 경우**: `webhook-bridge.sh`의 헤더 파싱 루프(이미 `content-length`를
   대소문자 무시로 파싱한다)에 `authorization` 헤더 추출을 추가하고,
   `WEBHOOK_TOKEN_FILE` 환경 변수(존재 시)에서 읽은 기대 토큰과 비교해 불일치면
   `WARN` 로그 + 알림 스킵 후 **그대로 HTTP 200 응답**한다(200 계약 유지 —
   fail-open이 아니라 "알림만 억제"). 토큰 파일이 미설정이면 현행 무인증 동작을
   유지한다(하위 호환). Nix 쪽에는 `LoadCredential`로 토큰을 전달할 자리만
   마련한다 — 실제 토큰 `.age` 생성/Karakeep UI 등록은 운영자 절차이므로 plan
   보고서에 절차를 명시하고 끝낸다.
3. **지원하지 않는 경우**: 이 단계를 건너뛰고 그 사실을 최종 보고에 기록한다
   (Step 1-2의 하드닝만으로도 root 증폭 경로는 제거된다).

**Verify**:
`shellcheck -S warning modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh`
→ exit 0; 토큰 검증을 추가한 경우
`printf 'POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n' | bash modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh`
(PUSHOVER_CRED_FILE/SERVICE_LIB를 임시 스텁 파일로 설정) → 마지막 줄에
`HTTP/1.1 200 OK` 포함

### Step 4: 전체 게이트 통과 확인

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP (실패 0)

## Test plan

- 이 저장소의 셸 테스트 컨벤션: `tests/suites/*.sh`에 정의 전용(sourced) 테스트,
  `tests/lib/test-common.sh`의 `new_sandbox`/`fail`/`assert_contains` 헬퍼 사용.
  구조 패턴은 `tests/suites/fragile-hardcoding-guard.sh`(stdin JSON을 훅에 흘려
  stdout을 assert하는 소형 suite)를 모델로 삼는다.
- 신규 suite `tests/suites/webhook-bridge.sh`를 추가한다. 케이스:
  1. 정상 crawled 페이로드 → 응답 마지막에 `HTTP/1.1 200 OK`, 스텁
     `send_notification`이 호출됨(스텁이 마커 파일 기록).
  2. 비-crawled operation → 200 응답 + 알림 미호출.
  3. 본문이 JSON이 아님 → 200 응답 유지(계약), 알림 미호출.
  4. (Step 3을 구현한 경우) 잘못된 토큰 → 200 응답 + 알림 미호출 + stderr에 WARN.
  - `PUSHOVER_CRED_FILE`/`SERVICE_LIB`는 sandbox 내 스텁 파일로 주입한다
    (스크립트가 이미 env 주입 구조라 스텁이 쉽다).
- Verification: `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` → 신규 테스트 포함 전부 통과

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "DynamicUser" modules/nixos/programs/docker/karakeep-notify.nix` → 1건
- [ ] `grep -n "LoadCredential" modules/nixos/programs/docker/karakeep-notify.nix` → 1건
- [ ] `grep -n "ProtectSystem" modules/nixos/programs/docker/karakeep-notify.nix` → 1건
- [ ] `bash tests/run-eval-tests.sh` → exit 0
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` → exit 0 (webhook-bridge suite 포함)
- [ ] 최종 보고에 "운영자 후속: `nrs` 적용 후 Karakeep에서 페이지 1건 아카이브 → Pushover 알림 도착 확인" 명시
- [ ] `git status --porcelain`에 in-scope 외 파일 없음
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

Stop and report back (do not improvise) if:

- "Current state" 발췌와 실제 코드가 다르다.
- `codex-remote-control.nix`에 hardening 패턴이 없다(전제 오류 — exemplar 부재).
- `LoadCredential`+`DynamicUser` 조합이 eval 단계에서 에러를 낸다
  (NixOS 버전 호환 문제 가능 — 대안 설계로 improvise하지 말 것).
- Step 3에서 토큰 시크릿을 위해 `.age` 파일 생성이 필요해진다 — agenix 암호화는
  운영자 키가 필요하므로 자리(옵션/코드)만 만들고 절차를 보고.
- HTTP 200 계약을 깨지 않고는 요구사항을 구현할 수 없다고 판단될 때.

## Maintenance notes

- **운영자 확인 필수**: `nrs` 적용 후 실제 아카이브 이벤트로 알림 경로 왕복을
  확인해야 한다. sandbox가 과하게 조이면(예: `RestrictAddressFamilies`에
  `AF_UNIX` 누락으로 socat/journald 상호작용 실패) 알림이 조용히 죽는다 —
  `journalctl -u karakeep-webhook-bridge -f`로 확인.
- **후속 (이번 범위 밖)**: socat `bind=` 제한. `host.containers.internal`이
  가리키는 게이트웨이 IP는 podman 네트워크 서브넷 고정이 선행돼야 안정적이므로
  (karakeep-network가 명시적 `--subnet` 없이 생성됨), 네트워크 재생성이 필요한
  운영 개입과 함께 별도로 다룬다. 그때 `libraries/constants.nix`에 서브넷 상수를
  추가하는 것이 이 저장소의 상수 관리 규칙이다.
- 이 서비스의 위협 모델 요약(리뷰어용): 도달 표면 = podman 브리지 + tailnet
  (tailscale0 trusted). Step 1-2는 침해 시 증폭(root)을 제거하고, Step 3은 위조
  요청을 억제한다. 둘은 독립적 방어층이다.
