---
name: managing-secrets
description: |
  Manage encrypted secrets with agenix (.age) and 1Password (op CLI, Service Account token, SSH/Automation vault).
  Covers .age re-encryption, decryption failures, github-pat 무인 gh 인증, SA token 90일 rotation, SSH device key.
  Trigger: '시크릿', '암호화', '복호화', 'agenix', 'secrets.nix', 'age key', '.age', '토큰 추가',
  're-encrypt', '/run/agenix', '1Password', '1password', 'op CLI', 'op_get', 'opnix', 'service account token', 'SA token',
  'Automation vault', 'SSH vault', 'github-pat', 'gh 무인 인증', '90일 rotation', 'op read', 'biometric unlock',
  'SSH device key', 'mobile-ssh', 'Termius'.
---

# Secret 관리 (agenix)

agenix를 사용한 `.age` 파일 기반 secret 암호화/배포 가이드.

## Known Issues

Claude Code에서 `agenix -e` 실패 (`/dev/stdin` 에러)
- `agenix -e`는 interactive 에디터를 사용하므로 non-interactive 환경에서 실패
- 해결: `age` CLI pipe 패턴 사용 (아래 "Secret 추가/수정" 참조)
- 상세: [references/troubleshooting.md](references/troubleshooting.md)

## 빠른 참조

### 설정 파일 구조

| 파일 | 역할 |
|------|------|
| `secrets/secrets.nix` | secret 선언 + 암호화 대상 공개키 (constants.nix import) |
| `secrets/<name>.age` | 암호화된 secret 파일 (Git 추적) |
| `libraries/constants.nix` | SSH 공개키 단일 소스 (secrets.nix에서 참조) |
| `modules/shared/programs/secrets/default.nix` | 배포 경로 + 권한 설정 (Home Manager 레벨) |
| `modules/nixos/programs/docker/immich.nix` | 시스템 레벨 시크릿 (NixOS agenix) |

### agenix 레벨 구분

| 레벨 | 설정 위치 | 기본 배포 경로 | 용도 |
|------|----------|---------------|------|
| Home Manager | `modules/shared/programs/secrets/default.nix` | 사용자 지정 경로 (`~/.config/...`) | Pushover, pane-note 등 사용자 레벨 |
| NixOS 시스템 | 각 서비스 모듈 (`immich.nix`, `smartd.nix`, `temp-monitor/` 등) | `/run/agenix/<secret-name>` | immich-db-password, pushover-system-monitor 등 시스템 서비스 |

두 레벨이 공존하며, NixOS 시스템 레벨은 `flake.nix`에서 `inputs.agenix.nixosModules.default`로 활성화.
서비스 모듈에서는 하드코딩 대신 `config.age.secrets.<name>.path`를 참조해 실제 경로를 사용한다.

Secret 형식은 shell 변수 (`KEY=value`)로, 사용처에서 `source`로 로드한다.
배포 권한은 기본 `0400` mode이며, agenix가 복호화하여 지정 경로에 배치한다 (예외: opnix SA token `.age`는 `root:onepassword-secrets` `0640` — inventory 참조).

### Routing Matrix (사용주체 × Storage × Vault × Tag)

agenix(.age 정적)와 1Password(동적 github-pat / SSH device key / SA token)가 공존한다. 사용주체별 라우팅:

| 사용주체 | Storage | Vault | Tag / 식별자 |
|----------|---------|-------|--------------|
| Mac 무인 gh 인증 (gh-pat-mac → github-pat 캐시) | 1Password | Automation | `github-pat` (`op://Automation/github-pat/token`) |
| Mac SA token (gh-pat-mac이 `OP_SERVICE_ACCOUNT_TOKEN`으로 사용) | agenix → 1Password SA | Automation (read-only SA) | service account token (mac) |
| MiniPC opnix (부팅 oneshot → `/run/opnix/<user>/github-pat` materialize) | 1Password | Automation | `github-pat` (`op://Automation/github-pat/token`) |
| MiniPC SA token (opnix tokenFile, host key 복호화) | agenix → 1Password SA | Automation (read-only SA) | service account token (minipc) |
| Mac SSH agent + MiniPC authorized_keys 등록 (`mac-ssh`) | 1Password | SSH | ssh device key — SSH vault 격리 |
| Emergency fallback SSH (`~/.ssh/emergency_ed25519` + backup copy) | 1Password | SSH | ssh device key (`emergency-ssh`) — SSH vault 격리 |
| iPhone/iPad (Termius 공유 단일 키) | Termius keychain | — | ssh device key (`mobile-ssh`) — 단일 공유 키, 1Password 미보관 |
| agenix .age 시크릿 (Mac+MiniPC home / MiniPC service) | agenix | — | recipient group (allHosts / minipcOnly / minipcHostOnly / macbook) |

핵심 원칙:
- SA token = Automation read-only → SSH vault 접근 불가. blast radius를 github-pat 한정으로 축소.
- agenix는 recipient group으로 호스트 노출을 통제: `allHosts` / `minipcOnly`(서비스) / `minipcHostOnly`(host key 전용 부팅 의존) / `macbook`(Mac user 키 단독).
- 1Password 운영 절차 본문(SA 발급 / rotation / op CLI / gh 무인 / SSH device key)은 [references/1password.md](references/1password.md) 참조.

### 통합 Secret Inventory

agenix `.age` 18개(디스크 실측) + 1Password 항목(github-pat, SSH device key) + 1Password Service Account(token material은 agenix `.age` 보관)를 단일 표로 통합. 이 표는 빠른 참조용 스냅샷이며 SSOT가 아니다 — 값이 충돌하면 코드(`secrets/secrets.nix` recipient, `libraries/constants.nix` vault/sshDeviceKeys, HM home 경로는 `modules/shared/programs/secrets/default.nix` · NixOS `/run/agenix` 서비스 시크릿은 `modules/nixos/programs/` 하위 service module)을 우선한다. secret 추가/변경 시 코드를 먼저 갱신한 뒤 이 표를 동기화한다. recipient(복호화 가능 호스트)와 실제 배포 호스트는 다를 수 있다.

| Name | Storage | Vault | 배포경로·위치 | 소비처 | recipient |
|------|---------|-------|---------------|--------|-----------|
| `pushover-share.age` | agenix | — | `~/.config/pushover/share` (Mac+MiniPC home) | sharing-text 수동 push; opnix-rotate-mac 만료 알림 `PUSHOVER_FILE` source | allHosts |
| `pane-note-links.age` | agenix | — | `~/.config/pane-note/links.txt` (Mac+MiniPC home) | pane-note.sh 새 노트 Links 섹션 | allHosts |
| `immich-db-password.age` | agenix | — | `/run/agenix/immich-db-password` (MiniPC) | immich.nix dbPasswordPath → PostgreSQL | minipcOnly |
| `immich-api-key.age` | agenix | — | Mac `~/.config/immich/api-key` / MiniPC `/run/agenix/immich-api-key` | immich-update·immich-cleanup FolderAction upload | allHosts |
| `pushover-immich.age` | agenix | — | Mac `~/.config/pushover/immich` / MiniPC `/run/agenix/pushover-immich` | immich-update·cleanup·backup 알림 | allHosts |
| `pushover-folder-actions.age` | agenix | — | `~/.config/pushover/folder-actions` (Mac 전용) | macOS FolderActions (compress-video / convert-video-to-gif / rename-asset / compress-rar) 실패 알림 | macbook 단독(인라인) |
| `shottr-license.age` | agenix | — | `~/.config/shottr/license` (Mac home, Darwin-only HM 배포) | Shottr 라이센스 (kc-license + kc-vault pre-fill) | allHosts (복호화 recipient — 배포는 Mac만) |
| `copyparty-password.age` | agenix | — | `/run/agenix/copyparty-password` (MiniPC) | copyparty.nix passwordPath → 파일서버 비밀번호 | minipcOnly |
| `cloudflare-dns-api-token.age` | agenix | — | `/run/agenix/cloudflare-dns-api-token` (MiniPC) | caddy.nix → Caddy HTTPS(DNS-01) 인증서 발급 | minipcOnly |
| `pushover-uptime-kuma.age` | agenix | — | `/run/agenix/pushover-uptime-kuma` (MiniPC) | uptime-kuma-update 알림 | minipcOnly |
| `pushover-copyparty.age` | agenix | — | `/run/agenix/pushover-copyparty` (MiniPC) | copyparty-update 알림 | minipcOnly |
| `karakeep-nextauth-secret.age` | agenix | — | `/run/agenix/karakeep-nextauth-secret` (MiniPC) | karakeep.nix nextauthSecretPath → NextAuth secret | minipcOnly |
| `karakeep-meili-master-key.age` | agenix | — | `/run/agenix/karakeep-meili-master-key` (MiniPC) | karakeep.nix meiliMasterKeyPath → Meilisearch master key | minipcOnly |
| `karakeep-openai-key.age` | agenix | — | `/run/agenix/karakeep-openai-key` (MiniPC) | karakeep.nix openaiKeyPath → AI 태깅 OpenAI 키 | allHosts |
| `pushover-karakeep.age` | agenix | — | `/run/agenix/pushover-karakeep` (MiniPC) | karakeep-update·notify·singlefile-bridge·backup·fallback-sync·log-monitor (다중 모듈 merge) | allHosts |
| `pushover-system-monitor.age` | agenix | — | `/run/agenix/pushover-system-monitor` (MiniPC) | smartd·temp-monitor·smoke-test·opnix-rotate(MiniPC) 하드웨어/SMART/온도/SA rotation 알림 (다중 모듈 merge) | minipcOnly |
| `opnix-service-account-token.age` | agenix → 1Password SA | Automation (SA 접근 vault) | `/run/agenix/opnix-service-account-token` (`root:onepassword-secrets`, 0640, MiniPC) | opnix tokenFile → 부팅 oneshot이 `op://Automation/github-pat/token`을 `/run/opnix/<user>/github-pat` tmpfs로 materialize → nixos.nix gh wrapper가 GH_TOKEN 소비 | minipcHostOnly (host key 복호화) |
| `opnix-service-account-token-mac.age` | agenix → 1Password SA | Automation (SA 접근 vault) | `~/.config/op/sa-token-mac` (agenix home-manager, 0400, `isDarwin && hostType==personal`) | darwin.nix gh-pat-mac이 `OP_SERVICE_ACCOUNT_TOKEN`으로 `op read op://Automation/github-pat/token` → temp 캐시 → gh-auth/c/codex 런처가 GH_TOKEN 주입. MiniPC host-key SA와 별개 격리 SA | macbook (Mac user 로그인 키 단독, work role 미배포) |
| `github-pat` (1Password 항목) | 1Password | Automation | `op://Automation/github-pat/token` | Mac: gh-pat-mac이 SA token으로 `op read` → temp 캐시. MiniPC: opnix가 tmpfs로 materialize. SA token이 읽는 실제 PAT 항목 | — |
| `mac-ssh` (1Password 항목) | 1Password | SSH | SSH vault item (comment `mac-ssh`, `constants.sshDeviceKeys.macSsh`) | Mac SSH agent(agent.toml이 SSH vault 노출) + MiniPC authorized_keys 등록. Automation→SSH vault 격리 | — |
| `mobile-ssh` (디바이스 키) | Termius keychain | — | Termius keychain 보관 (iPhone·iPad 동기화 공유); 공개키만 `constants.sshDeviceKeys.mobile` | iPhone/iPad Termius 공유 단일 키(디바이스별 격리 불성립). MiniPC + personal Mac authorized_keys 등록용(work Mac 미배포). 1Password 미보관 | — |
| `emergency-ssh` (1Password 항목) | 1Password | SSH | SSH vault item (backup copy; ssh key comment `emergency-fallback`); 운영 키는 `~/.ssh/emergency_ed25519` (`IdentityAgent=none` 독립 fallback) | 긴급 fallback SSH 접속. 1Password backup copy가 SSH vault 보관. Automation→SSH vault 격리 | — |
| SA token (mac) | 1Password | Automation (read-only) | 1Password Service Account; token은 `opnix-service-account-token-mac.age`로 암호화되어 `~/.config/op/sa-token-mac` 배포 | Mac gh-pat-mac이 github-pat 발급 시 사용. blast radius=Automation read-only(SSH vault 접근 불가). 90일 cadence rotation (만료 record†) | — |
| SA token (minipc) | 1Password | Automation (read-only) | 1Password Service Account; token은 `opnix-service-account-token.age`로 암호화되어 `/run/agenix/opnix-service-account-token` 배포 | MiniPC opnix가 github-pat materialize 시 사용. blast radius=Automation read-only. 90일 cadence rotation (만료 record†). Mac SA와 별개 발급 격리 SA | — |

† `secrets/opnix-service-account-expiry.txt`(MiniPC) / `secrets/opnix-service-account-expiry-mac.txt`(Mac)는 평문 ISO date record(.age 아님). 1Password Individual SA 자동 만료 미지원 + op CLI 만료 조회 미지원 대체. rotation 운영은 [references/1password.md](references/1password.md) 참조.

상세는 `secrets/secrets.nix`(.age) + `libraries/constants.nix`(1Password) 참조.

### Secret 추가/수정

추가 워크플로 (3단계):

1. `secrets/secrets.nix`에 선언 추가
2. `.age` 파일 생성 (암호화 방법은 [references/workflows.md](references/workflows.md) 참조)
3. 배포 경로 + 권한 설정 (HM home secret은 `modules/shared/programs/secrets/default.nix`, NixOS 서비스 secret은 해당 service module, opnix SA token은 opnix module)

수정 워크플로:

1. 기존 값 확인 (복호화 방법은 [references/workflows.md](references/workflows.md) 참조)
2. 새 내용으로 재암호화하여 `.age` 파일 덮어쓰기

호스트 추가: 새 호스트의 secret 접근이 필요한 경우 [references/workflows.md](references/workflows.md) 참조.

### Shottr 라이센스 pre-fill (agenix)

Shottr 라이센스 키를 agenix로 암호화하여 `nrs` 실행 시 전용 CFPreferences writer의 stdin으로
pre-fill합니다.

Secret 파일 형식:
```
KC_LICENSE=<base64 encoded license>
KC_VAULT=<base64 encoded vault>
```

`.age` 파일 생성/갱신:
```bash
./scripts/secrets/refresh-shottr-license.sh secrets/shottr-license.age \
  nix shell nixpkgs#age -c age \
  -r "ssh-ed25519 <macbook-pubkey>" \
  -r "ssh-ed25519 <minipc-pubkey>"
```

두 read 중 하나라도 실패하거나 30초 deadline을 넘으면 age 출력을 시작하지 않는 fail-closed
절차다. tracked refresh helper는 첫 명령에서 inherited `xtrace`를 끄고, inherited `allexport`와
기존 export 속성을 제거하므로 평문은 터미널 trace나 timeout/helper/age의 child environment로
전달되지 않는다. atomic helper는 stdin을 age에 전달하고 같은 디렉터리의 mode `0600` 임시 파일에
성공한 뒤에만 원자적으로 교체하므로 실패 시 기존
암호문을 보존한다. 실제 값은 터미널에 출력하지 않는다. HM activation은 `~/.config/shottr/license`에서 값을
읽고, 전용 CFPreferences writer의 stdin으로만 전달한다. 라이센스 값은 activation 프로세스의
명령행 인자나 timeout/writer child environment에 포함되지 않는다. AppData prompt로 timeout되면
후속 Shottr write만 생략하고 나머지 activation을 계속한다.
새 맥북에서 Shottr 실행 후 Activate 버튼 1회 클릭으로 활성화됩니다.

> Shottr 크레덴셜 구조, deadline, action-time 앱 종료 규칙은
> [managing-macos의 Shottr 상세 runbook](../managing-macos/references/shottr-credentials.md)을 따른다.

## 자주 발생하는 문제

1. `agenix -e`의 `/dev/stdin` 에러: non-interactive 환경에서 발생 → `age` CLI pipe 우회
2. 복호화 실패: SSH 키 불일치 또는 identity path 오류
3. 재암호화 누락: `secrets/secrets.nix`의 publicKeys 변경 후 `cd secrets && nix run github:ryantm/agenix -- -r` 미실행
4. 배포 후 파일 미생성: Home Manager agenix 서비스 상태 확인, `nrs` 재실행
5. macOS agenix crash loop (.tmp 잔류): `nrs`가 복호화 중인 agent를 kill → stale `.tmp` 파일이 다음 generation을 block. 예방 코드(`cleanupAgenixStaleGenerations`)가 `setupLaunchAgents` 전에 자동 정리 (삭제 전 `launchctl bootout`으로 활성 writer와 직렬화, rm 실패는 non-fatal)
6. macOS activation에서 시크릿 미발견: agenix는 `launchd.agents`로 복호화 → `setupLaunchAgents` 이후 + polling 필요
7. macOS agent 무한 재스폰 (exit 0인데 5~15초마다 재실행, stdout 로그 비대): upstream `KeepAlive.Crashed = false`의 launchd 의미론("non-crash 종료 시 재시작")이 원인 → `KeepAlive` override로 교정 완료 (`modules/shared/programs/secrets/default.nix`)

상세는 [references/troubleshooting.md](references/troubleshooting.md) 참조.

## Shell Plugin 확장 정책

추가 shell plugin 도입 조건 = (a) 도구 secret을 `.env`로 export하는 패턴이 2건 이상 OR (b) agenix 평문 노출 위험 보고 1건. 둘 중 하나를 충족할 때만 새 shell plugin을 도입한다 (SSOT: 확장 트리거 기준).

## 레퍼런스

- 1Password 운영 (SA 발급 / 90일 rotation / op CLI / gh 무인 / SSH device key / 1Password 함정 트러블슈팅): [references/1password.md](references/1password.md)
- 워크플로 상세 (암호화/복호화/호스트 추가): [references/workflows.md](references/workflows.md)
- 트러블슈팅 (agenix 계열): [references/troubleshooting.md](references/troubleshooting.md)
