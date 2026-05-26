# Phase 3: MiniPC opnix

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (merged #842)
Last Updated: 2026-05-26

## Objective

MiniPC에서 1Password Service Account Token으로 자동화 credential을 headless materialize하도록 opnix를 도입하고, MiniPC의 `gh` CLI가 1Password Automation vault의 `github-pat`을 GH_TOKEN wrapper로 사용하게 전환한다. brizzbuzz/opnix의 `services.onepassword-secrets`(1Password Go SDK 기반 root oneshot — op CLI 래퍼 아님)가 `op://` reference를 tmpfs에 native materialize한다. 부팅 시 1Password SaaS HTTPS 호출 의존성을 인지하고, 컨테이너 secret은 agenix에 영구 잔존시켜 SaaS outage 시 컨테이너 미기동을 차단한다 (A-3).

## Context From Master PRD

- Goals covered: G-2 (1Password 통합 — MiniPC는 op:// materialization 경로), G-3 (agenix 축소 — user-level만)
- Success Criteria: SC-1 (MiniPC는 opnix materialization으로 충족 — op CLI 대신 Go SDK), SC-2 부분 (MiniPC gh 인증 — GH_TOKEN wrapper)
- Requirements covered: FR-6 (rotation timer + Pushover activation), FR-12 (opnix 모듈)
- Key scenarios touched: Scenario 3 (MiniPC headless gh), Scenario 6 (SA token rotation)
- Critical assumption: A-3 (컨테이너 secret은 agenix 영구 잔존 — opnix는 user-level credential에 한정)

## 확정 설계 (opnix native materialization)

master PRD Open Questions의 "SA token user shell bridge" 후보 3종을 Phase 3 진입 시 재검토한 결과, **opnix native materialization**(후보 3 "opnix가 제한 권한으로 필요한 값만 materialize"의 구체화)으로 확정했다. SA token 자체는 user shell에 전혀 노출하지 않고, 필요한 credential(github-pat)만 root oneshot이 tmpfs에 owner-scoped로 materialize한다. 폐기된 잠정 설계(`/etc/profile.d/opnix.sh`가 SA token을 user shell로 export + Shell Plugin alias)는 SA token을 user shell에 노출하므로 채택하지 않는다.

- **opnix system module**: `flake.nix`에 `inputs.opnix.url = "github:brizzbuzz/opnix"`(follows nixpkgs) + `nixosModules.default`를 `mkNixosConfig`에서 import(agenix와 동일 패턴, darwin 제외).
- **SA token (agenix, host key 복호화)**: `services.onepassword-secrets.tokenFile = config.age.secrets.opnix-service-account-token.path`. ⚠️ opnix-secrets.service는 tokenFile을 `users` 옵션과 **무관하게** 항상 `chown root:onepassword-secrets; chmod 640`으로 강제한다(opnix `nix/module.nix`). 따라서 agenix secret도 `mode="0640"; owner="root"; group="onepassword-secrets"`로 선언해 매 activation/boot 권한 경합(토글)을 제거한다. `services.onepassword-secrets.users`는 비워 onepassword-secrets group 멤버를 0으로 유지 → 0640이어도 group으로 읽을 수 있는 user가 없어 **실질 root-only**다(사용자 보안 결정; 명시 의도였던 "SA token user shell 노출 0" 충족).
- **github-pat materialization**: `services.onepassword-secrets.secrets.githubPat = { reference = "op://Automation/github-pat/token"; path = "/run/opnix/<user>/github-pat"; owner = <user>; group = "users"; mode = "0400"; }`. opnix는 secret key에 camelCase만 허용하므로 key는 `githubPat`(파일명은 path로 지정). tmpfs(`/run`)라 평문이 디스크에 영구 잔존하지 않는다. parent dir은 systemd tmpfiles로 `/run/opnix/<user>` 0700 `<user>` 선생성(opnix processor의 0755 root MkdirAll보다 먼저 만들어 권한 보존).
- **gh 인증 (GH_TOKEN wrapper)**: Home Manager `programs.zsh.initContent`(shell/nixos.nix)에 `gh() { ... GH_TOKEN="$(< /run/opnix/<user>/github-pat)" command gh "$@"; }`. headless 환경이라 1Password Shell Plugin(desktop app + interactive 요구)은 부적합 → Mac(Phase 2b) Shell Plugin alias와 다른 패턴이지만 headless라 정당하다. github-pat 파일 부재(부팅 직후/ SaaS outage) 시 plain gh로 폴백.
- **op CLI 미설치**: materialization을 opnix Go SDK가 수행하므로 `nixpkgs._1password-cli`는 불필요. MiniPC `op_get`은 op CLI 미설치라 기존 guard가 127을 반환(비활성) — `op_get`의 `--account` 고정은 Mac biometric 경로 전용이고 MiniPC와 충돌하지 않으므로 변경 없음.
- **SA token 90일 rotation**: `modules/nixos/programs/opnix-rotate.nix` 신규. weekly oneshot이 `/etc/opnix-service-account-expiry`(Phase 1 stub이 배포)를 읽어 만료 14일 이하면 Pushover 알림. op CLI 의존 없음. `homeserver.opnix.enable` 게이팅.

## Scope

### In Scope

- `flake.nix`: opnix input + `nixosModules.default` import (mkNixosConfig만)
- `modules/nixos/programs/opnix/default.nix`: Phase 1 stub **extend** — expiry record 라인 **보존** + SA token agenix 등록(0640 onepassword-secrets) + `services.onepassword-secrets`(materialization) + tmpfiles
- `modules/nixos/configuration.nix`: `homeserver.opnix.enable = true`
- `modules/shared/programs/shell/nixos.nix`: gh GH_TOKEN wrapper (username 인자 추가)
- `modules/nixos/programs/opnix-rotate.nix`: SA token rotation 알림 (weekly timer + Pushover)
- `modules/nixos/options/homeserver.nix`: opnix-rotate import + opnix 옵션 주석 갱신
- `tests/eval-tests.nix`: opnix materialization 보안 회귀 핀 5개

### Out of Scope

- 컨테이너 secret (immich/karakeep/awesome-anki) 1Password 이관 — A-3에 따라 영구 agenix 잔존
- Mac SSH 변경 (Phase 2a) / Shell Plugin Mac 적용 (Phase 2b)
- managing-secrets SKILL.md 갱신 (Phase 5)
- MiniPC `~/.config/gh/hosts.yml` 평문 정리: GH_TOKEN wrapper가 env로 주입하므로 hosts.yml oauth_token이 있어도 GH_TOKEN이 우선한다. E2E에서 평문 잔존 확인 후 있으면 정리(SC-2 정합).

## Implementation Checklist

- [x] `flake.nix` inputs에 `opnix.url = "github:brizzbuzz/opnix"` 추가(follows nixpkgs) + `nixosModules.default`를 mkNixosConfig modules에 import
- [x] `nix flake lock`으로 opnix lock(rev 35344e1, v0.10.1) → `nix flake check --no-build --all-systems` 통과
- [x] `modules/nixos/programs/opnix/default.nix` extend (expiry record `environment.etc."opnix-service-account-expiry".source` 라인 **보존** 확인):
  - SA token agenix 등록: `age.secrets.opnix-service-account-token = { file; mode="0640"; owner="root"; group="onepassword-secrets"; }`
  - `services.onepassword-secrets`: `enable=true`, `tokenFile`=agenix path, `secrets.githubPat`(op://Automation/github-pat/token → /run/opnix/<user>/github-pat, owner=user, mode 0400), `users` 미설정
  - systemd tmpfiles: `/run/opnix` 0755 root, `/run/opnix/<user>` 0700 user
  - 검증: git diff에서 expiry record 라인 보존 확인 완료 (E2E에서 `test -r /etc/opnix-service-account-expiry`로 deployed 확인)
- [x] `homeserver.opnix.enable` mkEnableOption 보존 확인(재추가 안 함) + 옵션 주석을 native materialization으로 갱신
- [x] MiniPC `configuration.nix`에 `homeserver.opnix.enable = true` 추가
- [x] gh GH_TOKEN wrapper: `shell/nixos.nix` `programs.zsh.initContent`에 `gh()` 함수(파일 부재 시 plain gh 폴백). systemd env가 SSH user shell에 상속되지 않는 문제를 wrapper가 해결
- [x] op_get MiniPC 호환성 확인: op CLI 미설치 → 기존 guard 127 반환(비활성), `--account` 충돌 없음 → shell/default.nix 변경 불필요
- [x] SA token rotation: `modules/nixos/programs/opnix-rotate.nix` 신규 (weekly oneshot이 `/etc/opnix-service-account-expiry` 읽어 14일 이하면 `send_notification_strict`로 Pushover, op CLI 의존 X), homeserver.nix import + opnix.enable 게이팅
- [x] `tests/eval-tests.nix`: opnix 보안 핀 5개 (services.onepassword-secrets.enable / githubPat tmpfs·0400·user-owned / reference / tokenFile 0640 onepassword-secrets / users 비움) — `nix eval` 통과
- [x] (merge 후) MiniPC에서 main pull + nrs (2026-05-26, nrs 29s, closure delta +0 — 이미 #842 배포 상태였음 재확인):
  - [x] `/etc/opnix-service-account-expiry` → `2026-08-22` (ISO-8601)
  - [x] `opnix-secrets.service` → active(exited), 13h 전 부팅서 자동 활성
  - [x] `stat /run/opnix/greenhead/github-pat` → `400 greenhead:users` (tmpfs)
  - [x] `gh api user` → login=greenheadHQ (GH_TOKEN wrapper = shell function)
  - [x] `gh pr list` → 정상 응답 (#850/#849/#846)
  - [x] `env | grep -c OP_SERVICE_ACCOUNT_TOKEN` → 0 (SA token user shell 노출 0)
  - [~] hosts.yml 평문 oauth_token: GH_TOKEN env가 우선하므로 기능 영향 0. 평문 정리(SC-2)는 미확인 — 후속 항목
  - [x] `systemctl list-timers` → opnix-rotate-check.timer 다음 발화 2026-06-01
  - [x] `sudo systemctl start opnix-rotate-check.service` → exit 0 + journalctl "SA token expiry: 2026-08-22 (87 days left)" silent
  - [x] 재부팅 smoke: opnix-secrets.service가 13h 전 부팅서 자동 active (재부팅 자동 활성 충족)

## Validation Strategy

- 부팅 후 opnix-secrets.service 활성 + github-pat materialize + gh 동작 검증. 컨테이너 secret(immich/karakeep)이 영향 받지 않음을 확인(secret 파일 변경 없음). SA outage detection은 능동 시뮬레이션 대신 opnix-secrets.service의 `Restart=on-failure`(opnix 모듈 기본) + 기존 service-state 알림으로 갈음(production risk 회피).

## Validation Checklist

- [x] Static check 통과: `nix flake check --no-build --all-systems`
- [x] 자동 test 추가: `tests/eval-tests.nix`에 opnix materialization 보안 핀 5개 (당초 "_1password-cli systemPackages 존재" 검증은 op CLI 미설치 확정으로 폐기 → materialization 경로 검증으로 대체)
- [x] API/CLI 검증 (E2E 완료): `gh api user`=greenheadHQ, `gh pr list` 정상. **token 비노출**: `env | grep -c OP_SERVICE_ACCOUNT_TOKEN`=0 (SA token user shell 노출 0)
- [x] Browser/UI E2E — N/A · Agent/dev browser — N/A · Mobile — N/A · Visual — N/A
- [x] Observability/logging — `journalctl -u opnix-secrets.service` 정상(token 값 미노출). 1Password Activity log 기록은 SaaS GUI 영역이라 미확인
- [x] Manual smoke check — opnix-secrets.service 13h 전 부팅서 자동 활성 + gh 동작 확인
- [x] error/rollback — SaaS outage detection은 opnix-secrets.service `Restart=on-failure`(opnix 기본 RestartSec 15min, StartLimitBurst 2) + 기존 service-state 알림으로 처리. 능동 시뮬레이션 skip(production risk)

## Exit Criteria

- [x] 코드 구현 + flake check + eval-tests 통과 (정적 검증)
- [x] Phase objective 달성 — MiniPC opnix materialization + github-pat 동작 + gh 인증 1Password 경유 (E2E 확인)
- [x] FR-12 구현 + FR-6 timer activation (Phase 1 token 보관 + 본 phase timer + Pushover, dry-run exit 0)
- [x] 컨테이너 secret이 모두 agenix에 영구 잔존 (opnix만 변경 — immich/karakeep/awesome-anki/pushover-* .age 불변)
- [x] opnix-rotate-check.timer active 노출(다음 2026-06-01) + dry-run exit 0(87일 silent)
- [x] 다음 phase (Phase 5) 시작 blocker 없음

## Phase-End Multi-Pass Review

- [x] 1. Intent/coverage — SC-1(MiniPC materialization), SC-2(MiniPC GH_TOKEN wrapper) 달성 (E2E)
- [x] 2. Correctness — 부팅 → opnix-secrets → github-pat materialize → gh wrapper happy path 확인; SaaS outage는 Restart=on-failure로 처리
- [x] 3. Simplicity — opnix 모듈 + homeserver.opnix.enable + gh wrapper + rotation timer로 최소. user shell SA token 노출 0
- [x] 4. Code quality — opnix/default.nix·opnix-rotate.nix가 temp-monitor/immich-update 등 기존 패턴 일관(service-lib, tmpfiles, ConditionPathExists)
- [~] 5. Duplication/cleanup — MiniPC hosts.yml 평문 잔존은 미확인(GH_TOKEN env 우선이라 기능 무관, SC-2 평문 정리는 후속)
- [x] 6. Security/privacy — SA token 실질 root-only(0640 empty group), github-pat tmpfs 0400 user-owned, SA token user shell 노출 0, SaaS outage 시 컨테이너 영향 0 (A-3)
- [x] 7. Performance — opnix-secrets 부팅 자동 활성(13h 지속), nrs 29s. RemainAfterExit oneshot이라 상시 런타임 overhead 없음
- [x] 8. Validation — flake check + eval-tests + nrs + ssh gh + 재부팅 smoke 완료
- [ ] 9. Future-phase — Phase 5에서 managing-secrets에 opnix 운영 절차 박제 — 발견 사실을 Discoveries에 기록
- [x] 10. PRD sync — master PRD Status/Phase Index/Change Log/Open Questions/Scenario 3/SC-1/SC-2/FR-12 갱신

## Discoveries / Decisions

- opnix 0.10.1(brizzbuzz, rev 35344e1) `nix/module.nix` 실측 발견:
  - opnix-secrets.service script가 `users` 옵션과 무관하게 tokenFile을 항상 `chown root:onepassword-secrets; chmod 640`으로 강제 → "0400 root 유지"는 모듈 fork 없이 불가. 해법: agenix secret을 0640 onepassword-secrets로 선언(권한 합의) + users 비움(group 멤버 0 → 실질 root-only).
  - secret key는 camelCase(`^[a-z][a-zA-Z0-9]*$`)만 허용 → `github-pat` 불가, `githubPat`(파일명은 path로 지정).
  - secret materialization 시 processor가 parent dir을 0755 root로 MkdirAll(존재 시 no-op) → tmpfiles로 0700 user 선생성하면 권한 보존.
  - systemd.services.opnix-secrets는 모듈이 이미 `after/wants=network-online.target`, `Restart=on-failure`, `RestartSec=15min`, `StartLimitBurst=2`를 설정 → 본 모듈에서 추가 override 불필요(잠정 설계의 RestartSec 30s 항목은 불요).
  - 기본 outputDir `/var/lib/opnix/secrets`(영구) + changeDetection.hashFile `/var/lib/opnix/secret-hashes.json` → 평문은 path로 지정한 tmpfs에만, hash(평문 아님)는 /var/lib에. github-pat 평문은 디스크 비잔존.
  - `_1password-cli`는 materialization에 불필요(Go SDK).
- (merge 후 E2E, 2026-05-26) opnix-secrets.service는 부팅 시 자동 활성(active exited, 13h 지속 확인). nrs 재적용은 closure delta +0(이미 배포 상태) — opnix는 부팅 1회 materialize 후 RemainAfterExit. rotation timer dry-run은 만료 87일이라 silent(정상). github-pat은 0400 greenhead:users로 tmpfs에 정확히 materialize, SA token은 user shell 노출 0.
- (후속 개선, Phase 3 무관) Mac 비대화형/LLM `gh`는 `op plugin run` Shell Plugin이라 매 호출 op biometric(Touch ID) 마찰 발생 → #848 등록(GH_TOKEN 우회 경로, Mac 한정). MiniPC는 본 phase의 GH_TOKEN wrapper라 이 마찰이 없음(대조 패턴).

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-25: opnix native materialization으로 확정 설계 갱신 + 구현 완료 (PR 대기). 잠정 설계(profile.d SA token export + Shell Plugin alias)를 폐기하고 opnix `services.onepassword-secrets`로 github-pat만 tmpfs에 owner-scoped materialize + gh GH_TOKEN wrapper로 전환. SA token user shell 노출 0. 사용자 결정: opnix가 tokenFile을 강제 0640하므로 agenix도 0640 onepassword-secrets로 선언, users 비워 실질 root-only 수용. flake check + eval-tests(보안 핀 5개) 통과, 커밋 완료. MiniPC E2E는 merge 후 진행(Phase 1/2b 패턴).
- 2026-05-26: PR #842 squash merge → MiniPC 배포(nrs 29s) + E2E 전항목 통과. opnix-secrets active(부팅 자동), github-pat 400 greenhead:users(tmpfs), tokenFile 640 root:onepassword-secrets(실질 root-only), gh api user=greenheadHQ, SA token user shell 노출 0, rotation timer dry-run exit 0(87일 silent). 후속 개선 #848(Mac 비대화형 gh op plugin biometric 마찰 → GH_TOKEN 우회) 분리 등록.
