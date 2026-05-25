# Phase 1: Foundation

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (merged, PR #824)
Last Updated: 2026-05-25

## Objective

1Password 데스크탑 앱·CLI 설치, Automation vault 생성, naming convention 박제, gh PAT 신규 발급 + 1Password 저장 + retrieval 검증, op_get helper 도입, Service Account 발급 및 agenix 보관까지 — 후속 phase가 의존하는 모든 기반 자산을 마련한다. hosts.yml 평문 정리·구 PAT revoke·alias 활성 검증은 Phase 2b 책임. SA token 90일 rotation timer 구현·activation은 Phase 3 책임. 이 phase 완료 후에야 Phase 2a/2b/3가 진행 가능하다.

## Context From Master PRD

- Goals covered: G-1 (1Password 통합), G-2 (op CLI 통합), G-4 (Automation vault inventory 기반)
- Success Criteria: SC-1 (op item get 동작 — Phase 1 부분), SC-2 (gh PAT 1Password 보관까지 — Phase 1 부분, 구 PAT revoke는 Phase 2b)
- Requirements covered: FR-1, FR-2, FR-4, FR-5 완전 + FR-3 부분 (Phase 1 절반) + FR-6 부분 (token 발급·agenix 보관까지, timer는 Phase 3)
- Key scenarios touched: Scenario 1 (routing 결정), Scenario 2 (Mac gh pr create — Phase 1은 token retrieval까지)

## Phase Discovery Gate

코드 편집 전에 재확인한다 (Phase 1 구현 시 확인 완료):
- [x] 관련 코드/파일: `modules/darwin/programs/homebrew.nix`, `modules/shared/programs/git/default.nix`, `libraries/constants.nix`, `secrets/secrets.nix`, `modules/nixos/programs/pushover-system-monitor.nix`
- [x] 관련 테스트/fixture: `tests/eval-tests.nix` (constants 변경 시), `managing-secrets/evals/queries.json`
- [x] 관련 docs/spec/외부 참조: https://developer.1password.com/docs/service-accounts/, https://developer.1password.com/docs/cli/, https://github.com/brizzbuzz/opnix
- [x] 관련 command 또는 도구: `nrs darwin`, `gh auth`, `op` (Mac CLI), `agenix -r` (re-encrypt)
- [x] Master PRD의 assumption A-1 (Individual SA 가용성)이 여전히 유효함 (2026-05-17 GUI 확인 완료)
- [x] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope

### In Scope

- 1Password 데스크탑 앱 + op CLI 설치 (Mac, Homebrew Cask)
- Automation vault 생성 + item naming convention 박제
- gh PAT Phase 1 부분 (신규 발급 → 1Password Automation vault 저장 → `op_get`+`GH_TOKEN` 단발 retrieval 검증). 평문 정리·구 PAT revoke·audit·alias 활성은 Phase 2b 책임
- `libraries/constants.nix`에 `onePassword.vaults.{personal, automation}` 상수 등록
- `op_get <name> <field> [<vault>]` zsh function 작성 (`modules/shared/programs/shell/`)
- 1Password Service Account 발급 → `secrets/opnix-service-account-token.age` agenix 등록 (publicKeys=minipcHostOnly, host key 전용). 단 token의 실 소비(opnix module)와 90일 rotation timer activation은 Phase 3 책임
- macOS biometric unlock 활성화 (op CLI 1Password 데스크탑 통합)

### Out of Scope

- MiniPC opnix 모듈 실제 도입 (Phase 3)
- MiniPC gh PAT 1Password 인증 전환 (Phase 3)
- Mac SSH IdentityAgent 변경 (Phase 2a)
- Shell plugin gh alias 활성화 + `~/.config/gh/hosts.yml` 평문 oauth_token 제거 + 구 PAT GitHub 측 revoke (Phase 2b)
- SA token rotation systemd timer + Pushover 알림 활성화 (Phase 3, MiniPC 시스템 구성)

## Implementation Checklist

- [x] `modules/darwin/programs/homebrew.nix`에 `casks = [ "1password" "1password-cli" ]` 추가 (personal hostType)
- [x] `nrs darwin` → 1Password 데스크탑 앱 정상 설치 확인 → 사용자 로그인 + biometric unlock 활성화 (Settings → Developer → "Use the SSH agent" + Biometric). SSH agent 토글 시 `~/.ssh/config` 자동편집은 거부 (nix-darwin declarative 관리, IdentityAgent는 Phase 2a)
- [x] 1Password GUI → Automation vault 생성 ("Automaton" 오타 → "Automation"으로 수정)
- [x] naming convention 박제: item title은 `<service>-<role>[-<host>]` (예: `github-pat`)
- [x] `libraries/constants.nix`에 `onePassword.vaults = { personal; automation; }` 추가
- [x] `op_get name field [vault]` zsh function 작성 — `modules/shared/programs/shell/default.nix`에 inline chunk로 (별도 op-get.nix 대신; PRD "또는 적합한 모듈 위치" 허용). vault 기본값 `constants.onePassword.vaults.automation`. `op read --no-newline "op://vault/item/field"` secret reference 방식 (공식 권장, redact 회피용 --reveal 불필요). op CLI 멀티 계정 환경에서 `--account`(개인 계정 my.1password.com)로 고정
- [x] `nrs darwin` → `op_get` 함수가 zsh에서 호출 가능 확인 (`type op_get`)
- [x] gh PAT Phase 1 부분 (Phase 2b가 hosts.yml 제거·구 PAT revoke·alias 활성 검증을 이어받음):
  - [x] (1) GitHub 신규 PAT 발급 (scope: `repo`, `read:org`, `gist`, `workflow`, 만료 90일)
  - [x] (2) 1Password Automation vault에 item `github-pat` 생성, 커스텀 `token` 필드에 PAT 저장 (API Credential 기본 "자격 증명" 대신 — `op_get github-pat token` 매칭). 만료일+취득일 필드 추가 (Watchtower). Tag `dev`
  - [x] (3) `op_get github-pat token`이 신규 PAT 반환 확인
  - [x] (4) `GH_TOKEN=$(op_get github-pat token) gh api user` → login=`greenheadHQ` 검증 완료. hosts.yml 평문 정리·alias 활성·구 PAT revoke은 Phase 2b로 이관
- [x] 1Password GUI → Service Accounts → Generate:
  - [x] Name: `nixos-automation-minipc`
  - [x] Vault access: Automation (read_items 전용, write 없음 — 최소권한), Personal (접근 없음), 항목 공유 OFF
  - [x] Expiration: Individual 플랜은 자동 만료 미지원 → 정책 cadence 90일 (만료 목표 2026-08-22)
  - [x] Generated token 캡처
- [x] `secrets/secrets.nix`에 `opnix-service-account-token.age` 항목 추가 — `publicKeys=minipcHostOnly` (host key 전용 recipient, PRD #780 host key 복호화 계약 정합. user 로그인 키 노출 표면과 분리)
- [x] `agenix -e secrets/opnix-service-account-token.age` 로 SA token 저장 (host key recipient로 재암호화)
- [x] `nix flake check --no-build --all-systems` 통과 (agenix recipient + age.identityPaths dual 검증). MiniPC 활성화·timer는 Phase 3 책임이므로 `nrs minipc` 미호출 (token 보관만)
- [x] **SA token 만료일 record 파일 + Nix stub 배포** (Phase 3 timer가 읽을 SSOT):
  - source 파일: `secrets/opnix-service-account-expiry.txt` (평문 commit, agenix 아님). 내용: `2026-08-22`
  - Nix 배포 **stub**: `modules/nixos/programs/opnix/default.nix` 신규 생성 — `environment.etc."opnix-service-account-expiry".source` 한 줄 (`mkIf cfg.enable` 가드). opnix 모듈의 full 구현 (opnix flake input import, SA token EnvironmentFile, systemd unit)은 **Phase 3에서 본 stub을 extend**. `homeserver.opnix.enable` mkEnableOption은 stub 활성화에 필요하므로 본 Phase 1에서 함께 추가했다 (Phase 3 작업이 아님). Phase 3는 이 `environment.etc` 라인과 enable 옵션을 보존하고 MiniPC에서 `enable=true`만 설정
  - 본 stub은 MiniPC `homeserver.opnix.enable = true` (Phase 3) 시 활성되어 `/etc/opnix-service-account-expiry`에 배포. Phase 1 단독으로는 stub만 commit (enable=false라 미평가)
- [x] SA token 발급 메타데이터(이름 `nixos-automation-minipc`·정책 만료일 2026-08-22)를 Discoveries에 박제 + record 파일 경로 명시

## Validation Strategy

- nix flake 평가: `nix flake check --no-build --all-systems` (constants 변경, secrets.nix 변경)
- agenix re-encrypt 검증: `nrs darwin` 성공 + `agenix -r` 무경고
- op CLI 동작: `op vault list` → Automation + Personal 노출, `op_get github-pat token` (= `op read --no-newline --account my.1password.com "op://Automation/github-pat/token"`) 정상 반환
- 신규 gh PAT 유효성: `GH_TOKEN=$(op_get github-pat token) gh api user` 응답에 login=`greenheadHQ`. 본 phase는 retrieval 검증까지 — hosts.yml 정리·alias·구 PAT revoke은 Phase 2b가 검증
- SA token: 1Password Activity log에서 SA 발급 기록 확인 + 만료일을 Discoveries에 박제 (Phase 3에서 timer 구현 시 참조)

## Validation Checklist

- [x] Static check 통과: `nix flake check --no-build --all-systems`
- [x] 자동 test 추가/갱신 및 통과: `tests/eval-tests.nix` Test 5e-8/5e-9 (constants.onePassword.vaults hard pin)
- [x] API/CLI 검증: `op vault list` (Automation+Personal), `op_get github-pat token`, `GH_TOKEN=$(op_get github-pat token) gh api user` (login=greenheadHQ) 정상 응답
- [x] Browser/UI E2E — N/A (CLI/GUI 작업)
- [x] Agent/dev browser check — N/A
- [x] Mobile/app simulator — N/A
- [x] Visual/screenshot check — 1Password GUI Automation vault + SA wizard 스크린샷 사용자 제공 확인
- [ ] Observability/logging — **Remaining**: 1Password Activity log SA 발급 기록 확인 미수행 (Individual 플랜 Events API 부재로 forensic only — Phase 3 timer 검증 시 함께)
- [ ] Manual smoke check — **Remaining**: Mac 재로그인 후 1Password 데스크탑 자동 unlock 실측 미수행 (사용자 차후 확인)
- [x] error/empty 상태 — `op_get`에 op CLI 부재(exit 127)·인자 누락(exit 2) 처리 포함

## Exit Criteria

- [x] Phase objective 달성 (1Password GUI/CLI 설치 + Automation vault + naming + Phase 1 gh 부분 + op_get helper + SA token agenix 보관)
- [x] FR-1, FR-2, FR-4, FR-5 구현 완료. FR-3은 Phase 1 부분(신규 PAT 발급+vault 저장+retrieval 검증)까지, 나머지는 Phase 2b로 이관. FR-6은 token 발급+agenix 보관까지, timer activation은 Phase 3로 이관
- [x] Validation checklist 완료 또는 gap이 근거와 함께 기록됨 (Observability/Manual smoke 2건 Remaining 명시)
- [x] 다음 phase (Phase 2a, 2b, 3)를 시작하지 못하게 막는 blocker 없음
- [x] SA token 발급 메타데이터 (이름·만료일) Discoveries에 박제됨

## Phase-End Multi-Pass Review

다음 phase로 이동하기 전 순서대로 완료한다 (구현 후 코드 리뷰를 정확성·설계·회귀·유지보수 관점으로 수행):
- [x] 1. Intent/coverage review — Phase 1이 FR-1, FR-2, FR-4, FR-5를 완전 달성하고 FR-3/FR-6은 Phase 1 부분(retrieval 검증 + agenix 보관)까지 달성했다.
- [x] 2. Correctness review — SA token recipient가 user 로그인 키에서 host key 전용으로 정정됨.
- [x] 3. Simplicity review — op_get helper가 필요 이상 복잡하지 않다. shell function 1개로 충분.
- [x] 4. Code quality review — `onePassword.vaults` 상수 이름/위치/형식이 constants.nix 컨벤션과 일치한다.
- [x] 5. Duplication/cleanup review — 중복 alias, dead code 없음.
- [x] 6. Security/privacy review — SA token이 host key 전용(minipcHostOnly) recipient로 격리됨. Phase 1 retrieval 검증에서 GH_TOKEN env가 일시적·single-command scope.
- [x] 7. Performance/load review — op_get helper가 매 호출마다 op CLI fork — 1Password biometric authorization(10분 inactivity 세션·사용 시 refresh·12시간 hard limit)에 의존.
- [x] 8. Validation review — flake check + op CLI 응답 + retrieval 검증까지 완료. timer/alias 검증은 Phase 3/2b 책임.
- [x] 9. Future-phase review — Phase 2a/2b/3가 Phase 1 산출물에 의존. Phase 2b는 hosts.yml 정리·구 PAT revoke·alias 활성, Phase 3는 timer activation을 이어받는다.
- [x] 10. PRD sync review — master PRD Status, Current Phase, Change Log가 갱신되었다.

## Discoveries / Decisions

- **SA 운영 모델**: 전역 공유 SA 1개 + minipc 단일 저장 (`secrets/opnix-service-account-token.age`, publicKeys=minipcHostOnly — host key 전용 recipient로 user 로그인 키 노출 표면과 분리). Mac은 biometric(데스크탑 unlock)으로 op CLI 인증하므로 SA token 미사용 → 실 소비처는 minipc 하나. SA 이름 `nixos-automation-minipc`. Automation vault read_items 전용 (write 없음 — 최소권한, op read 조회만 사용), Personal 접근 없음, 항목 공유 OFF.
- **SA 만료 정책**: 1Password Individual 플랜은 SA token 자동 만료(expiration) 옵션 미지원 (Business/Teams 전용). 따라서 정책 cadence로 운영 — 90일(NFR-4 준수), 만료 목표일 **2026-08-22**를 `secrets/opnix-service-account-expiry.txt`에 평문 record (Phase 3 timer가 N-14일 Pushover 알림에 사용).
- **1Password Individual 발견**: SA 발급 wizard "환경 액세스" 단계가 빈 목록 — Business/Teams의 환경 라벨 분류 기능으로 SA 권한·동작과 무관, 선택 없이 통과.
- **op CLI 필드 조회 방식**: `op item get --field`는 password 필드를 기본 redact해 `--reveal`이 필요하나(redact된 안내가 stdout 오염→401), 1Password 공식 권장은 `op read` secret reference URI다. `op_get`은 `op read --no-newline "op://vault/item/field"` 채택 (--reveal 불필요).
- **op CLI 멀티 계정**: op CLI에 개인(my.1password.com) + 회사(zaritalk) 계정이 함께 로그인되면 `op read`/`op item get` 모두 account 모호("multiple accounts") → `--account`(개인 계정 my.1password.com)로 고정. constants.onePassword.account에 박제. MiniPC(Phase 3)는 OP_SERVICE_ACCOUNT_TOKEN이 account를 결정하므로 호환성 별도 확인.
- **github-pat item 필드**: API Credential 템플릿 기본 "자격 증명" 대신 커스텀 `token` 라벨 필드 채택 (`op_get github-pat token` 매칭). 만료일+취득일 필드 추가 (1Password Watchtower 만료 알림 활용).
- **SSH agent 다이얼로그**: 1Password "Use the SSH agent" 토글 시 `~/.ssh/config` 자동편집 거부 — nix-darwin이 declarative 관리하므로 충돌. IdentityAgent 추가는 Phase 2a 책임.
- **회사 맥북 SSH 키 공유**: 개인 맥북 SSH 키가 회사 맥북에 사본 존재. 회사 맥북은 Tailnet 미멤버라 minipc 직접 접근은 차단되나, agenix `allHosts` 시크릿은 복호화 가능. work_mac 5번째 키 분리는 별 세션 grill-me 의제로 이관 (PRD FR-10 확장 후보).
- **worktree/main nrs 충돌**: main repo에서 `nrs` 실행 시 `~/.zshrc` symlink가 main generation으로 복원되어 op_get이 사라짐. worktree에서 `nrs` 재실행으로 복구. Phase 진행 중 main repo nrs 자제.

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-24: Phase 1 구현 완료. FR-1/2/4/5 완전 + FR-3(Phase 1 부분: 발급·저장·retrieval 검증)·FR-6(token 발급·agenix 보관) 달성. 코드 7건 + SA token agenix 보관 + expiry record. flake check 통과. hosts.yml 정리·구 PAT revoke·alias 활성은 Phase 2b, SA token EnvironmentFile·rotation timer는 Phase 3로 이관.
- 2026-05-25: PR #824로 squash merge. 리뷰 반영(host key·opnix expiry 경로 constants 중앙화 · SA token bridge 잠정 마킹+후보 나열 · constants.onePassword.account hard-pin) 후 merge. merge된 main을 nrs로 로컬 적용 후 E2E 전 항목 통과 (op CLI 2.34.0, op_get 함수 활성화, op read retrieval → gh api user=greenheadHQ, 에러 처리 2/127, opnix stub 비활성, flake check Test 5e-8/9/10 포함). Validation Checklist의 Observability(SA Activity log)·Manual smoke(재로그인 자동 unlock) 2건은 Phase 3/사용자 후속으로 잔존.
