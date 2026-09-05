# Phase 6: Vaultwarden EOL

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Complete
Last Updated: 2026-06-01

본 phase는 Phase 4 (Apple Passwords)와 의존 없음 → 병렬 가능.

## Objective

2주 병행 검증 완료 후 Vaultwarden 서비스 전체를 atomic 삭제한다. 코드/모듈/스킬/agenix vaultwarden-touch 파일 + cross-reference cleanup을 **단일 PR**로 제거하고 (대상 SSOT는 본 phase의 Implementation Checklist), `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 게이트로 cleanup 완성을 검증한다 (PRD 디렉토리는 작업 history로 보존되므로 제외). 백업 디렉토리는 종료 시점 static archive snapshot으로 6개월 보관하고 만료 시점 Pushover purge reminder를 등록한다. 카운트 표기(8/13/N개)는 사용하지 않는다 — drift 방지.

## Context From Master PRD

- Goals covered: G-1 (Vaultwarden 종료), G-3 (agenix 축소)
- Success Criteria: SC-6 (vaultwarden-touch 파일 atomic 처리 + rg 잔존 0건, PRD 디렉토리 제외)
- Requirements covered: FR-18, FR-19, FR-20, NFR-1, NFR-2
- Key scenarios touched: Scenario 7 (Vaultwarden 종료)
- Constraint: 2주 병행 검증 (Vaultwarden 컨테이너는 살아있되 사용자는 1Password만 사용) 완료 후에만 본 phase 진입

## Phase Discovery Gate

- [ ] 관련 코드/파일 (삭제 대상):
  - `modules/nixos/programs/docker/vaultwarden.nix` (전체)
  - `modules/nixos/programs/docker/vaultwarden-backup.nix` (전체)
  - `modules/nixos/programs/vaultwarden-update/` (디렉토리 전체)
  - `modules/nixos/programs/caddy.nix` (vaultwarden virtualHost block 98-104 또는 해당 라인)
  - `modules/nixos/options/homeserver.nix` (vaultwarden + vaultwardenUpdate mkOption + imports 라인)
  - `tests/eval-tests.nix` (Test 5h / 5h-2 vaultwarden 블록)
  - `libraries/constants.nix` (ports.vaultwarden, subdomains.vaultwarden, containers.vaultwarden — 3건)
  - `secrets/secrets.nix` (publicKeys 2행: vaultwarden-admin-token, pushover-vaultwarden)
  - `secrets/vaultwarden-admin-token.age` (파일 자체)
  - `secrets/pushover-vaultwarden.age` (파일 자체)
  - `.claude/skills/hosting-vaultwarden/` (디렉토리 전체)
  - `modules/nixos/programs/smoke-test.nix` (5번째 줄 vaultwarden-backup.nix 인용 + healthcheck 35-36 + backup freshness 127-135 블록)
  - `modules/nixos/configuration.nix` (MiniPC system config, `homeserver.vaultwarden.enable` + `vaultwardenUpdate.enable` 2라인. shared/darwin configuration.nix는 vaultwarden 무관)
  - `modules/nixos/programs/docker/immich-backup.nix` (vaultwarden-backup.nix 패턴 참조 주석 — dead reference로 전락, 삭제 또는 immich-only로 갱신)
  - `README.md` (vaultwarden 언급 라인 65, 185 — service 목록 + 문서 인덱스)
- [ ] 관련 cross-reference (수정 대상):
  - `.claude/skills/managing-minipc/references/host-prerequisites.md` ("3종" → "2종", 라인 3, 19)
  - `.claude/skills/managing-minipc/references/features.md` (vaultwarden 언급 라인 45-46, 154)
  - `.claude/skills/managing-minipc/SKILL.md` (156)
  - `.claude/skills/running-containers/SKILL.md` (NOT-for 분기 11-12)
  - `.claude/skills/running-containers/references/service-update-system.md` (136)
  - `.claude/skills/running-containers/references/troubleshooting.md` (vaultwarden 라인)
  - `.claude/skills/running-containers/evals/queries.json` (vaultwarden 쌍)
  - `.claude/skills/managing-secrets/SKILL.md` (`NOT for Vaultwarden 비밀번호 관리자 ...` 라인)
  - `.claude/skills/managing-secrets/evals/queries.json` (vaultwarden 혼동 쌍 — Phase 5에서 1Password 쌍 신규 추가 + 본 phase에서 vaultwarden 쌍 삭제)
  - `README.md` (vaultwarden 언급 라인 65, 185)
- [ ] 관련 테스트/fixture: `tests/eval-tests.nix` (vaultwarden 블록 삭제 시 eval 정합성)
- [ ] 관련 docs/spec/외부 참조: 없음 (Vaultwarden 외부 docs는 archive)
- [ ] 관련 command 또는 도구: `nrs minipc`, `rg`, `nix flake check`, `eval-tests`
- [ ] Phase 4 완료 또는 진행 중이어도 무관 (의존 없음)
- [ ] 사용자 확인: 2주 병행 검증 통과 (1Password 자동채움·검색·multi-device sync 모두 정상)

## Scope

### In Scope

- 컨테이너 중지: `ssh minipc 'sudo systemctl stop podman-vaultwarden.service'`
- 단일 PR로 vaultwarden-touch 파일 atomic 처리 (전체 삭제 + 라인 수정 + cross-reference cleanup — 정확한 대상은 아래 Implementation Checklist가 SSOT)
- agenix 2개 `.age` 파일 삭제
- hosting-vaultwarden 스킬 전체 디렉토리 삭제 (전례: hosting-archivebox, hosting-linkwarden 등 hard delete 컨벤션)
- `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 게이트 통과 (PRD 디렉토리는 작업 history로 보존)
- `/mnt/data/backups/vaultwarden/`를 종료 시점 static archive snapshot으로 보존: `mv` 후 중립 이름 path `/mnt/data/backups/archives/password-manager-<shutdown-date>`로 이전 (`<shutdown-date>`은 실제 Phase 6 실행일을 ISO-8601 형식으로 치환, 예: `2026-08-01`). archive 경로는 reminder 구현(아래) 외에는 repo 코드에 박제하지 않는다 — PRD/git history에서 추적
- 6개월 후 (`<purge-date>` = `<shutdown-date>` + 6개월) Pushover purge reminder: `modules/nixos/programs/pushover-system-monitor.nix` 또는 별 reminder timer에 등록
- smoke-test.nix의 vaultwarden 의존 블록 제거 (vaultwarden 게이트가 enable=false면 자동 dead, 본 phase에서 명시 삭제)

### Out of Scope

- Bitwarden iOS 앱 사용자 디바이스에서 삭제 (사용자 manual)
- 6개월 보관 후 실제 purge 실행 (별 reminder trigger 시 manual)
- Apple Passwords import (Phase 4 — 본 phase와 독립)

## Implementation Checklist

- [ ] 2주 병행 검증 통과 확인 (사용자 명시 보고)
- [ ] 컨테이너 중지: `ssh minipc 'sudo systemctl stop podman-vaultwarden.service podman-vaultwarden-backup.service vaultwarden-update.timer vaultwarden-version-check.timer'`
- [ ] 백업 디렉토리 archive (중립 경로 사용 — `rg -w vaultwarden` gate 통과 보장). 실행자가 다음 두 값을 결정 후 명령에 치환: `<shutdown-date>` = 본 phase 실행일 (ISO-8601), `<purge-date>` = `<shutdown-date>` + 6개월. `ssh minipc 'sudo mv /mnt/data/backups/vaultwarden /mnt/data/backups/archives/password-manager-<shutdown-date> && sudo touch /mnt/data/backups/archives/password-manager-<shutdown-date>/PURGE_AFTER_<purge-date>.txt'`. 결정된 두 날짜를 본 phase Discoveries에 박제 (reminder 구현이 같은 값을 참조).
- [ ] 단일 PR atomic 삭제:
  - [ ] `git rm -r modules/nixos/programs/docker/vaultwarden.nix modules/nixos/programs/docker/vaultwarden-backup.nix modules/nixos/programs/vaultwarden-update/`
  - [ ] `git rm -r secrets/vaultwarden-admin-token.age secrets/pushover-vaultwarden.age`
  - [ ] `git rm -r .claude/skills/hosting-vaultwarden/`
  - [ ] `secrets/secrets.nix`: vaultwarden-admin-token + pushover-vaultwarden publicKeys 2행 삭제
  - [ ] `libraries/constants.nix`: ports.vaultwarden, subdomains.vaultwarden, containers.vaultwarden 3건 삭제
  - [ ] `modules/nixos/programs/caddy.nix`: vaultwarden virtualHost block 삭제
  - [ ] `modules/nixos/options/homeserver.nix`: vaultwarden + vaultwardenUpdate mkOption + imports 라인 삭제
  - [ ] `tests/eval-tests.nix`: Test 5h / 5h-2 vaultwarden 블록 삭제
  - [ ] `modules/nixos/programs/smoke-test.nix`: 5번째 줄 vaultwarden-backup.nix 인용 제거 + healthcheck + backup freshness 블록 삭제
  - [ ] `modules/nixos/configuration.nix`: `homeserver.vaultwarden.enable` + `vaultwardenUpdate.enable` 2라인 삭제 (MiniPC system config가 여기 위치)
  - [ ] `modules/nixos/programs/docker/immich-backup.nix`: vaultwarden-backup.nix 참조 코멘트 제거 또는 immich-only 패턴 설명으로 갱신
  - [ ] `README.md`: vaultwarden 언급 라인 (service 목록 + 문서 인덱스) 삭제
- [ ] Cross-reference cleanup:
  - [ ] `.claude/skills/managing-minipc/references/host-prerequisites.md`: "hosting-3종" → "hosting-2종" (라인 3, 19)
  - [ ] `.claude/skills/managing-minipc/references/features.md`: vaultwarden 라인 45-46, 154 삭제
  - [ ] `.claude/skills/managing-minipc/SKILL.md`: 156 vaultwarden 인용 삭제
  - [ ] `.claude/skills/running-containers/SKILL.md`: NOT-for 분기 11-12에서 hosting-vaultwarden 제거
  - [ ] `.claude/skills/running-containers/references/service-update-system.md`: 136 vaultwarden 인용 삭제
  - [ ] `.claude/skills/running-containers/references/troubleshooting.md`: vaultwarden 라인 삭제
  - [ ] `.claude/skills/running-containers/evals/queries.json`: vaultwarden 쌍 삭제
  - [ ] `.claude/skills/managing-secrets/SKILL.md`: `NOT for Vaultwarden 비밀번호 관리자` 라인 삭제
  - [ ] `.claude/skills/managing-secrets/evals/queries.json`: vaultwarden 혼동 쌍 11-20행 삭제 (Phase 5에서 1Password 쌍 신규 추가됨)
  - [ ] `README.md`: 65, 185 vaultwarden 라인 삭제
- [ ] `nix flake check --no-build --all-systems` 통과 확인
- [ ] `nrs minipc` 빌드 + 활성화 (Vaultwarden 모듈 제거 후 정상 빌드)
- [ ] **Acceptance gate**: `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 확인. PRD 디렉토리(`.claude/prds/prd-1password-migration*`)는 작업 history 보존 목적으로 제외. evals/queries.json의 vaultwarden 혼동 쌍도 본 phase에서 삭제 대상이므로 0건이어야 함
- [ ] smoke-test 회귀: `ssh minipc 'sudo systemctl status podman-vaultwarden.service' → not-found` 확인
- [ ] eval-tests 재실행: `nix eval .#nixosConfigurations.minipc.config.assertions` 통과
- [ ] 6개월 후 Pushover purge reminder 등록 (메시지·경로에서 `vaultwarden` 단어 미사용 — repo 코드는 rg gate 통과해야 함):
  - `modules/nixos/programs/pushover-system-monitor.nix` 또는 별 `pushover-purge-reminder.nix` 신규에 systemd timer 추가: `OnCalendar = "<purge-date> 09:00:00 Asia/Seoul"` 1회성 (위 archive 단계에서 결정한 `<purge-date>` 치환)
  - reminder 메시지 (중립 표현): "Password manager backup archive (`/mnt/data/backups/archives/password-manager-<shutdown-date>`) 6개월 보관 만료. manual integrity check 후 purge 검토." — 본문에 `vaultwarden` 단어 미사용. `<shutdown-date>`는 archive 단계에서 결정한 값 치환. 운영자가 어떤 서비스의 archive인지는 PRD/git history에서 추적.
- [ ] Issue #780에 진행 comment + close (또는 close 안 하고 reminder 등록 후 자연 close)

## Validation Strategy

- 가장 핵심은 `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 게이트. 다음으로 `nrs minipc` 빌드 성공 + smoke-test 통과 + eval-tests 통과. Pushover reminder timer 등록 확인 (`systemctl list-timers | grep purge`).

## Validation Checklist

- [ ] Static check 통과: `nix flake check --no-build --all-systems`
- [ ] 자동 test 추가/갱신: `tests/eval-tests.nix`에서 Test 5h/5h-2 삭제 (vaultwarden 컨테이너가 사라졌으므로 테스트도 dead)
- [ ] API/CLI 검증: `ssh minipc 'systemctl status podman-vaultwarden'` → `Unit not found` 정상
- [ ] Browser/UI E2E — `vaultwarden.greenhead.dev` 도메인이 응답하지 않음 (Caddy block 제거됨) 확인
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — 사용자가 iPhone Bitwarden 앱에서 동기화 실패하는지 manual 확인 (이미 1Password 전환 후)
- [ ] Visual/screenshot check — N/A
- [ ] Observability/logging — `ssh minipc 'journalctl -u podman-vaultwarden -n 5'` → unit not found
- [ ] Manual smoke check — `rg -w vaultwarden --glob '!.claude/prds/**' .` 잔존 0건 명시 확인
- [ ] 해당 시 error/empty/loading/permission/retry/rollback — Vaultwarden 종속 다른 서비스 영향 0 (vaultwarden-update가 mk-update-module의 유일 호출자 아님 — copyparty/karakeep도 사용 중이므로 mk-update-module 모듈은 유지)

## Exit Criteria

- [x] Phase objective 달성 (atomic 삭제 + cross-reference cleanup + rg 잔존 0건 + 백업 archive + 6개월 reminder)
- [x] FR-18, FR-19, FR-20 구현
- [x] NFR-1 (atomic PR), NFR-2 (rg 잔존 0건 — 단 진짜 게이트는 `rg -i --hidden`, Discoveries 참조) 충족
- [x] `nrs minipc`(= MiniPC 로컬 nixos-rebuild) + eval-tests + smoke-test 모두 통과
- [x] Issue #780 진행 comment + close (PR Closes #780/#879)

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-6 달성
- [ ] 2. Correctness — atomic 삭제 + cross-reference cleanup + 백업 archive + reminder 모두 처리
- [ ] 3. Simplicity — 단일 PR로 처리. mk-update-module 등 다른 서비스 영향 0
- [ ] 4. Code quality — 삭제만이므로 quality 유지 (잔존 0건이 quality 척도)
- [ ] 5. Duplication/cleanup — 잔존 0건 (NFR-2)이 본 항목 그 자체
- [ ] 6. Security/privacy — admin-token, pushover-vaultwarden agenix 파일 git 이력에서도 제거 필요 — `git rm`은 working tree 삭제일 뿐, 이력 sanitize는 별 task (BFG repo-cleaner 등). 본 phase에서는 git rm으로 충분 (agenix file은 암호화돼 있어 history leak 위험 낮음)
- [ ] 7. Performance — Vaultwarden 컨테이너 자원 회수 (256MB RAM + CPU 0.5)
- [ ] 8. Validation — rg 잔존 0건 + nrs 빌드 + eval-tests + smoke-test
- [ ] 9. Future-phase — 모든 phase 종료. Final 10-pass review 진입
- [ ] 10. PRD sync — master PRD Status → "Complete" 갱신. Issue #780에 PRD 링크 + Final review 결과 박제

## Discoveries / Decisions

- 백업 archive 디렉토리: `/mnt/data/backups/archives/password-manager-2026-06-01` (2026-06-01 실행, 날짜별 스냅샷 보존 + `PURGE_AFTER_2026-12-01.txt` 마커)
- `<shutdown-date>` = 2026-06-01, `<purge-date>` = 2026-12-01 (reminder timer가 같은 값 참조)
- 6개월 purge reminder: 2026-12-01 09:00 KST — `pushover-purge-reminder.nix` systemd timer 신설(OnCalendar 1회성 + Persistent=true). nrs 후 `systemctl list-timers`로 `NEXT Tue 2026-12-01 09:00 KST` 등록 확인. PRD가 가정한 `pushover-system-monitor.nix`는 미존재 → 신규 모듈 + `configuration.nix` import로 구현(`opnix-rotate.nix` 패턴 계승, `pushover-system-monitor.age` 공유 merge).
- mk-update-module 추상화는 vaultwarden-update를 직접 참조하지 않음을 재확인 (copyparty/karakeep/uptime-kuma 호출자 잔존 → 모듈 유지)
- **★ Acceptance gate 결함 (중요, 향후 잔존 게이트에 반영)**: 본 PRD/Objective가 명시한 `rg -w vaultwarden --glob '!.claude/prds/**' .`는 두 false-0 결함이 있다. (a) `--hidden` 부재 → `.claude/` 스킬 디렉토리(hosting-vaultwarden 등)를 검색하지 못함, (b) `-w` word boundary → 한글 조사 결합형("Vaultwarden은")과 vaultwarden 단어 없는 카운트("5개 컨테이너", ".age 20개")를 놓침. 진짜 게이트는 **`rg -i --hidden vaultwarden --glob '!.claude/prds/**' --glob '!.git/**' .`**. 적대적 DA 리뷰(8 세부 도메인)와 병렬 전수조사(6 bundle)가 이 결함으로 놓칠 뻔한 5곳을 추가로 잡아 0건 달성.
- eval-tests 삭제 대상은 PRD가 말한 "Test 5h/5h-2"가 아니라 실제 **Test 5e/5e-2**였다 (PRD 라인번호 stale → rg 실측으로 교정).

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-06-01: Phase 6 완료. atomic 삭제(코드 모듈 3 + agenix `.age` 2 + hosting-vaultwarden 스킬) + cross-ref cleanup(managing-minipc/running-containers/managing-secrets) + `pushover-purge-reminder.nix` 신설. MiniPC 컨테이너/타이머 중지 + 백업 중립 archive(`password-manager-2026-06-01` + PURGE 마커) + nrs 배포(16 vaultwarden units 제거, reminder timer 등록 확인). 적대적 DA 리뷰(8 도메인) + 병렬 전수조사(6 bundle)로 acceptance gate 결함 보정 5곳 추가 수정. `rg -i --hidden` 잔존 0 + nix flake check + eval-tests + smoke-test 통과. Phase 5 잔여 후속 ①(constants 주석 #874) + ②(managing-secrets eval negative 가드 2쌍) 동봉. PR(Closes #879/#780).
