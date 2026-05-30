# Phase 2a: Mac SSH Integration

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (merged #833) + mobile follow-up open
Last Updated: 2026-05-27

## Objective

Mac SSH 인증을 1Password SSH agent로 이관하되, 단일 의존 실패 모드(1Password 데스크탑 quit / Touch ID 고장 / 계정 잠금)에서 ssh minipc가 일괄 차단되는 risk를 emergency ed25519 fallback key로 차단한다. 디바이스별 SSH key 4개 inventory를 1Password Automation vault와 NixOS authorized_keys 양쪽에 일관되게 등록한다.

## Context From Master PRD

- Goals covered: G-1 (1Password 통합), G-4 (디바이스 inventory)
- Success Criteria: SC-3 (SSH agent 동작 + emergency fallback 실측), SC-4 (4개 디바이스 키 inventory)
- Requirements covered: FR-7, FR-8, FR-9, FR-10
- Key scenarios touched: Scenario 4 (iPhone Termius), Scenario 5 (디바이스 분실)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [ ] 관련 코드/파일: `modules/darwin/programs/ssh/default.nix` (`programs.ssh`, `matchBlocks.minipc` ControlMaster, `matchBlocks.minipc-emergency`, 1Password `agent.toml`), `modules/nixos/programs/ssh.nix` (서버측 sshd 설정), `libraries/constants.nix` (`constants.sshDeviceKeys`), `hosts/greenhead-minipc/default.nix` (MiniPC authorizedKeys consumer)
- [ ] 관련 테스트/fixture: 없음 (manual smoke)
- [ ] 관련 docs/spec/외부 참조: https://developer.1password.com/docs/ssh/agent/, https://developer.1password.com/docs/ssh/agent/config/, https://developer.1password.com/docs/ssh/manage-keys/, https://termius.com/documentation/generate-ssh-key, https://termius.com/documentation/copy-ssh-key-to-server
- [ ] 관련 command 또는 도구: `nrs darwin`, `ssh-keygen`, `ssh -v minipc`, `ssh-add -l`, `op` CLI
- [ ] Master PRD의 assumption A-2 (iOS Termius local key file 영구 유지)가 여전히 유효함
- [ ] Phase 1의 Automation vault + naming convention이 완료되었음

## Scope

### In Scope

- 1Password 데스크탑 앱 Settings → Developer → "Use the SSH agent" 활성화 (Phase 1에서 이미 켰을 가능성 있음 — 재확인)
- `mac_ed25519` key 생성: 1Password GUI → New Item → SSH Key → Generate (Ed25519) → title `mac-ssh` → tag `ssh`. private key는 1Password vault 자체 보관, public key 캡처
- `iphone_ed25519`, `ipad_ed25519` key 생성: 각각 디바이스에서 직접 ssh-keygen으로 생성 후 1Password Automation vault에 `iphone-ssh`, `ipad-ssh` item으로 backup copy 저장 (Termius는 디바이스 local file 보유)
- `emergency_ed25519` key 생성: `ssh-keygen -t ed25519 -C "emergency-fallback" -f ~/.ssh/emergency_ed25519` (passphrase 강). 1Password Automation vault `emergency-ssh` item에 backup
- 4개 public key를 `libraries/constants.nix`의 `constants.sshDeviceKeys`에 선언하고 `hosts/greenhead-minipc/default.nix`의 MiniPC authorizedKeys 목록에서 소비
- Mac `~/.ssh/config`: 
  - 전역 `IdentityAgent`는 1Password group container socket(`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`) 사용
  - `Host minipc-emergency` 분기 → `Hostname <minipc>` + `IdentityFile ~/.ssh/emergency_ed25519` + `IdentityAgent none`
- ControlPersist 정책 결정 + 적용: 현재 600초 → 영구(`yes`) 또는 launchd으로 master daemon 띄우는 패턴 중 1개 선택 (사용자 워크플로 모니터링 후 결정)
- Mac ssh module cleanup: 기존 `launchd.agents.ssh-add-keys`/`sshAddScript`/`sshKeyPath`/identityFile 경로를 제거하고, 1Password agent 전용 `programs.ssh` + `agent.toml` 구성으로 정리. 별도 전환 옵션은 최종 구현에서 도입하지 않음(Discoveries / Decisions 참조)
- `~/.ssh/id_ed25519` 파일 처분: 1Password vault에 backup item으로 저장 후 file 삭제 (또는 `~/.ssh/id_ed25519.archive`로 mv + chmod 000)
- `programs.ssh.matchBlocks."*".identityFile`가 1Password agent와 충돌하지 않게 검토 (필요 시 identityFile 라인 제거)

### Out of Scope

- Original Phase 2a scope에서는 iPhone/iPad Termius 디바이스 자체에 새 key 등록을 사용자 GUI 작업으로 두고 가이드만 제공했다. Post-Merge Remediation은 이 범위의 예외이며 mobile identity/import/rotation 검증을 별도 후속으로 추적한다.
- MiniPC opnix 도입 (Phase 3)
- Shell plugin gh (Phase 2b)
- git commit signing 통합 (Out of Scope of full PRD)

### Post-Merge Follow-Up Scope

- Mobile actual connection identity는 server-side evidence로 닫는다. Canonical checklist, hardening gate, evidence format, and decision questions are in [Post-Merge Remediation](#post-merge-remediation-termius-mobile-key-mismatch).
- iPad Termius도 동일 회귀 가능성이 있으므로 검증 범위에 포함할지 사용자 결정을 받는다.

## Implementation Checklist

- [ ] 1Password 데스크탑 앱: Settings → Developer → "Use the SSH agent" ON 확인. group container socket 존재 확인: `test -S "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`
- [ ] 1Password GUI에서 `mac-ssh` SSH Key item 생성 (Ed25519, Generate). public key 캡처
- [ ] 직접 emergency key 생성 (passphrase는 interactive prompt — argv/shell history 노출 방지):
  - 명령: `ssh-keygen -t ed25519 -C "emergency-fallback-$(hostname)" -f ~/.ssh/emergency_ed25519` (`-N` 인자 사용 금지)
  - ssh-keygen이 "Enter passphrase" 프롬프트로 묻고 입력 시 화면·history에 echo 안 됨
  - 별도 단계: 1Password Automation vault `emergency-ssh` item을 GUI에서 생성하여 (a) private key (`cat ~/.ssh/emergency_ed25519`), (b) public key (`cat ~/.ssh/emergency_ed25519.pub`), (c) passphrase 3개 필드를 수동 입력. 명령줄 `op` 호출 안 함 (passphrase가 argv 노출 회피)
- [ ] iPhone Termius / iPad Termius에서 각각 ssh-keygen 생성 (디바이스별로 사용자 수동). public key 캡처 → 1Password Automation vault `iphone-ssh`, `ipad-ssh` item에 backup
- [ ] `libraries/constants.nix`의 `constants.sshDeviceKeys` 신규 또는 확장 후, `hosts/greenhead-minipc/default.nix`의 MiniPC authorizedKeys 목록이 이를 소비하는지 확인:
  ```nix
  sshDeviceKeys = {
    macSsh = "ssh-ed25519 AAA... mac-ssh";
    iphone = "ssh-ed25519 AAA... iphone-ssh";
    ipad = "ssh-ed25519 AAA... ipad-ssh";
    emergency = "ssh-ed25519 AAA... emergency-fallback";
  };

  users.users.${username}.openssh.authorizedKeys.keys = with constants.sshDeviceKeys; [
    macSsh
    iphone
    ipad
    emergency
  ];
  ```
- [ ] `modules/darwin/programs/ssh/default.nix` 수정:
  - 기존 `launchd.agents.ssh-add-keys`/`sshAddScript`/`sshKeyPath`/identityFile 경로 제거
  - `programs.ssh.matchBlocks."*".extraOptions.IdentityAgent`에 1Password group container socket 추가
  - `home.file.".config/1Password/ssh/agent.toml"`에 Automation vault 노출 설정
  - `matchBlocks.minipc-emergency` 신규 (Hostname=minipc, IdentityFile=~/.ssh/emergency_ed25519, IdentityAgent=none)
  - ControlPersist 정책: 사용자 워크플로 검토 후 `"yes"` (영구) 또는 launchd master daemon 패턴 중 선택. Phase Decision으로 박제
- [ ] launchd cleanup 검증: `nrs darwin` 후 `rg 'ssh-add-keys|sshAddScript|sshKeyPath' modules/darwin/programs/ssh/default.nix` 결과가 0건이어야 정상
- [ ] `nrs darwin` 빌드 + activate
- [ ] **MiniPC authorized_keys 배포** — `constants.sshDeviceKeys`와 `hosts/greenhead-minipc/default.nix`의 authorizedKeys 목록은 NixOS config이므로 MiniPC도 rebuild해야 새 키가 deploy됨:
  - [ ] `nrs minipc` 실행 (Mac에서 트리거 가능)
  - [ ] deployed-key presence check: `ssh minipc 'wc -l /etc/ssh/authorized_keys.d/greenhead'` 결과가 신규 키 추가만큼 증가 (예: 기존 1줄 → 4줄)
  - [ ] 키 indices 확인: `ssh minipc 'grep -c "mac-ssh\|iphone-ssh\|ipad-ssh\|emergency-fallback" /etc/ssh/authorized_keys.d/greenhead'` 결과 = 4
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
- Mobile Termius 후속 검증은 [Post-Merge Remediation](#post-merge-remediation-termius-mobile-key-mismatch)의 checklist와 evidence table을 canonical gate로 따른다.

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
- [ ] Historical mobile gate: iPhone/iPad Termius `ssh minipc` 정상 동작은 사용자 manual 보고 기준이었다. Server-side accepted fingerprint 기준으로는 닫히지 않았으므로 Post-Merge Remediation에서 추적한다.
- [ ] `~/.ssh/id_ed25519` 평문 file 처분 완료 (archive 또는 1Password vault 이관)
- [ ] 다음 phase (Phase 2b)를 시작하지 못하게 막는 blocker 없음

## Post-Merge Remediation: Termius Mobile Key Mismatch

2026-05-26에 iPhone Termius 접속 실패를 분석한 결과, iPhone Tailscale IP에서 MiniPC `sshd`까지 연결은 도달했지만 PAM 인증 실패로 종료됐다. 당시 MiniPC는 `kbdinteractiveauthentication yes` 상태였다. 또한 직전 iPhone 성공 기록의 accepted publickey fingerprint는 현재 `iphone-ssh`가 아니라 retired `macbook` key와 일치했다. 따라서 Phase 2a의 server-side key 배포 확인만으로는 충분하지 않았고, mobile actual connection identity를 server-side accepted fingerprint로 검증하는 gate가 빠진 것이 사각지대다.

### Decision Gate

- [ ] Remediation checklist 실행 전에 [Required Before iPhone Remediation](#required-before-iphone-remediation) 질문을 먼저 닫는다.
- [ ] Retired `macbook` key 임시 재등록을 실제로 사용할 때만 [Fallback Only](#fallback-only-retired-macbook-key-temporary-re-registration) decision set을 먼저 닫는다.

### Remediation Checklist

- [x] 현재 MiniPC 등록 fingerprint 확인: `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead`에서 `iphone-ssh`, `ipad-ssh`, `mac-ssh`, `emergency-fallback` fingerprint를 아래 fingerprint inventory table에 기록 (2026-05-30 완료 — retired 공유 키 row 포함)
- [x] MiniPC OpenSSH hardening: `modules/nixos/programs/ssh.nix`에 `services.openssh.settings.KbdInteractiveAuthentication = false` 추가 후 적용 — PR #867 squash merge + MiniPC 배포(2026-05-30, `ssh minipc` → `git pull` + `nrs`)
- [x] Server hardening 검증: `sudo -n sshd -T` 결과 `passwordauthentication no`, `pubkeyauthentication yes`, `kbdinteractiveauthentication no` 확인 (2026-05-30, 배포 직후)
- [ ] Termius iPhone host profile 확인: host는 MiniPC Tailscale endpoint, user는 `greenhead`, auth는 key identity 중심, identity는 `iphone-ssh`
- [ ] iPhone에서 접속 시도 후 MiniPC 로그 확인: attempt time window를 KST ISO range로 정하고 같은 range를 `journalctl -u sshd.service --since ... --until ...`에 사용
- [ ] Evidence log extraction: `journalctl -u sshd.service --since "<KST start>" --until "<KST end>" | rg 'for <user> from <device Tailscale IP>( port|$)' | rg 'Accepted publickey|keyboard-interactive|PAM|Failed publickey'` 결과에서 해당 device IP + user의 accepted log line/time과 PAM 여부를 evidence table에 기록. `<device Tailscale IP>`와 `<user>`는 evidence table 값과 같아야 하며, iPhone 기준 known values는 `100.76.27.1`과 `greenhead`이다.
- [ ] Mobile regression check: evidence table의 accepted fingerprint가 expected fingerprint와 일치하고, 같은 device IP + user + attempt time window에 keyboard-interactive/PAM 실패 로그가 남지 않음
- [ ] 실패 시 분기:
  - Publickey accepted line 없이 PAM failure가 관찰되면 host profile의 identity binding을 수정
  - accepted publickey fingerprint가 expected fingerprint와 다르면 accepted fingerprint의 출처를 식별하고 `iphone-ssh`로 교체
  - accepted publickey line이 없고 key mismatch가 의심되면 MiniPC 기본 sshd 로그만으로 rejected key fingerprint를 단정하지 않는다. Evidence capture는 read-only public key view/copy 또는 client verbose log만 허용한다. Termius의 `Copy SSH Key to Server` / `Export to host`처럼 server `authorized_keys`를 변경할 수 있는 flow는 진단 중 사용 금지다. Read-only public key 파일을 확보한 경우 `ssh-keygen -lf <public-key-file>`로 fingerprint화해 `Rejected/mismatched key evidence`에 기록한다. Read-only public key 또는 fingerprint를 확인할 수 없으면 해당 field를 `unavailable`로 기록하고 `iphone-ssh` import 또는 rotation 중 하나를 선택한다.
  - `iphone-ssh` private key가 Termius에 없으면 1Password Automation vault backup에서 복구한다. 새 iPhone keypair를 생성하는 경우에는 1Password Automation vault `iphone-ssh` item의 private key, public key, fingerprint와 `constants.sshDeviceKeys.iphone`를 함께 rotate한 뒤 `nrs`를 적용하고, MiniPC authorized_keys fingerprint와 vault 기록 fingerprint가 일치하는지 대조한다. Rotation 후에는 fingerprint inventory table의 `iphone-ssh` row를 새 MiniPC deployed fingerprint로 다시 채우고, evidence table의 expected fingerprint도 갱신된 row에서 가져온다.
- [ ] iPad도 검증 범위로 선택되면 동일 절차를 `ipad-ssh`에 반복
- [ ] 검증 완료 후 Phase 2a Change Log와 master PRD Open Questions/Change Log를 token/secret 없이 갱신. #780 comment는 선택적 mirror로만 사용

표준 복구 경로는 `iphone-ssh` backup import 또는 새 iPhone keypair rotation이다. Retired `macbook` key 임시 재등록은 두 표준 경로가 막힌 경우의 최후수단이며, 허용 시 server-side source restriction(`from=` 또는 동등한 제한), TTL/removal gate, private key 보유 위치 확인, 제거 검증이 모두 필요하다.

### Closed Status Definition

이 follow-up의 `닫힘` 상태는 Phase 2a Post-Merge Remediation이 canonical이다. 최소 조건은 MiniPC OpenSSH `KbdInteractiveAuthentication = false` 적용, `sudo -n sshd -T`의 `kbdinteractiveauthentication no` 검증, iPhone accepted fingerprint match, 같은 device IP + user + attempt window의 keyboard-interactive/PAM 실패 로그 부재, Required Before iPhone Remediation 결정 완료, Phase 2a/master PRD 기록 완료다. iPad를 remediation 범위에 포함하기로 결정한 경우에는 iPad accepted fingerprint match도 `닫힘` 조건에 포함한다. Policy Follow-Up 질문은 immediate recovery `닫힘`을 막지 않는다. Fallback Only decision set은 fallback을 실제로 사용하기로 선택한 경우에만 `닫힘` 조건에 포함한다.

### Fingerprint Inventory Table

Measured 2026-05-30 (MiniPC `sshd` journal 보존 시작 2026-05-02). `mac-ssh`/`emergency-fallback`은 배포된 키, `iphone-ssh`/`ipad-ssh`는 2026-05-30 Termius 디바이스에서 새로 생성한 **rotated 키**(배포 후 authorized_keys에 반영), 마지막 row는 authorized_keys에 더 이상 없는 retired 공유 키로 journal `Accepted publickey` 로그에서만 관측된다.

| Key label | SHA256 fingerprint | Source command |
|---|---|---|
| `iphone-ssh` | `SHA256:hlE5JoF+9xFVJmw3BVN/+NC5134uDU5sv5KfdbNmq1k` | rotated 2026-05-30 (Termius 디바이스 생성, 직전 폐기 `SHA256:qkDV…wA4PKrI`); 배포 후 `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead`로 재확인 |
| `ipad-ssh` | `SHA256:rtx6yaP26dIw0P2wQ2drV/W+IHF+keaU4eCKW4i+KoY` | rotated 2026-05-30 (Termius 디바이스 생성, 직전 폐기 `SHA256:rCm2…2OIiDWo`); 배포 후 `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead`로 재확인 |
| `mac-ssh` | `SHA256:h/M3XNgDVwUQueVTaVbiUdeGJpsfRZVQPPzYOa/CnVI` | `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead` |
| `emergency-fallback` | `SHA256:Ux1iqQmI6lrCa7r48lM7fC2gbVvkgsf+PDTUfoTcOiI` | `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead` |
| retired shared key (현재 미등록) | `SHA256:6RE7i26xUU6VGdFAFLxdWnF0oHiuHR5KQqUoQT8RydQ` | MiniPC `sshd` journal `Accepted publickey` — authorized_keys 부재, 마지막 accept 2026-05-25T17:37 KST |

### Mobile Attempt Evidence Table

이 표는 Phase 2a Change Log와 master PRD Open Questions/Change Log를 갱신하기 전의 canonical mobile attempt evidence 형식이다. `attempt time window`는 KST ISO range로 기록하고, 같은 범위를 `journalctl --since/--until`에 사용한다. `expected SHA256 fingerprint`는 fingerprint inventory table에서 가져오고, `accepted SHA256 fingerprint`와 `accepted log line/time`은 MiniPC `sshd` 로그에서 가져온다.

아래는 2026-05-30 baseline 진단 — hardening 적용 및 Termius 키 복구 **이전**, MiniPC `sshd` journal(보존 2026-05-02~) 과거 로그 분석 결과다. Termius 키 복구 후 재시도의 accepted-match evidence는 closeout 시점에 별도 row로 덮어쓴다.

| Device | User | Tailscale IP | Attempt time window | Expected key label | Expected SHA256 fingerprint | Accepted SHA256 fingerprint | Accepted log line/time | Rejected/mismatched key evidence | Keyboard-interactive/PAM observed | Result |
|---|---|---|---|---|---|---|---|---|---|---|
| iPhone | `greenhead` | `100.76.27.1` | 2026-05-26T18:29 ~ 2026-05-28T20:14 KST | `iphone-ssh` | `SHA256:qkDVFnuu…wA4PKrI` | none (Accepted publickey 라인 없음) | 없음 — 5/26·5/28 총 5회 `Disconnected from authenticating user greenhead … [preauth]` | 키 교체(#833) 이전 66회 `SHA256:6RE7…RydQ`(retired)로 accept; `iphone-ssh` accept 0회 | pubkey 거부 후 preauth 종료, PAM session 미도달 (`passwordauthentication no`) | FAIL — #833이 retired 공유 키를 authorized에서 제거한 뒤 Termius가 미교체 키 보유로 차단 |
| iPad (if in scope) | `greenhead` | `100.114.211.7` | 마지막 성공 2026-05-24T15:37 KST; #833(2026-05-25) 이후 시도 없음 | `ipad-ssh` | `SHA256:rCm2oVgt…2OIiDWo` | `SHA256:6RE7…RydQ` (retired, 마지막 성공 기준) | `2026-05-24T15:37 Accepted publickey … SHA256:6RE7…RydQ` | `ipad-ssh` accept 0회; 전량 retired 공유 키 의존 | N/A (키 교체 후 미시도) | 키 교체 후 미접속(침묵) — 시도 시 iPhone과 동일 실패 예상 (동일 retired key 의존) |

### Baseline Diagnosis (2026-05-30)

근본 원인은 **클라이언트 키 미교체**로 확정된다. 서버 쪽 배포(`constants.sshDeviceKeys`의 `iphone-ssh`/`ipad-ssh`를 MiniPC authorized_keys에 등록)는 #833에서 완료됐으나, iPhone/iPad **Termius 디바이스에는 새 디바이스 키의 private key가 설치되지 않았다.** 두 디바이스는 retire된 공유 키 `SHA256:6RE7…RydQ` 하나로 인증해 왔고(Mac 150 / iPhone 66 / iPad 14회, 마지막 accept 2026-05-25T17:37 KST), #833이 이 키를 authorized_keys에서 제거하면서 iPhone이 차단됐다. `iphone-ssh`/`ipad-ssh`는 journal 전 기간에 걸쳐 **accept 0회**다.

- iPhone: 2026-05-26·05-28 재시도 5회 전부 preauth 단계에서 종료 (실측).
- iPad: 2026-05-24 이후 접속 시도 자체가 없어 "우연히 통과 중"이 아니라 침묵 상태이며, 동일 retired key 의존이므로 시도 시 동일 차단이 예상된다 → remediation 범위 포함 권장.
- 표준 복구 경로(`iphone-ssh`/`ipad-ssh` backup import 또는 새 keypair rotation)는 디바이스 측 작업이라 이 진단으로 코드 변경 대상이 아니다. Fallback Only(retired key 임시 재등록) decision set은 표준 경로가 막힌 경우에만 연다.

### Questions For User Decision

#### Required Before iPhone Remediation

- [x] 검증 범위: **iPhone + iPad 둘 다 포함** (Baseline Diagnosis상 iPad도 동일 retired key 의존이라 시도 시 동일 차단 — 함께 rotation). 2026-05-30 결정.
- [x] `iphone-ssh`/`ipad-ssh` private key source: **새 keypair rotation**. Automation vault 확인 결과 `iphone-ssh`/`ipad-ssh` item 부재(import 대상 없음 — vault에는 `mac-ssh`/`emergency-ssh`만 존재) → Termius 디바이스(iPhone/iPad)에서 각각 ED25519 신규 생성 후 public key를 `constants.sshDeviceKeys.iphone`/`.ipad`에 rotate. **private key는 디바이스 keychain 전용**(1Password vault·Mac 미경유, 노출 최소). 2026-05-30 결정.
- [x] Rejected-key evidence path: server-side journal 실측으로 retired 공유 키 `SHA256:6RE7…RydQ` 의존을 확정(Baseline Diagnosis). 디바이스의 옛 key는 server-mutating 없이 read-only 확인이 불요해 `unavailable`로 두고 rotation으로 직행. 2026-05-30 결정.

#### Fallback Only: Retired `macbook` Key Temporary Re-Registration

기본 복구 경로(`iphone-ssh` import 또는 rotation)가 가능하면 이 decision set은 열지 않는다.

- [ ] Retired key 임시 재등록 허용 여부: old `macbook` public key 재등록을 최후수단으로 허용할지, 보안상 계속 금지하고 `iphone-ssh` import/rotation만 허용할지?
- [ ] Retired key source restriction: MiniPC server-side 제한을 `from="<iPhone Tailscale IP>"` 또는 동등한 source restriction 중 무엇으로 둘지?
- [ ] Retired key TTL: 임시 재등록 유지 시간을 무엇으로 둘지?
- [ ] Retired key removal owner: 제거 실행 주체를 누구로 둘지?
- [ ] Retired key removal verification command: 제거 검증 명령을 무엇으로 둘지? 기준은 `ssh-keygen -lf /etc/ssh/authorized_keys.d/greenhead`에서 old `macbook` fingerprint absent 확인이다.
- [ ] Retired key private-key ownership check: old `macbook` private key가 어디에 남아 있는지 확인하고, 예상 밖 보유 위치가 발견되면 임시 재등록을 중단할지?

#### Policy Follow-Up (Not Blocking Immediate Recovery)

- [ ] Termius host canonical target: host 값을 `constants.network.minipcTailscaleIP`의 raw Tailscale IP로 고정할지, MagicDNS/hostname을 표준으로 둘지?
- [ ] Termius profile policy: server-side `KbdInteractiveAuthentication = false` hardening을 필수로 둔 상태에서, Termius UI에서도 keyboard-interactive 또는 password/PAM prompt를 비활성 또는 미사용으로 둘지?
- [ ] Evidence policy: mobile SSH key rotation/revoke 때마다 MiniPC `sshd` accepted fingerprint 대조를 mandatory gate로 둘지?
- [ ] Inventory policy: 1Password `iphone-ssh`/`ipad-ssh` item에 public fingerprint와 Termius host profile 이름을 필드로 추가해 운영 인벤토리로 삼을지?
- [x] Issue/PR tracking: 별도 GitHub 추적 이슈 #866 등록 (2026-05-30). 진행/닫힘 판단의 canonical SSOT는 본 phase-02a를 유지하고, #866은 가시화용 mirror로 운영한다.

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-3, SC-4 달성
- [ ] 2. Correctness — happy path, 1Password quit, biometric 거부, ControlMaster 만료 후 무인 호출 hang 모두 처리
- [ ] 3. Simplicity — IdentityAgent 1줄 + emergency Host 분기로 최소 변경
- [ ] 4. Code quality — `programs.ssh`/`agent.toml` 구조가 현재 모듈과 일치하고, 제거된 ssh-add launchd 경로가 completion criteria에 남지 않음
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
- **전환 옵션 생략 + 최종 cleanup**: phase-02a가 명시한 전환 옵션 대신 모듈 let 상수로 구현(토글 수요 없어 YAGNI). id_ed25519 처분 시 launchd ssh-add-keys 경로 전체가 dead가 되어 legacy launchd/sshAddScript/sshKeyPath 경로까지 함께 제거 → ssh/default.nix가 1Password agent 전용으로 단순화.
- **id_ed25519 처분**: minipc 외 미사용 확인(github는 HTTPS git, MiniPC는 mac-ssh) → `~/.ssh/id_ed25519.archive`(chmod 000)로 mv. ssh config identityFile 제거 후 `ssh minipc`가 mac-ssh agent만으로 인증됨을 실측. darwin의 Mac 접속용 authorizedKeys(macbook 공개키)는 별개라 보존.
- **Mobile Termius validation gap**: Phase 2a closeout은 Mac agent path와 emergency fallback을 강하게 검증했지만, iPhone/iPad Termius actual connection identity가 신규 device key인지 서버 로그 fingerprint 기준으로 닫지 못했다. 이후 mobile SSH 검증은 "client success + server accepted fingerprint match"를 함께 요구한다.

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-25: Phase 2a 구현 완료 → PR #833 squash merge. 디바이스 키 4개(mac-ssh/iphone/ipad/emergency)를 `constants.sshDeviceKeys`로 정의하고 MiniPC authorizedKeys에 배포(nrs minipc). Mac ssh config: IdentityAgent(group container socket) + agent.toml(Automation vault 노출) + minipc-emergency Host + ControlPersist 600(ControlMaster 유지). id_ed25519 archive. 검증: `ssh minipc`=mac-ssh agent 인증(Touch ID), emergency fallback 실측(1Password quit→emergency 접속 성공→ssh minipc Permission denied→재시작 복귀), id_ed25519 처분 후 agent-only 인증. merge 후 main nrs 적용 + E2E 전항목 재검증 통과. agent.toml vault를 constants 참조로 정정(SSOT). 발견: ControlPersist 영구는 무인 hang(→600 유지), agent socket은 group container 경로, agent.toml로 키 노출 명시 필수.
- 2026-05-26: iPhone Termius 접속 실패 후속 분석 반영. iPhone Tailscale IP에서 MiniPC `sshd`까지 연결은 도달했지만 PAM 인증 실패로 종료됐고, 당시 MiniPC는 `kbdinteractiveauthentication yes` 상태였다. 직전 iPhone 성공 기록의 accepted publickey fingerprint는 현재 `iphone-ssh`가 아니라 retired `macbook` key와 일치했다. Post-Merge Remediation checklist와 사용자 결정 질문을 추가.
- 2026-05-30: hardening + 진단 + rotation. (a) `ssh.nix`에 `KbdInteractiveAuthentication = false` 추가 → **PR #867** squash merge·MiniPC 배포(`ssh minipc` → `git pull` + `nrs`, 26s), `sudo -n sshd -T`=`kbdinteractiveauthentication no` 검증(`passwordauthentication no`·`pubkeyauthentication yes` 회귀 없음). (b) MiniPC journal 실측으로 retired 공유 키 `SHA256:6RE7…RydQ` 정체 규명 — iPhone 66·iPad 14회 accept(마지막 2026-05-25T17:37 KST), `iphone-ssh`/`ipad-ssh`는 accept 0회 → 근본원인은 클라이언트(Termius) 키 미교체. (c) Automation vault에 `iphone-ssh`/`ipad-ssh` item 부재 확인(import 불가) → Termius 디바이스(iPhone/iPad)에서 ED25519 신규 생성, `constants.sshDeviceKeys` rotate(iphone `SHA256:hlE5…q1k`, ipad `SHA256:rtx6…KoY`), private key는 디바이스 keychain 전용. iPad 범위 포함 결정. 추적 이슈 #866. 배포 후 재접속 accepted fingerprint match 검증은 closeout에서 별도 기록.
