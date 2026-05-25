# Phase 2a: Mac SSH Integration

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (merged #833)
Last Updated: 2026-05-25

## Objective

Mac SSH 인증을 1Password SSH agent로 이관하되, 단일 의존 실패 모드(1Password 데스크탑 quit / Touch ID 고장 / 계정 잠금)에서 ssh minipc가 일괄 차단되는 risk를 emergency ed25519 fallback key로 차단한다. 디바이스별 SSH key 4개 inventory를 1Password Automation vault와 NixOS authorized_keys 양쪽에 일관되게 등록한다.

## Context From Master PRD

- Goals covered: G-1 (1Password 통합), G-4 (디바이스 inventory)
- Success Criteria: SC-3 (SSH agent 동작 + emergency fallback 실측), SC-4 (4개 디바이스 키 inventory)
- Requirements covered: FR-7, FR-8, FR-9, FR-10
- Key scenarios touched: Scenario 4 (iPhone Termius), Scenario 5 (디바이스 분실)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [ ] 관련 코드/파일: `modules/darwin/programs/ssh/default.nix` (특히 `sshAddScript` 16-21줄 + `launchd.agents.ssh-add-keys` 52-64줄 + `matchBlocks.minipc` ControlMaster 44-47줄), `modules/nixos/programs/ssh/default.nix` (서버측 sshd 설정), `modules/nixos/users/<user>/authorized_keys.nix` (없으면 신규 작성)
- [ ] 관련 테스트/fixture: 없음 (manual smoke)
- [ ] 관련 docs/spec/외부 참조: https://developer.1password.com/docs/ssh/agent/, https://developer.1password.com/docs/ssh/agent/config/, https://developer.1password.com/docs/ssh/manage-keys/
- [ ] 관련 command 또는 도구: `nrs darwin`, `ssh-keygen`, `ssh -v minipc`, `ssh-add -l`, `op` CLI
- [ ] Master PRD의 assumption A-2 (iOS Termius local key file 영구 유지)가 여전히 유효함
- [ ] Phase 1의 Automation vault + naming convention이 완료되었음

## Scope

### In Scope

- 1Password 데스크탑 앱 Settings → Developer → "Use the SSH agent" 활성화 (Phase 1에서 이미 켰을 가능성 있음 — 재확인)
- `mac_ed25519` key 생성: 1Password GUI → New Item → SSH Key → Generate (Ed25519) → title `mac-ssh` → tag `ssh`. private key는 1Password vault 자체 보관, public key 캡처
- `iphone_ed25519`, `ipad_ed25519` key 생성: 각각 디바이스에서 직접 ssh-keygen으로 생성 후 1Password Automation vault에 `iphone-ssh`, `ipad-ssh` item으로 backup copy 저장 (Termius는 디바이스 local file 보유)
- `emergency_ed25519` key 생성: `ssh-keygen -t ed25519 -C "emergency-fallback" -f ~/.ssh/emergency_ed25519` (passphrase 강). 1Password Automation vault `emergency-ssh` item에 backup
- 4개 public key를 `modules/nixos/users/<user>/authorized_keys.nix` (또는 적합한 위치)에 declarative 등록
- Mac `~/.ssh/config`: 
  - 전역 `IdentityAgent ~/.1password/agent.sock` (1Password macOS agent socket symlink — 1Password 데스크탑 앱이 자동 생성)
  - `Host minipc-emergency` 분기 → `Hostname <minipc>` + `IdentityFile ~/.ssh/emergency_ed25519` + `IdentityAgent none`
- ControlPersist 정책 결정 + 적용: 현재 600초 → 영구(`yes`) 또는 launchd으로 master daemon 띄우는 패턴 중 1개 선택 (사용자 워크플로 모니터링 후 결정)
- `cfg.useOpAgent` 옵션 신설 + 정확한 Nix 표현 (SSOT 1개): `launchd.agents.ssh-add-keys = lib.mkIf (!cfg.useOpAgent) { ... 기존 정의 그대로 ... };` — 즉 useOpAgent=true이면 launchd agent 정의 자체가 빠짐. `.enable = ...` attribute 패턴은 사용하지 않음 (의미 충돌 방지)
- `~/.ssh/id_ed25519` 파일 처분: 1Password vault에 backup item으로 저장 후 file 삭제 (또는 `~/.ssh/id_ed25519.archive`로 mv + chmod 000)
- `programs.ssh.matchBlocks."*".identityFile`가 1Password agent와 충돌하지 않게 검토 (필요 시 identityFile 라인 제거)

### Out of Scope

- iPhone/iPad Termius 디바이스 자체에 새 key 등록 (사용자 GUI 작업, 본 phase에서 가이드만 제공)
- MiniPC opnix 도입 (Phase 3)
- Shell plugin gh (Phase 2b)
- git commit signing 통합 (Out of Scope of full PRD)

## Implementation Checklist

- [ ] 1Password 데스크탑 앱: Settings → Developer → "Use the SSH agent" ON 확인. `~/.1password/agent.sock` symlink 존재 확인 (`ls -la ~/.1password/agent.sock`)
- [ ] 1Password GUI에서 `mac-ssh` SSH Key item 생성 (Ed25519, Generate). public key 캡처
- [ ] 직접 emergency key 생성 (passphrase는 interactive prompt — argv/shell history 노출 방지):
  - 명령: `ssh-keygen -t ed25519 -C "emergency-fallback-$(hostname)" -f ~/.ssh/emergency_ed25519` (`-N` 인자 사용 금지)
  - ssh-keygen이 "Enter passphrase" 프롬프트로 묻고 입력 시 화면·history에 echo 안 됨
  - 별도 단계: 1Password Automation vault `emergency-ssh` item을 GUI에서 생성하여 (a) private key (`cat ~/.ssh/emergency_ed25519`), (b) public key (`cat ~/.ssh/emergency_ed25519.pub`), (c) passphrase 3개 필드를 수동 입력. 명령줄 `op` 호출 안 함 (passphrase가 argv 노출 회피)
- [ ] iPhone Termius / iPad Termius에서 각각 ssh-keygen 생성 (디바이스별로 사용자 수동). public key 캡처 → 1Password Automation vault `iphone-ssh`, `ipad-ssh` item에 backup
- [ ] `modules/nixos/users/<user>/authorized_keys.nix` (또는 `modules/nixos/programs/ssh/authorized_keys.nix` 등 적절 위치) 신규 또는 확장:
  ```nix
  { ... }: {
    users.users.<user>.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAA... mac-ssh"
      "ssh-ed25519 AAA... iphone-ssh"
      "ssh-ed25519 AAA... ipad-ssh"
      "ssh-ed25519 AAA... emergency-fallback"
    ];
  }
  ```
- [ ] `modules/darwin/programs/ssh/default.nix` 수정:
  - cfg.useOpAgent 옵션 신설 (default true)
  - `launchd.agents.ssh-add-keys = lib.mkIf (!cfg.useOpAgent) { ... 기존 정의 그대로 ... };`로 정의 전체를 wrap. useOpAgent=true이면 agent 자체가 launchd에 등록되지 않음
  - `programs.ssh.extraConfig` 또는 `matchBlocks."*".extraOptions`에 `IdentityAgent ~/.1password/agent.sock` 추가
  - `matchBlocks.minipc-emergency` 신규 (Hostname=minipc, IdentityFile=~/.ssh/emergency_ed25519, IdentityAgent=none)
  - ControlPersist 정책: 사용자 워크플로 검토 후 `"yes"` (영구) 또는 launchd master daemon 패턴 중 선택. Phase Decision으로 박제
- [ ] launchd gate 동작 검증: `nrs darwin` 후 `launchctl list | grep ssh-add-keys` 결과가 빈 행이어야 정상 (useOpAgent=true 기본값에서 agent unload됨)
- [ ] `nrs darwin` 빌드 + activate
- [ ] **MiniPC authorized_keys 배포** — `authorized_keys.nix`가 NixOS 모듈이므로 MiniPC도 rebuild해야 새 키가 deploy됨:
  - [ ] `nrs minipc` 실행 (Mac에서 트리거 가능)
  - [ ] deployed-key presence check: `ssh minipc 'wc -l ~/.ssh/authorized_keys'` 결과가 신규 키 추가만큼 증가 (예: 기존 1줄 → 4줄)
  - [ ] 키 indices 확인: `ssh minipc 'grep -c "mac-ssh\|iphone-ssh\|ipad-ssh\|emergency-fallback" ~/.ssh/authorized_keys'` 결과 = 4
- [ ] `~/.ssh/id_ed25519` 처분:
  - 1Password Automation vault `mac-ssh-legacy` item 생성 (backup용)
  - file을 `~/.ssh/id_ed25519.archive`로 mv + `chmod 000`
- [ ] 동작 검증 (위 deployed-key check 통과 후에만 진행):
  - [ ] `ssh -v minipc` → 1Password agent biometric prompt → Touch ID → 성공
  - [ ] `ssh-add -l` → 1Password agent의 key list 출력 (mac-ssh 1개)
  - [ ] ControlMaster 활성 후 두 번째 `ssh minipc` → biometric 없이 통과
- [ ] Emergency fallback 실측 (Phase Exit Gate):
  - [ ] 1Password 데스크탑 앱 완전 종료 (Quit, not just close window)
  - [ ] `ssh minipc-emergency` → passphrase 입력 → 성공
  - [ ] `ssh minipc` → 1Password agent 미동작으로 실패 (정상)
  - [ ] 1Password 데스크탑 재시작 → `ssh minipc` 정상 동작 복귀

## Validation Strategy

- 일반 동작은 `ssh -v minipc`와 `ssh-add -l`로 검증. 1Password 데스크탑 quit 시 강제 실패 + emergency Host로 우회 가능함을 실측. ControlMaster cache 만료 후 첫 호출에서 popup 거부 시 timeout 동작 확인 (사용자가 수동 수용 가능 시간 측정).

## Validation Checklist

- [ ] Static check 통과: `nix flake check --no-build --all-systems`
- [ ] 자동 test — N/A (manual SSH 동작)
- [ ] API/CLI 검증: `ssh -v minipc` + `ssh-add -l` 정상
- [ ] Browser/UI E2E — N/A
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — N/A (iPhone/iPad는 실기기 manual)
- [ ] Visual/screenshot check — 1Password 데스크탑의 SSH agent 활성 상태 캡처 1회
- [ ] Observability/logging — `/var/log/system.log` ssh-agent 로그에 1Password agent 인증 기록 확인
- [ ] Manual smoke check — `ssh minipc` → biometric → 성공 + emergency fallback 실측
- [ ] 해당 시 error/empty/loading/permission/retry/rollback 상태 검증 — 1Password 데스크탑 quit 후 ssh minipc 실패 → emergency 우회 성공 → 데스크탑 재시작 후 정상 복귀

## Exit Criteria

- [ ] Phase objective 달성 (Mac SSH가 1Password agent 인증 + emergency fallback 검증 통과 + 디바이스별 4개 key inventory 완료)
- [ ] FR-7, FR-8, FR-9, FR-10 모두 구현
- [ ] Emergency fallback 실측 통과 (NFR-5)
- [ ] iPhone/iPad Termius에 본인이 생성한 key가 등록되어 `ssh minipc` 정상 동작 (사용자 manual 보고)
- [ ] `~/.ssh/id_ed25519` 평문 file 처분 완료 (archive 또는 1Password vault 이관)
- [ ] 다음 phase (Phase 2b)를 시작하지 못하게 막는 blocker 없음

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-3, SC-4 달성
- [ ] 2. Correctness — happy path, 1Password quit, biometric 거부, ControlMaster 만료 후 무인 호출 hang 모두 처리
- [ ] 3. Simplicity — IdentityAgent 1줄 + emergency Host 분기로 최소 변경
- [ ] 4. Code quality — cfg.useOpAgent 옵션 이름/default가 nix-darwin 모듈 컨벤션 일치
- [ ] 5. Duplication/cleanup — ssh-add 관련 dead code (launchd ssh-add-keys 게이트로 비활성) 정리
- [ ] 6. Security/privacy — `~/.ssh/id_ed25519` 평문 잔존 없음. emergency key passphrase 1Password vault 보관
- [ ] 7. Performance — ControlPersist 정책으로 Touch ID popup 빈도 사용자 수용 범위 내
- [ ] 8. Validation — emergency fallback 실측이 phase exit gate
- [ ] 9. Future-phase — Phase 2b/3에 SSH 관련 의존 없음 (Phase 3 ssh minipc는 본 phase의 mac-ssh key 사용)
- [x] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- **ControlPersist 정책**: 600 유지 (영구/daemon 채택 안 함). 영구(yes)는 무인 파이프 호출(`ssh minipc | grep`, Claude Code Bash 캡처 포함)에서 master가 stdout을 점유해 hang을 유발한다. ControlMaster auto + ControlPersist 600은 #710 analyzing-da-sessions의 K=8 worker pool SSH multiplexing이 의존하므로 ControlMaster 제거 불가(제거 시 그 스킬이 fetch skip → 5분 budget 회귀).
- **1Password agent socket 경로**: macOS는 group container 경로(`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`)가 실제 socket. phase-02a가 가정한 `~/.1password/agent.sock` symlink는 자동 생성되지 않으므로, ssh config `IdentityAgent`에 group container 경로를 직접 지정(공백 포함이라 quote).
- **agent.toml 필수**: 1Password SSH agent는 SSH 키를 자동 노출하지 않는다(GUI에 "SSH 키가 설정되지 않았습니다"). `~/.config/1Password/ssh/agent.toml`에 노출 vault를 명시해야 ssh-add -l에 키가 뜬다 → `vault = "Automation"`. `home.file`로 declarative 박제.
- **useOpAgent let + 최종 cleanup**: phase-02a가 명시한 "옵션" 대신 모듈 let 상수로 구현(토글 수요 없어 YAGNI). id_ed25519 처분 시 launchd ssh-add-keys 경로 전체가 dead가 되어 useOpAgent/launchd/sshAddScript/sshKeyPath까지 함께 제거 → ssh/default.nix가 1Password agent 전용으로 단순화.
- **id_ed25519 처분**: minipc 외 미사용 확인(github는 HTTPS git, MiniPC는 mac-ssh) → `~/.ssh/id_ed25519.archive`(chmod 000)로 mv. ssh config identityFile 제거 후 `ssh minipc`가 mac-ssh agent만으로 인증됨을 실측. darwin의 Mac 접속용 authorizedKeys(macbook 공개키)는 별개라 보존.

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-25: Phase 2a 구현 완료 → PR #833 squash merge. 디바이스 키 4개(mac-ssh/iphone/ipad/emergency)를 `constants.sshDeviceKeys`로 정의하고 MiniPC authorizedKeys에 배포(nrs minipc). Mac ssh config: IdentityAgent(group container socket) + agent.toml(Automation vault 노출) + minipc-emergency Host + ControlPersist 600(ControlMaster 유지). id_ed25519 archive. 검증: `ssh minipc`=mac-ssh agent 인증(Touch ID), emergency fallback 실측(1Password quit→emergency 접속 성공→ssh minipc Permission denied→재시작 복귀), id_ed25519 처분 후 agent-only 인증. merge 후 main nrs 적용 + E2E 전항목 재검증 통과. agent.toml vault를 constants 참조로 정정(SSOT). 발견: ControlPersist 영구는 무인 hang(→600 유지), agent socket은 group container 경로, agent.toml로 키 노출 명시 필수.
