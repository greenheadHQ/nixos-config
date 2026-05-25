# Phase 3: MiniPC opnix

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Not Started (설계 확정 2026-05-25 — 구현은 별도 세션 대기)
Last Updated: 2026-05-25

## Objective

MiniPC에서 opnix system module(`services.onepassword-secrets`)이 Service Account Token으로 headless 인증해 1Password Automation vault의 `github-pat`을 user 파일로 materialize하고, MiniPC의 `gh` CLI가 `GH_TOKEN` wrapper로 그 파일을 읽어 인증하게 전환한다 (SA token은 user shell 미노출 — opnix root oneshot만 사용). 부팅 시 1Password SaaS HTTPS 호출 의존성을 인지하고, 컨테이너 secret은 agenix에 영구 잔존시켜 SaaS outage 시 컨테이너 미기동을 차단한다.

## Context From Master PRD

- Goals covered: G-2 (op CLI 통합), G-3 (agenix 축소 — user-level만)
- Success Criteria: SC-1 (MiniPC op item get 동작), SC-2 부분 (MiniPC gh 인증)
- Requirements covered: FR-6 부분 (SA token 실 사용), FR-12
- Key scenarios touched: Scenario 3 (MiniPC headless gh issue create)
- Critical assumption: A-3 (컨테이너 secret은 agenix 영구 잔존 — opnix는 user-level에 한정)

## Phase Discovery Gate

- [ ] 관련 코드/파일: `modules/nixos/programs/` 하위 패턴 (caddy/smartd 등), `modules/nixos/options/homeserver.nix`, `secrets/secrets.nix` (Phase 1에서 opnix-service-account-token.age 추가), `flake.nix` (inputs), `modules/shared/programs/shell/default.nix` (op_get `--account` 고정이 MiniPC OP_SERVICE_ACCOUNT_TOKEN 경로와 호환되는지 확인)
- [ ] 관련 테스트/fixture: `tests/eval-tests.nix`, `modules/nixos/programs/smoke-test.nix`
- [ ] 관련 docs/spec/외부 참조: https://github.com/brizzbuzz/opnix (canonical, mrjones2014/opnix는 archived), https://developer.1password.com/docs/service-accounts/use-with-1password-cli/
- [ ] 관련 command 또는 도구: `nrs minipc`, `ssh minipc 'op vault list'`, `ssh minipc 'gh api user'`
- [ ] Phase 1의 SA token이 agenix `opnix-service-account-token.age`에 보관됨
- [ ] A-3 (컨테이너 secret은 agenix 영구) 재확인 — 본 phase에서 immich/karakeep/awesome-anki/pushover-* 등의 .age를 1Password로 옮기지 않음

## Scope

### In Scope

- `flake.nix`에 `inputs.opnix.url = "github:brizzbuzz/opnix"` 추가 + follows nixpkgs
- `modules/nixos/programs/opnix/default.nix` 확장 (Phase 1 stub extend):
  - opnix flake input의 **NixOS system module**(`services.onepassword-secrets`, 1Password Go SDK 기반 root oneshot)을 imports. op CLI 래퍼가 아니므로 `nixpkgs._1password-cli` systemPackages는 materialization엔 불필요 (MiniPC에 op CLI 직접 쓸 용도 생기면 그때 별도 추가)
  - `services.onepassword-secrets.tokenFile`을 agenix path(`config.age.secrets.opnix-service-account-token.path`, **0400 root 유지**)에 binding. ⚠️ `services.onepassword-secrets.users` 옵션은 token file을 `root:onepassword-secrets 0640`(group readable)으로 바꾸므로 **사용 금지**
  - `services.onepassword-secrets.secrets.<name>`로 `op://Automation/github-pat/token`을 user 파일로 materialize: `path = "/run/opnix/greenhead/github-pat"`(tmpfs), `owner = "greenhead"`, `mode = "0400"`. parent dir은 systemd tmpfiles로 `0700 greenhead`
- `modules/nixos/options/homeserver.nix`의 `homeserver.opnix.enable` mkEnableOption은 **Phase 1에서 이미 추가됨** (보존만 확인). MiniPC `configuration.nix`에서 `enable = true`만 설정
- MiniPC `configuration.nix`에 `homeserver.opnix.enable = true` 추가
- **MiniPC user shell 인증 경로 (확정 — opnix native materialization, 2026-05-25 master Open Questions 해소)** — SA token을 user shell에 노출하지 않는다. opnix root oneshot이 github-pat을 user 파일로 materialize하고, gh는 GH_TOKEN wrapper로 그 파일만 읽는다:
  - (1) **SA token user shell 미노출**: 기존 잠정 설계의 `OP_SERVICE_ACCOUNT_TOKEN` user shell export(`/etc/profile.d/opnix.sh`)는 **폐기**. SA token은 opnix root oneshot(`services.onepassword-secrets`)만 사용하고 user shell엔 진입하지 않는다.
  - (2) **gh = GH_TOKEN wrapper** (Shell Plugin alias 폐기): Home Manager `programs.zsh.initContent`에 `gh() { GH_TOKEN="$(< /run/opnix/greenhead/github-pat)" command gh "$@"; }` wrapper 함수 등록. GH_TOKEN은 gh 공식 headless auth 경로(stored credential보다 우선). `op plugin run` Shell Plugin은 desktop app + interactive credential selection을 요구해 headless에 부적합 → 채택 안 함 (Mac Phase 2b와 다른 패턴 — headless 환경 차이로 정당)
- MiniPC `~/.config/gh/hosts.yml`의 기존 평문 oauth_token 제거 (Phase 2b가 Mac에서 했던 정리를 MiniPC에서도 1회 수행)
- **SA token 90일 rotation systemd timer + Pushover 알림** 구현·activation (Phase 1에서 이관). `modules/nixos/programs/opnix-rotate.nix` 신규: weekly oneshot이 Phase 1에서 생성한 `secrets/opnix-service-account-expiry.txt`를 읽어 N-14일 이하면 Pushover 알림. op CLI 의존 없음. timer는 MiniPC opnix.enable에 게이팅
- Caddy/Tailscale 등 다른 시스템 컨테이너의 secret은 변경 없음 (A-3 박제)

### Out of Scope

- 컨테이너 secret (immich/karakeep/awesome-anki) 1Password 이관 — A-3에 따라 영구 agenix 잔존
- Mac SSH 변경 (Phase 2a)
- Shell plugin Mac 적용 (Phase 2b)
- managing-secrets SKILL.md 갱신 (Phase 5)

## Implementation Checklist

- [ ] `flake.nix` inputs에 `opnix.url = "github:brizzbuzz/opnix"` 추가. follows nixpkgs 설정
- [ ] `nix flake update opnix` 후 `nix flake check --no-build --all-systems` 통과 확인
- [ ] `modules/nixos/programs/opnix/default.nix` 확장 (Phase 1 stub을 **extend**, `environment.etc."opnix-service-account-expiry"` 라인 **반드시 보존**):
  - opnix flake input의 **system module**(`services.onepassword-secrets`)을 imports (`programs.onepassword-secrets` Home Manager 모듈 아님 — user activation에서 tokenFile 읽어야 해 root-only SA token과 안 맞음)
  - `services.onepassword-secrets.tokenFile`을 agenix path(`config.age.secrets.opnix-service-account-token.path`)에 binding. ⚠️ `services.onepassword-secrets.users` 옵션 **사용 금지**(token file을 `root:onepassword-secrets 0640` group readable로 바꿈 — SA token 0400 root 유지)
  - `services.onepassword-secrets.secrets.<name>`로 `op://Automation/github-pat/token` → `/run/opnix/greenhead/github-pat`(tmpfs, owner=greenhead, mode 0400) materialize. parent dir은 systemd tmpfiles `0700 greenhead`
  - (op CLI 래퍼가 아닌 Go SDK oneshot이므로 `nixpkgs._1password-cli` systemPackages는 materialization엔 불필요)
  - systemd service의 `After = [ "network-online.target" ]`, `Wants = [ "network-online.target" ]` (1Password SaaS 도달성 보장 — A-3와 정합)
  - `Restart = "on-failure"`, `RestartSec = 30` (SaaS 일시 outage 대응)
  - **검증**: 본 phase의 default.nix diff에서 Phase 1이 박제한 `environment.etc."opnix-service-account-expiry".source` 라인이 그대로 살아있어야 한다 (git diff로 확인 + `ssh minipc 'test -r /etc/opnix-service-account-expiry'`로 deployed 확인)
- [ ] `modules/nixos/options/homeserver.nix`의 `homeserver.opnix.enable` mkEnableOption은 **Phase 1에서 이미 추가됨** — 보존만 확인 (재추가 금지). Phase 3는 enable 시 활성화될 full 구현(systemd service 등)을 opnix/default.nix에 extend
- [ ] MiniPC configuration.nix에 `homeserver.opnix.enable = true;` 추가
- [ ] **gh GH_TOKEN wrapper 등록** (확정 설계 — SA token user shell 미노출):
  - Home Manager(NixOS user) `programs.zsh.initContent`에 wrapper 함수: `gh() { GH_TOKEN="$(< /run/opnix/greenhead/github-pat)" command gh "$@"; }` (파일 부재 시 GH_TOKEN 빈 값 → gh가 평소 경로로 fallback)
  - `OP_SERVICE_ACCOUNT_TOKEN`을 user shell로 export하는 `/etc/profile.d/opnix.sh`는 **만들지 않는다**(폐기된 잠정 설계). SA token은 opnix root oneshot만 사용
  - 적용 대상: `homeserver.opnix.enable = true`일 때만 (cfg.enable 게이팅)
- [ ] **op_get MiniPC**: (B) opnix native에서 MiniPC gh는 op CLI를 안 쓰므로 op_get은 MiniPC에서 비활성(op CLI 미설치 → `command -v op` 실패 시 127, 기존 guard 동작). 향후 MiniPC에 op CLI를 쓸 일이 생기면 op_get의 `--account my.1password.com` 고정이 `OP_SERVICE_ACCOUNT_TOKEN` 인증과 충돌하므로(SA token이 account 결정) 그때 `OP_SERVICE_ACCOUNT_TOKEN` 존재 시 `--account` 생략 분기 추가 (`modules/shared/programs/shell/default.nix`)
- [ ] `nrs minipc` 빌드 + 활성화
- [ ] `ssh minipc`로 접속 후 검증:
  - [ ] opnix materialize 확인: `test -r /run/opnix/greenhead/github-pat`(0400 greenhead) + parent dir `0700 greenhead`. **token 값은 stdout/log에 출력 금지**
  - [ ] opnix oneshot service active 확인 (`systemctl status`로 opnix가 만드는 unit명)
  - [ ] **SA token user shell 미노출 검증**: `ssh minipc 'env | grep -c OP_SERVICE_ACCOUNT_TOKEN'` → 0 (user shell에 SA token env 없음)
- [ ] MiniPC `~/.config/gh/hosts.yml` 백업 후 `oauth_token` 라인 제거 (기존 평문 정리 — 인증은 GH_TOKEN wrapper가 담당)
- [ ] gh wrapper 검증: `nrs minipc` 활성화 후 새 ssh session에서 `type gh`가 GH_TOKEN wrapper 함수로 정의됐는지 확인 (`op plugin run -- gh` alias 아님). github-pat 파일을 GH_TOKEN으로 읽어 인증
- [ ] `nrs minipc` 활성화
- [ ] `ssh minipc 'gh api user'` → login=greenheadHQ 응답 확인
- [ ] `ssh minipc 'gh pr list'` → 정상 응답
- [ ] systemd journal 확인: `ssh minipc 'journalctl -u opnix-secrets.service -n 50'` → 정상 활성
- [ ] SA token rotation timer 구현 — `modules/nixos/programs/opnix-rotate.nix` 신규:
  - source of truth = Phase 1에서 `modules/nixos/programs/opnix/default.nix`로 배포된 **`/etc/opnix-service-account-expiry`** (Phase 1이 `environment.etc` 패턴으로 pin함). op CLI 명령 의존 X
  - systemd timer (weekly oneshot): `cat /etc/opnix-service-account-expiry`로 만료일 읽기 → `expiry_epoch=$(date -d "$(cat /etc/opnix-service-account-expiry)" +%s)` + `now_epoch=$(date +%s)` → `(( (expiry_epoch - now_epoch) / 86400 <= 14 ))`이면 알림 발송
  - 알림 발송: `pushover-system-monitor.nix` 패턴 (제목 "1Password SA token rotation needed", 본문은 expiry 파일 내용 + Phase 1 Discoveries 참조)
  - timer는 `config.homeserver.opnix.enable` 게이팅
- [ ] 배포 검증 — `ssh minipc 'test -r /etc/opnix-service-account-expiry && cat /etc/opnix-service-account-expiry'`로 expiry 파일이 read-only로 배포됐는지 확인. 출력이 ISO-8601 date (예: `2026-08-17`)이어야 정상
- [ ] `nrs minipc` 재활성화 후 timer 등록 검증: `ssh minipc 'systemctl list-timers | grep opnix-rotate'` → 다음 발화 시각 노출
- [ ] timer dry-run: `ssh minipc 'sudo systemctl start opnix-rotate.service'` → exit 0 + journalctl에 정상 메시지 (alert 발송은 만료 14일 이상이면 silent)

## Validation Strategy

- 부팅 후 opnix-secrets.service 활성 확인 + op CLI/gh CLI 동작 검증. 컨테이너 secret(immich/karakeep)이 영향 받지 않음을 smoke-test로 확인. SA outage 시 detection은 능동 시뮬레이션 대신 systemd `Restart=on-failure` + `pushover-system-monitor.nix`의 service-state 알림으로 갈음한다 (의도적으로 production 시뮬레이션은 skip — risk가 production 영향).

## Validation Checklist

- [ ] Static check 통과: `nix flake check --no-build --all-systems`
- [ ] 자동 test 추가/갱신: `tests/eval-tests.nix`에 `homeserver.opnix.enable = true` 시 systemPackages에 `_1password-cli` 존재 검증 1줄
- [ ] API/CLI 검증: `ssh minipc 'gh api user'`(login=greenheadHQ), `ssh minipc 'gh pr list'`. **SA token 비노출 검증**: `ssh minipc 'env | grep -c OP_SERVICE_ACCOUNT_TOKEN'` → 0 (user shell env에 SA token 없음 — opnix root oneshot만 사용). github-pat 파일/token 값은 stdout/log에 절대 출력하지 않음
- [ ] Browser/UI E2E — N/A
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — N/A
- [ ] Visual/screenshot check — N/A
- [ ] Observability/logging — `ssh minipc 'journalctl -u opnix-secrets.service'` 정상 + `op` CLI 호출 시 1Password Activity log 기록 확인
- [ ] Manual smoke check — 재부팅 후 opnix-secrets.service 자동 활성 + gh 동작 확인 (`sudo reboot` 후 `ssh minipc 'gh api user'`)
- [ ] 해당 시 error/empty/loading/permission/retry/rollback — SaaS outage detection은 systemd `Restart=on-failure` + opnix-secrets.service의 RestartSec + `pushover-system-monitor.nix`의 service-state 알림으로 처리. 능동 시뮬레이션(iptables 등)은 production risk가 있어 skip — rationale: outage가 발생해도 (a) Restart로 자동 복구 (b) Pushover 알림으로 사용자 인지가 보장됨

## Exit Criteria

- [ ] Phase objective 달성 (MiniPC opnix 도입 + SA token 동작 + gh 인증 1Password 경유)
- [ ] FR-12 구현 + FR-6 timer activation 부분 구현 (Phase 1에서 token 보관까지, 본 phase에서 timer + Pushover)
- [ ] 컨테이너 secret이 모두 agenix에 영구 잔존 (immich/karakeep/awesome-anki/pushover-* 변경 없음 확인)
- [ ] `ssh minipc 'systemctl list-timers | grep opnix-rotate'`에 active timer 노출
- [ ] timer dry-run (`systemctl start opnix-rotate.service`)이 exit 0 + journalctl 정상 메시지
- [ ] 다음 phase (Phase 5) 시작 blocker 없음

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-1, SC-2 (MiniPC 부분) 달성
- [ ] 2. Correctness — 부팅 → opnix-secrets → gh CLI 흐름 happy path + SaaS outage 시나리오 처리
- [ ] 3. Simplicity — opnix 모듈 + homeserver.opnix.enable 옵션 + Shell Plugin source 1줄로 최소
- [ ] 4. Code quality — modules/nixos/programs/opnix/default.nix가 caddy/smartd 등 기존 패턴 일관
- [ ] 5. Duplication/cleanup — MiniPC 기존 hosts.yml 평문 token 잔존 0
- [ ] 6. Security/privacy — SA token 0400 root 유지(user shell 미노출 검증), github-pat tmpfs(`/run`) 0400 greenhead materialize, `services.onepassword-secrets.users` 미사용, SaaS outage 시 컨테이너 영향 0 (A-3)
- [ ] 7. Performance — op CLI 호출 overhead는 캐시로 완화. 부팅 시 opnix-secrets timing 측정
- [ ] 8. Validation — flake check + nrs + ssh op + ssh gh + 재부팅 smoke
- [ ] 9. Future-phase — Phase 5에서 managing-secrets에 opnix 운영 절차 박제 예정 — 본 phase에서 발견된 사실 (timing, 실패 모드 등)을 Discoveries에 기록
- [ ] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- 부팅 시 opnix-secrets.service 활성 timing 측정 (network-online.target 의존성 확인)
- SaaS outage 시 op CLI 실패 메시지 형식 및 Pushover 알림 가치 평가

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-25: SA token user shell bridge 설계 확정 (구현은 별도 세션). opnix native materialization 채택 — `services.onepassword-secrets` system module(Go SDK root oneshot)이 SA token(0400 root 유지)으로 github-pat을 user 파일(`/run/opnix/greenhead/github-pat`, tmpfs 0400 greenhead) materialize, gh는 GH_TOKEN wrapper. 잠정 설계(`OP_SERVICE_ACCOUNT_TOKEN` user shell export + Shell Plugin alias) 폐기. 외부 기술 자문(codex xhigh) 교차검증: opnix는 op CLI 래퍼가 아닌 Go SDK oneshot, `services.onepassword-secrets.users` 옵션은 token을 0640 group readable로 바꿔 사용 금지, Shell Plugin은 headless 부적합. Scope·Implementation Checklist·Validation·Multi-Pass를 확정안으로 갱신.
