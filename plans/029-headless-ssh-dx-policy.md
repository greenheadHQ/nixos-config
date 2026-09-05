# Plan 029: Claude/Codex headless SSH의 인증 대기만 bounded하게 만든다

> Claude Code Remote Control과 Codex Desktop tool child의 `ssh minipc`가 Mac 로컬의
> 1Password 승인 UI를 기다리며 무기한 멈추지 않게 한다. 정상 장시간 command와 PTY는
> 그대로 보존한다. private key·복호화 secret·token은 읽거나 출력하지 않는다.

## Status

- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1094
- **Branch**: `codex/issue-1094-headless-ssh-dx-policy`
- **Base snapshot**: `origin/main@78f26c667a3b383d8110cf31bd549ce3b626e26d`
- **Priority**: P1
- **Risk**: HIGH — launcher PATH와 SSH 인증/command 경계를 바꾼다
- **Execution**: COMPLETE — automated/host E2E와 PR #1213 생성 완료, merge하지 않음
- **Plan DA**: COMPLETE — R22 MEDIUM+ 0; signal 보존 LOW는 반영, 유지보수 LOW 2건은 범위 고정에 따라 잔존
- **PR DA**: COMPLETE — confirmed MEDIUM launcher binding 1건 반영 후 재검토 MEDIUM+ 0; LOW만 잔존

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
| C: `minipc-headless` key | ✅ | GUI 0회 | agenix materialization 뒤 독립 | 기존 MiniPC 전용 key | `managing-ssh` 수동 rotate/revoke runbook |
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

- Claude: launchd maint와 personal Darwin의 얇은 manual `claude-rc`/`claude-rc-maint` wrapper가
  `~/.local/share/nixos-config/headless-ssh/bin`을 child PATH 앞에 둔다.
- Codex: Darwin config의 `shell_environment_policy.set` marker를 받은 non-TTY tool shell만
  `.zshenv`에서 같은 stable private PATH를 prepend한다.
- marker 없는 기존 remote/automation interactive zsh는 공통 headless predicate로 stable
  dispatcher를 직접 호출해 main의 bounded 인증 계약을 보존한다. interactive Ghostty는 해당
  신호가 없어 raw SSH를 유지한다.
- stable home symlink는 activation 때 현재 immutable package로 relink된다. 따라서 SSH 때문에
  Claude environment generation/attestation이나 shared lifecycle schema를 추가하지 않는다.
- versioned manifest에서 parser가 소비하는 값은 OpenSSH short-option arity뿐이고, 그 옆의
  `verifiedOn`(macos/ssh/date)은 arity 표를 어느 환경에서 확인했는지만 남기는 근거 표기라
  런타임·`runtimeGeneration` 해시에 들어가지 않는다. macOS의 `/usr/bin/ssh`가 갱신되면
  `ssh -h`/manpage의 short-option argument 유무와 함께 arity와 `verifiedOn`을 갱신한다.
- Ghostty: marker가 없으므로 `/usr/bin/ssh`와 기존 interactive 1Password preflight를 유지한다.

### 2. Target scope

dispatcher는 lexical destination을 먼저 파싱한다.

- raw exact: `minipc-emergency`, 명백한 다른 host, meta `-V/-Q/-G/-O`
- managed candidate: `minipc`, `minipc-headless`, exact MiniPC Tailscale IP
- `user@host`, `-W`, `-t/-tt`, remote argv, safe custom `-F`는 보존한다.
- candidate와 destination을 바꿀 수 있는 explicit `-F`/`-o HostName` 호출만 bounded
  `/usr/bin/ssh -G`로 effective host/user/port를 확인한다. 따라서 `-F safe.conf custom-alias`
  가 MiniPC tuple이면 managed되고, 일반 다른 host는 config를 두 번 평가하지 않고 raw exact-once다.
- effective host가 MiniPC가 아니면 original OpenSSH로 돌아간다.
- explicit identity/proxy/master ownership을 바꾸는 unsupported option은 network 전에 125로
  진단한다. 조용한 1Password/emergency fallback은 없다.

### 3. Authentication-only deadline

configured ControlPath가 active면 bounded `-O check` 뒤 그 socket으로 data command를 실행한다.
새 인증이 필요하면 unique `${DARWIN_USER_TEMP_DIR}/headless-ssh/call-*` socket을 만든다.

1. GNU `timeout`은 `/usr/bin/ssh -fN -M` 인증 master에만 적용한다. `-M`과
   `ControlMaster=yes`를 중복 지정하지 않아 OpenSSH confirmation mode를 켜지 않는다.
2. master는 `IdentityAgent=none`, dedicated key, `BatchMode=yes`, password/keyboard-interactive off,
   `ControlPersist=5`로 direct MiniPC tuple에 인증한다.
3. timeout은 stable exit 124와 `HEADLESS_SSH_AUTH_TIMEOUT` 복구 안내를 출력한다.
4. 인증 success 뒤 actual command는 explicit mux socket과 `ProxyCommand=/usr/bin/false`를 사용한다.
   socket race가 direct 재인증으로 fallback하지 않는다.
5. data command에는 deadline을 적용하지 않고 stdout/stderr/exit/signal/PTY를 보존한다.
6. foreground 종료 뒤 bounded `-O exit`와 call dir cleanup을 수행한다. `-f` background session은
   master를 즉시 끊지 않고 socket을 unpublish한다. active client가 끝난 뒤 idle master는
   `ControlPersist=5`에 따라 5초 후 자가 종료한다. 이는 wrapper crash 중인 active session의
   5초 watchdog을 의미하지 않는다.

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
10. `user@host`, safe custom `-F` alias/host-verification transport, explicit
    `-o HostName`, `-W`, `-tt` 보존
11. effective retarget non-MiniPC raw
12. explicit identity override network 전 fail-closed
13. 동시 호출 unique socket과 cleanup
14. TERM 전달·동일 signal 종료·cleanup
15. `-f` background session master 비간섭과 bounded self-exit
16. real SSH/timeout 부재 fail-closed
17. key mode 오류 network 전 fail-closed
18. auth master가 non-confirming ControlMaster enablement를 정확히 한 번만 사용

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
   - 실제 OpenSSH `-tt`: remote stdin/stdout TTY 할당 success
   - 실제 OpenSSH `-f`: dispatcher socket unpublish 뒤 짧은 background marker 완료
   - child `ssh` resolved path와 ancestry
6. fresh action-time 확인 뒤 1Password locked/quit 상태에서도 두 actual child가 prompt 0,
   bounded success인지 확인한다. 기존 C 배포·직접 E2E의 안정 근거는 #1094의
   2026-07-18 완료 comment와 merge commit `cd3555d1`이며, 이번에는 새 launcher binding만
   재검증한다.
7. launcher restart 뒤 같은 matrix를 반복한다. C의 reboot 독립 주장은 fresh action-time
   승인 뒤 actual-child success/prompt 0으로 확인한다.
8. Ghostty는 raw `/usr/bin/ssh`; `minipc-emergency`와 다른 host 비간섭

실제 probe는 바깥 watchdog을 가지되 production command 전체 deadline과 혼동하지 않는다.
secret/key 내용은 기록하지 않고 path/exit/elapsed/prompt 여부만 기록한다.

### 2026-08-06 actual evidence

- `NRS_ALLOW_WORKTREE_RELINK=1 nrs`: exit 0, 80초. 직후 `verify-ai-compat` 완전 통과.
- PR DA의 manual maint binding 수정 뒤 `nrs`: exit 0, 108초. 배포된
  `claude-rc-maint-headless-launcher`가 marker와 private SSH PATH를 전달하고 등록 bridge 2개가
  bounded health check에서 running/healthy임을 확인했다.
- Codex actual app-server child: private `headless-ssh/bin/ssh` resolve, no-master 기본
  `0/0s`, 장시간 `0/17s`, PTY `0`, `-f` marker 완료, unsupported identity는 network 전
  `125`, active configured master 재사용 `0/0s`와 master 생존 확인.
- Claude actual Remote child: declared bridge의 versioned `--sdk-url` child에서 같은 private
  path를 resolve했고 no-master 기본 `0/0s`, 장시간 `0/17s`, PTY `0`; active configured
  master 재사용은 `0/0s`와 master 생존으로 확인했다.
- 최초 active-master fixture에서 auth master에 `-M`과 `ControlMaster=yes`가 함께 들어가
  OpenSSH confirmation mode가 켜지는 회귀를 발견했다. 중복 enablement를 제거하고
  hermetic regression test, 재배포, Codex/Claude actual child를 모두 다시 통과했다.
- Claude bridge는 active session 0 확인 뒤 정상 restart했다. ChatGPT/Codex quit/reopen은
  action-time 질문에서 사용자가 생략을 선택해 이번 실행에서는 하지 않았다. 현재 actual
  app-server child binding은 확인됐지만 fresh app process persistence cell은 미실행이다.
- 1Password GUI/승인, credential/key, MiniPC authorized_keys, TCC, reboot mutation은 0건이다.
  C의 lock/quit/reboot 독립성은 기존 #1094 완료 comment와 merge commit `cd3555d1`의
  실증을 유지하며, 이번 변경에서는 launcher와 deadline 경계만 재검증했다.
- 모든 test master/socket/Remote session/browser tab을 정리했고 `launchctl submit` job 0,
  SDK test child 0, configured master inactive, `/tmp/nrs-state` free를 확인했다.

## Commit, DA, PR

1. checkpoint commit 뒤 latest `origin/main` rebase
2. 전체 gate와 영향받은 nrs/E2E 반복
3. `$run-da for_pr`; unresolved MEDIUM+ 0이면 LOW를 정직하게 기록하고 진행
4. final branch push
5. PR 직전 duplicate OPEN PR을 다시 확인하고, 없으면 CLOSED #1094를 reopen한다.
6. `$create-pr`로 main 대상 PR 생성, Summary에 `Closes #1094`
7. DA 결과는 별도 PR comment, handoff comment 없음, merge하지 않음

## Completion checklist

- [x] C+D 적용, E 보조 선택 기록
- [x] A/B GUI mutation 0건
- [x] credential/key/server authorized_keys mutation 0건
- [x] PTY 보존 결정 기록
- [x] hermetic focused/full tests 통과
- [x] Claude/Codex actual child binding과 master 없음/있음 E2E
- [x] 성공/실패 bounded, 장시간 command 회귀 없음
- [x] nrs와 verify-ai-compat 통과
- [x] `$run-da for_pr` MEDIUM+ 0
- [x] branch push와 `$create-pr` — PR #1213
- [x] PR URL/base/head/7 sections/`Closes #1094`/final SHA 재검증
- [x] worktree clean, merge하지 않음

## STOP conditions

- actual Claude/Codex child가 private dispatcher를 resolve하지 못함
- 장시간 command 또는 PTY를 짧은 timeout으로 잘라야 함
- 다른 host/Ghostty/emergency 경로를 감싸야 함
- 실제 test가 1Password/private key 내용을 요구함
- nrs/E2E/test/DA MEDIUM+가 해결되지 않음
- GitHub auth 실패 또는 duplicate OPEN PR
