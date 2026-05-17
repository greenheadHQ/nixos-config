# Phase 3: MiniPC opnix

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Not Started
Last Updated: 2026-05-17

## Objective

MiniPC에서 `op` CLI가 Service Account Token으로 headless 인증되도록 opnix 모듈을 도입하고, MiniPC의 `gh` CLI가 1Password Automation vault의 `github-pat` item을 op CLI 경유로 사용하게 전환한다. 부팅 시 1Password SaaS HTTPS 호출 의존성을 인지하고, 컨테이너 secret은 agenix에 영구 잔존시켜 SaaS outage 시 컨테이너 미기동을 차단한다.

## Context From Master PRD

- Goals covered: G-2 (op CLI 통합), G-3 (agenix 축소 — user-level만)
- Success Criteria: SC-1 (MiniPC op item get 동작), SC-2 부분 (MiniPC gh 인증)
- Requirements covered: FR-6 부분 (SA token 실 사용), FR-12
- Key scenarios touched: Scenario 3 (MiniPC headless gh issue create)
- Critical assumption: A-3 (컨테이너 secret은 agenix 영구 잔존 — opnix는 user-level에 한정)

## Phase Discovery Gate

- [ ] 관련 코드/파일: `modules/nixos/programs/` 하위 패턴 (caddy/smartd 등), `modules/nixos/options/homeserver.nix`, `secrets/secrets.nix` (Phase 1에서 opnix-service-account-token.age 추가), `flake.nix` (inputs)
- [ ] 관련 테스트/fixture: `tests/eval-tests.nix`, `modules/nixos/programs/smoke-test.nix`
- [ ] 관련 docs/spec/외부 참조: https://github.com/brizzbuzz/opnix (canonical, mrjones2014/opnix는 archived), https://developer.1password.com/docs/service-accounts/use-with-1password-cli/
- [ ] 관련 command 또는 도구: `nrs minipc`, `ssh minipc 'op vault list'`, `ssh minipc 'gh api user'`
- [ ] Phase 1의 SA token이 agenix `opnix-service-account-token.age`에 보관됨
- [ ] A-3 (컨테이너 secret은 agenix 영구) 재확인 — 본 phase에서 immich/karakeep/awesome-anki/pushover-* 등의 .age를 1Password로 옮기지 않음

## Scope

### In Scope

- `flake.nix`에 `inputs.opnix.url = "github:brizzbuzz/opnix"` 추가 + follows nixpkgs
- `modules/nixos/programs/opnix/default.nix` 신규 작성:
  - `nixpkgs._1password-cli`를 systemPackages에 추가 (allowUnfreePredicate 필요 시 처리)
  - `OP_SERVICE_ACCOUNT_TOKEN`을 systemd EnvironmentFile로 주입하는 패턴 (또는 brizzbuzz/opnix 모듈 import 후 옵션 설정)
  - token 파일은 agenix `config.age.secrets.opnix-service-account-token.path`
- `modules/nixos/options/homeserver.nix`에 `homeserver.opnix.enable` mkOption 추가 (default false, MiniPC만 true)
- MiniPC `configuration.nix`에 `homeserver.opnix.enable = true` 추가
- **MiniPC user shell 인증 경로 (SSOT — Shell Plugin alias 단일 패턴, Phase 2b와 일관)** — systemd env는 SSH 일반 사용자 shell에 상속되지 않으므로 별도 wrapper 필수. 두 단계로 구성:
  - (1) opnix 모듈에 `environment.etc."profile.d/opnix.sh".source` 패턴으로 user shell 진입 시 `OP_SERVICE_ACCOUNT_TOKEN`을 agenix path에서 단발 export: `export OP_SERVICE_ACCOUNT_TOKEN=$(cat /run/agenix/opnix-service-account-token 2>/dev/null || true)`. 이 단계만이 token을 user shell로 가져오는 유일한 경계
  - (2) `gh` 호출은 Phase 2b의 Shell Plugin alias 패턴을 그대로 MiniPC에 적용 — `op plugin init gh` 1회 + Home Manager `programs.zsh.initContent`에서 `~/.config/op/plugins.sh` source. `GH_TOKEN` env 직접 export 방식은 사용하지 않음 (alias가 호출 시점에 op CLI로 자동 주입)
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
  - opnix flake input의 NixOS module을 imports
  - `nixpkgs._1password-cli` systemPackages 추가
  - SA token 파일 경로를 opnix 모듈의 token option에 binding (agenix path)
  - systemd service의 `After = [ "network-online.target" ]`, `Wants = [ "network-online.target" ]` (1Password SaaS 도달성 보장 — A-3와 정합)
  - `Restart = "on-failure"`, `RestartSec = 30` (SaaS 일시 outage 대응)
  - **검증**: 본 phase의 default.nix diff에서 Phase 1이 박제한 `environment.etc."opnix-service-account-expiry".source` 라인이 그대로 살아있어야 한다 (git diff로 확인 + `ssh minipc 'test -r /etc/opnix-service-account-expiry'`로 deployed 확인)
- [ ] `modules/nixos/options/homeserver.nix`에 mkOption 추가:
  ```nix
  homeserver.opnix = {
    enable = lib.mkEnableOption "Enable 1Password op CLI with service account token";
  };
  ```
- [ ] MiniPC configuration.nix에 `homeserver.opnix.enable = true;` 추가
- [ ] **User shell token bridge 생성** (systemd EnvironmentFile은 SSH 일반 사용자 shell에 상속되지 않으므로 필수):
  - `modules/nixos/programs/opnix/default.nix`에 `environment.etc."profile.d/opnix.sh"` 선언 추가
  - 파일 내용 (Nix string literal): `export OP_SERVICE_ACCOUNT_TOKEN=$(cat /run/agenix/opnix-service-account-token 2>/dev/null || true)`
  - 권한: mode `0444` (read-only world) — secret 자체는 agenix path가 root-only이므로 bridge 파일은 명령만 들고 있음
  - 적용 대상: `homeserver.opnix.enable = true`일 때만 활성 (cfg.enable 게이팅)
- [ ] `nrs minipc` 빌드 + 활성화
- [ ] `ssh minipc`로 접속 후 검증:
  - [ ] `op vault list` → Automation vault 노출 (Personal은 SA 접근 불가로 미노출 — 정상)
  - [ ] `op item get github-pat --field token --vault Automation` → 신규 PAT 반환
- [ ] MiniPC `~/.config/gh/hosts.yml` 백업 후 `oauth_token` 라인 제거
- [ ] MiniPC에 Shell Plugin alias 활성화 (Phase 2b와 동일 SSOT 패턴 — GH_TOKEN env 직접 export는 사용하지 않음):
  - `ssh minipc 'op plugin init gh'` 1회 실행 (interactive — Automation vault의 `github-pat` 선택)
  - Home Manager (NixOS user) `programs.zsh.initContent`에 `~/.config/op/plugins.sh` source guard 추가 (Phase 2b의 declarative 등록 패턴 그대로)
  - `nrs minipc` 활성화 후 새 ssh session에서 `type gh`가 `op plugin run -- gh`로 alias됨을 확인
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
- [ ] API/CLI 검증: `ssh minipc 'op vault list'`, `ssh minipc 'gh api user'`, `ssh minipc 'gh pr list'`. **token 비노출 검증** (`env`/`printenv`로 token 값 출력 금지) — 대신 `ssh minipc 'env | grep -E "^OP_SERVICE_ACCOUNT_TOKEN=" >/dev/null && echo present || echo missing'`로 env에 set됐는지만 확인. 값 자체는 stdout/log에 절대 출력하지 않음
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
- [ ] 6. Security/privacy — SA token mode 0400, EnvironmentFile 패턴, SaaS outage 시 컨테이너 영향 0 (A-3)
- [ ] 7. Performance — op CLI 호출 overhead는 캐시로 완화. 부팅 시 opnix-secrets timing 측정
- [ ] 8. Validation — flake check + nrs + ssh op + ssh gh + 재부팅 smoke
- [ ] 9. Future-phase — Phase 5에서 managing-secrets에 opnix 운영 절차 박제 예정 — 본 phase에서 발견된 사실 (timing, 실패 모드 등)을 Discoveries에 기록
- [ ] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- 부팅 시 opnix-secrets.service 활성 timing 측정 (network-online.target 의존성 확인)
- SaaS outage 시 op CLI 실패 메시지 형식 및 Pushover 알림 가치 평가

## Phase Change Log

- 2026-05-17: Phase file created.
