# Plan 029: Claude/Codex headless SSH의 인증 대기만 bounded하게 만든다

> Claude Code Remote Control과 Codex Desktop tool child의 `ssh minipc`가 Mac 로컬의
> 1Password 승인 UI를 기다리며 무기한 멈추지 않게 한다. 정상 장시간 command와 PTY는
> 그대로 보존한다. private key·복호화 secret·token은 읽거나 출력하지 않는다.

## Status

- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1094
- **Branch**: `codex/issue-1094-headless-ssh-dx-policy`
- **Base snapshot**: `origin/main@28b556e9d79c03fdff2f39f088b4c6a0624d37e0`
- **Priority**: P1
- **Risk**: HIGH — launcher PATH와 SSH 인증/command 경계를 바꾼다
- **Execution**: IN PROGRESS
- **Plan DA**: R18, MEDIUM+ 0 / LOW 0

## Problem

현재 main의 headless fallback은 `timeout 20 ssh ...`로 SSH 전체를 감싼다. 이 방식은
1Password 승인 hang은 끝내지만 인증이 이미 성공한 정상 remote command도 20초에 잘라 버린다.
또 interactive zsh 함수에만 구현되어 Claude/Codex 실제 child가 `/usr/bin/ssh`를 직접 실행하면
정책을 우회한다.

이번 변경의 불변식은 다음과 같다.

1. MiniPC 인증 전 대기는 bounded다.
2. 인증 후 command에는 deadline이 없다.
3. Claude/Codex 실제 child가 private dispatcher를 PATH에서 실행한다.
4. interactive Ghostty, 다른 SSH host, GitHub SSH, `minipc-emergency`는 raw OpenSSH다.
5. secret/private key 내용은 test·stdout/stderr·diff·PR에 나타나지 않는다.

## A/B/C/D/E decision

| 정책 | 선택 | 원격 DX | lock/quit/reboot | 범위 | 운영비용 |
|---|---:|---|---|---|---|
| A: all applications 승인 | ❌ | agent session 동안 편함 | 1Password unlock/session에 다시 종속 | user process 전체 | 승인 상태 정리 필요 |
| B: per-app 승인 | ❌ | 앱별 승인 필요 | app/agent 수명에 종속 | Claude/ChatGPT process | launcher별 관리 |
| C: `minipc-headless` key | ✅ | GUI 0회 | agenix materialization 뒤 독립 | 기존 MiniPC 전용 key | 기존 rotate/revoke runbook |
| D: auth deadline | ✅ 필수 | 무한 hang 대신 bounded 124 | 상태와 무관 | launcher MiniPC auth phase | 낮음 |
| E: active master reuse | ✅ 보조 | 재인증 0회 | master 생존 동안 | 검증된 configured socket | 새 공유 master 없음 |

선택은 **C+D**, E는 이미 살아 있는 configured ControlMaster만 재사용한다. A/B GUI 상태는
변경하지 않는다. 기존 `minipc-headless` key를 재생성·교체하지 않고 `minipc-emergency`를
fallback으로 재사용하지 않는다.

### PTY 정책 결정

기존 dedicated authorized_keys entry에 `no-pty`를 추가하는 방안을 action-time에 설명했으나,
사용자가 DX 저하 우려로 명시적으로 거부했다. 따라서 MiniPC server 파일과 key는 변경하지 않고
PTY를 보존한다. 현행 `from=` 및 port/agent/X11 forwarding 제한은 그대로다. 일반 command를
유지해야 하므로 허위 `command=` restriction도 추가하지 않는다.

## Regression context

- PR #889: MiniPC 판정은 `ssh -G` effective host/user/port를 확인한다.
- PR #936: data-plane stderr를 `tee`, process substitution, 임시파일로 캡처하지 않는다.
- PR #1136: whole-command deadline은 장시간 command를 자르는 결함이 있다.
- PR #1137: dedicated `minipc-headless` key는 mac-ssh/emergency와 분리돼 있다.

## Implementation

### 1. Launcher-scoped PATH

private package는 `bin/ssh`만 제공하며 global `home.packages`나 `home.sessionPath`에 넣지 않는다.

- Claude: 하나의 launch-environment constructor가 launchd maint, manual `claude-rc`, 실제 bridge
  child PATH를 만든다. bridge attestation은 실행 중인 bridge가 해당 environment generation을
  실제로 소유하는지 확인한다.
- Codex: evaluated personal-role config seed가 `NIXOS_CONFIG_HEADLESS_SSH=1`을 child shell에
  넣고 `.zshenv`가 non-TTY launcher child에서만 private PATH를 prepend한다.
- Ghostty: marker가 없으므로 `/usr/bin/ssh`와 기존 interactive 1Password preflight를 유지한다.

### 2. Target scope

dispatcher는 lexical destination을 먼저 파싱한다.

- raw exact: `minipc-emergency`, 다른 host, meta `-V/-Q/-G/-O`
- managed candidate: `minipc`, `minipc-headless`, exact MiniPC Tailscale IP
- `user@host`, `-W`, `-t/-tt`, remote argv, safe custom `-F`는 보존한다.
- candidate만 bounded `/usr/bin/ssh -G`로 effective host/user/port를 확인한다.
- effective host가 MiniPC가 아니면 original OpenSSH로 돌아간다.
- explicit identity/proxy/master ownership을 바꾸는 unsupported option은 network 전에 125로
  진단한다. 조용한 1Password/emergency fallback은 없다.

### 3. Authentication-only deadline

configured ControlPath가 active면 bounded `-O check` 뒤 그 socket으로 data command를 실행한다.
새 인증이 필요하면 unique `${DARWIN_USER_TEMP_DIR}/headless-ssh/call-*` socket을 만든다.

1. GNU `timeout`은 `/usr/bin/ssh -fN -M` 인증 master에만 적용한다.
2. master는 `IdentityAgent=none`, dedicated key, `BatchMode=yes`, password/keyboard-interactive off,
   `ControlPersist=5`로 direct MiniPC tuple에 인증한다.
3. timeout은 stable exit 124와 `HEADLESS_SSH_AUTH_TIMEOUT` 복구 안내를 출력한다.
4. 인증 success 뒤 actual command는 explicit mux socket과 `ProxyCommand=/usr/bin/false`를 사용한다.
   socket race가 direct 재인증으로 fallback하지 않는다.
5. data command에는 deadline을 적용하지 않고 stdout/stderr/exit/signal/PTY를 보존한다.
6. foreground 종료 뒤 bounded `-O exit`와 call dir cleanup을 수행한다. `-f` background session은
   master를 즉시 끊지 않고 socket을 unpublish한 뒤 `ControlPersist=5` 자가 종료에 맡긴다.
   wrapper crash도 같은 짧은 상한으로 수렴한다.

이 구현은 persistent policy FSM, bootstrap, rotation/recovery helper를 추가하지 않는다. 정상 사용에
새 수동 승인이나 복구 절차를 만들지 않는 것이 DX 계약이다.

### 4. Failure contract

- auth stall: 124 + dedicated key/Tailscale/authorized_keys 진단
- immediate SSH failure: 원래 exit 255와 stderr
- missing/wrong real SSH, timeout, key mode: network 전 125
- remote command exit 124: timeout 진단 없이 그대로 124
- stale master: bounded dedicated auth
- vanished mux socket: `/usr/bin/false`를 통한 빠른 실패, direct auth fallback 없음

## Hermetic tests

실제 1Password·실제 key·MiniPC를 사용하지 않는 fake SSH fixture로 다음을 고정한다.

1. success 0 + stdout/stderr
2. immediate auth 255 보존
3. auth stall과 TERM 무시 후 kill-after 모두 deadline+2초 이내 124+진단
4. auth 뒤 장시간 command가 deadline 이후 성공
5. remote exit 124 오분류 없음
6. active master 재사용, 새 auth 0회
7. stale master의 bounded dedicated auth
8. `minipc-emergency`/다른 host raw exact once
9. `-V/-Q/-G/-O` meta raw
10. `user@host`, safe custom `-F`의 host-verification transport, `-W`, `-tt` 보존
11. effective retarget non-MiniPC raw
12. explicit identity override network 전 fail-closed
13. 동시 호출 unique socket과 cleanup
14. TERM 전달·동일 signal 종료·cleanup
15. `-f` background session master 비간섭과 bounded self-exit
16. real SSH/timeout 부재 fail-closed
17. key mode 오류 network 전 fail-closed

Canonical gates:

```bash
nix develop --command python3 tests/headless-ssh-dispatcher-tests.py
git diff --check
nix eval --impure --file tests/eval-tests.nix
CI=1 nix develop --command bash tests/run-all-tests.sh
./scripts/ai/verify-ai-compat.sh
```

## Deployment and actual E2E

Host mutation은 `/tmp/nrs-state` free 확인과 fresh action-time 승인 뒤에만 수행한다.

1. `NRS_ALLOW_WORKTREE_RELINK=1 nrs`
2. 즉시 `./scripts/ai/verify-ai-compat.sh`
3. Claude bridge 상태/active session을 확인하고 사용자 승인 뒤 정상 restart
4. ChatGPT/Codex는 사용자 승인 뒤 정상 quit/reopen; `launchctl submit` 금지
5. Claude actual child와 Codex actual app-server child에서 아래 bounded matrix 실행
   - master 없음: success 0
   - master 있음: success 0, 새 auth 없음
   - dedicated auth 불가: auth deadline 안 124/255
   - auth 뒤 장시간 command: deadline 이후 success
   - child `ssh` resolved path와 ancestry
6. Ghostty는 raw `/usr/bin/ssh`; `minipc-emergency`와 다른 host 비간섭

실제 probe는 바깥 watchdog을 가지되 production command 전체 deadline과 혼동하지 않는다.
secret/key 내용은 기록하지 않고 path/exit/elapsed/prompt 여부만 기록한다.

## Commit, DA, PR

1. checkpoint commit 뒤 latest `origin/main` rebase
2. 전체 gate와 영향받은 nrs/E2E 반복
3. `$run-da for_pr`; unresolved MEDIUM+ 0이면 LOW를 정직하게 기록하고 진행
4. final branch push
5. `$create-pr`로 main 대상 PR 생성, Summary에 `Closes #1094`
6. DA 결과는 별도 PR comment, handoff comment 없음, merge하지 않음

## Completion checklist

- [ ] C+D 적용, E 보조 선택 기록
- [x] A/B GUI mutation 0건
- [x] credential/key/server authorized_keys mutation 0건
- [x] PTY 보존 결정 기록
- [ ] hermetic focused/full tests 통과
- [ ] Claude/Codex actual child binding과 master 없음/있음 E2E
- [ ] 성공/실패 bounded, 장시간 command 회귀 없음
- [ ] nrs와 verify-ai-compat 통과
- [ ] `$run-da for_pr` MEDIUM+ 0
- [ ] branch push와 `$create-pr`
- [ ] PR URL/base/head/7 sections/`Closes #1094`/final SHA 재검증
- [ ] worktree clean, merge하지 않음

## STOP conditions

- actual Claude/Codex child가 private dispatcher를 resolve하지 못함
- 장시간 command 또는 PTY를 짧은 timeout으로 잘라야 함
- 다른 host/Ghostty/emergency 경로를 감싸야 함
- 실제 test가 1Password/private key 내용을 요구함
- nrs/E2E/test/DA MEDIUM+가 해결되지 않음
- GitHub auth 실패 또는 duplicate OPEN PR
