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

1Password Individual은 SA 자동 만료를 미지원하고, SA 만료일 확인은 1Password.com 웹 GUI 전용이다 — op CLI로는 조회할 수 없다 (아래 트러블슈팅 참조). 그 대체로 평문 ISO date expiry record(.txt)를 SSOT로 운용한다. SA 재발급 시 GUI에서 만료일을 확인해 해당 `.txt`를 갱신한다.

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
3. biometric(데스크탑 앱 연동) — 기본 차단(positive-gate). SA 경로 실패 시 시도 없이 fail-fast한다 — `op read`의 승인 팝업은 Mac 로컬 화면에만 떠서 무인·원격 컨텍스트에서 진입하면 무한 hang하기 때문(#1041). TTY denylist로는 표식 없는 PTY 자동화를 못 잡으므로(gh-auth가 같은 이유로 biometric fallback을 제거한 #876 F3 선례), 사람이 Mac 화면 앞에 있을 때만 켜는 `OP_GET_BIOMETRIC=1 op_get ...` opt-in에서만 biometric을 허용한다.

SA 경로(1·2단계)는 서브셸에서 `OP_CONNECT_HOST`/`OP_CONNECT_TOKEN`을 제거하고 SA token은 `env`로 감싼 단일 command subtree에만 주입한다 — Connect env가 SA token보다 우선하는 op 공식 우선순위 때문이며, 이 repo는 Connect 서버 미도입(NG-1)이라 잔존 Connect env는 항상 오염이다. 같은 계약을 `gh-pat-mac`(darwin.nix)도 공유한다. 경로 단일 소스는 `constants.onePassword.saTokenMacRelPath`.

회귀 핀: `tests/eval-tests.nix` Test D18 (SA 경로 상수 배선 + `OP_GET_BIOMETRIC` opt-in 마커).

SSOT: `libraries/constants.nix`(onePassword), `modules/shared/programs/shell/default.nix`(op_get), `modules/shared/programs/shell/darwin.nix`(gh 무인).

## SSH device key 운영 (#866 닫힘 — mobile-ssh 단일 공유 키)

`constants.sshDeviceKeys` 3종 — `macSsh`(comment `mac-ssh`), `mobile`(comment `mobile-ssh`), `emergency`(comment `emergency-fallback`) — 은 MiniPC `authorized_keys` 등록용 공개키이며(`mac-ssh`만 추가로 Mac SSH agent에 노출), agenix 복호화 recipient(`sshKeys`)와는 분리된 개념이다.

- iPhone/iPad는 Termius keychain 동기화로 디바이스별 격리가 불성립 → `iphone-ssh`/`ipad-ssh` 분리 키를 폐기하고 단일 `mobile-ssh` 공유 키로 통합(#866 닫힘). 운영 모델: `mobile-ssh` 공유 키 rotate + Termius 디바이스 해제.
- `mac-ssh` private key는 1Password SSH vault에 보관(#874로 Automation에서 격리), `agent.toml`이 SSH vault에 바인딩되어 SA token blast radius가 축소된다(SA는 SSH vault `op read` 차단). `mobile-ssh`는 1Password가 아니라 Termius keychain에만 보관된다(공개키만 agenix `sshDeviceKeys`로 MiniPC authorized_keys 등록).
- Emergency fallback 운영 키는 `~/.ssh/emergency_ed25519` (`IdentityAgent=none` 독립 fallback), 1Password backup copy는 SSH vault에 보관.

SSOT: `libraries/constants.nix`(sshDeviceKeys), `modules/darwin/programs/ssh/default.nix`, `secrets/secrets.nix`.

## 트러블슈팅 — 1Password 함정 (#1041)

agenix 계열 트러블슈팅은 [troubleshooting.md](troubleshooting.md) 참조. `op read` 비대화형 hang은 #1134로 코드 상환됨 — 위 "op_get 해석 순서" 참조.

### SA token 만료일이 op CLI로 조회되지 않음

증상: SA token의 만료일을 op CLI로 확인하려 해도 만료 정보를 얻을 수 없다.

원인: 1Password는 SA 만료일을 CLI에 노출하지 않는다 — 만료일 확인은 1Password.com 웹 GUI(Service Accounts 페이지) 전용이다.

해결: GUI에서 확인한 만료일을 평문 expiry record(`secrets/opnix-service-account-expiry{,-mac}.txt`)에 박제하고, rotation 알림이 이 record를 SSOT로 읽는다 (위 "SA token 90일 rotation" 섹션). SA 재발급 시 GUI에서 새 만료일을 확인해 `.txt`를 갱신한다.

### 1Password 데스크탑 (재)기동 후 SSH 키 승인 팝업 반복 (Mac 전용)

증상: 1Password 데스크탑 앱이 재기동될 때마다 (그리고 기본 설정 "Until 1Password locks"에서는 잠금해제 후에도) SSH 실행 시 키 사용 승인 팝업이 다시 뜬다. 원격/무인 세션에서는 이 팝업이 Mac 로컬 화면에만 떠서 보이지 않는 무한 대기가 된다 (#1094 실측: `BatchMode`/`ConnectTimeout`은 agent 서명 승인 대기에 상한을 주지 못해 40초+ hang).

원인: `agent.toml`(SSH vault 노출, `modules/darwin/programs/ssh/default.nix`가 박제)로 agent에 노출된 키는 1Password의 클라이언트 앱별(per-app) 승인 모델을 따르는데, 승인 기억이 agent session(앱 실행 단위)에 묶여 앱 quit·재부팅 시 리셋된다. 시간 기반 승인(4·12·24h)은 잠금 자체는 견디지만 앱 재기동에는 무효이고, "Approve for all applications"는 지속시간이 아니라 그 session에서 키를 쓸 수 있는 애플리케이션 범위를 넓히는 옵션이다. `onepassword-autostart` launchd가 로그인마다 앱을 재기동하므로, 재로그인 후 첫 서명 요청부터 승인 팝업이 반복 출현한다 (#1094에서 승인 기억 연장안(A/B)을 기각한 사유 — 외출 후 재로그인·재부팅이 기본 상태라 앱 재기동으로 무효).

해결: 로컬 대화형에서는 이 팝업이 정상 보안 경계다 — 끄지 않는다. 원격/무인 hang은 interactive zsh의 `ssh()` 래퍼(무인 판정 + `minipc-headless` 키 `IdentityAgent=none` 1Password 완전 우회 + 20초 outer deadline)가 처리한다 (#1094 C·D안, `modules/shared/programs/shell/darwin.nix`). 단 이 래퍼는 zsh 함수라 `.zshrc`를 거치지 않는 비대화형 자식 `ssh`(Claude Bash tool·Codex app-server 등)에는 적용되지 않는다 — 그 경로의 launcher 배선은 plan 029의 미해결 범위다. agent.toml 노출 vault는 SSH vault 한정으로 좁게 유지한다 — 노출을 넓히면 승인 대상 키만 늘어난다.
