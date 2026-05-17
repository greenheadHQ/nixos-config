# Phase 1: Foundation

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Not Started
Last Updated: 2026-05-17

## Objective

1Password 데스크탑 앱·CLI 설치, Automation vault 생성, naming convention 박제, gh PAT 신규 발급 + 1Password 저장 + retrieval 검증, op_get helper 도입, Service Account 발급 및 agenix 보관까지 — 후속 phase가 의존하는 모든 기반 자산을 마련한다. hosts.yml 평문 정리·구 PAT revoke·alias 활성 검증은 Phase 2b 책임. SA token 90일 rotation timer 구현·activation은 Phase 3 책임. 이 phase 완료 후에야 Phase 2a/2b/3가 진행 가능하다.

## Context From Master PRD

- Goals covered: G-1 (1Password 통합), G-2 (op CLI 통합), G-4 (Automation vault inventory 기반)
- Success Criteria: SC-1 (op item get 동작 — Phase 1 부분), SC-2 (gh PAT 1Password 보관까지 — Phase 1 부분, 구 PAT revoke는 Phase 2b)
- Requirements covered: FR-1, FR-2, FR-4, FR-5 완전 + FR-3 부분 (Phase 1 절반) + FR-6 부분 (token 발급·agenix 보관까지, timer는 Phase 3)
- Key scenarios touched: Scenario 1 (routing 결정), Scenario 2 (Mac gh pr create — Phase 1은 token retrieval까지)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [ ] 관련 코드/파일: `modules/darwin/programs/homebrew.nix`, `modules/shared/programs/git/default.nix`, `libraries/constants.nix`, `secrets/secrets.nix`, `modules/nixos/programs/pushover-system-monitor.nix`
- [ ] 관련 테스트/fixture: `tests/eval-tests.nix` (constants 변경 시), `managing-secrets/evals/queries.json`
- [ ] 관련 docs/spec/외부 참조: https://developer.1password.com/docs/service-accounts/, https://developer.1password.com/docs/cli/, https://github.com/brizzbuzz/opnix
- [ ] 관련 command 또는 도구: `nrs darwin`, `gh auth`, `op` (Mac CLI), `agenix -r` (re-encrypt)
- [ ] Master PRD의 assumption A-1 (Individual SA 가용성)이 여전히 유효함 (2026-05-17 GUI 확인 완료)
- [ ] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope

### In Scope

- 1Password 데스크탑 앱 + op CLI 설치 (Mac, Homebrew Cask)
- Automation vault 생성 + item naming convention 박제
- gh PAT Phase 1 부분 (신규 발급 → 1Password Automation vault 저장 → `op_get`+`GH_TOKEN` 단발 retrieval 검증). 평문 정리·구 PAT revoke·audit·alias 활성은 Phase 2b 책임
- `libraries/constants.nix`에 `onePassword.vaults.{personal, automation}` 상수 등록
- `op_get <name> <field> [<vault>]` zsh function 작성 (`modules/shared/programs/shell/`)
- 1Password Service Account 발급 → `secrets/opnix-service-account-token.age` agenix 등록 (publicKey=minipc). 단 token의 실 소비(opnix module)와 90일 rotation timer activation은 Phase 3 책임
- macOS biometric unlock 활성화 (op CLI 1Password 데스크탑 통합)

### Out of Scope

- MiniPC opnix 모듈 실제 도입 (Phase 3)
- MiniPC gh PAT 1Password 인증 전환 (Phase 3)
- Mac SSH IdentityAgent 변경 (Phase 2a)
- Shell plugin gh alias 활성화 + `~/.config/gh/hosts.yml` 평문 oauth_token 제거 + 구 PAT GitHub 측 revoke (Phase 2b)
- SA token rotation systemd timer + Pushover 알림 활성화 (Phase 3, MiniPC 시스템 구성)

## Implementation Checklist

- [ ] `modules/darwin/programs/homebrew.nix`에 `casks = [ "1password" "1password-cli" ]` 추가
- [ ] `nrs darwin` → 1Password 데스크탑 앱 정상 설치 확인 → 사용자 로그인 (`shren0812@gmail.com`) + biometric unlock 활성화 (Settings → Developer → "Use the SSH agent" + Biometric)
- [ ] 1Password GUI → Vaults → Create New Vault → 이름 "Automation" → 설명 "LLM·자동화·시스템 토큰 + 디바이스 SSH key inventory"
- [ ] 1Password GUI → Vaults → Create New Vault (또는 기본 Personal 활용) → naming convention 박제: item title은 `<service>-<role>[-<host>]` (소문자 + dash, 예: `github-pat`, `github-pat-emergency`)
- [ ] `libraries/constants.nix`에 `onePassword = { vaults = { personal = "Personal"; automation = "Automation"; }; }` 추가
- [ ] `modules/shared/programs/shell/op-get.nix` (또는 적합한 모듈 위치) 신규 파일 작성: zsh function `op_get name field [vault]` — vault 기본값 `${constants.onePassword.vaults.automation}`. `programs.zsh.initContent`에 함수 정의 inject
- [ ] `nrs darwin` → `op_get` 함수가 zsh에서 호출 가능한지 확인 (`type op_get`)
- [ ] gh PAT Phase 1 부분 (Phase 2b가 hosts.yml 제거·구 PAT revoke·alias 활성 검증을 이어받음):
  - [ ] (1) GitHub → Settings → Developer settings → Personal access tokens → fine-grained 또는 classic 신규 발급 (필요 scope: `repo`, `read:org`, `gist`, `workflow`). 만료 90일
  - [ ] (2) 1Password Automation vault에 item 생성: title `github-pat`, type `API Credential`, field `token` 에 신규 PAT 저장. Tag `dev`
  - [ ] (3) `op_get github-pat token`이 신규 PAT를 반환하는지 확인 (Phase 1 acceptance)
  - [ ] (4) `GH_TOKEN=$(op_get github-pat token) gh api user`로 신규 PAT가 유효한지 검증 (login=`greenheadHQ` 응답). 본 단계는 단일 명령 내 env scoping 확인이며 hosts.yml은 건드리지 않음. hosts.yml 평문 정리·alias 활성·구 PAT revoke은 모두 Phase 2b로 이관
- [ ] 1Password GUI → Sidebar → Developer Tools → Service Accounts → "Generate Service Account":
  - [ ] Name: `nixos-automation-minipc` (또는 동등)
  - [ ] Vault access: Automation (read+write), Personal (접근 없음)
  - [ ] Expiration: 90일
  - [ ] Generated token 캡처
- [ ] `secrets/secrets.nix`에 `opnix-service-account-token.age` 항목 추가 (publicKey=minipc)
- [ ] `agenix -e secrets/opnix-service-account-token.age` 로 SA token 저장
- [ ] `nrs darwin` (agenix re-encrypt 검증). MiniPC 활성화·timer 등록은 Phase 3 책임이므로 본 phase에서 `nrs minipc`는 호출하지 않음 (token은 보관만)
- [ ] **SA token 만료일 record 파일 생성·commit·Nix stub 배포** (Phase 3 timer가 읽을 single source of truth):
  - source 파일: `secrets/opnix-service-account-expiry.txt` (만료일은 secret이 아니므로 평문 commit. agenix 아님)
  - 내용: ISO-8601 date 1줄 (예: `2026-08-17`). 1Password 발급 시 표시되는 expiration date를 수동 기록
  - Nix 배포 **stub**: `modules/nixos/programs/opnix/default.nix`를 **최소 stub**으로 신규 생성 — 본 phase는 다음 한 줄만 박제: `environment.etc."opnix-service-account-expiry".source = ../../../../secrets/opnix-service-account-expiry.txt;`. opnix 모듈의 full 구현 (opnix flake input import, SA token EnvironmentFile, systemd unit 의존성, mkOption 등)은 **Phase 3에서 본 stub을 extend**. Phase 3는 이 `environment.etc` 라인을 반드시 보존
  - 본 stub은 MiniPC `homeserver.opnix.enable = true` (Phase 3에서 추가) 시 활성되어 `/etc/opnix-service-account-expiry`에 read-only 배포. Phase 1 단독으로는 stub만 commit되고 MiniPC 활성은 Phase 3에서
- [ ] SA token 발급 메타데이터(이름·만료일)를 본 phase Discoveries에 박제 + 위 record 파일 경로 명시

## Validation Strategy

- nix flake 평가: `nix flake check --no-build --all-systems` (constants 변경, secrets.nix 변경)
- agenix re-encrypt 검증: `nrs darwin` 성공 + `agenix -r` 무경고
- op CLI 동작: `op vault list` → Automation + Personal 노출, `op item get github-pat --field token --vault Automation` 정상 반환
- 신규 gh PAT 유효성: `GH_TOKEN=$(op_get github-pat token) gh api user` 응답에 login=`greenheadHQ`. 본 phase는 retrieval 검증까지 — hosts.yml 정리·alias·구 PAT revoke은 Phase 2b가 검증
- SA token: 1Password Activity log에서 SA 발급 기록 확인 + 만료일을 Discoveries에 박제 (Phase 3에서 timer 구현 시 참조)

## Validation Checklist

- [ ] Static check 통과: `nix flake check --no-build --all-systems`
- [ ] 자동 test 추가/갱신 및 통과: `tests/eval-tests.nix`에 constants.nix.onePassword.vaults 존재성 검증 (간단한 assert 1줄)
- [ ] API/CLI 검증: `op vault list`, `op_get github-pat token`, `GH_TOKEN=$(op_get github-pat token) gh api user` 각각 정상 응답
- [ ] Browser/UI E2E — N/A (CLI/GUI 작업)
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — N/A
- [ ] Visual/screenshot check — 1Password GUI에서 Automation vault + SA 메뉴 스크린샷 1회 (PRD assumption 갱신용)
- [ ] Observability/logging — 1Password Activity log에서 SA 발급 기록 확인 (timer 등록은 Phase 3 검증)
- [ ] Manual smoke check — Mac 재로그인 후 1Password 데스크탑 자동 unlock + op CLI 동작 확인
- [ ] 해당 시 error/empty/loading/permission/retry/rollback 상태 검증 — op CLI 미인증 상태에서 `op_get` 호출 시 에러 메시지 적절성 확인

## Exit Criteria

- [ ] Phase objective 달성 (1Password GUI/CLI 설치 + Automation vault + naming + Phase 1 gh 부분 + op_get helper + SA token agenix 보관)
- [ ] FR-1, FR-2, FR-4, FR-5 구현 완료. FR-3은 Phase 1 부분(신규 PAT 발급+vault 저장+retrieval 검증)까지, 나머지는 Phase 2b로 이관. FR-6은 token 발급+agenix 보관까지, timer activation은 Phase 3로 이관
- [ ] Validation checklist 완료 또는 gap이 근거와 함께 기록됨
- [ ] 다음 phase (Phase 2a, 2b, 3)를 시작하지 못하게 막는 blocker 없음
- [ ] SA token 발급 메타데이터 (이름·만료일) Discoveries에 박제됨

## Phase-End Multi-Pass Review

다음 phase로 이동하기 전 순서대로 완료한다:
- [ ] 1. Intent/coverage review — Phase 1이 FR-1, FR-2, FR-4, FR-5를 완전 달성하고 FR-3/FR-6은 Phase 1 부분(retrieval 검증 + agenix 보관)까지 달성했다.
- [ ] 2. Correctness review — gh PAT 발급·1Password 저장·retrieval 검증의 happy path, op CLI 미인증 케이스가 처리되었다. hosts.yml 정리·구 PAT revoke 실패 케이스는 Phase 2b 책임.
- [ ] 3. Simplicity review — op_get helper가 필요 이상 복잡하지 않다. shell function 1개로 충분.
- [ ] 4. Code quality review — `onePassword.vaults` 상수 이름/위치/형식이 constants.nix 컨벤션과 일치한다.
- [ ] 5. Duplication/cleanup review — 중복 alias, dead code가 제거되었다 (hosts.yml 백업은 Phase 2b에서 처리).
- [ ] 6. Security/privacy review — SA token이 agenix에 mode 0400으로 보관. Phase 1 retrieval 검증에서 GH_TOKEN env가 일시적·single-command scope이며 shell history에 평문 leak 없음.
- [ ] 7. Performance/load review — op_get helper가 매 호출마다 op CLI fork — 1Password 데스크탑 unlock 캐시(30분)에 의존. 캐시 미스 시 biometric prompt 빈도 모니터링.
- [ ] 8. Validation review — flake check + nrs darwin + op CLI 응답 + retrieval 검증까지 완료. timer/alias 검증은 Phase 3/2b 책임.
- [ ] 9. Future-phase review — Phase 2a/2b/3가 Phase 1 산출물 (Automation vault, op_get, SA token agenix)에 의존. Phase 2b는 hosts.yml 정리·구 PAT revoke·alias 활성, Phase 3는 timer activation을 이어받는다.
- [ ] 10. PRD sync review — master PRD Status, Current Phase, Change Log가 갱신되었다.

## Discoveries / Decisions

- (Phase 진행 중 발견되는 사실/결정사항을 여기 기록)

## Phase Change Log

- 2026-05-17: Phase file created.
