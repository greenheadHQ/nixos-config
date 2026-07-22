# Plan 028: 원격 AI 세션의 macOS TCC 정책

> 이 문서는 공개 저장소에 보존되는 정책·재현 계약이다. 개인 Mac의 PID, exact 시각, Nix store
> hash, signing hash, Team ID, 현재 MDM/Keychain 상태와 원시 TCC 로그는 기록하지 않는다.

## Status

- **State**: IN PROGRESS — implementation/runtime complete; post-rebase DA fixes 재검증 중. 완료 조건: #1177/#1178/#1179 3개 분할 PR이 모두 머지되고 재검증 matrix가 통과하면 DONE으로 전환한다.
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1093
- **PRs**: #1177 (TCC 정책 본체) / #1178 (Shottr activation) / #1179 (claude-rc lifecycle) — #1133에서 분할
- **Policy owner**: operator
- **Remote policy**: C — Claude의 persistent additional directory는 `~/Workspace`만 유지
- **Direct terminal policy**: D — Ghostty Full Disk Access 유지
- **Base**: `main`

## Goal and boundaries

휴대폰에서 사용하는 Claude Code/Codex 원격 세션이 macOS TCC GUI 응답을 기다리며 멈추지
않게 한다. 우선순위는 다음과 같다.

1. Mac 앞에 없어도 원격 작업이 계속되는 DX
2. 앱 업데이트와 재부팅 뒤 지속성
3. 책임 앱과 권한 범위의 예측 가능성
4. 같은 DX라면 더 좁은 권한

TCC DB 직접 수정, broad `tccutil reset`, SIP 비활성화와 실제 private data read는 금지한다.
권한 변경, 앱 종료·재실행, `nrs`, reboot는 각각 action-time confirmation 뒤에만 수행한다.
모든 보호 폴더 probe는 고정 문자열 fixture 하나와 outer deadline을 사용한다.

## Confirmed problem

- 원격 launcher의 보호 폴더 read가 TCC prompt를 만들면 GUI 응답 전까지 caller가 오래 대기할
  수 있다.
- `nrs` 중 Shottr의 sandbox container preference read도 ChatGPT/Codex app identity에
  `SystemPolicyAppData` prompt를 귀속시킬 수 있었다.
- Claude Remote Control과 Codex App은 responsible identity가 다르다. 한 launcher의 성공을
  다른 launcher의 성공으로 계산할 수 없다.
- Ghostty의 권한은 Ghostty direct child에만 적용되며 launchd Claude 또는 Codex App child로
  승계되지 않는다.

## Attribution contract

| Launcher | Responsible code class | Accessing client class | Relevant TCC service | Stable identity assessment |
|---|---|---|---|---|
| Claude Remote Control | Nix-managed launch shell and declared bridge | actual bridge tool child | `SystemPolicyDesktopFolder`, fallback `SystemPolicyAllFiles` | Nix updates can change executable identity; durable manual grant candidate가 아님 |
| Codex App remote | signed ChatGPT app bundle (`com.openai.codex`) | bundled app-server/tool child | protected-folder services and investigation-only `SystemPolicyAppData` | bundle identity는 stable 후보지만 user consent가 restart 뒤 다시 필요할 수 있음 |
| Ghostty direct | signed Ghostty bundle (`com.mitchellh.ghostty`) | direct shell child | `SystemPolicyAllFiles` | direct terminal에 한해 stable 후보 |

`SystemPolicyAppData`는 원래 Claude protected-folder hang과 별개인 Shottr activation 경로다.
두 사건의 evidence와 성공 판정을 섞지 않는다.

## Options and ADR

| Option | Decision | Rationale | Rollback |
|---|---|---|---|
| A. responsible identity에 targeted Files & Folders/App Data | ❌ | 초기에는 A+D를 선택했지만 두 remote launcher에서 restart/update-safe하게 사전 부여되는 동일 계약을 만들지 못했다. Codex targeted consent 재등장도 관측했다. | 선택 service+bundle consent만 표적 제거 |
| B. responsible app/binary에 Full Disk Access | ❌ | 권한 폭만으로 기각하지 않았다. ChatGPT bundle과 달리 Claude 쪽 durable responsible identity를 두-launcher matrix에 고정할 수 없고, `bypassPermissions`와 결합 범위도 크다. | System Settings에서 exact app entry 제거 후 matrix 재검증 |
| C. `~/Workspace` persistent, protected folders opt-in | ✅ | 보호 폴더를 자동 traversal surface에서 빼고 remote 기본 경로를 prompt-free로 만든다. 필요할 때만 `/add-dir` 또는 `--add-dir`를 사용한다. | 필요한 폴더를 explicit opt-in; 정책 변경 시 A/B를 다시 실증 |
| D. Ghostty Full Disk Access | ✅ 보조 | direct terminal의 중단 없는 DX를 제공한다. remote launcher 성공 증거에는 포함하지 않는다. | System Settings에서 Ghostty entry 제거 후 direct matrix 재검증 |
| Managed PPPC + MDM | ❌ 이번 issue | Apple이 지원하는 선언적 후보이며 금지된 접근이 아니다. 다만 MDM enrollment, service, profile lifecycle이라는 새 trust/운영 경계를 함께 도입하므로 이번 선택에 포함하지 않는다. | MDM acknowledgment와 profile removal을 별도 runbook으로 검증 |

## CIR

### Context

과거 commit `d8b09f3e35c345cdd3f3203981a9327ae86c3730`은 기존
Downloads/Documents/Workspace persistent roots를 유지하면서 Desktop을 추가하고,
`/add-dir`/`--add-dir` root의 `CLAUDE.md` 자동 로드를 도입해 로컬 편의를 높였다. 휴대폰 원격
운영에서는 persistent protected roots가 TCC prompt를 implicit하게 유발해 같은 설정의 비용이
달라졌다. 자동 로드 flag는 protected roots를 session opt-in하는 대체 DX로 유지한다.

### Intervention

- A/B/C/D를 권한 폭만으로 걸러내지 않고 launcher별 responsible/accessing identity와 service를
  분리해 bounded fixture로 검증했다.
- 운영자는 처음 A+D를 선택했으나 targeted consent의 재등장과 Shottr AppData attribution을
  확인한 뒤 최종 C+D로 전환했다.
- PPPC/MDM은 운영자가 금지한 것이 아니라는 정정을 반영했다. 지원되는 future policy-as-code
  경로로 남기되 이번 issue에서는 선택하지 않았다.
- 선택하지 않은 ChatGPT/Claude folder/FDA 시험 grant는 표적 cleanup한다. remembered Deny는
  grant가 아니며, 의도적으로 남는 권한은 D의 Ghostty FDA뿐이다.

### Result

- Claude persistent `additionalDirectories`는 `~/Workspace` 하나다.
- protected folder는 `/add-dir` 또는 `--add-dir`로 session마다 명시적으로 선택한다.
- repo read는 actual launcher lineage에서 성공해야 하고, protected fixture는 C 정책상 즉시 deny
  또는 bounded 종료해야 한다. prompt를 승인해 read가 성공한 cell은 C 성공으로 계산하지 않는다.
- Shottr activation은 AppData 요청이 발생해도 GNU `timeout`과 circuit breaker로 다음 write를
  건너뛰고 전체 `nrs`를 계속한다.
- Shottr license/vault 값은 native CFPreferences writer의 stdin으로만 전달하며 process argv,
  child environment와 warning log에 포함하지 않는다.
- Claude bridge lifecycle은 실제 PID, executable, cwd, exact argv, trusted flock parent와 lock
  ownership을 함께 검증한다. launcher deadline 실패 뒤 같은 process group의 지연 child가 살아남지 않으며, status
  write 실패는 성공으로 숨기지 않는다. 다른 process가 startup race에서 lock을 먼저 잡아도 그
  상태를 자기 launcher 성공으로 넘기지 않는다. identity를 확인할 수 없는 자기 replacement는
  exact guardian→group-leader ownership, stable PGID와 bounded cleanup으로 정리하고 lock-free
  postcondition까지 확인된 경우에만 `stopped`를 남긴다. descendant가 의도적으로 다른 process
  group/session으로 벗어나 lock을 유지하거나 successor가 lock을 잡아 cleanup을 입증하지 못하면
  `unknown`으로 보존한다.
- bridge candidate는 exact `remote-control`/`rc` token으로 찾되 self-updating CLI의 global-option
  문법을 복제하지 않는다. 명시적 prompt/argument boundary 뒤 token은 제외하고, 나머지 모호한
  same-cwd/versioned candidate는 signal하지 않은 채 두 번째 서버 시작만 차단한다. maint launcher는
  실행 전에 canonical `VERSIONS_DIR` 경계를 검증하고 symlink 대신 검증된 target을 실행한다.
- 수동 TCC state는 Nix가 선언적으로 보장한다고 주장하지 않는다.

### Decision-regression guard

C를 되돌리려면 다음 중 하나를 실제 두-launcher matrix로 먼저 입증해야 한다.

- targeted consent가 restart와 update 뒤 prompt 없이 유지됨
- durable responsible identity에 FDA가 두 launcher 모두 적용됨
- managed PPPC/MDM이 실제 acknowledgment, rollback, update 재검증까지 운영됨

## Implementation

### Remote policy and runbooks

- `modules/shared/programs/claude/files/settings.json`
  - persistent `additionalDirectories = ["~/Workspace"]`
- `.claude/skills/managing-claude-rc/SKILL.md`
  - protected folder opt-in과 remote evidence 기준
- `.claude/skills/managing-macos/references/tcc.md`
  - launcher attribution, bounded log query, apply/rollback/update 절차
- `.claude/skills/managing-macos/SKILL.md`
  - C+D 운영 surface

### Claude lifecycle

- `modules/darwin/programs/claude-remote-control.nix`
  - declared launcher의 주기적 recovery
- `modules/nixos/scripts/claude-rc-lib.sh`
- `modules/nixos/scripts/claude-rc.sh`
- `modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh`
- `modules/nixos/scripts/claude-rc-pid-argv.c`
- `modules/nixos/scripts/claude-rc-launch-group.c`
- `modules/nixos/lib/claude-rc-launch-group-package.nix`
- `modules/nixos/lib/claude-rc-package.nix`
- `modules/nixos/lib/claude-rc-maint-package.nix`
  - exact process identity, lock lineage, stable process-group supervision, callback/result propagation과
    delayed-launch cancellation
- `flake.nix`, `scripts/ai/test-runtime-profile.sh`, `scripts/ai/lib/tomlkit-bootstrap.sh`
  - devShell, pre-push profile, fallback과 production이 같은 플랫폼별 pinned `flock` 구현을 제공·검증
  - profile fingerprint와 staged-snapshot 비교는 한 runtime-input 목록을 공유하고, wrapper closure/PATH
    fixture는 current platform selector의 exact `flock` output을 고정한다

### Shottr activation safety

- `scripts/secrets/age-encrypt-atomic.sh`
  - stdin age 입력을 same-directory temporary output에 성공시킨 뒤 atomic replace
- `modules/darwin/programs/shottr/default.nix`
- `modules/darwin/programs/shottr/defaults-helper.sh`
- `modules/darwin/programs/shottr/cfpreferences-writer.c`
- `modules/darwin/programs/shottr/cfpreferences-writer-package.nix`
  - bounded read/write, per-activation breaker, secret stdin boundary
- `.claude/skills/managing-macos/references/shottr-credentials.md`
- `.claude/skills/managing-secrets/SKILL.md`
  - xtrace/argv/child environment 값 비공개, deadline, action-time confirmation 계약

### Tests

- `tests/lib/claude-remote-control-fixtures.sh`
- `tests/suites/claude-remote-control-wrapper.sh`
- `tests/suites/claude-remote-control-guardian.sh`
- `tests/suites/claude-remote-control-maint.sh`
- `tests/suites/shottr-defaults.sh`
- `tests/shell-script-tests.sh`
- `tests/eval-tests.nix`
- `tests/run-all-tests.sh`
  - 기계적으로 보장 가능한 config, identity, deadline, argv, guardian/process-group cleanup, hermetic runtime과
    failure-propagation 불변식만 검증
  - production wrapper closure/PATH에서 exact PID argv helper와 platform-selected `flock`을 고정하고,
    `nrs` 직후 previous-generation `flock` parent도 managed lineage로 유지한다
  - official `remote-control`/`rc` exact token과 joined/split global-option candidate를 차단하면서
    explicit prompt boundary와 substring decoy는 제외하는 argv fixture를 고정한다
  - Darwin-only CFPreferences round-trip은 다른 runner에서 묵시적으로 PASS하지 않고 canonical `N/A`로
    표시하며, Darwin host PASS는 아래 실제 host 검증 증거와 함께 요구한다

## Verification contract

### Automated

```bash
jq empty modules/shared/programs/claude/files/settings.json
shellcheck modules/nixos/scripts/claude-rc-lib.sh \
  modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh \
  modules/darwin/programs/shottr/defaults-helper.sh
./tests/run-eval-tests.sh
./tests/run-shell-script-tests.sh
./scripts/ai/verify-ai-compat.sh
CI=1 nix develop --command bash tests/run-all-tests.sh
git diff --check
```

Native Shottr writer는 Darwin에서 빌드하고 temporary preferences basename에만 round-trip한다.
실제 Shottr license 값, 다른 앱 container 또는 private data는 테스트하지 않는다.

### Exclusive host phase

다른 Goal의 `nrs`/GUI/E2E window가 끝나고 lock이 free인 것을 확인한 뒤, 하나의 operator window로
다음을 수행한다.

1. action-time confirmation
2. `NRS_ALLOW_WORKTREE_RELINK=1 nrs`
3. shared skill 변경 후 `./scripts/ai/verify-ai-compat.sh`
4. actual Claude Remote Control child와 actual Codex App child에서 repo/protected fixture matrix
5. 필요한 launcher restart는 별도 confirmation 뒤 반복
6. Ghostty direct child는 D 보조 matrix로 별도 기록
7. fixture와 임시 process cleanup, 선택하지 않은 grant 0건 확인

| Cell | Repo | Protected fixture under C | Prompt budget |
|---|---|---|---|
| Claude Remote Control actual child | exit 0 within deadline | immediate deny or bounded nonzero | 0 new prompt |
| Codex App actual child | exit 0 within deadline | immediate deny or bounded nonzero | 0 new prompt after remembered deny |
| Ghostty direct child | exit 0 within deadline | exit 0 within deadline | 0 new prompt |

로컬 `claude -p`, 일반 shell 또는 Codex Desktop 내부 shell만으로 actual launcher 증거를 대체하지
않는다. D 결과는 Claude/Codex remote 성공 합계에 넣지 않는다.

latest `main` rebase와 승인된 `nrs` 뒤 실제 launcher lineage에서 다음 aggregate를 다시 확인했다.
exact 시각, PID, executable/store path와 원시 로그는 공개 plan에 보존하지 않는다.

| Cell | Repo | Desktop fixture | Elapsed | New prompt | TCC observation |
|---|---:|---:|---:|---:|---|
| Claude Remote Control actual child | 0 | 2 | deadline 내 | 0 | remembered deny가 즉시 반환됐고 exact probe window에 새 auth request 없음 |
| Codex App actual bundled child | 0 | 2 | deadline 내 | 0 | `SystemPolicyDesktopFolder`/`SystemPolicyAllFiles`, remembered deny |
| Ghostty direct child | 0 | 0 | deadline 내 | 0 | Desktop request 없음; 기존 FDA로 direct child 성공 |

Claude bridge와 ChatGPT App을 각각 정상 재시작한 뒤 actual child를 새로 확인하고 remote 두 행을
반복했다. 두 launcher 모두 repo 성공과 protected fixture의 bounded deny가 유지됐고 새 prompt는
없었다. 재시작 전 웹에 남아 있던 Claude worktree 세션은 예상대로 tombstone 상태를 명시적으로
반환했으며, 재기동된 declared environment에서 만든 새 Remote Control 세션만 성공 증거로
계산했다. tombstone을 TCC hang 또는 launcher 성공으로 오인하지 않는다.

Ghostty direct 행은 앱 재시작과 두 차례 reboot 뒤에도 같은 prompt-free matrix를 유지했다. 이는
보조 D의 direct-terminal 지속성만 입증하며 Claude/Codex remote 성공으로 계산하지 않는다.

App Data consent를 표적 reset한 상태에서 forced activation을 반복하자 first-use prompt가 다시
발생했지만, helper가 deadline 뒤 Shottr preference write만 건너뛰고 전체 `nrs`는 성공했다. prompt
요청 process가 끝난 뒤 저장된 consent는 같은 service/bundle만 다시 reset해 Delete event를
확인했으며, prompt를 다시 만들 수 있는 probe는 반복하지 않았다.

DA에서 확인한 argv classifier와 helper invocation 수정 뒤 worktree generation을 다시 배포했고
runtime compatibility 검증이 완전 통과했다. 새 local Remote Control 세션의 actual managed bridge
lineage에서 bounded repo read는 exit 0으로 즉시 끝났고 새 TCC prompt는 0건이었다. 이 smoke가 만든
session, SDK child와 결과 파일은 모두 정리했다. protected-path 정책은 바뀌지 않았으므로 위의
repo/protected/restart matrix를 그대로 유지한다.

후속 DA는 prompt decoy 방어가 공식 `rc` alias와 command 앞 global option까지 함께 제외하는 회귀를
확인했다. 첫 수정은 positional parser로 두 공식 subcommand와 global option을 구분했지만, latest-main
재검토에서 joined option 누락과 self-updating CLI 문법 복제 자체가 다시 확인됐다. 최종 구현은 exact
command token과 explicit prompt boundary만 사용한다. 모호한 same-cwd/versioned candidate는 lifecycle
signal 대상이 아니라 duplicate start 차단 대상으로만 취급한다. split/joined option, alias, prompt와
substring decoy를 각각 behavior fixture로 고정했다.

최종 정적 검토에서 macOS 1분 ensure가 live version drift까지 자동 재시작하면 위의 action-time
경계와 충돌함을 확인했다. Darwin periodic policy를 liveness-only로 분리해 죽은 bridge는 계속 1분
안에 자동 복구하되 live drift는 `deferred-restart-confirmation`으로 보존한다. 운영자가 확인한
exact `(path,runningVersion,desiredVersion)` JSON을 `confirmed` policy에 전달한 한 번의 ensure만
재시작을 수행하며, NixOS의 기존 unattended `automatic` 정책은 유지한다. optional debug filter와
background-agent prompt처럼 bridge 여부가
모호한 process는 새 시작을 보수적으로 막지만 signal하지 않으며, explicit print/argument boundary와
`--sdk-url` option terminator는 session/prompt exclusion fixture로 고정했다. 수동 `confirmed` 실행 전
`defer` snapshot의 전체 drift 후보와 `claude-rc ls`를 제시하고, lifecycle lock 안에서 approval JSON과
현재 tuple 집합을 다시 exact compare한다. mismatch·malformed·empty approval은 restart 전에
fail-closed하며, one-shot policy/approval env는 새 bridge로 전파하지 않는다. snapshot은 ensure exit 0과
status `action=completed`/`exitCode=0`을 검증한다. Darwin `defer`와 NixOS `automatic` 배선은 각각
eval로 검증한다.

이 후속 수정도 worktree generation으로 배포했고 runtime compatibility 검증이 통과했다. bounded
`claude-rc ls`는 기존 등록/선언 bridge를 모두 healthy로 판정했다. 보호 폴더 정책, TCC state와 실제
remote command 경로는 바뀌지 않아 추가 prompt probe나 launcher restart는 수행하지 않았다.

liveness-only drift 정책까지 반영한 최종 worktree generation도 배포했다. launchd의 deployed
environment는 `defer`, stable `claude-rc-maint` home symlink는 executable로 확인했고 runtime
compatibility 검증이 통과했다. bounded `claude-rc ls`와 maint status는 등록된 두 bridge를 모두
running/healthy로 보고했다. 이 단계 역시 앱 재시작, TCC mutation, 보호 폴더 probe 없이 끝냈다.

latest `main` 재베이스 뒤 `$run-da for_pr`는 stable maintenance symlink를 bare로 실행할 때 shared
default `automatic`이 action-time confirmation 경계를 우회할 수 있음을 확인했다. shared default를
fail-closed `defer`로 바꾸고, NixOS service만 unattended `automatic`, 운영자 확인 뒤 실행하는 명령은
exact snapshot을 요구하는 `confirmed`를 명시한다.
같은 라운드에서 Markdown·shell source의 exact 문자열·공백·출현 횟수를 성공 증거로 삼던 eval을
제거했다. eval은 evaluated attr와 platform selector만 검사하고, 실행 동작은 tracked helper의
behavior fixture가 검증한다.

다음 전체 DA 라운드는 maint launcher가 version 경계를 검증하기 전에 실행될 수 있는 문제, Shottr
secret refresh의 실행 SoT가 Markdown heredoc이던 문제, production status와 운영 표의 parity drift를
확인했다. maint는 canonical launcher를 pre-exec 검증하고, Shottr refresh는 tracked executable로
이동했으며, production action 전부가 운영 표에 존재하는지 fixture가 확인한다.

후속 read-only 검토는 top-level status action과 instance action의 문서 경계가 섞여 있던 문제,
공백을 포함할 수 있는 Shottr timeout executable 호출 경계, 비대해진 Remote Control fixture의 변경
격리 문제를 확인했다. top-level과 instance action은 각각 production vocabulary·운영 표 parity를
검증하고, timeout executable은 quoted path fixture로 고정했다. Remote Control fixture는 공통 harness와
wrapper·guardian·maint/status suite로 분리하되 기존 test function 68개가 모두 discovery되는 것을 전체
shell suite로 검증한다.

다음 frozen changeset의 FULL DA는 one-shot restart policy가 장기 bridge에 상속되는 문제, 게시 실패
뒤에만 정해져 `status.json`에 기록할 수 없는 diagnostic을 top-level status 값으로 문서화한 문제,
lifecycle lock file open 실패가 internal `none` action으로 게시되는 문제를 확인했다. confirmed restart는
locked runtime tuple 집합과 exact match하는 non-empty approval만 허용하고 policy/approval env를 bridge
exec 전에 제거한다. status publication failure는 exit·stderr·alert 전용 diagnostic으로 분리하고,
lock parent/open 실패는 canonical `lock-setup-failed` status와 behavior fixture로 보존한다.

최신 `main` 재베이스 뒤 fresh FULL 검토는 유지보수 suite 소유권을 포함한 low-severity 제안 3건을
확인했다. 운영자는 그중 suite 소유권만 반영하고 추가 검토를 중단하도록 결정했다. wrapper suite의
maint-only fixture 6개를 등록과 동작을 바꾸지 않고 maint suite로 옮겼고, shell fixture 275개와 전체
suite 10개 그룹이 다시 통과했다. 나머지 2건은 반영하지 않았으며 post-fix CLEAR를 주장하지 않는다.
이 운영자 결정은 최종 review 상태의 일부로 보존한다.

최종 readback과 cleanup은 선택 정책의 권한만 남기고 기존의 무관한 TCC 결정을 변경하지 않는
범위로 완료했다. remembered deny는 grant로 세지 않으며 선택하지 않은 시험 grant는 0건이다.

### Update-time revalidation

다음이 바뀌면 attribution table과 영향받는 matrix를 다시 실행한다.

- Claude, ChatGPT/Codex 또는 Ghostty app/CLI
- Nix bash 또는 launcher package
- macOS major version이나 TCC/PPPC schema
- MDM/profile 도입 또는 제거
- `additionalDirectories`, Shottr activation, launcher lifecycle 로직

## Completion checklist

- [x] 운영자 최종 선택 C+D 기록
- [x] A/B/C/D와 managed PPPC 판단 기록
- [x] 자동 config/lifecycle/Shottr safety 구현과 focused fixture
- [x] latest `main` rebase 뒤 전체 automated suite
- [x] action-time 승인된 `nrs`, verify-ai-compat, actual launcher E2E
- [x] 선택하지 않은 시험 grant 0건과 fixture/process cleanup
- [x] `$run-da for_pr` 실행과 운영자 선택 finding 반영 (추가 검토 중단, post-fix CLEAR 미주장)
- [x] single reviewed changeset push와 PR 공개 정보 재감사
- [x] `$create-pr` update 뒤 base/head, 7개 섹션, `Closes #1093`, 공개 정보 readback

## STOP conditions

- responsible identity가 재시작/update 전후 바뀌어 선택 정책을 입증할 수 없음
- Claude/Codex 중 한 launcher만 완료됨
- 실제 private data가 있어야만 테스트 가능함
- probe에 outer deadline을 적용할 수 없음
- action-time confirmation 없이 권한 변경, 앱 재시작, `nrs` 또는 reboot가 필요함
- automated test 또는 host E2E 실패, 혹은 명시적 운영자 결정 없는 review nonconvergence

STOP 시 worktree를 보존하고 완료 단계, blocker, 재개 지점을 보고한다. PR을 성공으로 과장하지
않고 merge하지 않는다.

## References

- [Apple PPPC payload](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol)
- [Apple PPPC services](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary)
- [Apple Device Enrollment](https://support.apple.com/guide/deployment/depd1c27dfe6/web)
- [Apple file access controls](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web)
- [Claude working directories](https://code.claude.com/docs/en/permissions#working-directories)
- [Claude bypassPermissions mode](https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode)
