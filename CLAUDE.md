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

비대화형(에이전트) 컨텍스트에서 `nrs`는 sudo 캐시가 필요 없다 — macOS는 sudoers NOPASSWD 규칙(darwin-rebuild 한정, `modules/darwin/configuration.nix`의 `security.sudo.extraConfig`)이, NixOS는 `wheelNeedsPassword=false`가 인증을 면제한다. **`sudo -n true`로 실행 가능 여부를 사전 확인하지 마라**: `true`는 NOPASSWD 규칙 밖 명령이라 캐시 없으면 항상 실패하며, nrs 실행 가능성과 무관한 잘못된 프록시다 (2026-07 오진으로 불필요한 사용자 위임 반복 발생). 검증이 필요하면 `sudo -n -ll /run/current-system/sw/bin/darwin-rebuild switch` 출력에 `Options: !authenticate`가 있는지 본다 — rc 기반 판정(`sudo -n -l <cmd>`)은 admin `(ALL) ALL` 규칙 때문에 인증이 필요한 명령에도 rc 0을 주므로 쓰지 않는다. 비TTY에서 `nrs`는 sudo를 `-n`으로 호출하므로 규칙이 깨져도 hang 없이 즉시 실패하고 원인을 안내한다.

home-manager activation 충돌 정책: macOS에서 mkOutOfStoreSymlink target이 외부 프로세스의 atomic rename으로 일반 파일이 되면 `home-manager.backupCommand`가 자가 치유한다 (regular file은 unlink + 콘솔 한 줄 echo, directory는 timestamped backup). 사이드이펙트로, symlink가 깨진 시간 동안 사용자가 home 쪽에서 의도 변경한 내용도 silent 손실될 수 있다 (예: VSCode UI에서 keybinding 추가 후 settings.json이 깨진 상태에서 한 후속 변경). 정상 symlink 흐름에서는 source 직접 수정 = git 추적이 정상 동작한다. 본 정책은 사용자 명시 동의 범위 내. 정책 본체는 `modules/darwin/home.nix`.

## Worktree (wt)

`wt`로 git worktree를 생성/이동/정리한다 (`.claude/worktrees/<dir>`, 현재 HEAD 기준 분기). 비대화형 셸(LLM Bash tool 등)에서는 자동으로 비대화형 모드가 된다 (fzf/번호 선택/tmux attach/tmux 윈도우 전환 비활성; `WT_NONINTERACTIVE=1`로 강제 가능). LLM 하네스가 대화형 셸 snapshot을 주입해 zsh 래퍼 함수가 비대화형 셸에 존재할 수 있으나, 래퍼는 비대화형(WT_NONINTERACTIVE 또는 stdin 비TTY)을 감지하면 `~/.local/bin/wt` 바이너리로 passthrough하므로 아래 규칙은 동일하게 성립한다. 비대화형 사용 규칙:

- 생성: `wt <branch>`. 기존 worktree/브랜치와 충돌하면 비대화형은 **안전하게 실패**하므로 의도를 `--if-exists=reuse|recreate|fail`로 명시한다.
- 이동: 비대화형은 cd 불가 — 경로를 stdout으로 출력하므로 `cd "$(wt cd <name>)"`로 쓴다. 인자 없는 `wt cd`는 실패하니 이름을 지정한다.
- 목록: `wt ls --json` (name/branch/path/pr/dirty/unpushed/current/committedAt/age 구조화 출력, jq 파싱용). `unpushed`는 "정리하면 잃을 커밋이 있는가"를 뜻한다 — squash merge로 원격 브랜치가 사라져 upstream이 없어도, PR이 MERGED이고 그 판정 근거인 OID가 현재 HEAD와 일치하는 동안에는 `false`다 (`lib/wt/git-state.sh`의 `_wt_has_unpushed_risk`). `pr`은 조회 시점 스냅샷이라, 조회 뒤 새 커밋이 생기면 `pr: "MERGED"`와 `unpushed: true`가 함께 나올 수 있다 — 근거가 낡았다는 정상 신호이지 결함이 아니다.
- 정리: `wt cleanup --auto` (MERGED 자동) 또는 `wt cleanup <name>...` (이름 지정). `--yes`는 선정된 대상의 제거 전략을 강제로 바꾼다 — dirty/unpushed 확인을 우회하고, MERGED 무확인 삭제에 붙는 보호(비강제 제거·제거 직전 재확인·ref CAS)를 해제한다. 다만 `--auto`의 후보 선정(dirty·merge 후 추가 커밋은 스킵)과, 그 경로가 삭제 직전에 다시 보는 dirty·근거(조회 이후 HEAD 변경, 근거 기록 부재 포함)는 우회하지 않는다. **정리 대상 worktree 밖(저장소 루트)에서 실행한다** — 자기 자신은 삭제 시 셸의 cwd가 사라지므로 항상 제외된다. `wt`는 제외 사실을 알리고, 그 worktree가 실제 정리 대상(PR MERGED)이거나 이름으로 직접 지정된 경우에는 저장소 루트 재실행 명령도 함께 안내한다.

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
- (문법은 같은데 의미가 다른 경우) `find -size`의 단위 suffix — `-size -50M`은 GNU에서 MB 올림 비교, BSD에서 바이트 정확 비교라 같은 명령이 호스트마다 다른 파일 집합을 낸다. 원격 실행처럼 상대 구현을 고를 수 없으면 `c`(바이트) suffix를 써서 두 구현의 경계를 일치시킨다 (`analyzing-da-sessions`의 corpus size cap 사례).

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

스킬 문서의 CLI 명령이 에러나면 `--help`로 확인 후 차이를 사용자에게 보고.
승인 없이 문서를 우회해 진행하지 않는다.
