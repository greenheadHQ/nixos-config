# PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계

## Document Status

- Status: In Progress
- File Mode: Split
- Current Phase: Phase 2a Done (PR 대기) — Phase 1·2b merged (#824·#827), Phase 3 ready (선택 대기)
- Active Phase File: [Phase 1](./prd-1password-migration/phase-01-foundation.md)
- Last Updated: 2026-05-25
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

- SC-1: Mac과 MiniPC에서 `op item get` 명령이 `OP_SERVICE_ACCOUNT_TOKEN` (MiniPC) 또는 biometric (Mac) 으로 정상 동작한다.
- SC-2: gh PAT가 1Password Automation vault에 보관되고, Mac/MiniPC 모두 `gh` 명령이 1Password Shell Plugin alias로 자동 인증된다. 구 PAT는 GitHub 측에서 revoked 상태이고 `~/.config/gh/hosts.yml`에 평문 oauth_token이 없다.
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
- Expected outcome: 부팅 시 opnix-secrets.service가 agenix SA token을 systemd EnvironmentFile로 주입 → SSH user shell 진입 시 `/etc/profile.d/opnix.sh` bridge가 `OP_SERVICE_ACCOUNT_TOKEN`을 user env로 노출 → Shell Plugin alias `gh = op plugin run -- gh`가 호출 시점에 `op item get`으로 PAT 자동 주입 → `gh` 명령 성공. popup 없음 (headless). token 값 자체는 stdout/log에 노출되지 않음.

### Scenario 4: iPhone Termius에서 ssh minipc

- Actor: 사용자 (iPhone Scriptable + Termius 워크플로)
- Trigger: Immich 업로드 → 경로 클립보드 복사 → Termius SSH → Claude Code 전달
- Expected outcome: iPhone Termius가 보유한 `iphone_ed25519` private key로 인증. Mac과 별개 키. MiniPC `authorized_keys`에 등록되어 있어 동작. 1Password가 down되어도 영향 없음.

### Scenario 5: 디바이스 분실

- Actor: 사용자
- Trigger: iPad 분실
- Expected outcome: `modules/nixos/users/<user>/authorized_keys.nix`에서 ipad 라인 1개 제거 → `nrs minipc`. 1Password Automation vault에 백업된 `ipad_ed25519` item을 `revoked` tag. Mac/iPhone 영향 0.

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
- Current system: Vaultwarden Podman 컨테이너 (`vaultwarden/server:1.35.4`, port 8222, vaultwarden.greenhead.dev, Tailscale 내부 전용, Caddy reverse proxy). 매일 04:30 KST SQLite + rsync 백업, 30일 보존. agenix `.age` 23개 (`secrets/secrets.nix`), 그중 `vaultwarden-admin-token` + `pushover-vaultwarden`이 Vaultwarden 의존. Mac SSH: `~/.ssh/id_ed25519` + `launchd.agents.ssh-add-keys` (`modules/darwin/programs/ssh/default.nix:16-21, 52-64`). `programs.gh` enable (`modules/shared/programs/git/default.nix:176`). gh 호출 빈도: MiniPC Claude Code 단일 세션 39회.
- Validation surface: `nrs` (nix-darwin/nixos-rebuild) + `nix flake check --no-build --all-systems` + `tests/eval-tests.nix` + `smoke-test.nix` + `managing-secrets/evals/queries.json`. 1Password 동작은 GUI + `op` CLI 명령 + Touch ID 응답으로 manual 검증.
- Design implications: (a) 1Password Service Account가 Individual 플랜에서 GUI 노출됨을 사용자가 GUI 스크린샷으로 확인 (2026-05-17). (b) Mac은 Homebrew Cask `1password`, NixOS는 nixpkgs `_1password-cli`만. (c) opnix canonical은 `brizzbuzz/opnix` (mrjones2014는 archived, brizzbuzz README가 명시). (d) envScript 패턴은 vaultwarden뿐 아니라 karakeep·awesome-anki에서도 사용 중 → 별도 references 이관 불필요.
- Confidence / gaps: Apple Passwords CSV의 TOTP/passkey 보존 여부는 Phase 4에서 sample 3개 사전 실측으로 확정한다. 1Password Individual은 Events API audit log 없음 — 구조적 한계로 vault separation + rotation cadence로 보완.

## Requirements

### Functional Requirements

- FR-1: 1Password 데스크탑 앱과 op CLI를 Mac에 Homebrew Cask로 설치한다.
- FR-2: 1Password Automation vault를 생성하고, item naming convention `<service>-<role>[-<host>]`를 박제한다.
- FR-3: gh PAT rotation을 Phase 1과 Phase 2b로 분할한다. Phase 1 acceptance: (1) 신규 PAT 발급 → 1Password Automation vault `github-pat` item 저장 → (2) `GH_TOKEN=$(op_get github-pat token) gh api user`로 retrieval 동작 검증까지. Phase 2b acceptance: (3) Shell Plugin alias 활성화 후 `gh api user` 동작 → (4) `~/.config/gh/hosts.yml` 평문 oauth_token 제거 → (5) 구 PAT GitHub 측 revoke → (6) audit (`gh api user` + `git log -p` 평문 검색).
- FR-4: `libraries/constants.nix`에 `onePassword.vaults.{personal, automation}` 상수를 등록한다.
- FR-5: `op_get <name> <field> [<vault>]` helper (zsh function 또는 shell library)를 작성한다. vault 기본값은 `constants.onePassword.vaults.automation`.
- FR-6: 1Password Service Account를 발급하고 토큰을 `secrets/opnix-service-account-token.age`로 agenix에 보관한다 (Phase 1). 90일 rotation systemd timer + Pushover 알림(만료 N-14일)은 MiniPC 시스템 구성이므로 Phase 3에서 구현·activation 검증한다.
- FR-7: Mac `~/.ssh/config`에 `IdentityAgent ~/.1password/agent.sock` 추가. ControlPersist 정책 결정 (영구 또는 daemon master).
- FR-8: `launchd.agents.ssh-add-keys.enable = false` 또는 동등 게이트. `~/.ssh/id_ed25519` 처분 결정 (archive 또는 1Password vault item으로 이관 후 file 삭제).
- FR-9: Emergency ed25519 fallback key (`emergency_ed25519`) 생성 + `~/.ssh/config` Host 분기 + MiniPC `authorized_keys` 등록 + 실측 acceptance ("1Password 데스크탑 quit 후 emergency key로 ssh minipc 성공").
- FR-10: 디바이스별 SSH 키 4개 (`mac_ed25519` agent-managed, `iphone_ed25519`, `ipad_ed25519`, `emergency_ed25519`). 1Password Automation vault `ssh` tag에 backup copy + revocation 절차 박제. MiniPC `modules/nixos/users/<user>/authorized_keys.nix`에 declarative 등록.
- FR-11: `op plugin init gh` 실행 후 `~/.config/op/plugins.sh`를 `programs.zsh.initContent`에 declarative source 등록 (Home Manager).
- FR-12: `modules/nixos/programs/opnix/default.nix` 신규 작성. SA token EnvironmentFile 주입.
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
- nixpkgs unfree: `_1password-cli` (Linux), Homebrew Cask `1password` (Mac) 둘 다 unfree. allowUnfreePredicate 또는 nix-darwin homebrew.casks 등록 필요.
- agenix host key 부트 의존: opnix-service-account-token.age 복호화는 host SSH key 기반. 부트 시점 1Password 의존 없음 (순환 안전).
- 1Password Individual 한계: Events API 없음. SA token rotation 90일 cadence가 보완책.

## Risks / Edge Cases

- iPhone/iPad SSH key file 보유 패턴은 1Password 의도와 보안 모델이 다름 (A-2). 디바이스 분실 시 즉시 `authorized_keys.nix`에서 해당 라인 revoke.
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
| Phase 2a: Mac SSH | Done (PR 대기) | IdentityAgent + emergency fallback + 디바이스별 키 inventory | ssh minipc 동작 + 1Password quit 후 fallback 실측 | [phase-02a-mac-ssh.md](./prd-1password-migration/phase-02a-mac-ssh.md) |
| Phase 2b: Shell plugin gh | Done (merged #827) | Home Manager declarative plugin 등록 | gh pr list 동작 (biometric prompt 1회) | [phase-02b-shell-plugin-gh.md](./prd-1password-migration/phase-02b-shell-plugin-gh.md) |
| Phase 3: MiniPC opnix | Not Started | opnix 모듈 + SA token + MiniPC gh 전환 | nrs minipc + ssh minipc 'gh pr list' 동작 | [phase-03-minipc-opnix.md](./prd-1password-migration/phase-03-minipc-opnix.md) |
| Phase 4: Apple Passwords | Not Started | CSV 매트릭스 실측, import, iCloud disable, TOTP/passkey 정책 | iOS 자동채움 1Password 우선 동작 | [phase-04-apple-passwords.md](./prd-1password-migration/phase-04-apple-passwords.md) |
| Phase 5: Skill 리팩토링 | Not Started | managing-secrets routing 매트릭스 + inventory + queries.json | evals/queries.json 통과 + SKILL.md ≤ 250줄 | [phase-05-skill-refactor.md](./prd-1password-migration/phase-05-skill-refactor.md) |
| Phase 6: Vaultwarden EOL | Not Started | vaultwarden-touch 파일 atomic 삭제·수정 단일 PR + rg 잔존 0건 + 6개월 백업 정책 | nrs minipc + eval-tests + rg | [phase-06-vaultwarden-eol.md](./prd-1password-migration/phase-06-vaultwarden-eol.md) |

의존성 그래프: Phase 1 → Phase 2a, Phase 2b, Phase 3. Phase 3 → (Phase 5 일부). Phase 4와 Phase 6은 서로 무관. Phase 5는 Phase 1-3 완료 후 시작 (1Password 운영 패턴이 안정되어야 inventory/routing 매트릭스 작성 가능).

## Appendix: 최종 secrets.nix 변경 요약

| Secret | Before | After | Phase |
|---|---|---|---|
| `opnix-service-account-token.age` | (없음) | publicKeys=minipcHostOnly (host key) | Phase 1 |
| `vaultwarden-admin-token.age` | publicKeys=minipc | (삭제) | Phase 6 |
| `pushover-vaultwarden.age` | publicKeys=minipc | (삭제) | Phase 6 |
| 기타 21개 .age (immich/karakeep/copyparty/anki 등) | publicKeys=minipc | 변경 없음 | — |

## Final Multi-Pass Review After All Phases

`.claude/skills/plan-with-questions/references/prd/multi-pass-review.md` 체크리스트를 수행한다. 10-pass 항목 + review-impl overlay (6-classification + overbuilt 우선 분류). auto-fix 미적용.

## Open Questions

- Phase 2c (git commit signing 통합) 도입 시점과 범위는 별도 epic으로 분리할지 본 PRD에서 다룰지. 현재는 Out of Scope.
- Phase 4의 TOTP 별도 sub-phase 범위 (서비스 카운트 N건 임계). 사전 실측 후 결정.
- SA token user shell bridge 설계 (Phase 3): phase-03의 `/etc/profile.d/opnix.sh`가 user shell 진입 시 `/run/agenix/opnix-service-account-token`을 `cat`하지만, 해당 agenix secret은 root-only(0400 root)다. root-only면 user shell이 못 읽어 `OP_SERVICE_ACCOUNT_TOKEN`이 빈 값이 되고, user-readable로 풀면 SA token이 모든 user shell/subprocess에 노출되어 보안이 약화된다. Phase 3 진입 시 아래 후보 접근법 중 하나를 설계 검토로 택일·확정해야 한다 (root private key는 그대로 두고, 파일 권한을 약화하지 않는 방향):
    1. systemd user service가 polkit/sudo로 제한된 scope의 토큰만 요청하도록 구성
    2. caller를 검증하고 인가된 프로세스에만 토큰을 emit하는 wrapper binary (setuid 또는 capability 기반)
    3. opnix 모듈이 user shell 전용 derived limited-scope credential을 생성 (1Password API가 지원하는 경우)
  택일 후 phase-03의 user shell bridge(잠정 설계)를 확정안으로 갱신하고, 어떤 wrapper가 어디서 어떤 인가 흐름으로 토큰을 materialize하는지 명시한다.

## Change Log

- 2026-05-17: Initial PRD created. grill-me 결정사항 + DA review findings 반영. 사용자 추가 결정: routing 트리를 2단계로 단순화하고 mirror 패턴 폐기, 디바이스별 SSH key 4개 (mac/iphone/ipad/emergency), iCloud Keychain AutoFill 비활성화, envScript 패턴은 다른 컨테이너에서 자연 보존.
- 2026-05-24: Phase 1 구현 완료 (PR 대기). Mac 1Password(Homebrew Cask) 설치, Automation vault, gh PAT 발급+1Password 저장+retrieval 검증 (login greenheadHQ), op_get helper (op read secret reference + 멀티계정 --account 고정), SA token (`nixos-automation-minipc`, 전역 공유·minipc 단일 저장, host key 전용 recipient) agenix 보관, opnix stub + expiry record. 발견: 1Password Individual은 SA 자동 만료 미지원 → 정책 90일 cadence (만료 목표 2026-08-22, NFR-4 준수); op CLI 필드 조회는 op read secret reference 권장; op CLI 멀티 계정(개인+회사) 환경은 --account 고정 필요. 사용자 신규 결정: SA 운영 모델은 전역 공유 1개 (Mac은 biometric이라 SA 미사용, 실 소비처 minipc). 회사 맥북 SSH 키 분리는 별 세션 의제로 이관 (FR-10 확장 후보).
- 2026-05-25: Phase 1 PR #824로 squash merge. 리뷰 반영 — agenix host key·opnix expiry 경로를 constants.nix로 중앙화, SA token user shell bridge를 잠정 설계로 마킹하고 해결 후보 3종(systemd+polkit / wrapper binary / derived credential) 나열, constants.onePassword.account hard-pin 추가. merge 후 nrs 로컬 적용 + E2E 전 항목 통과 (op_get retrieval → gh api user=greenheadHQ, op_get 함수 활성화, 에러 처리 2/127, opnix stub 비활성, flake check). Phase 2a/2b/3 진입 가능.
- 2026-05-25: Phase 2b 구현 완료 → PR #827 squash merge. gh를 1Password Shell Plugin alias로 전환 — `shell/default.nix`에 plugins.sh file-guard source chunk + `op plugin init gh`(global default, github-pat) + nrs. `gh api user`=greenheadHQ(op plugin 경유 github-pat 주입) 검증, hosts.yml 평문 oauth_token 0건(yq 제거+백업), git history leak 0건, 구 PAT 없음 확인, keyring `gho_` unused fallback 유지 결정. merge 후 main을 nrs로 적용 + E2E 전항목 통과(type gh=alias, gh api user=greenheadHQ, hosts.yml 평문 0건, gh pr list 정상). Phase 2a/3 진입 가능.
- 2026-05-25: Phase 2a 구현 완료 (PR 대기). Mac SSH를 1Password agent로 전환 — 디바이스 키 4개(mac-ssh/iphone/ipad/emergency, `constants.sshDeviceKeys`)를 MiniPC authorizedKeys에 배포, ssh config에 IdentityAgent(group container socket)·agent.toml(Automation vault 노출)·minipc-emergency Host·ControlPersist 600(ControlMaster 유지 — #710 analyzing-da-sessions 회귀 방지) 추가, id_ed25519 archive(agent 전용 정리). 검증: ssh minipc=mac-ssh agent 인증(Touch ID), emergency fallback 실측(1Password quit→emergency 접속→ssh minipc 실패→재시작 복귀), id_ed25519 처분 후 agent-only 인증. 발견: ControlPersist 영구는 무인 파이프 hang(→600), agent socket은 group container 경로, agent.toml로 키 노출 명시 필수. Phase 3 진입 가능.
