# 1Password 운영 (SA 발급 / 인증 상태 점검 / op CLI / gh 무인 / SSH device key)

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

## SA 실제 비밀 조회 상태 점검 — Mac launchd + MiniPC systemd

기존 90일 날짜 비교 알림(#875)은 실제 토큰 만료 설정을 조회하지 않았다. 두 SA가 1Password 웹의 서비스 계정 표에서 `만료되지 않음`으로 설정되어 있으므로, 날짜 기록과 교체 알림을 제거하고 실제 비밀 조회 점검으로 대체한다. 토큰 자체와 vault 권한은 변경하지 않는다. 만료 설정은 웹에서 다시 확인하며, 조회 실패를 토큰 만료로 단정하지 않는다.

| 호스트 | 스케줄·검사 | 상태 기록 |
|--------|-------------|-----------|
| MiniPC | `opnix-health-check.service` + hourly timer (`Persistent=true`, 최대 5분 지연). 기존 root SA로 `opnix env` 실행 | `/var/lib/opnix-health/status.json` |
| 개인 Mac | `opnix-health-mac` launchd agent (`StartInterval=3600`, `RunAtLoad=true`). 기존 SA로 `op read` 실행 | `~/.local/state/opnix-health/status.json` |

공통 동작: `op://Automation/github-pat/token`을 조회하고 결과는 메모리에서만 확인한다. 검사당 20초 제한, 실패 시 5초 후 한 번 재시도한다. 비밀·원문 stderr는 출력하지 않으며 데스크탑 인증으로 폴백하지 않는다. `opnix env`의 상속 SA 환경값은 제거해 지정한 배포 파일만 검사한다. 비밀 materialization·서비스 재시작·GitHub API 검증은 수행하지 않는다.

기존 Pushover 채널로 장애 최초(priority=1), 복구(priority=0)를 알리고, 지속 장애는 마지막 성공한 알림으로부터 24시간 후 다시 알린다. 정상 시 알리지 않는다. 전송 실패는 알림 완료로 기록하지 않아 다음 검사 때 재시도한다. 상태 파일은 마지막 검사·성공·알림 시각과 상태만 저장하며 비밀은 포함하지 않는다. Mac 잠자기·종료 중에는 검사하지 않는다.

SSOT: `modules/{darwin,nixos}/programs/opnix-health.nix`, `modules/shared/lib/opnix-health-check.nix`, `modules/shared/scripts/opnix-health-check.py`, `constants.onePassword`.

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

`constants.sshDeviceKeys`는 SSH 접속 클라이언트 공개키의 정본이다. 대상 호스트의 `authorized_keys`에 등록하며(`mobile-ssh`는 MiniPC + personal Mac, work Mac 미배포), `mac-ssh`는 추가로 Mac SSH agent에 노출된다. agenix 복호화 recipient(`sshKeys`)와는 분리된 개념이다.

- iPhone/iPad는 Termius keychain 동기화로 디바이스별 격리가 불성립 → `iphone-ssh`/`ipad-ssh` 분리 키를 폐기하고 단일 `mobile-ssh` 공유 키로 통합(#866 닫힘). 운영 모델: `mobile-ssh` 공유 키 rotate + Termius 디바이스 해제.
- `mac-ssh` private key는 1Password SSH vault에 보관(#874로 Automation에서 격리), `agent.toml`이 SSH vault에 바인딩되어 SA token blast radius가 축소된다(SA는 SSH vault `op read` 차단). `mobile-ssh`는 1Password가 아니라 Termius keychain에만 보관된다(공개키는 `sshDeviceKeys`를 통해 MiniPC + personal Mac authorized_keys에 등록, work Mac 미배포).
- Emergency fallback 운영 키는 `~/.ssh/emergency_ed25519` (`IdentityAgent=none` 독립 fallback), 1Password backup copy는 SSH vault에 보관.

SSOT: `libraries/constants.nix`(sshDeviceKeys), `modules/darwin/programs/ssh/default.nix`, `secrets/secrets.nix`.

## 트러블슈팅 — 1Password 함정 (#1041)

agenix 계열 트러블슈팅은 [troubleshooting.md](troubleshooting.md) 참조. `op read` 비대화형 hang은 #1134로 코드로 해결됨 — 위 "op_get 해석 순서" 참조.

### SA 비밀 조회 실패 알림

증상: 재시도 후에도 필요한 비밀 조회가 실패하거나 제한 시간을 초과한다.

원인: 네트워크, SA 파일 누락, 자격 취소, vault 권한, 참조 항목 변경 등을 구분해 조사해야 한다. CLI/SDK의 일반 실패 코드는 인증 오류와 네트워크 오류를 구분하지 못하므로 알림만으로 만료를 단정하지 않는다.

해결: 상태 파일의 마지막 성공과 알림 사유를 확인하고 대상 호스트에서 배포 SA를 명시해 조사한다. Mac은 `op whoami`와 `op read`, MiniPC는 `opnix env`를 사용하며 비밀 값은 출력하지 않는다. 실제 만료 설정은 개인 계정의 웹 Developer → 서비스 계정 표에서 확인한다. 교체가 필요하다고 확인되기 전에는 토큰을 재발급하지 않는다.

### 1Password 데스크탑 (재)기동 후 SSH 키 승인 팝업 반복 (Mac 전용)

증상: 1Password 데스크탑 앱이 재기동될 때마다 (그리고 기본 설정 "Until 1Password locks"에서는 잠금해제 후에도) SSH 실행 시 키 사용 승인 팝업이 다시 뜬다. 원격/무인 세션에서는 이 팝업이 Mac 로컬 화면에만 떠서 보이지 않는 무한 대기가 된다 (#1094 실측: `BatchMode`/`ConnectTimeout`은 agent 서명 승인 대기에 상한을 주지 못해 40초+ hang).

원인: `agent.toml`(SSH vault 노출, `modules/darwin/programs/ssh/default.nix`가 박제)로 agent에 노출된 키는 1Password의 클라이언트 앱별(per-app) 승인 모델을 따르는데, 승인 기억이 agent session(앱 실행 단위)에 묶여 앱 quit·재부팅 시 리셋된다. 시간 기반 승인(4·12·24h)은 잠금 자체는 견디지만 앱 재기동에는 무효이고, "Approve for all applications"는 지속시간이 아니라 그 session에서 키를 쓸 수 있는 애플리케이션 범위를 넓히는 옵션이다. `onepassword-autostart` launchd가 로그인마다 앱을 재기동하므로, 재로그인 후 첫 서명 요청부터 승인 팝업이 반복 출현한다 (#1094에서 승인 기억 연장안(A/B)을 기각한 사유 — 외출 후 재로그인·재부팅이 기본 상태라 앱 재기동으로 무효).

해결: 로컬 대화형에서는 이 팝업이 정상 보안 경계다 — 끄지 않는다. Claude Remote Control과 Codex Desktop의 non-TTY child는 launcher marker + private PATH를 통해 `minipc-headless` key(`IdentityAgent none`)와 auth-phase deadline을 사용한다 (#1094 C·D, `modules/darwin/programs/ssh/headless-dispatcher.nix`). interactive Ghostty의 `ssh()`는 기존 1Password 경로를 유지한다. agent.toml 노출 vault는 SSH vault 한정으로 좁게 유지한다 — 노출을 넓히면 승인 대상 키만 늘어난다.
