# 1Password 운영 (SA 발급 / rotation / op CLI / gh 무인 / SSH device key)

agenix(.age 정적 시크릿)와 별개로, 1Password를 동적 시크릿(github-pat) / SSH device key / Service Account(SA) token의 저장소로 사용한다. 본 문서는 1Password 운영 절차 본문을 담당하며, routing matrix와 통합 inventory는 SKILL.md에 있다.

평문 금지: SA token / PAT(`ghp_`, `github_pat_`) / SSH private key / 공개키 본체는 이 문서에 포함하지 않는다. item 이름·vault·경로·comment 식별자만 기록한다.

## Vault 접근 경계

vault 라우팅(Automation / SSH / Personal)의 정본은 SKILL.md의 Routing Matrix다. 여기서는 1Password에 실제 보관되는 항목과 SA 접근 경계만 정리한다.

- `Automation` vault item: `github-pat`. (1Password Service Account는 Automation read-only로 `github-pat`을 읽는 주체이며, SA token material 자체는 agenix `.age`에 보관된다 — vault item 아님.)
- `SSH` vault(#874로 Automation에서 격리): `mac-ssh`(SSH agent), `emergency-ssh` backup copy(ssh key comment는 `emergency-fallback`). `mobile-ssh`는 1Password가 아니라 Termius keychain에 보관되므로 SSH vault에 없다.
- SA token(Automation read-only)은 SSH vault 접근 불가 → blast radius가 github-pat 한정으로 축소된다(#874).

SSOT: `libraries/constants.nix`의 `onePassword.vaults` / `onePassword.account` / `sshDeviceKeys`.

## Service Account(SA) 발급 — Mac / MiniPC 격리 SA 2개

호스트별로 별개 SA를 발급해 blast radius를 분리한다 (둘 다 Automation read-only).

- MiniPC SA token → `opnix-service-account-token.age`로 agenix 재암호화 (recipient=`minipcHostOnly`, host key `/etc/ssh/ssh_host_ed25519_key`) → `/run/agenix/opnix-service-account-token` (`root:onepassword-secrets`, `0640`).
- Mac SA token → `opnix-service-account-token-mac.age`로 재암호화 (recipient=`[constants.sshKeys.macbook]`, Mac user 키 단독, work role 미배포) → `~/.config/op/sa-token-mac` (`0400`, `isDarwin && hostType==personal` 한정).
- SA는 SSH vault 접근 불가 → SA `op read` 대상은 `op://Automation/github-pat/token` 한정.

host key recipient(`minipcHostOnly`) .age의 rekey는 host private key가 없는 Mac에서 실패하므로, MiniPC/root에서 user key와 host key를 둘 다 `-i`로 넘겨 rekey한다 (secrets.nix 헤더 주석 참조).

SSOT: `secrets/secrets.nix`(L67-78), `modules/shared/programs/secrets/default.nix`, `modules/nixos/programs/opnix/default.nix`.

## SA token 90일 rotation 만료 알림 — Mac launchd + MiniPC systemd 양쪽

1Password Individual은 SA 자동 만료를 미지원하므로, 평문 ISO date expiry record(.txt)를 SSOT로 운용한다 (op CLI 만료 조회 미지원 대체). SA 재발급 시 해당 `.txt`를 갱신한다.

| 호스트 | 메커니즘 | expiry record (SSOT) |
|--------|----------|----------------------|
| MiniPC (NixOS) | `systemd.services.opnix-rotate-check` (oneshot) + timer (`OnCalendar=weekly`, `Persistent=true`, `RandomizedDelaySec=1h`), `homeserver.opnix.enable` 게이팅 | `/etc/opnix-service-account-expiry` = `secrets/opnix-service-account-expiry.txt` |
| Mac | `launchd.agents.opnix-rotate-mac` (user agent, `StartCalendarInterval` Weekday=1 10:00, `RunAtLoad=false`, Persistent 미지원), `hostType==personal` 한정 | `~/.config/op/sa-expiry-mac` = `secrets/opnix-service-account-expiry-mac.txt` |

공통 동작: `warnDays=14` (남은 일수 ≤14면 알림, <0이면 priority=1). ISO-8601 `YYYY-MM-DD` 정규식 검증 후 GNU `date -d`로 epoch 변환 (BSD date 회피 — Mac은 `runtimeInputs`에 coreutils). MiniPC는 `pushover-system-monitor` cred + service-lib `send_notification_strict`, Mac은 `pushover/share` cred로 `curl api.pushover.net` 직접 호출.

관련 PR: 90일 rotation 도입 #875.

SSOT: `modules/darwin/programs/opnix-rotate.nix`, `modules/nixos/programs/opnix-rotate.nix`, `secrets/opnix-service-account-expiry{,-mac}.txt`.

## Mac 무인 gh 인증 (방식 B: SA token → github-pat per-user temp 캐시)

`gh-pat-mac` (`pkgs.writeShellScriptBin`, PATH 실행 파일):

1. `getconf DARWIN_USER_TEMP_DIR`로 temp dir 획득 (absolute `/` 검증, 아니면 fail-closed `exit 0`).
2. 캐시 경로 `$_tmp/gh-pat-$(id -u)`.
3. 캐시 존재 & 720분(12h) 이내 & `ghp_`/`github_pat_` prefix면 캐시 반환.
4. 아니면 `~/.config/op/sa-token-mac`을 읽어 `OP_SERVICE_ACCOUNT_TOKEN` env로만 전달해 `op read --no-newline op://Automation/github-pat/token` (SA token은 셸 env에 상주시키지 않음).
5. prefix 검증 통과 시 `umask 077`로 atomic `mv` (디렉토리 `0700` / 파일 `0600`, 재부팅 시 휘발).
6. stdout 출력.

`gh-auth` (`writeShellScriptBin`): `GH_TOKEN` 미설정 시 `gh-pat-mac`으로 발급·export 후 실제 `gh` exec (발급 실패해도 graceful). `home.shellAliases.gh="gh-auth"`로 라우팅 — shell snapshot이 캡처해 LLM 자동화 셸까지 커버한다(#876).

범위 한계 (F4): rc를 읽지 않는 CI류 `bash -c`는 범위 밖이고, homebrew `gh`가 PATH 최우선이면 shim이 무효가 될 수 있다. op plugin의 gh alias source는 회귀 차단을 위해 제거됨.

SSOT: `modules/shared/programs/shell/darwin.nix`.

### c/codex 런처 — interactive 세션 GH_TOKEN 주입

`mkOrder 1600` 블록의 `c()`/`codex()` 함수(interactive `.zshrc` 전용)는 세션 시작 시 `gh-pat-mac`으로 github-pat을 발급해 성공 시에만 `GH_TOKEN`을 프로세스 한정으로 export한 뒤 런처를 실행한다. `gh` 자체 라우팅은 `gh-auth` wrapper가 별도 담당한다.

## op CLI / op read — vault·item 라우팅

- Mac: `onePassword.account` = 개인 sign-in 도메인이 biometric unlock 경로 전용 account로 고정 (멀티 계정 환경).
- MiniPC: op CLI를 직접 쓰지 않고 opnix(Go SDK)가 `op://Automation/github-pat`을 `/run/opnix/<user>/github-pat`으로 materialize한다(`OP_SERVICE_ACCOUNT_TOKEN`이 account 결정). 아래 라우팅은 Mac/수동 op CLI 경로 기준.
- 라우팅: 자동화/시스템 토큰 = `Automation` vault(`github-pat` 등), 디바이스 SSH 키 = `SSH` vault(`mac-ssh`/`emergency-ssh`; `mobile-ssh`는 Termius keychain이라 제외), 개인 항목 = `Personal` vault. SA(Automation read-only)는 SSH vault `op read` 차단.

### op_get 해석 순서 (SA-first, 무인 폴백)

`op_get <name> <field> [<vault>]`(zsh initContent, `modules/shared/programs/shell/default.nix`)는 3단계로 해석한다:

1. `OP_SERVICE_ACCOUNT_TOKEN` env가 이미 있으면 그대로 `op read` (SA env가 account를 결정 — `--account` 미전달).
2. Mac SA token(`~/.config/op/sa-token-mac`, 방식 B #873 재사용)이 읽히면 SA로 `op read` — biometric 0회, 데스크탑 앱·잠금·원격 여부 무관(SaaS 직행). SA 도달 범위(Automation read-only) 밖 vault(Personal/SSH)는 권한 오류로 즉시 실패하고 3단계로 넘어간다. LLM이 프롬프트 없이 읽어야 할 시크릿은 Automation vault에 두면 이 경로를 탄다.
3. biometric(데스크탑 앱 연동) — 대화형 전용. stdin·stderr 모두 non-TTY면 무인으로 판정하고 시도 없이 명확히 실패한다(fail-fast) — 비대화형 `op read`는 Mac 화면에만 뜨는 승인을 기다리며 무한 hang하기 때문(#1041). 한계: PTY를 받은 자동화는 TTY 판정상 대화형으로 보인다.

회귀 핀: `tests/eval-tests.nix` Test D18 (SA 폴백 배선 + 비대화형 biometric 차단 가드).

SSOT: `libraries/constants.nix`(onePassword), `modules/shared/programs/shell/default.nix`(op_get), `modules/shared/programs/shell/darwin.nix`(gh 무인).

## SSH device key 운영 (#866 닫힘 — mobile-ssh 단일 공유 키)

`constants.sshDeviceKeys` 3종 — `macSsh`(comment `mac-ssh`), `mobile`(comment `mobile-ssh`), `emergency`(comment `emergency-fallback`) — 은 MiniPC `authorized_keys` 등록용 공개키이며(`mac-ssh`만 추가로 Mac SSH agent에 노출), agenix 복호화 recipient(`sshKeys`)와는 분리된 개념이다.

- iPhone/iPad는 Termius keychain 동기화로 디바이스별 격리가 불성립 → `iphone-ssh`/`ipad-ssh` 분리 키를 폐기하고 단일 `mobile-ssh` 공유 키로 통합(#866 닫힘). 운영 모델: `mobile-ssh` 공유 키 rotate + Termius 디바이스 해제.
- `mac-ssh` private key는 1Password SSH vault에 보관(#874로 Automation에서 격리), `agent.toml`이 SSH vault에 바인딩되어 SA token blast radius가 축소된다(SA는 SSH vault `op read` 차단). `mobile-ssh`는 1Password가 아니라 Termius keychain에만 보관된다(공개키만 agenix `sshDeviceKeys`로 MiniPC authorized_keys 등록).
- Emergency fallback 운영 키는 `~/.ssh/emergency_ed25519` (`IdentityAgent=none` 독립 fallback), 1Password backup copy는 SSH vault에 보관.

SSOT: `libraries/constants.nix`(sshDeviceKeys), `modules/darwin/programs/ssh/default.nix`, `secrets/secrets.nix`.
