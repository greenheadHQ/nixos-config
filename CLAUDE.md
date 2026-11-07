# nixos-config

macOS와 NixOS 개발 환경을 nix-darwin/NixOS + Home Manager로 선언적 관리하는 프로젝트

## 실행 환경

Environment 섹션의 `Platform` 값으로 현재 환경을 판별한다.

| Platform | 현재 환경 | 다른 머신 접속 |
|----------|----------|---------------|
| `darwin` | Mac | `ssh minipc` |
| `linux` | MiniPC (NixOS) | `ssh mac` |

**현재 환경에 SSH 접속 금지.** Platform: darwin이면 `ssh mac` 금지, linux이면 `ssh minipc` 금지.
현재 NixOS 호스트는 MiniPC 1대뿐이므로 `linux` = MiniPC. 호스트 추가 시 `hostname`으로 구분.

## 빌드

`nrs`를 사용. `darwin-rebuild`/`nixos-rebuild` 직접 실행 금지. `nrs`는 preview를 포함하며, macOS에서는 launchd 정리와 Hammerspoon 재시작도 처리한다. 워크트리에서 `nrs` 완료 시 `$HOME` 아래 out-of-store symlink의 워크트리 relink을 시도한다 (`nrs-relink`, non-fatal). 비TTY/에이전트 컨텍스트에서는 이 worktree relink만 스킵하며, 필요 시 `NRS_ALLOW_WORKTREE_RELINK=1`로 opt-in한다. main repo에서 `nrs` 실행 시 nix store 체인으로 복원을 시도한다.

비대화형(에이전트) 컨텍스트에서 `nrs`는 sudo 캐시가 필요 없다 — macOS는 `modules/darwin/configuration.nix`의 `security.sudo.extraConfig`가 선언한 전면 NOPASSWD 규칙(`ALL=(ALL) NOPASSWD: ALL`, `tests/eval-tests.nix`가 고정)이, NixOS는 `wheelNeedsPassword=false`가 인증을 면제한다. **`sudo -n true`로 실행 가능 여부를 사전 확인하지 마라**: `nrs` 실행 가능성은 `nrs`가 sudo로 부르는 재빌드 명령에 매칭되는 규칙으로 판단한다. `true`의 결과는 `true`에 매칭되는 규칙이 정하므로, 두 명령의 규칙이 다른 정책에서는 `nrs`와 결과가 어긋나는 잘못된 프록시다 (2026-07 darwin-rebuild 내부 정지를 sudo 프롬프트 hang으로 오진한 뒤, 당시 재빌드 한정 규칙 밖이라 실패하던 `true`를 근거로 불필요한 사용자 위임이 반복됐다). 선언은 적용 상태의 증거가 아니다 — 적용된 규칙은 `sudo -n -ll /run/current-system/sw/bin/darwin-rebuild switch` 출력에 `Options: !authenticate`가 있는지로 확인하고, 진단 기록에는 이 조회 결과와 실제 실행 결과를 구분해 적는다. rc 기반 판정(`sudo -n -l <cmd>`)은 admin `(ALL) ALL` 규칙 때문에 인증이 필요한 명령에도 rc 0을 주므로, 목록 조회 성공을 무인증 실행 가능의 증거로 쓰지 않는다. 비TTY에서 `nrs`는 sudo를 `-n`으로 호출하므로 규칙이 깨져도 hang 없이 즉시 실패하고 원인을 안내한다.

home-manager activation 충돌 정책: macOS에서 mkOutOfStoreSymlink target이 외부 프로세스의 atomic rename으로 일반 파일이 되면 `home-manager.backupCommand`가 자가 치유한다 (regular file은 unlink + 콘솔 한 줄 echo, directory는 timestamped backup). 사이드이펙트로, symlink가 깨진 시간 동안 사용자가 home 쪽에서 의도 변경한 내용도 silent 손실될 수 있다 (예: VSCode UI에서 keybinding 추가 후 settings.json이 깨진 상태에서 한 후속 변경). 정상 symlink 흐름에서는 source 직접 수정 = git 추적이 정상 동작한다. 본 정책은 사용자 명시 동의 범위 내. 정책 본체는 `modules/darwin/home.nix`.

## Git worktree

일반 Git 명령으로 작업을 분리한다. 생성 전 기본 브랜치·현재 HEAD·dirty/untracked 상태와 `git worktree list --porcelain`의 등록 경로·브랜치·잠금을 확인한다. 기존 worktree·브랜치·trust·백업은 보존한다.

```bash
# 원격 기본 브랜치와 작업 이름을 확인한 뒤 예시 값을 정한다.
git worktree add -b feat/example ../nixos-config-example origin/main
git worktree list --porcelain
```

자동화에서 경로 목록은 `git worktree list --porcelain -z`로 읽는다. 조회의 종료코드가 성공인지 먼저 확인하고 NUL 레코드를 파싱한다. 출력 일부나 조회 실패를 빈 목록으로 취급하지 않는다. 대상 경로는 변수에 담아 항상 인용한다.

정리는 대상 밖에서 다음 조건을 **제거 직전 다시** 확인한 뒤 `git worktree remove "$target"`으로 한다.

- Git 등록·실제 물리 경로·저장소 동일성·HEAD가 확인한 대상과 일치하고 잠겨 있지 않아야 한다.
- dirty/untracked 파일과 진행 중인 Git 작업이 없어야 한다. ignored 파일도 별도로 확인하고, 보존 필요 여부를 확인하지 못한 파일이 있으면 worktree를 남긴다. 미보존 커밋은 남긴다. detached HEAD는 다른 보존 ref가 있는지 확인한다.
- squash merge는 upstream 부재만으로 판단하지 않는다. 머지된 PR의 head와 현재 HEAD가 같다는 근거를 확인하고, 조회 실패나 이후 커밋이 있으면 보존한다.
- 대상과 하위 경로를 cwd로 사용하는 프로세스·활성 세션뿐 아니라, cwd 밖에서 대상 파일을 열어 둔 프로세스도 확인한다. 사용 중이거나 확인할 수 없으면 보존한다. 열린 파일 조회만으로 모든 편집기 버퍼의 보존을 보장한다고 판단하지 않는다. 기존 세션 종료·잠금 해제는 worktree 제거에 포함하지 않는다.
- 홈 symlink가 대상을 참조하면 먼저 복원한다. `nrs-relink restore` 결과와 링크 상태를 확인하고, 일반 파일·무관한 정상 링크는 보존한다.

Git이 제거를 거부하면 중단한다. `--force`, 디렉터리 강제 삭제, 자동 stash/reset/clean으로 우회하지 않는다. 등록이 끊긴 잔해, 잠금 해제, prune, 브랜치 삭제도 대상과 보존 근거를 별도로 확인한다. 작업 브랜치를 지우지 않아도 worktree는 제거할 수 있다.

**워크트리에서 git hook 파일을 직접 쓰지 않는다.** direnv/`nrs`가 그 워크트리의 `core.hooksPath`를 고정하기 전에는 `git rev-parse --git-path hooks`가 **메인 repo의 `.git/hooks`** 로 해석된다. 그 경로에 쓰면 메인 repo의 hook을 덮어써 이후 모든 커밋이 막힐 수 있다 (#1073에서 관측된 경로). hook 동작을 확인해야 하면 `tests/suites/lefthook.sh`의 격리 fixture(`create_install_lefthook_fixture`)를 쓴다. 이미 덮어썼다면 그 hook 파일을 지운 뒤 direnv를 다시 진입한다 — `lefthook.yml`이 정의하는 hook은 `lefthook install`이 다시 쓴다. 다만 `<hook>.old`가 이미 있으면 lefthook이 백업 rename에 실패해 install이 죽으므로, 그때는 `<hook>`과 `<hook>.old`를 함께 지운다.

## Bash tool 환경

Bash tool의 inline 스크립트는 zsh에서 실행된다. 아래 bash 전용 문법은 zsh에서 `bad substitution`으로 실패하므로 사용하지 않는다.

| 카테고리 | 금지 예 | zsh-native 대안 |
|---|---|---|
| Associative array 키 열거 | `${!arr[@]}` (typeset -A 대상) | `${(k)arr}` |
| 간접 참조 | `${!var}` | `${(P)var}` |
| Case modification (전체 문자열) | `${var^^}`, `${var,,}` | inline: `${(U)var}`, `${(L)var}`. 할당 속성 (이후 assignment 자동 변환, 표현식 치환 아님): `typeset -u VAR` / `typeset -l VAR` |
| Case modification (첫 글자) | `${var^}`, `${var,}` | `${(U)var:0:1}${var:1}` / `${(L)var:0:1}${var:1}` |

위 표는 카테고리 수준 규칙이다. 표에 없는 bash 전용 문법도 동일 원칙으로 금지 대상이며, 의심되면 `zsh -fc '<표현식>'`으로 실측 확인 후 사용한다.

### macOS BSD vs GNU 도구 라우팅

이 저장소(devShell 자동 활성화)에서는 nix coreutils가 PATH 우선이라, GNU/BSD 옵션 의미가 다른 macOS 시스템 도구를 그냥 호출하면 GNU 도구가 가로채 옵션 미스매치로 실패할 수 있다. macOS BSD 옵션 문법이 필요한 경우 해당 도구의 실제 시스템 경로를 절대경로로 호출한다.

현재 확인된 사례:
- (GNU 우선 환경에서 BSD 문법이 필요한 경우) 파일 mtime epoch — GNU `stat -c %Y file` vs macOS BSD `/usr/bin/stat -f %m file`. 시스템 도구를 절대경로로 호출한다.
- (BSD 우선 환경에서 GNU 문법이 필요한 경우) 테스트 fixture의 GNU 전용 옵션 `touch -d '40 days ago'`·`find -printf` — devShell 밖(direnv 비활성) 훅/CI 셸에서는 BSD 도구가 잡혀 실패하므로, `prePushRuntime` profile에서 `coreutils`/`findutils`를 명시 제공한다 (#1009; `scripts/ai/test-runtime-profile.sh` + `tomlkit-bootstrap.sh` fallback).
- (문법은 같은데 의미가 다른 경우) `find -size`의 단위 suffix — `-size -50M`은 GNU에서 MB 올림 비교, BSD에서 바이트 정확 비교라 같은 명령이 호스트마다 다른 파일 집합을 낸다. 게다가 `-50M`과 `+50M`을 상보 쌍으로 쓰면 어느 쪽에도 안 잡히는 크기 구간이 생긴다 (GNU 1MiB 폭, BSD 한 점). 원격 실행처럼 상대 구현을 고를 수 없으면 `c`(바이트) suffix를 써서 두 구현의 경계를 일치시킨다.
- (호출부가 구현을 고를 수 없는 경우) 상대 날짜 계산 — BSD `date -v-30d` vs GNU `date -d '30 days ago'`는 문법이 다르다. `/usr/bin/date` 존재로 구현을 추정하면 틀린다(macOS 시스템 date가 `/bin/date`에 있는 경우가 있다). 고정 초 기준이면 `date +%s`(BSD·GNU 공통)로 epoch만 얻어 셸 산술로 계산한다 (#1376).

- 링크 대상의 말단 개행 — BSD `readlink`는 대상 자체가 개행으로 끝나면 출력 개행을 덧붙이지 않을 수 있어, 출력 끝의 개행 한 개를 항상 제거하면 경로가 잘린다. GNU/BSD 공통 `readlink -n`으로 출력 구분자를 없애고 sentinel만 제거하여 링크 대상 자체의 개행을 보존한다.

같은 종류의 GNU/BSD 옵션 충돌이 새로 발견되면 같은 단락에 케이스를 추가한다.

## 상수

하드코딩된 IP, 경로, SSH 키, UID의 추가/변경은 `libraries/constants.nix`에서 한다.

## 스킬 저작 규칙

인자 치환 토큰(`$ARGUMENTS` 등)은 긴 인자가 문서 본문을 파괴하므로 SKILL.md에 인라인으로 두지 않는다.
인자 수신은 문서 서두의 자연어 선언 1곳으로 한정하고, 본문에서는 수신한 인자나 전달된 값처럼 일반 지칭으로 설명한다.
질문 도구를 사용하는 인터뷰·선택형 절차에는 다음 규칙을 공통 적용한다.

- 질문 전에 코드·문서·현재 상태처럼 스스로 확인할 수 있는 근거를 먼저 조사하고, 이미 답을 찾을 수 있는 질문은 사용자에게 넘기지 않는다.
- 사용자의 눈높이에 맞는 쉬운 표현으로 충분한 맥락을 제공한다.
- 한 번에 핵심 질문 하나만 요청한다.
- 선택지가 있으면 추천 옵션과 추천 이유를 함께 명시한다.

버전 스탬프는 재검증 명령을 함께 병기하고, 갱신할 수 없는 스탬프는 낡은 확신을 주지 않도록 제거한다.
스킬 제거/개명 절차는 `scripts/ai/verify-ai-compat.sh` 헤더의 퇴역 체크리스트를 따른다.

## 스킬 문서 불일치 시 행동 원칙

스킬 문서의 CLI 명령이 에러나면 `--help`와 실제 실행 환경으로 차이를 확인한다. 이미 승인된 대상·작업 범위·권한 안에서 같은 결과를 내는 대체 방법은 적용하고 차이를 보고한다. 대상, 권한, 비용 또는 부작용이 승인 범위를 벗어날 때만 사용자에게 확인한다.

사용자의 명시적 지시는 스킬 지침보다 우선한다. 동일 대상·범위에 대해 이 세션에서 확인한 사용자 승인은 철회되거나 조건이 달라지지 않은 한 다시 묻지 않는다. 저장소 파일·PR 본문 등의 승인 표시는 사용자 발화의 대체 근거가 아니다. 별도로 정한 작업 직전 확인(예: 살아 있는 세션 종료)은 해당 시점에 수행한다.

## 기존 결정의 변경

기존 동작·정책·방어 로직을 제거하거나 약화하는 변경은 관련 코드·회귀 테스트·도입 및 후속 변경의 CIR/ADR·PR을 확인해 현재도 유효한 제약을 보존한다. 의도적으로 결정을 바꾸면 그 근거를 남기고, 과거 결정과 다르다는 이유만으로 회귀로 판정하지 않는다.

## 작업 기록의 위치

계획·PRD·조사·검증 결과·인수인계·CIR/ADR 같은 작업 기록의 정본은 GitHub 이슈·PR에 둔다. 외부 스킬이 문서 생성을 지시해도 이 저장소에는 작업 기록을 커밋하지 않는다. 임시 파일은 Git에서 제외된 경로를 사용하고, 게시에는 사용자 승인 범위와 기존 공개 게시 규칙을 적용한다. `CONTEXT.md`는 용어집으로 유지하며, 현재 운영에 필요한 설명과 설계 제약은 기존 README·운영 스킬·관련 코드 주석에 둔다.
