# PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계

## Document Status

- Status: In Progress
- File Mode: Split
- Current Phase: Phase 1·2a·2b·3 merged (#824·#833·#827·#842) + Phase 4 GUI/박제 완료(PR 대기) — Phase 5·6 남음 + Phase 2a mobile SSH follow-up 열림(non-blocking)
- Active Phase File: [Phase 4](./prd-1password-migration/phase-04-apple-passwords.md)
- Last Updated: 2026-05-27
- PRD File: `.claude/prds/prd-1password-migration.md`
- Issue: [#780](https://github.com/greenheadHQ/nixos-config/issues/780)
- Purpose: Living PRD / 실행 source of truth. 여기에서 작업을 체크 off 하고, 구현 중 새 사실이 드러나면 이 문서를 갱신하고, 계획이 바뀌면 진행 전에 후속 phase를 수정한다.

## Problem

Vaultwarden self-host는 Mac/iOS 자동채움 UX·passkey·SSH agent·shell plugin 등 개발자 통합이 약해서 daily workflow에서 인지 마찰을 만든다. 동시에 LLM 주도 개발이 일상화되면서 credential 라이프사이클(rotate·scope·audit)을 LLM workflow와 매끄럽게 엮는 단일 경로가 부재하다. agenix는 NixOS 부트 의존 시크릿에는 적합하지만, user-level credential과 LLM 자동화 토큰까지 모두 떠안는 것은 과적이다.

## Goals

- G-1: Vaultwarden self-host를 종료하고 1Password (Individual)로 vault·passkey·SSH key·gh PAT를 통합 관리한다.
- G-2: op CLI를 Mac과 MiniPC 양쪽에 통합하여 LLM (Claude Code, Codex)이 user-level credential을 단일 패턴으로 호출한다.
- G-3: agenix를 NixOS 부트 의존 layer(systemd unit이 root로 자동 읽는 시크릿)로 축소한다.
- G-4: SSH key·passkey·passwords의 디바이스별 inventory를 1Password Automation vault에서 한눈에 본다.
- G-5: 새 secret 등록 시 "어디 둘지" 결정을 일관되게 내릴 수 있는 routing 규칙을 `managing-secrets` 스킬에 명문화한다.

## Non-Goals

- NG-1: 1Password Connect Server self-host 도입. MiniPC 단일 host + opnix + Service Account Token으로 충분. Connect 마이그레이션은 vault 수가 늘어나거나 권한 세분화 요구가 생기면 그때 재검토.
- NG-2: agenix 완전 제거. NixOS 부트 의존 시크릿(systemd unit이 root로 자동 읽는 컨테이너 API 토큰, Pushover 알림 토큰 등)은 agenix에 영구 잔존.
- NG-3: managing-1password 신설 스킬 분리. managing-secrets에 통합 + progressive disclosure로 운영.
- NG-4: gh 외 shell plugin (aws/npm/anthropic 등) 사전 도입. yagni — 실제 필요 트리거 발생 시 추가.
- NG-5: passkey의 즉시 일괄 마이그레이션. FIDO CXP 상호운용 vendor 공개 전까지 lazy migration (서비스별 다음 로그인 시점 재등록).
- NG-6: agenix와 1Password 양쪽에 동일 secret을 동기화하는 mirror 패턴. Routing 트리는 2단계 (부트 의존 → agenix / user-level → 1Password). 같은 토큰이 양쪽 필요한 드문 경우는 수동 이중 등록.
- NG-7: 1Password 데스크탑 앱을 Mac에 nixpkgs `_1password-gui`로 설치. macOS는 Homebrew Cask `1password` (nixpkgs `_1password-gui`는 Linux 전용).

## Success Criteria

- SC-1: Mac에서 `op item get`이 biometric으로 동작하고, MiniPC에서는 opnix(1Password Go SDK)가 `OP_SERVICE_ACCOUNT_TOKEN`으로 `op://` reference를 materialize한다 (op CLI 미설치 — headless에서 Go SDK가 op CLI를 대체). user-level credential을 단일 1Password 경로로 조회.
- SC-2: gh PAT가 1Password Automation vault에 보관되고, `gh` 명령이 Mac은 1Password Shell Plugin alias로, MiniPC는 opnix가 materialize한 github-pat을 주입하는 GH_TOKEN wrapper(headless)로 자동 인증된다. GitHub git transport(push/pull/fetch)는 Mac에서 `git_protocol=https` + `url."https://github.com/".insteadOf`로 gh credential helper(PAT) 경로를 거치며(SSH 키 미사용), MiniPC는 기존 SSH 경로를 유지한다 (#853, `pkgs.stdenv.isDarwin` 가드). 구 PAT는 GitHub 측에서 revoked 상태이고 `~/.config/gh/hosts.yml`에 평문 oauth_token이 없다.
- SC-3: Mac SSH 호출이 1Password SSH agent로 인증된다 (Touch ID popup). 1Password 장애 시 emergency ed25519 key로 fallback 가능하다 (실측 통과).
- SC-4: iPhone/iPad/Mac 4개 SSH key (mac/iphone/ipad/emergency)가 1Password Automation vault `ssh` tag에 inventory되고, MiniPC `authorized_keys`에 모두 등록되어 있다.
- SC-5: macOS Passwords 앱 export CSV의 모든 password/username 항목이 1Password에 import되고, TOTP/passkey field 매트릭스가 PRD에 박제되어 있다. iCloud Keychain AutoFill이 비활성화되어 있다.
- SC-6: Vaultwarden 컨테이너가 종료되고 관련 코드/모듈/스킬/agenix .age 파일이 모두 삭제되어 있다. acceptance command: `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 (PRD 자체는 작업 history로 보존되므로 제외). 단, `modules/nixos/programs/docker/immich-backup.nix`의 vaultwarden 인용 코멘트는 dead reference이므로 함께 제거.
- SC-7: `managing-secrets` 스킬에 routing 매트릭스(2단계 트리), 통합 inventory 표, 1Password 운영 절차가 명문화되어 있고, evals/queries.json이 1Password 컨텍스트로 재작성되어 있다.

## Key Scenarios

### Scenario 1: 새 secret을 어디 둘지 결정

- Actor: 사용자 또는 LLM (Claude Code, Codex)
- Trigger: 새 외부 서비스 API key 발급 또는 시스템 토큰 생성 필요
- Expected outcome: managing-secrets SKILL.md 상단의 routing 매트릭스 1개로 즉시 분기 결정. NixOS systemd가 root로 자동 읽으면 agenix, 그 외 모두 1Password Automation vault. tag(`system/` vs `dev/`) 분류도 함께 결정.

### Scenario 2: Mac 워크스테이션에서 gh pr create

- Actor: 사용자 또는 LLM
- Trigger: `gh pr create` 호출
- Expected outcome: 1Password Shell Plugin alias가 `op item get`으로 PAT 주입 → biometric prompt 1회 (30분 캐시) → GitHub API 호출 성공. `~/.config/gh/hosts.yml` 평문 토큰 부재.

### Scenario 3: MiniPC headless 자동화 (Claude Code session)

- Actor: SSH로 접속한 사용자의 Claude Code session
- Trigger: 자동화 스크립트가 `gh issue create` 호출
- Expected outcome: 부팅 시 opnix-secrets.service(1Password Go SDK root oneshot)가 agenix SA token으로 `op://Automation/github-pat/token`을 `/run/opnix/<user>/github-pat`(tmpfs, owner=user, 0400)에 materialize → SSH user shell의 `gh` GH_TOKEN wrapper가 그 파일을 읽어 `GH_TOKEN`으로 주입 → `gh` 명령 성공. SA token은 user shell에 노출되지 않음(root oneshot 전용). popup 없음 (headless). token 값은 stdout/log에 노출되지 않음.

### Scenario 4: iPhone Termius에서 ssh minipc

- Actor: 사용자 (iPhone Scriptable + Termius 워크플로)
- Trigger: Immich 업로드 → 경로 클립보드 복사 → Termius SSH → Claude Code 전달
- Expected outcome: iPhone Termius가 보유한 `iphone_ed25519` private key로 인증. Mac과 별개 키. MiniPC `authorized_keys`에 등록되어 있어 동작. 1Password가 down되어도 영향 없음.
- Follow-up validation: canonical gates and evidence format live in [Phase 2a post-merge remediation](./prd-1password-migration/phase-02a-mac-ssh.md#post-merge-remediation-termius-mobile-key-mismatch).

### Scenario 5: 디바이스 분실

- Actor: 사용자
- Trigger: iPad 분실
- Expected outcome: `hosts/greenhead-minipc/default.nix`의 MiniPC authorizedKeys 목록에서 iPad key를 제거하고, source value는 `libraries/constants.nix`의 `constants.sshDeviceKeys.ipad`와 대조 → `nrs minipc`. 1Password Automation vault에 백업된 `ipad_ed25519` item을 `revoked` tag. Mac/iPhone 영향 0.

### Scenario 6: SA token rotation (90일)

- Actor: 사용자 (Pushover 알림으로 트리거)
- Trigger: SA token 만료 14일 전 systemd timer가 Pushover 알림 전송
- Expected outcome: 1Password GUI에서 SA token 재발급 → agenix `secrets/opnix-service-account-token.age` re-encrypt → `nrs minipc` → opnix-secrets.service 재시작 → 동작 검증. 절차는 managing-secrets SKILL.md에 1페이지 박제.

### Scenario 7: Vaultwarden 종료

- Actor: 사용자
- Trigger: 2주 병행 검증 완료 후 종료 결정
- Expected outcome: vaultwarden-touch 파일 단일 atomic PR (정확한 대상 목록은 Phase 6 Implementation Checklist가 SSOT). `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 게이트 통과. 종료 시점에 backup 디렉토리를 중립 이름 path(예: `/mnt/data/backups/archives/password-manager-<shutdown-date>`)로 이전 후 6개월 보관. 정확한 archive path, `<shutdown-date>`, purge reminder 날짜는 Phase 6 Implementation Checklist가 SSOT.

## Discovery Summary

- Reviewed: `modules/nixos/programs/docker/vaultwarden.nix`, `modules/nixos/programs/docker/vaultwarden-backup.nix`, `modules/nixos/programs/vaultwarden-update/default.nix`, `modules/nixos/programs/caddy.nix`, `modules/nixos/programs/smoke-test.nix`, `modules/darwin/programs/ssh/default.nix`, `secrets/secrets.nix`, `libraries/constants.nix`, `tests/eval-tests.nix`, `.claude/skills/managing-secrets/SKILL.md`, `.claude/skills/hosting-vaultwarden/SKILL.md`, `.claude/skills/running-containers/references/scriptable-immich-upload.md`
- Discovery baseline at PRD creation (2026-05-17): Vaultwarden Podman 컨테이너 (`vaultwarden/server:1.35.4`, port 8222, vaultwarden.greenhead.dev, Tailscale 내부 전용, Caddy reverse proxy). 매일 04:30 KST SQLite + rsync 백업, 30일 보존. agenix `.age` 23개 (`secrets/secrets.nix`), 그중 `vaultwarden-admin-token` + `pushover-vaultwarden`이 Vaultwarden 의존. Mac SSH는 당시 `~/.ssh/id_ed25519` + `launchd.agents.ssh-add-keys` 경로였다. 이후 변경은 각 phase change log가 canonical이다.
- Validation surface: `nrs` (nix-darwin/nixos-rebuild) + `nix flake check --no-build --all-systems` + `tests/eval-tests.nix` + `smoke-test.nix` + `managing-secrets/evals/queries.json`. 1Password 동작은 GUI + `op` CLI 명령 + Touch ID 응답으로 manual 검증.
- Design implications: (a) 1Password Service Account가 Individual 플랜에서 GUI 노출됨을 사용자가 GUI 스크린샷으로 확인 (2026-05-17). (b) Mac은 Homebrew Cask `1password`, NixOS는 nixpkgs `_1password-cli`만. (c) opnix canonical은 `brizzbuzz/opnix` (mrjones2014는 archived, brizzbuzz README가 명시). (d) envScript 패턴은 vaultwarden뿐 아니라 karakeep에서도 사용 중 → 별도 references 이관 불필요.
- Confidence / gaps: Apple Passwords CSV의 TOTP/passkey 보존 여부는 Phase 4에서 sample 3개 사전 실측으로 확정한다. 1Password Individual은 Events API audit log 없음 — 구조적 한계로 vault separation + rotation cadence로 보완.

## Requirements

### Functional Requirements

- FR-1: 1Password 데스크탑 앱과 op CLI를 Mac에 Homebrew Cask로 설치한다.
- FR-2: 1Password Automation vault를 생성하고, item naming convention `<service>-<role>[-<host>]`를 박제한다.
- FR-3: gh PAT rotation을 Phase 1과 Phase 2b로 분할한다. Phase 1 acceptance: (1) 신규 PAT 발급 → 1Password Automation vault `github-pat` item 저장 → (2) `GH_TOKEN=$(op_get github-pat token) gh api user`로 retrieval 동작 검증까지. Phase 2b acceptance: (3) Shell Plugin alias 활성화 후 `gh api user` 동작 → (4) `~/.config/gh/hosts.yml` 평문 oauth_token 제거 → (5) 구 PAT GitHub 측 revoke → (6) audit (`gh api user` + `git log -p` 평문 검색).
- FR-4: `libraries/constants.nix`에 `onePassword.vaults.{personal, automation}` 상수를 등록한다.
- FR-5: `op_get <name> <field> [<vault>]` helper (zsh function 또는 shell library)를 작성한다. vault 기본값은 `constants.onePassword.vaults.automation`.
- FR-6: 1Password Service Account를 발급하고 토큰을 `secrets/opnix-service-account-token.age`로 agenix에 보관한다 (Phase 1). 90일 rotation systemd timer + Pushover 알림(만료 N-14일)은 MiniPC 시스템 구성이므로 Phase 3에서 구현·activation 검증한다.
- FR-7: Mac `~/.ssh/config`에 1Password group container socket(`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`)을 `IdentityAgent`로 추가. ControlPersist 정책 결정 (영구 또는 daemon master).
- FR-8: `launchd.agents.ssh-add-keys.enable = false` 또는 동등 게이트. `~/.ssh/id_ed25519` 처분 결정 (archive 또는 1Password vault item으로 이관 후 file 삭제).
- FR-9: Emergency ed25519 fallback key (`emergency_ed25519`) 생성 + `~/.ssh/config` Host 분기 + MiniPC `authorized_keys` 등록 + 실측 acceptance ("1Password 데스크탑 quit 후 emergency key로 ssh minipc 성공").
- FR-10: 디바이스별 SSH 키 4개 (`mac_ed25519` agent-managed, `iphone_ed25519`, `ipad_ed25519`, `emergency_ed25519`). 1Password Automation vault `ssh` tag에 backup copy + revocation 절차 박제. MiniPC authorized key source는 `libraries/constants.nix`의 `constants.sshDeviceKeys`와 이를 소비하는 `hosts/greenhead-minipc/default.nix`의 `users.users.${username}.openssh.authorizedKeys.keys`이다.
- FR-11: `op plugin init gh` 실행 후 `~/.config/op/plugins.sh`를 `programs.zsh.initContent`에 declarative source 등록 (Home Manager).
- FR-12: `modules/nixos/programs/opnix/default.nix`에 opnix `services.onepassword-secrets`(1Password Go SDK root oneshot)를 설정해 SA token으로 `op://` reference를 tmpfs에 owner-scoped materialize한다. SA token을 user shell로 export하는 EnvironmentFile/profile.d 방식은 폐기(user shell 노출 방지).
- FR-13: macOS Passwords 앱에서 sample 3개 (password-only / TOTP / passkey 항목 각 1개) 사전 export → CSV field 매트릭스 PRD에 박제 → 정책 결정 (TOTP 별도 sub-phase로 분리 여부) → 일괄 import 실행.
- FR-14: iOS/macOS 설정에서 "AutoFill Passwords" 1Password만 활성화, iCloud Passwords 토글 해제.
- FR-15: `managing-secrets/SKILL.md` 상단에 routing 매트릭스 (2단계: 부트 의존 → agenix / user-level → 1Password Automation) + tag convention (`system/`, `dev/`) + Automation vault sub-folder 컨벤션 명문화.
- FR-16: `managing-secrets/references/inventory.md` 또는 SKILL.md inline에 통합 inventory 표 (`name × storage × vault × age path × 소비처`).
- FR-17: `managing-secrets/evals/queries.json`을 두 phase로 분할 처리한다 — Phase 5는 1Password 혼동 쌍 add-only (vaultwarden 쌍은 그대로 두되 deprecation comment만), Phase 6은 vaultwarden 쌍 delete-only.
- FR-18: 2주 병행 검증 후 Vaultwarden 종료: vaultwarden-touch 파일을 단일 atomic PR로 처리. 정확한 대상 목록·라인 위치·삭제/수정 구분은 Phase 6 Implementation Checklist가 SSOT. 본 FR는 atomic PR 단위 정책만 박제하며 카운트 표기는 사용하지 않는다 (drift 방지). 대분류만 명시: (a) 전체 삭제(코드 모듈 / agenix `.age` / hosting-vaultwarden 스킬 디렉토리), (b) 라인·블록 수정(MiniPC configuration.nix / caddy.nix / options/homeserver.nix / smoke-test.nix / immich-backup.nix 주석 / eval-tests.nix / constants.nix / secrets.nix publicKeys / README.md).
- FR-19: cross-reference cleanup: `managing-minipc/references/host-prerequisites.md` "3종" → "2종", `running-containers/SKILL.md` NOT-for 분기, `running-containers/evals/queries.json` vaultwarden 쌍, `README.md` 잔존 등.
- FR-20: 백업 보관: 종료 시점에 backup 디렉토리를 중립 이름 path로 archive하여 6개월 보관 (`rg -w vaultwarden` gate 통과 보장). 정확한 archive path, 종료일 (`<shutdown-date>`), 6개월 후 purge reminder 일정은 Phase 6 Implementation Checklist가 SSOT.

### Non-Functional Requirements

- NFR-1: PRD에 박제된 모든 phase는 PR 1개로 atomic 적용 가능해야 한다. Phase 6 (Vaultwarden EOL)은 vaultwarden-touch 파일 전체를 단일 atomic PR로 처리한다 (대상 목록 SSOT는 Phase 6 Implementation Checklist).
- NFR-2: `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 (Phase 6 acceptance gate). PRD 디렉토리는 작업 history로 보존되므로 제외.
- NFR-3: `managing-secrets/SKILL.md` ≤ 250줄 (현재 129줄). 초과 시 references/ 분할 트리거.
- NFR-4: SA token rotation cadence ≤ 90일. 자동화 systemd timer + Pushover 알림 필수.
- NFR-5: emergency ed25519 fallback 실측 (1Password 데스크탑 quit 후 ssh minipc 성공) Phase 2a acceptance gate.

## Assumptions

- A-1: 사용자 1Password Individual 계정 (이미 구독 중)에서 Service Account 생성 기능이 활성화되어 있다 (2026-05-17 GUI 확인 완료).
- A-2: iPhone/iPad SSH는 Termius 앱에서 디바이스 로컬 key file을 직접 보유하는 패턴이 영구 유지된다 (1Password SSH agent의 iOS system-level socket 미지원).
- A-3: opnix-secrets.service는 부팅 시 1Password SaaS HTTPS 호출이 필요하므로, "재부팅 후 무인 가용성 SLO가 필요한 컨테이너 secret"은 agenix에 영구 잔존한다 (Routing 트리 1단계).
- A-4: 1Password Individual은 Events API audit log를 제공하지 않는다. SA token 오남용은 vault separation + rotation cadence + journald 호출 로깅 (forensic only)으로 보완한다.
- A-5: managing-secrets 스킬 1개로 agenix + 1Password 양쪽 라우팅이 충분하다. SKILL.md ≤ 250줄 초과 시 references/ 분할 (NFR-3).
- A-6: brizzbuzz/opnix가 NixOS opnix 패턴의 canonical 구현이다 (mrjones2014/opnix는 archived).

## Dependencies / Constraints

- 1Password SaaS 가용성: opnix-secrets.service는 부팅 시 1Password API 호출. SaaS outage 시 의존 컨테이너 미기동 → A-3에 따라 컨테이너 secret은 agenix 잔존.
- nixpkgs unfree: Homebrew Cask `1password` (Mac)는 unfree (nix-darwin homebrew.casks 등록). MiniPC는 opnix Go SDK가 materialize하므로 `_1password-cli` 불필요 (op CLI 미설치).
- agenix host key 부트 의존: opnix-service-account-token.age 복호화는 host SSH key 기반. 부트 시점 1Password 의존 없음 (순환 안전).
- 1Password Individual 한계: Events API 없음. SA token rotation 90일 cadence가 보완책.

## Risks / Edge Cases

- iPhone/iPad SSH key file 보유 패턴은 1Password 의도와 보안 모델이 다름 (A-2). 디바이스 분실 시 즉시 `hosts/greenhead-minipc/default.nix`의 authorizedKeys 소비 목록에서 해당 디바이스 key를 제거하고, `libraries/constants.nix`의 `constants.sshDeviceKeys` 값과 vault item 상태를 대조한다.
- emergency ed25519 fallback이 일상적으로 사용되면 "emergency"가 아님. 사용 빈도 모니터링 필요 (사용자가 수동 인지).
- Apple Passwords CSV의 TOTP/passkey 보존이 실패할 경우 TOTP는 별도 sub-phase로 분리하여 서비스별 재설정.
- Vaultwarden 컨테이너 종료 후 2-6개월 사이 backup 모니터링 부재 (smoke-test 게이트 제거). 6개월 만료 시점 사용자 manual integrity check.
- gh PAT 구 토큰이 git history에 commit되었을 가능성: Phase 1에 `git log -p` 검색 + GitHub Secret scanning 알림 확인.

## Execution Rules

- 본 PRD가 명시적으로 수정되지 않는 한 phase는 순서대로 완료한다. 단 Phase 4와 Phase 6은 의존 없음 → 병렬 가능.
- 어떤 phase든 시작 전에 master PRD + active phase file + 관련 context note를 읽는다.
- PRD 파일만 active plan으로 사용한다. 경쟁하는 별도 체크리스트를 만들지 않는다.
- 사소한 애매함은 가장 합리적인 옵션을 고르고 assumption으로 기록한 뒤 계속 진행한다.
- 다음 항목에 한해서만 진행을 멈추고 도움을 요청한다: 접근 권한 부재, 비가역적 파괴 변경, 주요 요구사항 충돌, 보안/법률 관련 의미 있는 risk.
- 목표를 만족하는 최소·가역적 변경을 선호한다.
- 명백한 사유가 없는 한 기존 코드 패턴을 보존한다.
- 검증 방법은 risk와 가용 도구에 맞춰 선택한다. 모든 phase에 동일 tool을 기본값으로 사용하지 않는다.
- 각 phase 종료 시 본 PRD를 갱신하고 학습 결과에 따라 후속 phase를 수정한다.

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Foundation | Done (merged #824) | Mac 1Password 설치, Automation vault, gh PAT rotation, op_get helper, SA token | nrs darwin + gh API + op CLI 동작 | [phase-01-foundation.md](./prd-1password-migration/phase-01-foundation.md) |
| Phase 2a: Mac SSH | Done (merged #833) + mobile follow-up open | IdentityAgent + emergency fallback + 디바이스별 키 inventory | ssh minipc 동작 + 1Password quit 후 fallback 실측 + mobile post-merge remediation gate | [phase-02a-mac-ssh.md](./prd-1password-migration/phase-02a-mac-ssh.md) |
| Phase 2b: Shell plugin gh | Done (merged #827) | Home Manager declarative plugin 등록 | gh pr list 동작 (biometric prompt 1회) | [phase-02b-shell-plugin-gh.md](./prd-1password-migration/phase-02b-shell-plugin-gh.md) |
| Phase 3: MiniPC opnix | Done (merged #842) | opnix native materialization + SA token + gh GH_TOKEN wrapper | nrs minipc + ssh minipc E2E 전항목 통과 | [phase-03-minipc-opnix.md](./prd-1password-migration/phase-03-minipc-opnix.md) |
| Phase 4: Apple Passwords | Done (GUI/박제 — PR 대기) | CSV 매트릭스 실측, 62개 import, iCloud AutoFill OFF, passkey(기존 1Password) | 분기 A + TOTP 동작 + secure delete 게이트 통과 | [phase-04-apple-passwords.md](./prd-1password-migration/phase-04-apple-passwords.md) |
| Phase 5: Skill 리팩토링 | Not Started | managing-secrets routing 매트릭스 + inventory + queries.json | evals/queries.json 통과 + SKILL.md ≤ 250줄 | [phase-05-skill-refactor.md](./prd-1password-migration/phase-05-skill-refactor.md) |
| Phase 6: Vaultwarden EOL | Not Started | vaultwarden-touch 파일 atomic 삭제·수정 단일 PR + rg 잔존 0건 + 6개월 백업 정책 | nrs minipc + eval-tests + rg | [phase-06-vaultwarden-eol.md](./prd-1password-migration/phase-06-vaultwarden-eol.md) |

의존성 그래프: Phase 1 → Phase 2a, Phase 2b, Phase 3. Phase 3 → (Phase 5 일부). Phase 4와 Phase 6은 서로 무관. Phase 5는 Phase 1-3 완료 후 시작 (1Password 운영 패턴이 안정되어야 inventory/routing 매트릭스 작성 가능). Phase 2a mobile SSH follow-up은 Phase 5의 blocking dependency가 아니다. 해당 상태별 Phase 5 gate는 [Phase 5 Mobile SSH Integration Policy](./prd-1password-migration/phase-05-skill-refactor.md#phase-2a-mobile-ssh-integration-policy)가 canonical이다.

## Appendix: 최종 secrets.nix 변경 요약

| Secret | Before | After | Phase |
|---|---|---|---|
| `opnix-service-account-token.age` | (없음) | publicKeys=minipcHostOnly (host key) | Phase 1 |
| `vaultwarden-admin-token.age` | publicKeys=minipc | (삭제) | Phase 6 |
| `pushover-vaultwarden.age` | publicKeys=minipc | (삭제) | Phase 6 |
| 기타 .age (immich/karakeep/copyparty 등) | publicKeys=minipc | 변경 없음 | — |

## Final Multi-Pass Review After All Phases

`.claude/skills/plan-with-questions/references/prd/multi-pass-review.md` 체크리스트를 수행한다. 10-pass 항목 + review-impl overlay (6-classification + overbuilt 우선 분류). auto-fix 미적용.

## Open Questions

- Phase 2c (git commit signing 통합) 도입 시점과 범위는 별도 epic으로 분리할지 본 PRD에서 다룰지. 현재는 Out of Scope.
- Phase 2a mobile SSH follow-up: iPhone Tailscale IP에서 MiniPC `sshd`까지 연결은 도달했지만 PAM 인증 실패로 종료됐고, 당시 MiniPC는 `kbdinteractiveauthentication yes` 상태였다. 직전 iPhone 성공 기록의 accepted publickey fingerprint는 현재 등록된 `iphone-ssh`가 아니라 retired `macbook` key와 일치했다(2026-05-26). **[2026-05-30 baseline 진단]**: MiniPC `sshd` journal 실측으로 retired 공유 키 `SHA256:6RE7…RydQ`가 그 정체로 확정됐다(iPhone 66회·iPad 14회 accept, 마지막 2026-05-25T17:37 KST; `iphone-ssh`/`ipad-ssh`는 전 기간 accept 0회) → 근본 원인은 Termius 클라이언트 키 미교체. `modules/nixos/programs/ssh.nix`에 `KbdInteractiveAuthentication = false`를 추가(배포 대기)했고, 전용 추적 이슈 #866을 등록했다. 결정 질문과 닫힘 조건의 상세 SSOT는 [Phase 2a post-merge remediation](./prd-1password-migration/phase-02a-mac-ssh.md#post-merge-remediation-termius-mobile-key-mismatch)이다.
- ~~Phase 4의 TOTP 별도 sub-phase 범위 (서비스 카운트 N건 임계)~~ **[해소 — 2026-05-26]**: CSV에 otpauth 포함(분기 A) 실측 확인 → 별도 sub-phase 불필요, generic CSV import로 일괄(OTPAuth→`one-time password` 라벨).
- ~~SA token user shell bridge 설계 (Phase 3)~~ **[해소됨 — 2026-05-25 설계 확정, 기술 자문 교차검증]**: **opnix native materialization** 채택. opnix system module(`services.onepassword-secrets` — op CLI 래퍼가 아니라 1Password Go SDK 기반 root oneshot)이 SA token(`/run/agenix/opnix-service-account-token`, **0400 root 유지**)을 읽어 `op://Automation/github-pat/token`을 user-readable 파일(`/run/opnix/greenhead/github-pat`, tmpfs, owner=greenhead mode 0400)로 materialize한다. gh는 `GH_TOKEN` wrapper로 그 파일을 읽어 인증 → **SA token은 user shell/프로세스에 노출 0**(opnix root oneshot만 SA token 사용, user는 결과물 github-pat만 받음).
    - 기각된 후보: (1) systemd+polkit — 정책 복잡 + SA token이 여전히 user 도달, (2) wrapper binary(setuid/capability) — 보안 표면·감사 부담, (3) derived limited-scope credential — 1Password SA가 정적 JWT(AUK+SRP+keyset 직렬화)라 child token 발급 미지원.
    - 자문 교차검증 추가 제약: `services.onepassword-secrets.users` 옵션은 token file을 `root:onepassword-secrets 0640`(group readable)으로 바꾸므로 **사용 금지**(SA token 0400 root 유지), gh Shell Plugin(`op plugin run`)은 desktop app + interactive credential selection을 요구해 headless SA 모드에 부적합 → GH_TOKEN wrapper로 대체. github-pat 디스크 상주는 tmpfs(`/run`)로 재부팅 시 휘발 + blast radius가 SA token보다 작음(GitHub scope 한정·rotation 용이).

## Change Log

- 2026-05-17: Initial PRD created. grill-me 결정사항 + DA review findings 반영. 사용자 추가 결정: routing 트리를 2단계로 단순화하고 mirror 패턴 폐기, 디바이스별 SSH key 4개 (mac/iphone/ipad/emergency), iCloud Keychain AutoFill 비활성화, envScript 패턴은 다른 컨테이너에서 자연 보존.
- 2026-05-24: Phase 1 구현 완료 (PR 대기). Mac 1Password(Homebrew Cask) 설치, Automation vault, gh PAT 발급+1Password 저장+retrieval 검증 (login greenheadHQ), op_get helper (op read secret reference + 멀티계정 --account 고정), SA token (`nixos-automation-minipc`, 전역 공유·minipc 단일 저장, host key 전용 recipient) agenix 보관, opnix stub + expiry record. 발견: 1Password Individual은 SA 자동 만료 미지원 → 정책 90일 cadence (만료 목표 2026-08-22, NFR-4 준수); op CLI 필드 조회는 op read secret reference 권장; op CLI 멀티 계정(개인+회사) 환경은 --account 고정 필요. 사용자 신규 결정: SA 운영 모델은 전역 공유 1개 (Mac은 biometric이라 SA 미사용, 실 소비처 minipc). 회사 맥북 SSH 키 분리는 별 세션 의제로 이관 (FR-10 확장 후보).
- 2026-05-25: Phase 1 PR #824로 squash merge. 리뷰 반영 — agenix host key·opnix expiry 경로를 constants.nix로 중앙화, SA token user shell bridge를 잠정 설계로 마킹하고 해결 후보 3종(systemd+polkit / wrapper binary / derived credential) 나열, constants.onePassword.account hard-pin 추가. merge 후 nrs 로컬 적용 + E2E 전 항목 통과 (op_get retrieval → gh api user=greenheadHQ, op_get 함수 활성화, 에러 처리 2/127, opnix stub 비활성, flake check). Phase 2a/2b/3 진입 가능.
- 2026-05-25: Phase 2b 구현 완료 → PR #827 squash merge. gh를 1Password Shell Plugin alias로 전환 — `shell/default.nix`에 plugins.sh file-guard source chunk + `op plugin init gh`(global default, github-pat) + nrs. `gh api user`=greenheadHQ(op plugin 경유 github-pat 주입) 검증, hosts.yml 평문 oauth_token 0건(yq 제거+백업), git history leak 0건, 구 PAT 없음 확인, keyring `gho_` unused fallback 유지 결정. merge 후 main을 nrs로 적용 + E2E 전항목 통과(type gh=alias, gh api user=greenheadHQ, hosts.yml 평문 0건, gh pr list 정상). Phase 2a/3 진입 가능.
- 2026-05-25: Phase 2a 구현 완료 → PR #833 squash merge. Mac SSH를 1Password agent로 전환 — 디바이스 키 4개(mac-ssh/iphone/ipad/emergency, `constants.sshDeviceKeys`)를 MiniPC authorizedKeys에 배포, ssh config에 IdentityAgent(group container socket)·agent.toml(Automation vault 노출)·minipc-emergency Host·ControlPersist 600(ControlMaster 유지 — #710 analyzing-da-sessions 회귀 방지) 추가, id_ed25519 archive(agent 전용 정리). 검증: ssh minipc=mac-ssh agent 인증(Touch ID), emergency fallback 실측(1Password quit→emergency 접속→ssh minipc 실패→재시작 복귀), id_ed25519 처분 후 agent-only 인증. merge 후 main nrs 적용 + E2E 전항목 재검증 통과 (ssh config·agent.toml nix home.file 박제·ssh-add -l mac-ssh+emergency·ssh minipc agent-only). agent.toml vault를 constants 참조로 정정 (SSOT). 발견: ControlPersist 영구는 무인 파이프 hang(→600), agent socket은 group container 경로, agent.toml로 키 노출 명시 필수. Phase 3 진입 가능.
- 2026-05-25: Phase 3 SA token user shell bridge 설계 확정 (구현은 별도 세션). opnix native materialization 채택 — Open Questions 후보 1/2/3 기각, opnix system module(`services.onepassword-secrets`)이 root oneshot으로 SA token(0400 root 유지)을 읽어 github-pat을 user 파일(tmpfs `/run/opnix/greenhead/github-pat`, 0400 greenhead)로 materialize, gh는 GH_TOKEN wrapper. 외부 기술 자문(codex xhigh) 교차검증으로 opnix가 op CLI 래퍼가 아닌 Go SDK oneshot임을 확인하고, `services.onepassword-secrets.users` 옵션 금지(0640 group readable 회피)·Shell Plugin headless 부적합을 반영. phase-03 Scope/Implementation Checklist를 확정안으로 갱신.
- 2026-05-25: Phase 3 구현 완료 (PR #842). 확정 설계(opnix native materialization)를 구현 — flake.nix opnix input(v0.10.1) + nixosModules.default, opnix/default.nix(SA token agenix + `services.onepassword-secrets`로 github-pat을 `/run/opnix/greenhead/github-pat` tmpfs 0400 materialize + tmpfiles 0700), configuration.nix opnix.enable, shell/nixos.nix gh GH_TOKEN wrapper, opnix-rotate.nix(weekly Pushover), eval-tests 보안 핀 6개. 구현 발견: opnix가 tokenFile을 `users` 옵션과 무관하게 강제 `0640 root:onepassword-secrets`로 chmod → 설계의 "tokenFile 0400 root 유지"는 모듈 fork 없이 불가, agenix secret도 0640 onepassword-secrets로 선언(권한 경합 제거) + `users` 비워 group 멤버 0으로 **실질 root-only** 수용(보안 효과는 0400과 동일, SA token user shell 노출 0 충족); secret key camelCase 강제(githubPat); parent dir 0755 root MkdirAll → tmpfiles 0700 선생성으로 보존; opnix가 network-online.target after/wants + Restart=on-failure 기본 제공; `_1password-cli` 불필요(Go SDK). CodeRabbit 리뷰 반영(MD037 실제 원인은 underscore emphasis → 백틱, token.age 경로 constants 중앙화, eval-tests 정확매칭+tmpfiles 0700 핀). flake check + eval-tests 통과. MiniPC E2E는 merge 후 main pull + nrs로 진행(Phase 1/2b 패턴).
- 2026-05-26: Phase 3 PR #842 squash merge → MiniPC 배포(main pull + nrs, 29s) + E2E 전항목 통과. opnix-secrets.service active(exited, 부팅 자동 활성), github-pat materialize `/run/opnix/greenhead/github-pat`=400 greenhead:users(tmpfs), SA tokenFile=640 root:onepassword-secrets(users 비움 → 실질 root-only), gh GH_TOKEN wrapper로 `gh api user`=greenheadHQ·`gh pr list` 정상, SA token user shell 노출 0(env grep), opnix-rotate-check.timer 등록(다음 2026-06-01) + dry-run exit 0(만료 2026-08-22, 87일 → silent). Phase 4(Apple Passwords)·5(skill 리팩토링)·6(Vaultwarden EOL) 남음. 후속 개선: Mac 비대화형/LLM gh가 op Shell Plugin biometric으로 매 호출 Touch ID 마찰 → #848 등록(GH_TOKEN 우회 경로, Mac 한정). SSH ControlMaster·MiniPC GH_TOKEN wrapper는 무관 확인.
- 2026-05-26: Phase 4 (Apple Passwords) GUI/실기 완료 + PRD 박제 (PR 대기). 외부 조사(Apple/1Password/FIDO 공식 교차검증)로 PRD 가정 2건 정정 — (1) macOS 1Password는 시스템 AutoFill provider 미등록 설계라 Phase 4d "1Password ON 토글" 불성립(iCloud AutoFill OFF + 브라우저 extension으로 재정의; iOS는 시스템 토글 유효), (2) macOS 1Password는 FIDO Credential Exchange import 미구현(iOS 26·Android 14+만 수신)이라 CXP 직접 이전 불가 → CSV 경로 확정. CSV 매트릭스 실측(헤더 Title/URL/Username/Password/Notes/OTPAuth 6컬럼, 68 records, TOTP는 OTPAuth 컬럼 otpauth로 포함 → 분기 A). generic CSV import(Safari importer는 TOTP 버림 회피, OTPAuth→one-time password 라벨)로 62개(68−6 선별) 개인 vault 적재 + TOTP 6자리 코드 동작 검증 + green.com SSH·Twitch 중복 정리. CSV `/bin/rm -P` secure delete + 종료 게이트 0건(TM 백업 미설정 → N/A). passkey는 Google 1개가 기존 1Password passkey(2024-09)로 이미 충족 → Phase 4e lazy migration 정책 + 90일 calendar 폐기(YAGNI). SC-5 달성. Phase 5·6 남음.
- 2026-05-26: Phase 2a(#833) SSH agent 이관 후속 fix → PR #853 squash merge. 디바이스 키를 1Password agent로 이관하며 기존 GitHub 등록 키가 교체돼 GitHub 미등록 상태가 되자 `git@github.com:` remote의 SSH 인증이 `Permission denied (publickey)`로 실패(fetch/pull 차단). Mac 한정 https+gh credential helper(PAT) 경로로 통일 — `programs.gh.settings.git_protocol`을 darwin=https/nixos=ssh로 분기 + `url."https://github.com/".insteadOf="git@github.com:"`를 `pkgs.stdenv.isDarwin` 가드(`modules/shared/programs/git/default.nix`). SSH 키 GitHub 재등록 대신 gh credential helper 경로를 채택한 이유: 키 등록·관리 부담 제거 + #848 gh Touch ID 마찰 회피(SSH 경로 미사용). credential helper는 별도 gh 프로세스로 keyring PAT 또는 git 프로세스의 GH_TOKEN을 조회한다(git이 GH_TOKEN을 직접 읽지 않음 — #848 GH_TOKEN 주입이 적용되면 git transport도 무인 이득). MiniPC는 토큰 공급원이 달라(opnix github-pat) darwin 한정으로 좁힘 — 동일 통일 시 별도 설계 필요(deferred). merge 후 main nrs 적용 + E2E 전항목 통과(SSH 강제 차단 `GIT_SSH_COMMAND=false`에도 `git@github.com:` URL 연산 성공, nrs closure delta +0, insteadOf·git_protocol 활성). PRD 사각지대 보강: 그동안 SC-2가 `gh` 명령 인증만, SC-3/4·FR-10이 SSH 키를 원격 호스트 접속 용도로만 다뤄 GitHub git transport 인증 경로가 누락됐던 것을 SC-2에 명시.
- 2026-05-26: Phase 2a(#833) SSH agent 이관 후속 사각지대 발견 — iPhone Termius 접속은 MiniPC까지 도달했으나 인증 단계에서 실패했다. MiniPC `sshd` 로그는 iPhone Tailscale IP에서 PAM 인증 실패를 반복했고, 당시 MiniPC는 `kbdinteractiveauthentication yes` 상태였다. 직전 iPhone 성공 기록의 accepted publickey fingerprint는 현재 등록된 `iphone-ssh`가 아니라 retired `macbook` key와 일치했다. Phase 2a에 mobile Termius remediation checklist와 사용자 결정 질문을 추가. 향후 closeout은 Termius actual connection identity + server-side accepted fingerprint를 동시에 확인해야 한다.
