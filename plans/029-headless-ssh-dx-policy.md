# Plan 029: 원격 AI 세션의 1Password SSH 승인 hang을 DX 우선으로 제거한다

> **Executor instructions**: 이 plan은 1Password “Approve for all applications”를 포함한
> 인증 선택지를 실제 matrix로 비교하고 운영자 결정을 받은 뒤 구현한다. 어떤 인증안을 택해도
> headless SSH에는 outer deadline을 추가해 세션 무한 대기를 금지한다. private key 값은 읽거나
> plan/로그에 출력하지 않는다. 완료 시 `plans/README.md`의 029 행을 갱신한다.
>
> **Drift check (run first)**:
> `git diff --stat 368e3140..HEAD -- modules/darwin/programs/ssh/default.nix modules/shared/programs/shell/darwin.nix modules/darwin/programs/claude-remote-control.nix modules/shared/programs/codex/files/config.darwin.toml .claude/skills/managing-ssh/SKILL.md tests/`
> SSH agent, launcher PATH, timeout 관련 의미 변경이 있으면 Current state와 대조 후 STOP한다.

## Status

- **Priority**: P1
- **Effort**: M (A/B/D), L (Option C 전용 무인 key 채택 시)
- **Risk**: HIGH (승인 범위 확대 또는 별도 private key 도입 가능)
- **Depends on**: none (plan 028과 독립)
- **Category**: bug / dx / security
- **Planned at**: commit `368e3140`, 2026-07-13
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1094

## Why this matters

1Password SSH agent의 동의 모델은 로컬 interactive SSH에는 좋은 보안 경계지만, Mac 앞에 없는
원격 Claude/Codex에서는 보이지 않는 승인 UI가 된다. 실측 Codex `ssh minipc`는 TCP 연결 후
1Password agent socket에서 40초 넘게 대기했고, `BatchMode`/`ConnectTimeout`은 이 구간을
제한하지 못했다. DX를 최우선으로 “모든 앱 승인”과 전용 무인 key를 실제 후보로 평가하되,
인증 회귀가 나도 세션 자체는 반드시 bounded time 안에 복귀하게 한다.

## Current state

- `modules/darwin/programs/ssh/default.nix:21-25`: `Host *`가 1Password agent socket 사용.
- `modules/darwin/programs/ssh/default.nix:29-40`: `minipc`는 `mac-ssh.pub`,
  `IdentitiesOnly yes`, ControlMaster/ControlPersist 600 사용.
- `modules/darwin/programs/ssh/default.nix:43-49`: `minipc-emergency`는 파일 key와
  `IdentityAgent none`인 수동 fallback. 자동 전환 용도가 아니다.
- `modules/shared/programs/shell/darwin.nix:159-161`: interactive zsh 전용 preflight이며
  non-interactive automation은 raw SSH로 통과.
- `modules/shared/programs/shell/darwin.nix:187-206`: key 목록 확인에는 15초 상한이 있지만,
  실제 sign request에는 전체 deadline 없음.
- 같은 파일 `:208-225`는 “agent 목록은 제공하나 sign 승인만 실패/대기” 사각지대를 문서화한다.
- 실측: Codex 자식 SSH FD의 UNIX peer가 1Password `agent.sock`과 일치했고,
  LocalAuthentication은 `User interaction is required`를 반환했다.
- 1Password 공식 옵션: per-app, per-app/per-terminal, 요청별 “Approve for all applications”,
  lock/quit 또는 4/12/24h 승인 기억.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| bounded probe | `nix develop --command timeout 20s ssh -o BatchMode=yes -o ConnectTimeout=10 minipc true` | success=0 또는 bounded failure=124/255; 20초 내 복귀 |
| effective config | `ssh -G minipc | rg '^(hostname|identityagent|identityfile|controlmaster|controlpersist) '` | 현행 1Password route 확인 |
| 전체 게이트 | `bash tests/run-all-tests.sh` | FAILED 0 |
| AI 호환 게이트 | `./scripts/ai/verify-ai-compat.sh` | FAIL 0 |
| 실배포 | `nrs` | activation 성공 |

## Suggested executor toolkit

- `finding-unknowns`: A/B/C/E matrix와 운영자 결정 게이트.
- `managing-ssh`, `managing-secrets`: agent/key/vault 경계와 emergency fallback 유지.
- `configuring-codex`, `managing-claude-rc`: 두 headless launcher에 동일 정책 배선.

## Scope

**In scope**:

- A: 1Password “Approve for all applications” + 긴 승인 기억 기간
- B: Claude/ChatGPT per-app 장기 승인
- C: `minipc-headless` 전용 자동화 key/alias (`IdentityAgent none`)
- D: 모든 headless minipc SSH의 outer deadline + 명확한 진단
- E: ControlMaster 재사용은 보조 최적화로만 평가
- fake delayed SSH fixture와 launcher matrix 테스트

**Out of scope**:

- 기존 `minipc-emergency` key를 원격 자동화에 자동 사용
- 1Password vault private key export 또는 secret 값 출력
- 일반 `op`/`op_get` biometric 정책 (#1041 인접 이슈)
- GitHub HTTPS auth/gh-pat-mac (이미 SA 기반 무인 경로)
- “모든 앱 승인”을 보안 이유만으로 사전 기각하는 것 — 운영자 결정 대상

## Git workflow

- Branch: `fix/headless-ssh-dx-policy`
- Conventional commit 예: `fix(ssh): headless 1Password 승인 대기 제한`
- Option C 선택 시 key material은 절대 Git에 추가하지 않고 agenix recipient/배포 코드만 커밋한다.
- push/PR은 운영자 지시 후 수행한다.

## Steps

### Step 1: 현재 hang을 bounded probe로 특성화한다

운영자가 Mac 앞에 있을 때, 1Password approval을 초기화하지 말고 현재 lock/unlock 상태를
기록한다. 반드시 outer `timeout`이 있는 probe만 실행한다. Claude Remote Control과 Codex App
각각에서 아래 결과를 기록한다.

- exit code와 elapsed time
- 1Password prompt가 표시/억제되었는지
- menu bar의 “SSH request waiting” 여부
- active ControlMaster 유무

**Verify**: 두 launcher 모두 20초 안에 성공 또는 bounded failure. unbounded raw SSH 실행 금지.

### Step 2: Option A/B의 1Password 승인 matrix를 실증한다

운영자 확인 후 1Password prompt에서 다음을 각각 시험한다.

1. A: `Approve for all applications` + 운영자가 허용하는 가장 긴 기억 기간.
2. B: Claude/ChatGPT per-app + 동일 기억 기간.

각 옵션을 unlocked, locked, 1Password quit/restart, Mac reboot, launcher restart 상태에서 probe한다.
앱 lock 상태에서 approval은 기억돼도 private key unlock이 다시 필요한지 별도 기록한다.

**Verify**: 각 cell에 success/failure, prompt 여부, elapsed time이 있다. “가끔 성공”은 통과 아님.

### Step 3: A/B가 완전 무인을 못 만들면 Option C를 설계한다

Option C는 구현 전 아래 결정을 운영자에게 제시하고 승인을 받는다.

- 전용 key 이름/용도: `minipc-headless` 한정
- private storage: Mac user key로 암호화된 agenix secret 또는 동등한 최소 노출 경로
- server restriction: dedicated authorized_keys entry, Tailscale source 제한, 가능한 command/feature 제한
- rotation/revoke 및 Mac 분실 시 폐기 절차
- 기존 `mac-ssh`/`minipc-emergency`와 혼용 금지

**Verify**: decision record에 storage, recipient, server restriction, rotation, revoke 5항목 모두 있음.

### Step 4: 운영자 결정 게이트를 통과한다

A/B/C의 성공률과 보안 범위를 한 표로 보여주고 기본 인증안을 선택받는다. E(ControlMaster)는
보조 최적화 여부만 결정한다. D(outer deadline)는 선택과 무관하게 항상 채택한다.

**Verify**: issue #1094 또는 세션에 A/B/C 선택과 D 필수 채택이 명시됨.

### Step 5: 공통 headless SSH deadline을 구현한다

launcher별 raw SSH가 실제로 안전 경로를 거치는 binding을 먼저 증명한다. 단순 zsh 함수는
Claude Bash/Codex app-server에 적용되지 않으므로 해결책으로 인정하지 않는다.

권장 구현 shape:

- inject 가능한 real SSH path와 timeout 값을 가진 `ssh-headless` wrapper
- `minipc`/headless 호출에 outer coreutils `timeout`
- exit 124일 때 “1Password SSH approval 또는 unlock 대기 가능성” 진단
- interactive Ghostty `ssh()`와 일반 장기 SSH는 기존 동작 유지

wrapper 사용이 LLM 지시문에만 의존하면 STOP하고, Claude/Codex launcher PATH 또는 동등한
runtime binding으로 실제 child process가 wrapper를 실행함을 증명한다.

**Verify**: fake SSH가 deadline보다 오래 sleep해도 wrapper가 제한시간+여유 2초 안에 exit 124.

### Step 6: 선택한 A/B/C 인증안을 구현한다

- A/B: 1Password UI 운영 절차, 기억 기간, lock/quit/reboot 한계를 managing-ssh에 기록한다.
- C: dedicated host alias/key 배포/server restriction을 구현한다. emergency key 자동 fallback 금지.
- E 채택: ControlMaster는 최적화일 뿐, master 부재 시에도 A/B/C+D 계약이 유지되어야 한다.

**Verify**: `ssh -G`가 선택 route를 정확히 보여주고 private key 값은 출력되지 않음.

### Step 7: 회귀 테스트와 실배포 E2E를 수행한다

테스트 fixture는 실제 1Password를 호출하지 않는다. wrapper가 실행할 SSH binary를 env로
주입할 수 있게 하고, fake binary가 deadline보다 오래 sleep하는 케이스와 즉시 0/255를 반환하는
케이스를 만든다. 실제 런타임에서는 `nrs` 후 Claude/Codex 새 세션에서 probe한다.

**Verify**: 전체 tests/verify gate 통과 + 두 launcher에서 success/failure 모두 bounded.

## Test plan

- Unit/shell fixture:
  - fake SSH success → wrapper exit 0과 stdout/stderr 보존
  - fake SSH immediate 255 → exit 255 보존
  - fake SSH sleep → deadline 내 exit 124 + 1Password 진단
  - interactive bypass → 기존 raw SSH 동작 보존
- Config:
  - `ssh -G minipc`, `ssh -G minipc-emergency`, Option C면 `ssh -G minipc-headless`
- Runtime matrix:
  - Claude/Codex × unlocked/locked/restart/reboot × ControlMaster yes/no
- Full gate: `bash tests/run-all-tests.sh`, `./scripts/ai/verify-ai-compat.sh`, `nrs`.

## Done criteria

- [ ] A/B matrix 완료
- [ ] 필요 시 C의 5항목 security decision 완료
- [ ] 운영자의 A/B/C 선택 기록
- [ ] D outer deadline이 두 launcher 실제 child SSH에 적용됨
- [ ] fake delayed SSH가 제한시간 내 exit 124
- [ ] 대화형 Ghostty SSH와 emergency fallback 회귀 없음
- [ ] private key/secret 값 로그·diff 노출 0건
- [ ] 전체 tests 및 verify gate 통과
- [ ] `nrs` 후 Claude/Codex 원격 무한 대기 0건
- [ ] `plans/README.md` 029 행 갱신

## STOP conditions

- 1Password UI 선택을 운영자 확인 없이 변경해야 함.
- A/B가 lock/reboot 후 실패하지만 운영자 선택 없이 C를 자동 도입하려 함.
- C가 기존 emergency key 재사용 또는 unrestricted general-purpose key를 요구함.
- runtime binding을 증명하지 못하고 지시문/alias만으로 raw SSH를 막으려 함.
- fake test가 실제 1Password agent/private key를 요구함.
- GitHub/일반 SSH 장기 작업까지 고정 짧은 timeout으로 잘라야 함 — host/launcher scope 재설계 필요.

## Maintenance notes

- 1Password approval duration이나 launcher identity가 바뀌면 matrix를 재실행한다.
- Option A는 현재 OS user/agent session 범위의 임시 승인이지 영구 무인 인증이 아니다.
- Option C key는 mac-ssh 및 emergency key와 별도 rotate/revoke한다.
- outer deadline은 인증 정책과 독립된 불변식으로 유지한다.
